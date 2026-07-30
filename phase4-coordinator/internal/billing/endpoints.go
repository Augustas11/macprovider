package billing

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	statsprewarm "github.com/augstar/macprovider-coordinator/internal/stats/prewarm"
	"github.com/rs/zerolog"
)

type tokenValidator interface {
	ValidateToken(ctx context.Context, raw string) (providerID string, ok bool, err error)
}

type tokenUseMarker interface {
	ValidateAndMarkTokenUsed(ctx context.Context, raw string) (providerID string, ok bool, err error)
}

type idlePrewarmReader interface {
	ProviderIdlePrewarm(ctx context.Context, providerID string) (statsprewarm.Summary, error)
}

func (s *Store) Handlers(operatorKey string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int) http.Handler {
	return s.HandlersWithBridge(operatorKey, "", tokenStore, requireProviderTokens, earningsRateLimitPerMin)
}

// HandlersWithQuarantineGate is the SPEC-005 v0.4 (issue #169)
// constructor that lets callers wire the force-void route-layer
// gate (config flag `billing.quarantine_resolution_force_void_enabled`).
// Existing callers MAY continue to use Handlers() — that path
// defaults the gate to false (force-void endpoint returns 404
// regardless of config).
//
// SPEC-005 v0.4 §13.2 mandates that flag-flip audit emission
// (event_type=billing_config_flag_changed) is the responsibility of
// the config-reload caller, not the handler. On SIGHUP / HTTP
// reload, the caller compares old and new config, re-wires this
// Handler with the new value, and emits the audit row through the
// billing store's BeginTx path (see EmitConfigFlagChangedAudit
// below) so it shares atomicity with the ledger_config_snapshots
// row §13.2 already requires.
func (s *Store) HandlersWithQuarantineGate(operatorKey string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int, forceVoidEnabled bool) http.Handler {
	return s.handlersInternal(operatorKey, "", tokenStore, requireProviderTokens, earningsRateLimitPerMin, forceVoidEnabled, false, nil)
}

func (s *Store) HandlersWithQuarantineGateAndIdlePrewarm(operatorKey string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int, forceVoidEnabled bool, idlePrewarm idlePrewarmReader) http.Handler {
	return s.handlersInternal(operatorKey, "", tokenStore, requireProviderTokens, earningsRateLimitPerMin, forceVoidEnabled, false, idlePrewarm)
}

func (s *Store) HandlersWithQuarantineGates(operatorKey string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int, forceVoidEnabled bool, forceCreditEnabled bool) http.Handler {
	return s.handlersInternal(operatorKey, "", tokenStore, requireProviderTokens, earningsRateLimitPerMin, forceVoidEnabled, forceCreditEnabled, nil)
}

func (s *Store) HandlersWithQuarantineGatesAndIdlePrewarm(operatorKey string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int, forceVoidEnabled bool, forceCreditEnabled bool, idlePrewarm idlePrewarmReader) http.Handler {
	return s.handlersInternal(operatorKey, "", tokenStore, requireProviderTokens, earningsRateLimitPerMin, forceVoidEnabled, forceCreditEnabled, idlePrewarm)
}

// HandlersWithBridge mounts the admin/provider handlers. The
// `/admin/ledger/*` endpoints are operator-only (the codex security
// audit on PR #73, HIGH-1, flagged that accepting gateway_service_token
// here would silently grant the gateway human-admin power to read the
// full billing ledger). The gatewayServiceToken parameter is retained
// for backward compatibility with the M3-2 main.go wiring but is no
// longer consulted by `/admin/*` paths — only the operator key is
// accepted. Handlers (the legacy single-arg signature) is kept as a
// thin shim so test fixtures and direct callers don't churn.
func (s *Store) HandlersWithBridge(operatorKey, _gatewayServiceTokenIgnoredAdminOnly string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int) http.Handler {
	return s.handlersInternal(operatorKey, _gatewayServiceTokenIgnoredAdminOnly, tokenStore, requireProviderTokens, earningsRateLimitPerMin, false, false, nil)
}

func (s *Store) handlersInternal(operatorKey, _gatewayServiceTokenIgnoredAdminOnly string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int, forceVoidEnabled bool, forceCreditEnabled bool, idlePrewarm idlePrewarmReader) http.Handler {
	// SPEC-005 v0.4 (issue #169) — handler CONSTRUCTION must not be
	// able to silently flip the live route-layer flag. R8 fix
	// (ARCH-M1) replaces the unconditional SetForceVoidEnabled call
	// with a monotonic CompareAndSwap that only flips false→true on
	// FIRST construction. After any caller (production main.go's
	// startup setter, a prior constructor call, or a SIGHUP reload)
	// has set the atomic, subsequent constructor calls cannot reset
	// it. This is the property the codex ARCH-M1 finding required:
	// a future legacy Handlers() call (default-false) cannot
	// silently disable a production-enabled flag.
	//
	// Production wires up via main.go's explicit
	// SetForceVoidEnabled(ctx, value, "startup") which precedes the
	// handler construction and emits no audit (per §11.6.4 startup
	// carve-out). Tests still pass the desired flag value here for
	// the first-construction init case.
	if forceVoidEnabled {
		s.forceVoidEnabled.CompareAndSwap(false, true)
	}
	if forceCreditEnabled {
		s.forceCreditEnabled.CompareAndSwap(false, true)
	}
	h := &handler{
		store:                   s,
		operatorKey:             operatorKey,
		tokenStore:              tokenStore,
		requireProviderTokens:   requireProviderTokens,
		earningsRateLimitPerMin: earningsRateLimitPerMin,
		lastEarnings:            map[string][]time.Time{},
		adminBucket:             newAdminRateLimiter(),
		idlePrewarm:             idlePrewarm,
		log:                     zerolog.New(os.Stdout).With().Timestamp().Logger(),
	}
	return http.HandlerFunc(h.serveHTTP)
}

type handler struct {
	store                   *Store
	operatorKey             string
	tokenStore              tokenValidator
	requireProviderTokens   bool
	earningsRateLimitPerMin int
	mu                      sync.Mutex
	lastEarnings            map[string][]time.Time
	adminBucket             *adminRateLimiter
	idlePrewarm             idlePrewarmReader
	log                     zerolog.Logger
}

const settlementReceiptDiagnosticsDisclosure = "Settlement receipt diagnostics expose reason codes plus digest/fingerprint identifiers only. Raw receipt envelopes, raw receipt public keys, raw signatures, raw prompts, raw outputs, bearer tokens, receipt private keys, and provider-private state are not exposed."

const settlementReceiptDiagnosticsDefaultWindow = 31 * 24 * time.Hour
const idlePrewarmEarningsReadTimeout = 250 * time.Millisecond

type settlementReceiptSummary struct {
	ReceiptProfile        string                        `json:"receipt_profile"`
	WindowFromUTC         string                        `json:"window_from_utc,omitempty"`
	WindowToUTC           string                        `json:"window_to_utc,omitempty"`
	VerifiedCount         int64                         `json:"verified_count"`
	ZeroSettledCount      int64                         `json:"zero_settled_count"`
	FailedCount           int64                         `json:"failed_count"`
	PendingCount          int64                         `json:"pending_count"`
	DiagnosticsDisclosure string                        `json:"diagnostics_disclosure"`
	RecentFailures        []settlementReceiptDiagnostic `json:"recent_failures"`
}

type settlementReceiptDiagnostic struct {
	RequestID                     string `json:"request_id"`
	AttemptN                      int64  `json:"attempt_n"`
	ReceiptResult                 string `json:"receipt_result"`
	SettlementOutcome             string `json:"settlement_outcome"`
	Reason                        string `json:"reason"`
	ReceivedAtUnixMS              int64  `json:"received_at_unix_ms"`
	DeadlineUnixMS                int64  `json:"deadline_unix_ms"`
	RouteSnapshotDigest           string `json:"route_snapshot_digest"`
	RouteSnapshotPolicyVersion    string `json:"route_snapshot_policy_version"`
	RouteSnapshotMode             string `json:"route_snapshot_mode"`
	PaidEntrypoint                string `json:"paid_entrypoint"`
	Spec008HashStatus             string `json:"spec008_hash_status"`
	ProviderReceiptKeyFingerprint string `json:"provider_receipt_key_fingerprint"`
	CatalogBodyDigest             string `json:"catalog_body_digest"`
	ProviderReportedModelHash     string `json:"provider_reported_model_hash"`
	ExpectedCatalogModelHash      string `json:"expected_catalog_model_hash"`
	ModelID                       string `json:"model_id"`
	ModelHash                     string `json:"model_hash"`
	PromptHash                    string `json:"prompt_hash"`
	OutputHash                    any    `json:"output_hash"`
	UsageDigest                   any    `json:"usage_digest"`
	ReceiptTupleCanonicalSHA256   any    `json:"receipt_tuple_canonical_sha256"`
}

type settlementVerdictCounter struct {
	PolicyVersion string `json:"policy_version"`
	// PendingDeadlineSeconds is the EFFECTIVE per-request settlement deadline
	// (settlement.pending_deadline_seconds) captured on the route snapshot, not
	// derivable from PolicyVersion — a runtime SIGHUP that changes the deadline
	// keeps the same policy-version literal (SPEC-022 "Known limitations (B)"),
	// so counters are disaggregated by this to avoid merging deadline regimes. 0
	// when the verdict's route snapshot row is absent (LEFT JOIN miss).
	PendingDeadlineSeconds  int64  `json:"pending_deadline_seconds"`
	ModelID                 string `json:"model_id"`
	Entrypoint              string `json:"entrypoint"`
	ReasonCode              string `json:"reason_code"`
	VerifiedCount           int64  `json:"verified_count"`
	PendingCount            int64  `json:"pending_count"`
	QuarantinedCount        int64  `json:"quarantined_count"`
	ZeroSettledCount        int64  `json:"zero_settled_count"`
	LegacyReceiptCount      int64  `json:"legacy_receipt_count"`
	MissingReceiptCount     int64  `json:"missing_receipt_count"`
	CatalogMismatchCount    int64  `json:"catalog_mismatch_count"`
	ModelHashNullCount      int64  `json:"model_hash_null_count"`
	ReceiptKeyMismatchCount int64  `json:"receipt_key_mismatch_count"`
}

func (h *handler) serveHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/admin/ledger/quarantine" {
		h.quarantineListHandler(w, r)
		return
	}
	// SPEC-005 v0.4 §11.6 quarantine surface (issue #169).
	// matchQuarantinePath distinguishes "not this route" from
	// "matched route + bad id" so we can emit 400 (not 404) per
	// §11.6.1.1.
	if m := matchQuarantinePath(r.URL.Path); m.matched {
		// R3 fix (SEC-M1): when the route-layer flag is disabled the
		// endpoint must be byte-indistinguishable from a non-existent
		// route — return 404 universally BEFORE method or id-shape
		// checks. Otherwise GET / PUT / bad-id requests leak route
		// existence via 405 / 400 even when the operator has not
		// turned the surface on.
		enabled := h.store.ForceVoidEnabled()
		if m.kind == "force-credit" {
			enabled = h.store.ForceCreditEnabled()
		}
		if !enabled {
			if auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
				if !h.allowAdminRequest(w) {
					return
				}
			}
			writeError(w, http.StatusNotFound, "not_found", "not found")
			return
		}
		if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
			writeError(w, http.StatusForbidden, "forbidden", "operator key required")
			return
		}
		if !h.allowAdminRequest(w) {
			return
		}
		if r.Method != http.MethodPost {
			writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		if m.badID {
			writeError(w, http.StatusBadRequest, "bad_request", "request_credit_id must be a base-10 int64")
			return
		}
		switch m.kind {
		case "force-void":
			h.forceVoidHandler(w, r, m.id)
			return
		case "force-credit":
			h.forceCreditHandler(w, r, m.id)
			return
		}
	}
	switch {
	case r.URL.Path == "/admin/ledger/summary":
		h.admin(w, r, h.summary)
	case r.URL.Path == "/admin/ledger/providers":
		h.admin(w, r, h.providers)
	case r.URL.Path == "/admin/ledger/reconcile":
		h.admin(w, r, h.reconcile)
	case strings.HasPrefix(r.URL.Path, "/admin/ledger/"):
		h.adminNotFound(w, r)
	case strings.HasPrefix(r.URL.Path, "/providers/") && strings.HasSuffix(r.URL.Path, "/earnings"):
		h.earnings(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func (h *handler) quarantineListHandler(w http.ResponseWriter, r *http.Request) {
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	if !h.allowAdminRequest(w) {
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	status := r.URL.Query().Get("status")
	if status == "" {
		status = "open"
	}
	if status != "open" {
		writeError(w, http.StatusBadRequest, "bad_request", "status must be open")
		return
	}
	limit := 500
	if rawLimit := r.URL.Query().Get("limit"); rawLimit != "" {
		parsed, err := strconv.Atoi(rawLimit)
		if err != nil || parsed <= 0 || parsed > 500 {
			writeError(w, http.StatusBadRequest, "bad_request", "limit must be between 1 and 500")
			return
		}
		limit = parsed
	}
	cursorTS := ""
	cursorID := int64(0)
	if rawCursor := r.URL.Query().Get("cursor"); rawCursor != "" {
		cursor, err := decodeQuarantineListCursor(rawCursor)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "bad cursor")
			return
		}
		cursorTS = cursor.TS
		cursorID = cursor.ID
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rows, err := h.store.db.QueryContext(ctx, `
SELECT id, request_id, attempt_n, provider_id, ts_utc, quarantine_reason
  FROM ledger_request_credits lrc
 WHERE lrc.quarantined = 1
   AND NOT EXISTS (
       SELECT 1 FROM ledger_quarantine_resolutions lqr
        WHERE lqr.request_credit_id = lrc.id
   )
   AND (? = '' OR lrc.ts_utc < ? OR (lrc.ts_utc = ? AND lrc.id < ?))
 ORDER BY ts_utc DESC, id DESC
 LIMIT ?`, cursorTS, cursorTS, cursorTS, cursorID, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "query quarantine list: "+err.Error())
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id int64
		var requestID string
		var attemptN int64
		var providerID string
		var tsUTC string
		var quarantineReason sql.NullString
		if err := rows.Scan(&id, &requestID, &attemptN, &providerID, &tsUTC, &quarantineReason); err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", "scan quarantine list: "+err.Error())
			return
		}
		items = append(items, map[string]any{
			"request_credit_id": id,
			"request_id":        requestID,
			"attempt_n":         attemptN,
			"provider_id":       providerID,
			"ts_utc":            tsUTC,
			"quarantine_reason": nullStringOrNil(quarantineReason),
		})
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "read quarantine list: "+err.Error())
		return
	}
	var nextCursor any
	if len(items) > limit {
		last := items[limit-1]
		if ts, _ := last["ts_utc"].(string); ts != "" {
			if id, ok := last["request_credit_id"].(int64); ok {
				nextCursor = encodeQuarantineListCursor(quarantineListCursor{TS: ts, ID: id})
			}
		}
		items = items[:limit]
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      status,
		"count":       len(items),
		"items":       items,
		"next_cursor": nextCursor,
	})
}

type quarantineListCursor struct {
	TS string `json:"ts"`
	ID int64  `json:"id"`
}

func decodeQuarantineListCursor(raw string) (quarantineListCursor, error) {
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return quarantineListCursor{}, err
	}
	var cursor quarantineListCursor
	if err := json.Unmarshal(b, &cursor); err != nil {
		return quarantineListCursor{}, err
	}
	if cursor.TS == "" || cursor.ID <= 0 {
		return quarantineListCursor{}, errors.New("invalid cursor")
	}
	if _, err := time.Parse(time.RFC3339Nano, cursor.TS); err != nil {
		return quarantineListCursor{}, err
	}
	return cursor, nil
}

func encodeQuarantineListCursor(cursor quarantineListCursor) string {
	b, err := json.Marshal(cursor)
	if err != nil {
		return ""
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

func (h *handler) admin(w http.ResponseWriter, r *http.Request, fn func(http.ResponseWriter, *http.Request)) {
	// /admin/ledger/* is operator-only (codex PR #73 HIGH-1 fix). The
	// gateway service token is intentionally NOT accepted here so a
	// compromised gateway can't pivot to billing-ledger reads. Empty
	// operator_key still means DENY (M1-5 / SECU-5).
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	if !h.allowAdminRequest(w) {
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	h.log.Info().
		Str("event", "internal_bearer_accepted").
		Str("key", "operator_key").
		Str("path", r.URL.Path).
		Str("remote_addr", r.RemoteAddr).
		Msg("internal bearer accepted")
	fn(w, r)
}

func (h *handler) adminNotFound(w http.ResponseWriter, r *http.Request) {
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	if !h.allowAdminRequest(w) {
		return
	}
	writeError(w, http.StatusNotFound, "not_found", "not found")
}

func (h *handler) allowAdminRequest(w http.ResponseWriter) bool {
	if h.adminBucket.Allow() {
		return true
	}
	writeError(w, http.StatusTooManyRequests, "rate_limited", "admin rate limit exceeded")
	return false
}

func (h *handler) summary(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	settlementVerdictCounters, err := h.settlementVerdictCounters(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	current := sqliteTimeText(currentMondayUTC(time.Now().UTC()))
	resp := map[string]any{
		"total_gross_credits":             h.sum(ctx, `SELECT SUM(gross_credits) FROM spec022_payable_request_credits`),
		"total_provider_credits":          h.sum(ctx, `SELECT SUM(provider_credits) FROM spec022_payable_request_credits`),
		"total_operator_credits":          h.sum(ctx, `SELECT SUM(gross_credits - provider_credits) FROM spec022_payable_request_credits`),
		"current_window_provider_credits": h.sum(ctx, `SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE `+sqliteTimeSince("ts_utc"), current),
		"pending_payout_count":            h.sum(ctx, `SELECT COUNT(*) FROM ledger_payout_ready WHERE status='ready'`),
		"pending_payout_credits":          h.sum(ctx, `SELECT SUM(provider_credits) FROM ledger_payout_ready WHERE status='ready'`),
		// SPEC-005 v0.4 §11.6.5 OPEN_PREDICATE — `quarantined_count`
		// surfaces ONLY open quarantines (not force_void-resolved).
		// Force-voided rows are resolved-and-excluded.
		"quarantined_count": h.sum(ctx, `
SELECT COUNT(*) FROM ledger_request_credits lrc
 WHERE lrc.quarantined=1
   AND NOT EXISTS (SELECT 1 FROM ledger_quarantine_resolutions r
                    WHERE r.request_credit_id = lrc.id)`),
		"fault_count":                       h.sum(ctx, `SELECT COUNT(*) FROM ledger_request_credits WHERE fault_flag != 'none'`),
		"last_reconciliation_delta_credits": h.sum(ctx, `SELECT reconciliation_delta_credits FROM ledger_reconciliation_runs ORDER BY started_at_utc DESC, id DESC LIMIT 1`),
		"settlement_verdict_counters":       settlementVerdictCounters,
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *handler) providers(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			limit = n
		}
	}
	if limit > 200 {
		limit = 200
	}
	cursor := r.URL.Query().Get("cursor")
	includeQuarantined := r.URL.Query().Get("include_quarantined") == "true"
	current := sqliteTimeText(currentMondayUTC(time.Now().UTC()))
	// R2 fix (CODE-H4): payable aggregates ALWAYS exclude quarantined
	// rows (CASE on lrc.quarantined=0); quarantined_count ALWAYS uses
	// OPEN_PREDICATE (quarantined=1 AND no resolution row).
	// include_quarantined now controls only whether providers that
	// have ONLY quarantined credits appear in the listing, via a
	// HAVING clause on payable-row count. The aggregate columns no
	// longer change shape based on the query parameter.
	havingClause := ""
	if !includeQuarantined {
		havingClause = " HAVING SUM(CASE WHEN payable.id IS NOT NULL THEN 1 ELSE 0 END) > 0 "
	}
	// Single grouped LEFT JOIN — the prior shape was outer-aggregate +
	// per-row h.sum(...) on ledger_payout_ready, which (a) deadlocked at
	// MaxOpenConns(1) on the requestlog-shared pool (issue #21 / ARCH-3),
	// (b) was an N+1 with up to limit*2 statements serialized on the only
	// connection, (c) wasn't snapshot-consistent (the per-row sum could
	// observe a different write than the aggregate above it), and (d)
	// silently emitted pending_payout_credits=0 on a per-row inner-query
	// error because h.sum swallows errors. Folding the pending-payout
	// total into a grouped subquery joined on provider_id fixes all four
	// at once — one statement, one connection acquisition, point-in-time
	// consistent within the SQLite read transaction, errors propagate.
	// The grouped subquery scans ledger_payout_ready once for the whole
	// page, which is strictly cheaper than the per-provider sum loop.
	rows, err := h.store.db.QueryContext(ctx, `
SELECT lrc.provider_id,
       SUM(CASE WHEN payable.id IS NOT NULL THEN payable.provider_credits ELSE 0 END),
       SUM(CASE WHEN payable.id IS NOT NULL AND `+sqliteTimeSince("payable.ts_utc")+` THEN payable.provider_credits ELSE 0 END),
       MAX(lrc.ts_utc),
       SUM(CASE WHEN lrc.fault_flag != 'none' THEN 1 ELSE 0 END),
       SUM(CASE WHEN lrc.quarantined=1 AND NOT EXISTS (
             SELECT 1 FROM ledger_quarantine_resolutions r WHERE r.request_credit_id = lrc.id
       ) THEN 1 ELSE 0 END),
       MAX(lrc.attestation_class),
       COALESCE(pp.pending_payout, 0) AS pending_payout
  FROM ledger_request_credits lrc
  LEFT JOIN spec022_payable_request_credits payable ON payable.id = lrc.id
  LEFT JOIN (
        SELECT provider_id, SUM(provider_credits) AS pending_payout
          FROM ledger_payout_ready
         WHERE status = 'ready'
         GROUP BY provider_id
  ) pp ON pp.provider_id = lrc.provider_id
 WHERE lrc.provider_id > ?
 GROUP BY lrc.provider_id`+havingClause+`
 ORDER BY lrc.provider_id
 LIMIT ?`, current, cursor, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	defer rows.Close()
	items := make([]map[string]any, 0, limit)
	nextCursor := any(nil)
	for rows.Next() {
		var providerID string
		var total, currentWindow, faultCount, quarantinedCount, pendingPayout sql.NullInt64
		var lastActivity, attestation sql.NullString
		if err := rows.Scan(&providerID, &total, &currentWindow, &lastActivity, &faultCount, &quarantinedCount, &attestation, &pendingPayout); err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return
		}
		if len(items) == limit {
			nextCursor = items[len(items)-1]["provider_id"]
			break
		}
		items = append(items, map[string]any{
			"provider_id":            providerID,
			"total_provider_credits": nullInt(total),
			"current_window_credits": nullInt(currentWindow),
			"pending_payout_credits": nullInt(pendingPayout),
			"last_activity_utc":      nullStringAny(lastActivity),
			"fault_count":            nullInt(faultCount),
			"quarantined_count":      nullInt(quarantinedCount),
			"attestation_class":      nullStringAny(attestation),
		})
	}
	if err := rows.Err(); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	if err := rows.Close(); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	providerIDs := make([]string, 0, len(items))
	for _, item := range items {
		if providerID, ok := item["provider_id"].(string); ok {
			providerIDs = append(providerIDs, providerID)
		}
	}
	diagnosticsFrom, diagnosticsTo := settlementReceiptDiagnosticsWindow(time.Now().UTC(), time.Time{}, time.Time{}, false)
	summaries, err := h.settlementReceiptSummariesForProviders(ctx, providerIDs, diagnosticsFrom, diagnosticsTo, true, 3)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	for _, item := range items {
		providerID, _ := item["provider_id"].(string)
		item["settlement_receipts"] = summaries[providerID]
	}
	writeJSON(w, http.StatusOK, map[string]any{"providers": items, "next_cursor": nextCursor})
}

func (h *handler) reconcile(w http.ResponseWriter, r *http.Request) {
	fromRaw, toRaw := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	fromDay, err1 := time.Parse("2006-01-02", fromRaw)
	toDay, err2 := time.Parse("2006-01-02", toRaw)
	if fromRaw == "" || toRaw == "" || err1 != nil || err2 != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "from and to must be YYYY-MM-DD")
		return
	}
	from, to := fromDay.UTC(), toDay.UTC()
	if !to.After(from) || to.Sub(from) > 31*24*time.Hour {
		writeError(w, http.StatusBadRequest, "invalid_request", "reconcile range must be > 0 and <= 31 days")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rowsScanned, err := h.sumErr(ctx, `SELECT COUNT(*) FROM request_log WHERE `+sqliteTimeRange("ts_utc"), sqliteTimeText(from), sqliteTimeText(to))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	providerGross, err := h.sumErr(ctx, `SELECT SUM(gross_credits) FROM spec022_payable_request_credits WHERE `+sqliteTimeRange("ts_utc"), sqliteTimeText(from), sqliteTimeText(to))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	buyerEquivalent, err := h.buyerEquivalentCredits(ctx, from, to)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	splitDelta, err := h.sumErr(ctx, `
SELECT COUNT(*)
  FROM spec022_payable_request_credits lrc
  LEFT JOIN ledger_operator_credits loc ON loc.request_credit_id = lrc.id
 WHERE `+sqliteTimeRange("lrc.ts_utc")+`
   AND (loc.id IS NULL OR lrc.provider_credits + loc.operator_credits != lrc.gross_credits)`,
		sqliteTimeText(from), sqliteTimeText(to))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	rowsRecovered := int64(0)
	// SPEC-005 v0.4 §11.6.5 OPEN_PREDICATE — narrow rows_quarantined
	// to open quarantines only (force-voided rows are resolved-and-
	// excluded).
	rowsQuarantined, err := h.sumErr(ctx, `
SELECT COUNT(*) FROM ledger_request_credits lrc
 WHERE `+sqliteTimeRange("lrc.ts_utc")+` AND lrc.quarantined=1
   AND NOT EXISTS (SELECT 1 FROM ledger_quarantine_resolutions r
                    WHERE r.request_credit_id = lrc.id)`,
		sqliteTimeText(from), sqliteTimeText(to))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	// SPEC-005 v0.4 §11.6.5 — new mandatory reconcile field. Counts
	// `force_void` resolutions with created_at_utc in [from, to);
	// v0.5 will widen to include `force_credit`.
	rowsForceResolved, err := h.sumErr(ctx, `
SELECT COUNT(*) FROM ledger_quarantine_resolutions
 WHERE `+sqliteTimeRange("created_at_utc"),
		sqliteTimeText(from), sqliteTimeText(to))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	delta := providerGross - buyerEquivalent
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := h.store.db.ExecContext(ctx, `
INSERT INTO ledger_reconciliation_runs (
    run_type, from_utc, to_utc, request_log_rows_scanned,
    missing_credit_rows_created, orphan_credit_rows_quarantined,
    buyer_equivalent_credits, provider_gross_credits,
    reconciliation_delta_credits, started_at_utc, finished_at_utc, status,
    error, created_at_utc
) VALUES ('admin_reconcile', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'complete', NULL, ?)`,
		from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano), rowsScanned,
		rowsRecovered, rowsQuarantined, buyerEquivalent, providerGross, delta, now, now, now,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"from_utc":                     from.Format(time.RFC3339),
		"to_utc":                       to.Format(time.RFC3339),
		"buyer_equivalent_credits":     buyerEquivalent,
		"provider_gross_credits":       providerGross,
		"delta_gross_credits":          delta,
		"split_delta_rows":             splitDelta,
		"rows_scanned":                 rowsScanned,
		"rows_recovered":               rowsRecovered,
		"rows_quarantined":             rowsQuarantined,
		"rows_force_resolved_in_range": rowsForceResolved,
	})
}

func (h *handler) buyerEquivalentCredits(ctx context.Context, from, to time.Time) (int64, error) {
	// Two-pass to avoid nested-cursor deadlock at MaxOpenConns(1). Issue #21 /
	// ARCH-3: the prior loop held the request_log cursor open while running
	// h.byteEstimatedLedgerGross(...) and h.store.snapshotAt(...) per row,
	// both of which Query against the same shared *sql.DB. At cap=1 the
	// inner Query blocks on the pinned connection. Drain the request_log
	// scan into a typed scratch slice, close the cursor, then run the
	// per-row work.
	// Carry the raw ts text through the first pass — the second pass
	// applies the 503 filter BEFORE parsing, mirroring origin/main's
	// behavior (a malformed ts on a 503 row was ignored, not surfaced as
	// a hard error). The second pass only parses ts for rows that
	// actually contribute to the credit total.
	type requestLogScan struct {
		requestID          string
		tsText             string
		model              string
		providerAssignedID string
		prompt             sql.NullInt64
		cached             sql.NullInt64
		completion         sql.NullInt64
		status             int
		errorCode          sql.NullString
		cacheQuar          sql.NullString
		attemptN           int
	}
	// SPEC-002 v1.5.0 / issue #211 money-path defense-in-depth:
	// the attempt_n subquery scopes by (account_id, request_id)
	// under SQLite `IS` semantics so all three reconciliation
	// sites (hotpath.go, recovery.go, this admin reconcile)
	// compute identical ordinals for the same row. rl.request_id
	// is coordinator-internal (server-minted UUID v4); the
	// buyer-supplied #211 collision class lives on
	// external_request_id and is addressed by the composite
	// reconciliation key. Account scoping here is defense-in-depth
	// against any future internal-request_id recurrence; NULL-
	// account_id legacy rows cluster among themselves only,
	// preserving pre-v1.5.0 behavior.
	rows, err := h.store.db.QueryContext(ctx, `
SELECT rl.request_id, rl.ts_utc, rl.model, COALESCE(rl.provider_assigned_id, ''), rl.prompt_tokens, rl.cached_prompt_tokens, rl.completion_tokens, rl.status, rl.error_code, rl.cache_quarantine_reason,
       -- SPEC-002 v1.5.2 / SPEC-005 v0.3.3 (issue #168): prefer
       -- persisted rl.attempt_n when non-NULL; fall back to v0.3.1
       -- id-ASC derivation for legacy NULL rows during rollout.
       COALESCE(rl.attempt_n, (
         SELECT COUNT(*) - 1 FROM request_log prior
          WHERE prior.account_id IS rl.account_id
            AND prior.request_id = rl.request_id
            AND prior.id <= rl.id
       ), 0) AS attempt_n
  FROM request_log rl
 WHERE `+sqliteTimeRange("rl.ts_utc")+`
 ORDER BY rl.ts_utc, rl.id`, sqliteTimeText(from), sqliteTimeText(to))
	if err != nil {
		return 0, err
	}
	scratch := []requestLogScan{}
	for rows.Next() {
		var s requestLogScan
		if err := rows.Scan(&s.requestID, &s.tsText, &s.model, &s.providerAssignedID, &s.prompt, &s.cached, &s.completion, &s.status, &s.errorCode, &s.cacheQuar, &s.attemptN); err != nil {
			rows.Close()
			return 0, err
		}
		scratch = append(scratch, s)
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		return 0, err
	}
	rows.Close()

	total := int64(0)
	for _, s := range scratch {
		if s.status == http.StatusServiceUnavailable {
			continue
		}
		if s.cacheQuar.Valid && s.cacheQuar.String != "" {
			continue
		}
		ts, err := time.Parse(time.RFC3339Nano, s.tsText)
		if err != nil {
			return 0, err
		}
		var pp, cachedP, cp *int64
		if s.prompt.Valid {
			v := s.prompt.Int64
			pp = &v
		}
		if invalidRecoveryCached(s.prompt, s.cached) {
			continue
		}
		if s.cached.Valid && s.attemptN == 0 {
			v := s.cached.Int64
			cachedP = &v
		}
		if s.completion.Valid {
			v := s.completion.Int64
			cp = &v
		}
		if gross, ok, err := h.byteEstimatedLedgerGross(ctx, s.requestID, s.attemptN); err != nil {
			return 0, err
		} else if ok {
			total += gross
			continue
		}
		var rewards RewardsConfig
		var multiplier, share int64
		configSnapshotID, found, err := h.providerIdentityConfigSnapshotID(ctx, s.requestID, s.attemptN, s.providerAssignedID)
		if err != nil {
			return 0, err
		}
		if found {
			rewards, multiplier, share, err = snapshotByIDQueryer(ctx, h.store.db, configSnapshotID)
		} else if s.cached.Valid && s.cached.Int64 > 0 && s.attemptN == 0 {
			continue
		} else {
			_, rewards, multiplier, share, err = h.store.snapshotAt(ctx, ts)
		}
		if err != nil {
			continue
		}
		row := ComputeCreditsWithCache(pp, cachedP, cp, nil, usageFor(s.errorCode.String, nil), FaultNone, RateFor(rewards.RateCard, s.model), multiplier, share)
		total += row.GrossCredits
	}
	return total, nil
}

func (h *handler) providerIdentityConfigSnapshotID(ctx context.Context, requestID string, attemptN int, providerAssignedID string) (int64, bool, error) {
	var id sql.NullInt64
	err := h.store.db.QueryRowContext(ctx, `
SELECT config_snapshot_id
  FROM ledger_provider_identity_snapshots
 WHERE request_id = ? AND attempt_n = ? AND provider_assigned_id = ?
 ORDER BY id DESC
 LIMIT 1`, requestID, attemptN, providerAssignedID).Scan(&id)
	if err == sql.ErrNoRows {
		return 0, false, nil
	}
	if err != nil {
		return 0, false, err
	}
	return id.Int64, id.Valid, nil
}

func (h *handler) byteEstimatedLedgerGross(ctx context.Context, requestID string, attemptN int) (int64, bool, error) {
	rows, err := h.store.db.QueryContext(ctx, `
SELECT gross_credits
  FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND quarantined = 0 AND usage_source = 'byte_estimated'`, requestID, attemptN)
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()
	count := 0
	var gross int64
	for rows.Next() {
		count++
		if count > 1 {
			return 0, false, nil
		}
		if err := rows.Scan(&gross); err != nil {
			return 0, false, err
		}
	}
	if err := rows.Err(); err != nil {
		return 0, false, err
	}
	if count != 1 {
		return 0, false, nil
	}
	return gross, true, nil
}

func (h *handler) earnings(w http.ResponseWriter, r *http.Request) {
	if !h.requireProviderTokens {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "provider tokens not enabled")
		return
	}
	providerID := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/providers/"), "/earnings")
	raw := bearer(r.Header.Get("Authorization"))
	if raw == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return
	}
	if h.tokenStore == nil {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "provider tokens not available")
		return
	}
	marker, canMark := h.tokenStore.(tokenUseMarker)
	if !canMark {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "provider token use marker not available")
		return
	}
	subject, ok, err := marker.ValidateAndMarkTokenUsed(r.Context(), raw)
	if err != nil || !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return
	}
	if subject != providerID {
		writeError(w, http.StatusForbidden, "forbidden", "provider token subject mismatch")
		return
	}
	if !h.allowEarnings(providerID) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "provider earnings rate limit exceeded")
		return
	}
	if h.sum(r.Context(), `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=?`, providerID) == 0 {
		writeError(w, http.StatusNotFound, "not_found", "provider not found")
		return
	}
	rangeFrom, rangeTo, hasRange, err := parseOptionalDayRange(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	rangeSQL, rangeArgs := earningsRangeFilter(rangeFrom, rangeTo, hasRange)
	nowUTC := time.Now().UTC()
	current := sqliteTimeText(currentMondayUTC(nowUTC))
	todayUTC := sqliteTimeText(time.Date(nowUTC.Year(), nowUTC.Month(), nowUTC.Day(), 0, 0, 0, 0, time.UTC))
	models := h.modelsServed(r.Context(), providerID, rangeSQL, rangeArgs...)
	totalArgs := append([]any{providerID}, rangeArgs...)
	currentArgs := append([]any{providerID, current}, rangeArgs...)
	todayArgs := append([]any{providerID, todayUTC}, rangeArgs...)
	faultArgs := append([]any{providerID}, rangeArgs...)

	// Payable provider_credits for the range-scoped total plus the two rolling
	// windows the Malibu card shows. current_window == "this week" (since Monday
	// UTC); today == since midnight UTC. These honour any from/to range.
	totalCredits := h.sum(r.Context(), `SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=?`+rangeSQL, totalArgs...)
	weekCredits := h.sum(r.Context(), `SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=? AND `+sqliteTimeSince("ts_utc")+rangeSQL, currentArgs...)
	todayCredits := h.sum(r.Context(), `SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=? AND `+sqliteTimeSince("ts_utc")+rangeSQL, todayArgs...)
	// "Pending" = all USDC currently owed to the provider (earned, payout-
	// eligible, not yet paid). It is a lifetime, range-INDEPENDENT figure — a
	// from/to filter narrows the today/week/lifetime views but must never make
	// owed money appear smaller — so it deliberately ignores rangeSQL. The
	// SPEC-016 payout pipeline is default-off / not deployed, so no payable
	// credit has been paid yet and every payable credit is still owed. When
	// payouts go live, this must subtract only CONFIRMED, non-reorged/non-
	// orphaned payouts (payout reorg/orphan compensation is tracked outside
	// ledger_payout_ready — see internal/payout/reorg.go, orphans.go); a naive
	// `status NOT IN ('ready','voided')` subtraction would UNDERSTATE owed money
	// after an unresolved orphan, so it is intentionally not done here.
	pendingCredits := h.sum(r.Context(), `SELECT SUM(provider_credits) FROM spec022_payable_request_credits WHERE provider_id=?`, providerID)

	resp := map[string]any{
		"provider_id":            providerID,
		"total_credits":          totalCredits,
		"current_window_credits": weekCredits,
		"last_payout_ready":      h.lastPayout(r.Context(), providerID),
		"provider_share_bps":     h.latestShareBps(r.Context()),
		"models_served":          models,
		"rate_card_excerpt":      h.rateCardExcerpt(r.Context(), models),
		"fault_count":            h.sum(r.Context(), `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=? AND fault_flag != 'none'`+rangeSQL, faultArgs...),
		// usdc_* are the USD figures the Malibu client (ProviderEarningsClient)
		// decodes for the "today / wk / pending / life" card. Before this the
		// endpoint emitted only *_credits, so every card read $0.00 regardless
		// of real accrued earnings. Converted via the SPEC-016 §4.3 payout
		// invariant (provider_credits == USDC base units, 6 decimals), so the
		// displayed amount equals what the payout runner actually pays — not a
		// tunable stats display rate that could diverge from real payouts.
		"usdc_today":    providerCreditsToUSDC(todayCredits),
		"usdc_week":     providerCreditsToUSDC(weekCredits),
		"usdc_pending":  providerCreditsToUSDC(pendingCredits),
		"usdc_lifetime": providerCreditsToUSDC(totalCredits),
	}
	idlePrewarm := statsprewarm.Summary{
		EventsLast1h:        map[string]int64{},
		SkipsByReasonLast1h: map[string]int64{},
	}
	if h.idlePrewarm != nil {
		idleCtx, cancel := context.WithTimeout(r.Context(), idlePrewarmEarningsReadTimeout)
		idlePrewarm, err = h.idlePrewarm.ProviderIdlePrewarm(idleCtx, providerID)
		cancel()
		if err != nil {
			h.log.Warn().Err(err).Str("provider_id", providerID).Msg("provider idle prewarm summary unavailable")
			idlePrewarm = statsprewarm.Summary{
				EventsLast1h:        map[string]int64{},
				SkipsByReasonLast1h: map[string]int64{},
			}
		}
	}
	resp["idle_prewarm"] = idlePrewarm
	diagnosticsFrom, diagnosticsTo := settlementReceiptDiagnosticsWindow(time.Now().UTC(), rangeFrom, rangeTo, hasRange)
	summaries, err := h.settlementReceiptSummariesForProviders(r.Context(), []string{providerID}, diagnosticsFrom, diagnosticsTo, true, 5)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	resp["settlement_receipts"] = summaries[providerID]
	if hasRange {
		resp["from_utc"] = rangeFrom.Format(time.RFC3339)
		resp["to_utc"] = rangeTo.Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *handler) settlementReceiptSummariesForProviders(ctx context.Context, providerIDs []string, from, to time.Time, hasRange bool, recentLimit int) (map[string]settlementReceiptSummary, error) {
	out := make(map[string]settlementReceiptSummary, len(providerIDs))
	for _, providerID := range providerIDs {
		out[providerID] = settlementReceiptSummary{
			ReceiptProfile:        settlementReceiptProfileV04,
			DiagnosticsDisclosure: settlementReceiptDiagnosticsDisclosure,
			WindowFromUTC:         diagnosticsWindowString(from, hasRange),
			WindowToUTC:           diagnosticsWindowString(to, hasRange),
			RecentFailures:        []settlementReceiptDiagnostic{},
		}
	}
	if len(providerIDs) == 0 {
		return out, nil
	}
	placeholders := sqlPlaceholders(len(providerIDs))
	rangeSQL, rangeArgs := settlementReceiptRangeFilter(from, to, hasRange)
	args := make([]any, 0, len(providerIDs)+len(rangeArgs))
	for _, providerID := range providerIDs {
		args = append(args, providerID)
	}
	args = append(args, rangeArgs...)
	rows, err := h.store.db.QueryContext(ctx, `
SELECT provider_id,
       COALESCE(SUM(CASE WHEN settlement_outcome='verified' AND receipt_result='valid' THEN 1 ELSE 0 END), 0) AS verified_count,
       COALESCE(SUM(CASE WHEN settlement_outcome='zero_settled' AND receipt_result='valid' THEN 1 ELSE 0 END), 0) AS zero_settled_count,
       COALESCE(SUM(CASE WHEN settlement_outcome='quarantined' THEN 1 ELSE 0 END), 0) AS failed_count,
       COALESCE(SUM(CASE WHEN closed=0 THEN 1 ELSE 0 END), 0) AS pending_count
  FROM settlement_receipt_verdicts
 WHERE provider_id IN (`+placeholders+`)`+rangeSQL+`
 GROUP BY provider_id`, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var providerID string
		var summary settlementReceiptSummary
		summary.ReceiptProfile = settlementReceiptProfileV04
		summary.DiagnosticsDisclosure = settlementReceiptDiagnosticsDisclosure
		summary.WindowFromUTC = diagnosticsWindowString(from, hasRange)
		summary.WindowToUTC = diagnosticsWindowString(to, hasRange)
		summary.RecentFailures = []settlementReceiptDiagnostic{}
		if err := rows.Scan(&providerID, &summary.VerifiedCount, &summary.ZeroSettledCount, &summary.FailedCount, &summary.PendingCount); err != nil {
			return nil, err
		}
		out[providerID] = summary
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if err := rows.Close(); err != nil {
		return nil, err
	}
	if recentLimit <= 0 {
		return out, nil
	}

	for _, providerID := range providerIDs {
		recentArgs := make([]any, 0, 1+len(rangeArgs)+1)
		recentArgs = append(recentArgs, providerID)
		recentArgs = append(recentArgs, rangeArgs...)
		recentArgs = append(recentArgs, recentLimit)
		rows, err = h.store.db.QueryContext(ctx, `
SELECT request_id, attempt_n, receipt_result, settlement_outcome,
       reason, received_at_unix_ms, pending_deadline_unix_ms,
       route_snapshot_digest, route_snapshot_policy_version,
       route_snapshot_mode, paid_entrypoint, spec008_hash_status,
       provider_receipt_key_fingerprint, catalog_body_digest,
       provider_reported_model_hash, expected_catalog_model_hash,
       model_id, model_hash, prompt_hash,
       output_hash, usage_digest, receipt_tuple_canonical_sha256
  FROM settlement_receipt_verdicts
 WHERE provider_id = ?`+rangeSQL+`
   AND closed=1
   AND settlement_outcome='quarantined'
 ORDER BY received_at_unix_ms DESC, id DESC
 LIMIT ?`, recentArgs...)
		if err != nil {
			return nil, err
		}
		for rows.Next() {
			var diagnostic settlementReceiptDiagnostic
			var outputHash, usageDigest, tupleDigest sql.NullString
			if err := rows.Scan(
				&diagnostic.RequestID, &diagnostic.AttemptN,
				&diagnostic.ReceiptResult, &diagnostic.SettlementOutcome,
				&diagnostic.Reason, &diagnostic.ReceivedAtUnixMS,
				&diagnostic.DeadlineUnixMS, &diagnostic.RouteSnapshotDigest,
				&diagnostic.RouteSnapshotPolicyVersion,
				&diagnostic.RouteSnapshotMode, &diagnostic.PaidEntrypoint,
				&diagnostic.Spec008HashStatus,
				&diagnostic.ProviderReceiptKeyFingerprint,
				&diagnostic.CatalogBodyDigest,
				&diagnostic.ProviderReportedModelHash,
				&diagnostic.ExpectedCatalogModelHash, &diagnostic.ModelID,
				&diagnostic.ModelHash, &diagnostic.PromptHash,
				&outputHash, &usageDigest, &tupleDigest,
			); err != nil {
				rows.Close()
				return nil, err
			}
			diagnostic.OutputHash = nullStringAny(outputHash)
			diagnostic.UsageDigest = nullStringAny(usageDigest)
			diagnostic.ReceiptTupleCanonicalSHA256 = nullStringAny(tupleDigest)
			summary := out[providerID]
			summary.RecentFailures = append(summary.RecentFailures, diagnostic)
			out[providerID] = summary
		}
		if err := rows.Err(); err != nil {
			rows.Close()
			return nil, err
		}
		if err := rows.Close(); err != nil {
			return nil, err
		}
	}
	return out, nil
}

func settlementReceiptDiagnosticsWindow(now, from, to time.Time, hasRange bool) (time.Time, time.Time) {
	if hasRange {
		return from, to
	}
	to = now.UTC()
	return to.Add(-settlementReceiptDiagnosticsDefaultWindow), to
}

func diagnosticsWindowString(t time.Time, enabled bool) string {
	if !enabled {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func (h *handler) settlementVerdictCounters(ctx context.Context) ([]settlementVerdictCounter, error) {
	// Item 19 / SPEC-022 (B): disaggregate by the EFFECTIVE deadline, not just
	// the coarse route_snapshot_policy_version literal. The verdict row carries
	// only the absolute pending_deadline_unix_ms, so the effective
	// settlement.pending_deadline_seconds is pulled from the route snapshot the
	// verdict was pinned to (joined by digest). The subquery collapses to one
	// deadline per digest (the digest hashes the snapshot incl. the deadline, so
	// this is a defensive dedup against any digest collision — never a fan-out).
	// LEFT JOIN so a verdict whose snapshot row was pruned still reports (as
	// deadline 0), rather than silently dropping from the counters.
	rows, err := h.store.db.QueryContext(ctx, `
SELECT srv.route_snapshot_policy_version,
       COALESCE(srs.pending_deadline_seconds, 0) AS pending_deadline_seconds,
       srv.model_id,
       srv.paid_entrypoint,
       srv.reason,
       COALESCE(SUM(CASE WHEN srv.settlement_outcome='verified' THEN 1 ELSE 0 END), 0) AS verified_count,
       COALESCE(SUM(CASE WHEN srv.settlement_outcome='pending' THEN 1 ELSE 0 END), 0) AS pending_count,
       COALESCE(SUM(CASE WHEN srv.settlement_outcome='quarantined' THEN 1 ELSE 0 END), 0) AS quarantined_count,
       COALESCE(SUM(CASE WHEN srv.settlement_outcome='zero_settled' THEN 1 ELSE 0 END), 0) AS zero_settled_count,
       COALESCE(SUM(CASE
           WHEN srv.reason IN ('unknown_receipt_version', 'legacy_receipt_version')
             OR (srv.receipt_present=1 AND srv.receipt_version IS NOT NULL AND srv.receipt_version NOT IN ('4', 'spec015-v0.4', 'v0.4'))
           THEN 1 ELSE 0 END), 0) AS legacy_receipt_count,
       COALESCE(SUM(CASE
           WHEN srv.receipt_present=0 OR srv.reason IN ('missing_receipt', 'missing_receipt_deadline_elapsed')
           THEN 1 ELSE 0 END), 0) AS missing_receipt_count,
       COALESCE(SUM(CASE
           WHEN srv.reason IN ('catalog_snapshot_mismatch', 'expected_catalog_model_hash_mismatch')
             OR srv.reason LIKE 'catalog_%'
           THEN 1 ELSE 0 END), 0) AS catalog_mismatch_count,
       COALESCE(SUM(CASE
           WHEN srv.reason IN ('model_hash_invalid', 'model_hash_null')
             OR srv.spec008_hash_status IN ('missing', 'null', 'unavailable')
           THEN 1 ELSE 0 END), 0) AS model_hash_null_count,
       COALESCE(SUM(CASE
           WHEN srv.reason IN ('provider_receipt_key_id_invalid', 'provider_receipt_key_id_mismatch', 'receipt_key_mismatch')
           THEN 1 ELSE 0 END), 0) AS receipt_key_mismatch_count
  FROM settlement_receipt_verdicts srv
  LEFT JOIN (
      SELECT route_snapshot_digest, MIN(pending_deadline_seconds) AS pending_deadline_seconds
        FROM settlement_route_snapshots
       GROUP BY route_snapshot_digest
  ) srs ON srs.route_snapshot_digest = srv.route_snapshot_digest
 GROUP BY srv.route_snapshot_policy_version, pending_deadline_seconds, srv.model_id, srv.paid_entrypoint, srv.reason
 ORDER BY srv.route_snapshot_policy_version, pending_deadline_seconds, srv.model_id, srv.paid_entrypoint, srv.reason`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	counters := []settlementVerdictCounter{}
	for rows.Next() {
		var counter settlementVerdictCounter
		if err := rows.Scan(
			&counter.PolicyVersion,
			&counter.PendingDeadlineSeconds,
			&counter.ModelID,
			&counter.Entrypoint,
			&counter.ReasonCode,
			&counter.VerifiedCount,
			&counter.PendingCount,
			&counter.QuarantinedCount,
			&counter.ZeroSettledCount,
			&counter.LegacyReceiptCount,
			&counter.MissingReceiptCount,
			&counter.CatalogMismatchCount,
			&counter.ModelHashNullCount,
			&counter.ReceiptKeyMismatchCount,
		); err != nil {
			return nil, err
		}
		counters = append(counters, counter)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return counters, nil
}

func settlementReceiptRangeFilter(from, to time.Time, enabled bool) (string, []any) {
	if !enabled {
		return "", nil
	}
	return " AND received_at_unix_ms >= ? AND received_at_unix_ms < ?", []any{from.UnixMilli(), to.UnixMilli()}
}

func sqlPlaceholders(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.TrimRight(strings.Repeat("?,", n), ",")
}

func parseOptionalDayRange(r *http.Request) (time.Time, time.Time, bool, error) {
	fromRaw, toRaw := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	if fromRaw == "" && toRaw == "" {
		return time.Time{}, time.Time{}, false, nil
	}
	if fromRaw == "" || toRaw == "" {
		return time.Time{}, time.Time{}, false, errors.New("from and to must be YYYY-MM-DD")
	}
	fromDay, err1 := time.Parse("2006-01-02", fromRaw)
	toDay, err2 := time.Parse("2006-01-02", toRaw)
	if err1 != nil || err2 != nil {
		return time.Time{}, time.Time{}, false, errors.New("from and to must be YYYY-MM-DD")
	}
	from, to := fromDay.UTC(), toDay.UTC()
	if !to.After(from) || to.Sub(from) > 31*24*time.Hour {
		return time.Time{}, time.Time{}, false, errors.New("earnings range must be > 0 and <= 31 days")
	}
	return from, to, true, nil
}

func earningsRangeFilter(from, to time.Time, enabled bool) (string, []any) {
	if !enabled {
		return "", nil
	}
	return " AND " + sqliteTimeRange("ts_utc"), []any{sqliteTimeText(from), sqliteTimeText(to)}
}

func (h *handler) sum(ctx context.Context, query string, args ...any) int64 {
	n, err := h.sumErr(ctx, query, args...)
	if err != nil {
		return 0
	}
	return n
}

func (h *handler) sumErr(ctx context.Context, query string, args ...any) (int64, error) {
	var n sql.NullInt64
	if err := h.store.db.QueryRowContext(ctx, query, args...).Scan(&n); err != nil {
		return 0, err
	}
	if !n.Valid {
		return 0, nil
	}
	return n.Int64, nil
}

func (h *handler) allowEarnings(providerID string) bool {
	if h.earningsRateLimitPerMin <= 0 {
		return true
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	cutoff := time.Now().Add(-time.Minute)
	kept := h.lastEarnings[providerID][:0]
	for _, t := range h.lastEarnings[providerID] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= h.earningsRateLimitPerMin {
		h.lastEarnings[providerID] = kept
		return false
	}
	h.lastEarnings[providerID] = append(kept, time.Now())
	return true
}

func (h *handler) modelsServed(ctx context.Context, providerID string, rangeSQL string, rangeArgs ...any) []string {
	args := append([]any{providerID}, rangeArgs...)
	rows, err := h.store.db.QueryContext(ctx, `SELECT DISTINCT model FROM spec022_payable_request_credits WHERE provider_id=?`+rangeSQL+` ORDER BY model`, args...)
	if err != nil {
		return []string{}
	}
	defer rows.Close()
	models := []string{}
	for rows.Next() {
		var model string
		if rows.Scan(&model) == nil {
			models = append(models, model)
		}
	}
	return models
}

func (h *handler) rateCardExcerpt(ctx context.Context, models []string) map[string]RateCardEntry {
	var raw string
	if err := h.store.db.QueryRowContext(ctx, `SELECT rate_card_json FROM ledger_config_snapshots ORDER BY effective_at_utc DESC, id DESC LIMIT 1`).Scan(&raw); err != nil {
		return map[string]RateCardEntry{}
	}
	var card map[string]RateCardEntry
	if err := json.Unmarshal([]byte(raw), &card); err != nil {
		return map[string]RateCardEntry{}
	}
	out := map[string]RateCardEntry{}
	for _, model := range models {
		out[model] = RateFor(card, model)
	}
	return out
}

func (h *handler) latestShareBps(ctx context.Context) int64 {
	return h.sum(ctx, `SELECT provider_share_bps FROM ledger_config_snapshots ORDER BY effective_at_utc DESC, id DESC LIMIT 1`)
}

func (h *handler) lastPayout(ctx context.Context, providerID string) any {
	row := h.store.db.QueryRowContext(ctx, `
SELECT window_start_utc, window_end_utc, provider_credits, status
  FROM ledger_payout_ready
 WHERE provider_id = ?
 ORDER BY window_end_utc DESC, id DESC LIMIT 1`, providerID)
	var start, end, status string
	var credits int64
	if err := row.Scan(&start, &end, &credits, &status); errors.Is(err, sql.ErrNoRows) {
		return nil
	} else if err != nil {
		return nil
	}
	return map[string]any{
		"window_start_utc": start,
		"window_end_utc":   end,
		"provider_credits": credits,
		"status":           status,
	}
}

func currentMondayUTC(t time.Time) time.Time {
	day := time.Date(t.UTC().Year(), t.UTC().Month(), t.UTC().Day(), 0, 0, 0, 0, time.UTC)
	days := (int(day.Weekday()) - int(time.Monday) + 7) % 7
	return day.AddDate(0, 0, -days)
}

func bearer(auth string) string {
	token, ok := strings.CutPrefix(strings.TrimSpace(auth), "Bearer ")
	if !ok {
		return ""
	}
	return strings.TrimSpace(token)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func billingErrorType(status int) string {
	if status >= 500 {
		return "server_error"
	}
	return "invalid_request_error"
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": message, "type": billingErrorType(status), "param": nil, "code": code}})
}

func nullInt(v sql.NullInt64) int64 {
	if !v.Valid {
		return 0
	}
	return v.Int64
}

func nullStringAny(v sql.NullString) any {
	if !v.Valid {
		return nil
	}
	return v.String
}
