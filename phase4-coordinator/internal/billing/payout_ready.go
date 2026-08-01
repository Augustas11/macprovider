package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// SPEC-005 vX.Y+1 §9.5b `POST /admin/ledger/payout-ready` admin
// endpoint — the SPEC-016 §9.5b HARD prerequisite for the USDC payout
// pipeline's §4.7 reorg-compensation flow.
//
// The endpoint inserts a fresh `ledger_payout_ready` compensation row
// bound (in the SAME BEGIN IMMEDIATE transaction) to the IMMUTABLE
// `payout_reorg_orphans.observed_*` snapshot columns owned by
// SPEC-016. It does NOT set `compensation_settlement_id` — that link
// is written later by `/admin/payout/record-orphan` (the two-call
// flow). The `UNIQUE(idempotency_key)` constraint on
// `ledger_payout_ready` is the double-compensation guard.
//
// This handler MIRRORS the force-void write path in quarantine.go:
// Content-Type / size guards, a dedicated conn running an explicit
// `BEGIN IMMEDIATE` (modernc.org/sqlite's BeginTx does not map to
// IMMEDIATE without a DSN txlock we don't control), a committed bool
// with a deferred ROLLBACK, and the audit_log INSERT through the SAME
// conn so it shares atomicity with the ledger row.

const (
	payoutReadyPath          = "/admin/ledger/payout-ready"
	eventPayoutReadyInserted = "ledger_payout_ready_admin_inserted"
	// payoutReadyActor is a fixed principal marker, NOT the operator
	// bearer secret. The §9.5b.1 contract phrases the audit `actor`
	// field as `actor=operator_key`, meaning the request was
	// authenticated by the operator key — writing the literal secret
	// into a durable audit table would leak it. See NOTE in the
	// handler / implementation report.
	payoutReadyActor = "operator_key"
)

// reorgCompensationKeyRe matches the §9.5b.1 idempotency_key shape;
// the two capture groups are orig_payout_id and orig_attempt_seq.
var reorgCompensationKeyRe = regexp.MustCompile(`^reorg_compensation:(\d+):(\d+)$`)

type payoutReadyRequest struct {
	ProviderID               string `json:"provider_id"`
	GrossCredits             int64  `json:"gross_credits"`
	ProviderCredits          int64  `json:"provider_credits"`
	OperatorCredits          int64  `json:"operator_credits"`
	CadenceDays              int64  `json:"cadence_days"`
	SourceCreditCount        int64  `json:"source_credit_count"`
	MinPayoutCreditsOverride int64  `json:"min_payout_credits_override"`
	IdempotencyKey           string `json:"idempotency_key"`
	WindowStartUTC           string `json:"window_start_utc"`
	WindowEndUTC             string `json:"window_end_utc"`
	Reason                   string `json:"reason"`
}

// payoutReadyHandler implements POST /admin/ledger/payout-ready.
func (h *handler) payoutReadyHandler(w http.ResponseWriter, r *http.Request) {
	// FIX 13 fail-closed: the §5.2 per-payout cap is a money-path
	// blast-radius bound. A legacy / mis-wired construction (any
	// constructor other than HandlersWithQuarantineGatesIdlePrewarmAndPayoutCap
	// passes 0) MUST NOT be able to mount a payout authorizer with an
	// unbounded (cap 0 → everything > 0 rejected, but a future
	// >=-comparison regression could invert that) or absent cap. When
	// the cap is not positively configured we treat the endpoint as
	// NOT MOUNTED — byte-indistinguishable 404 before auth, so a
	// mis-wired binary cannot authorize any compensation at all.
	if h.perPayoutCapBaseUnits <= 0 {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	// Auth (403) → admin rate limit (429) → method (405), per §9.5b.1.
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

	// Body-shape pre-checks before reading (mirror quarantine.go).
	if ct := r.Header.Get("Content-Type"); !isJSONContentType(ct) {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported_media_type", "content-type must be application/json")
		return
	}
	if r.ContentLength > maxBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes+1)
	defer r.Body.Close()

	body, ok := decodePayoutReadyBody(w, r)
	if !ok {
		return
	}

	// §9.5b.1 400s — request-shape validation before touching the DB.
	headerKey := r.Header.Get("Idempotency-Key")
	if headerKey != body.IdempotencyKey {
		writeError(w, http.StatusBadRequest, "bad_request", "Idempotency-Key header must byte-equal body idempotency_key")
		return
	}
	m := reorgCompensationKeyRe.FindStringSubmatch(body.IdempotencyKey)
	if m == nil {
		writeError(w, http.StatusBadRequest, "bad_request", "idempotency_key must match ^reorg_compensation:\\d+:\\d+$")
		return
	}
	// Regex guarantees the two groups are decimal digit runs; the only
	// remaining failure is int64 overflow.
	origPayoutID, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "orig_payout_id overflows int64")
		return
	}
	origAttemptSeq, err := strconv.ParseInt(m[2], 10, 64)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_request", "orig_attempt_seq overflows int64")
		return
	}
	// The idempotency_key MUST be the CANONICAL encoding of the parsed
	// orphan identity. The regex admits leading zeros / non-minimal
	// encodings (e.g. `reorg_compensation:05:1`), which parse to the
	// SAME (payout_id, attempt_seq) yet are DISTINCT TEXT keys — so
	// UNIQUE(idempotency_key) would not collide and the exact-text
	// replay probe would miss, letting two rows bind to one orphan
	// (double-pay). Requiring canonical form makes the text key 1:1 with
	// the orphan identity.
	if body.IdempotencyKey != fmt.Sprintf("reorg_compensation:%d:%d", origPayoutID, origAttemptSeq) {
		writeError(w, http.StatusBadRequest, "bad_request", "non-canonical idempotency_key; leading zeros / non-minimal encodings are rejected")
		return
	}
	if strings.TrimSpace(body.ProviderID) == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "provider_id is required")
		return
	}
	if strings.TrimSpace(body.Reason) == "" {
		writeError(w, http.StatusBadRequest, "bad_request", "reason is required")
		return
	}
	if body.CadenceDays <= 0 {
		writeError(w, http.StatusBadRequest, "bad_request", "cadence_days must be > 0")
		return
	}
	if body.SourceCreditCount <= 0 {
		writeError(w, http.StatusBadRequest, "bad_request", "source_credit_count must be > 0")
		return
	}
	if body.MinPayoutCreditsOverride != 0 {
		writeError(w, http.StatusBadRequest, "bad_request", "min_payout_credits_override must be 0")
		return
	}
	// Synthetic window values must be RFC3339Nano; normalize to the
	// canonical SQLite text form used by every other ledger time column.
	windowStart, okStart := normalizeSQLiteTimeText(body.WindowStartUTC)
	if !okStart {
		writeError(w, http.StatusBadRequest, "bad_request", "window_start_utc must be RFC3339Nano")
		return
	}
	windowEnd, okEnd := normalizeSQLiteTimeText(body.WindowEndUTC)
	if !okEnd {
		writeError(w, http.StatusBadRequest, "bad_request", "window_end_utc must be RFC3339Nano")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	conn, err := h.store.db.Conn(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "acquire conn: "+err.Error())
		return
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "begin immediate: "+err.Error())
		return
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// Idempotent-replay probe (§9.5b.1 lines 4386–4387): a repeated
	// idempotency_key MUST return 409 with the ORIGINAL 201 body,
	// regardless of the orphan's CURRENT state. Once a compensation has
	// been recorded and its orphan resolved/linked, the orphan
	// preconditions below (resolved_at_utc IS NULL → no_matching_orphan;
	// compensation_settlement_id.Valid → already_compensated) would
	// otherwise short-circuit a replay to a 422. Probing the ledger key
	// first makes a true replay win. The UNIQUE-violation path on the
	// INSERT below stays as the concurrency backstop for two first-calls
	// racing before either commits. QueryRowContext closes its Rows, so
	// the dedicated conn stays free for the subsequent statements.
	var replayID int64
	switch err := conn.QueryRowContext(ctx, `
SELECT id FROM ledger_payout_ready WHERE idempotency_key = ?`, body.IdempotencyKey).Scan(&replayID); {
	case err == nil:
		writeJSON(w, http.StatusConflict, map[string]any{"id": replayID})
		return
	case errors.Is(err, sql.ErrNoRows):
		// Fresh key — proceed to orphan preconditions + INSERT.
	default:
		writeError(w, http.StatusInternalServerError, "internal_error", "replay probe: "+err.Error())
		return
	}

	// §9.5b.1 orphan binding — SELECT the IMMUTABLE snapshot columns in
	// the SAME transaction as the INSERT.
	var (
		observedProviderID      string
		observedProviderCredits int64
		observedGrossCredits    int64
		observedAmountBaseUnits int64
		compensationSettlement  sql.NullInt64
		isCancelSelfTransfer    int64
	)
	// JOIN payout_attempts (1:1 on (payout_id, attempt_seq)) to pull
	// is_cancel_self_transfer, which lives on payout_attempts, NOT on
	// payout_reorg_orphans. §9.5b.1 line 4481 requires EXACTLY ONE
	// orphan row: two unresolved orphans with different orphan_tx_hash
	// can coexist for the same (payout_id, attempt_seq) (the partial
	// UNIQUE index keys on orphan_tx_hash too), so we fail closed on
	// multiplicity rather than silently binding to the first. The
	// `resolved_at_utc IS NULL` filter (matching the idx_pro_unresolved
	// compensable set) excludes orphans an operator terminally resolved
	// via /admin/payout/record-orphan — e.g. "no compensation; provider
	// acknowledged" — which leave compensation_settlement_id NULL but
	// MUST NOT mint a payout. A resolved orphan yields 0 rows → the
	// existing no_matching_orphan 422 (fail-closed).
	rows, err := conn.QueryContext(ctx, `
SELECT pro.observed_provider_id, pro.observed_provider_credits, pro.observed_gross_credits,
       pro.observed_amount_base_units, pro.compensation_settlement_id,
       pa.is_cancel_self_transfer
  FROM payout_reorg_orphans pro
  JOIN payout_attempts pa
    ON pa.payout_id = pro.payout_id AND pa.attempt_seq = pro.attempt_seq
 WHERE pro.payout_id = ? AND pro.attempt_seq = ? AND pro.resolved_at_utc IS NULL`, origPayoutID, origAttemptSeq)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "orphan lookup: "+err.Error())
		return
	}
	if !rows.Next() {
		rowsErr := rows.Err()
		rows.Close()
		if rowsErr != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", "orphan lookup: "+rowsErr.Error())
			return
		}
		writeValidationError(w, "no_matching_orphan", "no payout_reorg_orphans row for the idempotency_key")
		return
	}
	if err := rows.Scan(&observedProviderID, &observedProviderCredits, &observedGrossCredits,
		&observedAmountBaseUnits, &compensationSettlement, &isCancelSelfTransfer); err != nil {
		rows.Close()
		writeError(w, http.StatusInternalServerError, "internal_error", "orphan scan: "+err.Error())
		return
	}
	multiple := rows.Next()
	rowsErr := rows.Err()
	// Close the Rows explicitly before issuing further statements on the
	// same dedicated conn — an open Rows on a MaxOpenConns(1) *sql.DB
	// would block the subsequent INSERT / COMMIT on this conn.
	rows.Close()
	if rowsErr != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "orphan lookup: "+rowsErr.Error())
		return
	}
	if multiple {
		writeValidationError(w, "ambiguous_orphan", "multiple unresolved payout_reorg_orphans rows for the idempotency_key")
		return
	}
	if compensationSettlement.Valid {
		writeValidationError(w, "orphan_already_compensated", "orphan already has a compensation_settlement_id")
		return
	}
	// Cancel-self-transfer orphans are NON-compensable: per SPEC-016
	// lines 2043–2048 a cancel self-transfer does not consume
	// ledger_payout_ready and the §9.5b compensation flow does not
	// apply (the §4.3 cancel carve-out). record-orphan writes an orphan
	// row for cancel attempts too, so the endpoint MUST reject them here
	// or it would mint real USDC for a non-compensable event.
	if isCancelSelfTransfer == 1 {
		writeValidationError(w, "orphan_not_compensable", "cancel-self-transfer orphans are not compensable (SPEC-016 §9.5b/§4.3 carve-out)")
		return
	}
	// Binding assertions — name the failed field per §9.5b.1.
	if body.ProviderID != observedProviderID {
		writeOrphanMismatch(w, "provider_id")
		return
	}
	if body.ProviderCredits != observedProviderCredits {
		writeOrphanMismatch(w, "provider_credits")
		return
	}
	// The compensation gross MUST equal the observed PROVIDER credits
	// (operator share is pinned to 0), NOT observed_gross_credits.
	if body.GrossCredits != observedProviderCredits {
		writeOrphanMismatch(w, "gross_credits")
		return
	}
	if body.OperatorCredits != 0 {
		writeOrphanMismatch(w, "operator_credits")
		return
	}
	_ = observedGrossCredits    // recorded for audit trail; not a target
	_ = observedAmountBaseUnits // recorded for audit trail; not a target

	// Provider must exist in provider_tokens (§9.5b.1 422).
	var providerExists int
	if err := conn.QueryRowContext(ctx, `
SELECT EXISTS(SELECT 1 FROM provider_tokens WHERE provider_id = ?)`, body.ProviderID).Scan(&providerExists); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "provider lookup: "+err.Error())
		return
	}
	if providerExists == 0 {
		writeValidationError(w, "provider_not_found", "provider_id not found in provider_tokens")
		return
	}
	// STRICT equality gross == provider (v0.1.8; §9.5b.1). Redundant
	// with the binding checks above (both pin to observed_provider_credits)
	// but asserted explicitly so a future binding change cannot silently
	// admit gross != provider skimming into reconciliation drift.
	if body.GrossCredits != body.ProviderCredits {
		writeValidationError(w, "gross_provider_mismatch", "gross_credits must strictly equal provider_credits")
		return
	}
	// §5.2 per-payout cap. 1 credit == 1 USDC base unit (C3 invariant),
	// so no unit conversion.
	if body.ProviderCredits > h.perPayoutCapBaseUnits {
		writeValidationError(w, "per_payout_cap_exceeded", "provider_credits exceeds per_payout_cap_usdc_base_units")
		return
	}

	nowTime := h.store.now().UTC()
	now := sqliteTimeText(nowTime)
	reason := body.Reason

	// INSERT the compensation row. operator_credits and
	// min_payout_credits are pinned to 0; payout_currency /
	// payout_external_id default to NULL. Does NOT trigger a settlement
	// run and does NOT write ledger_request_credits.
	res, err := conn.ExecContext(ctx, `
INSERT INTO ledger_payout_ready
    (provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
     gross_credits, provider_credits, operator_credits, min_payout_credits,
     status, idempotency_key, created_at_utc)
VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, 'ready', ?, ?)`,
		body.ProviderID, windowStart, windowEnd, body.CadenceDays, body.SourceCreditCount,
		body.GrossCredits, body.ProviderCredits, body.IdempotencyKey, now)
	if err != nil {
		if isSQLiteUniqueConstraint(err) {
			// idempotency_key replay (or window collision). Release the
			// tx conn BEFORE re-reading via h.store.db — MaxOpenConns(1)
			// on the shared *sql.DB would otherwise deadlock the re-read.
			// FIX 10: ROLLBACK with context.Background(), NOT the request
			// ctx — a canceled/expired request ctx would skip the ROLLBACK
			// and leave the BEGIN IMMEDIATE txn open on the sole conn,
			// wedging the billing store.
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
			committed = true // suppress the deferred ROLLBACK
			conn.Close()
			h.respondPayoutReadyReplay(w, ctx, body.IdempotencyKey)
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", "insert payout_ready: "+err.Error())
		return
	}
	newID, err := res.LastInsertId()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "last insert id: "+err.Error())
		return
	}

	// Audit-log INSERT through the SAME conn (shares atomicity). Exactly
	// the six §9.5b.1 fields; actor is the principal marker, not the secret.
	payload := map[string]any{
		"provider_id":     body.ProviderID,
		"id":              newID,
		"idempotency_key": body.IdempotencyKey,
		"reason":          reason,
		"actor":           payoutReadyActor,
		"ts_utc":          now,
	}
	payloadJSON, err := json.Marshal(payload)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "marshal audit payload: "+err.Error())
		return
	}
	if _, err := conn.ExecContext(ctx, `
INSERT INTO audit_log (ts_utc, event_type, provider_id, payload_json)
VALUES (?, ?, ?, ?)`, now, eventPayoutReadyInserted, body.ProviderID, string(payloadJSON)); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "insert audit: "+err.Error())
		return
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "commit: "+err.Error())
		return
	}
	committed = true

	// FIX 9 / §9.5b.1 line ~4448: emit the structured LOG event in
	// addition to the durable audit_log row. Exactly the six spec
	// fields; actor is the fixed principal marker payoutReadyActor —
	// NEVER the operator bearer secret / KEK / token.
	h.log.Info().
		Str("event", eventPayoutReadyInserted).
		Str("provider_id", body.ProviderID).
		Int64("id", newID).
		Str("idempotency_key", body.IdempotencyKey).
		Str("reason", reason).
		Str("actor", payoutReadyActor).
		Str("ts_utc", now).
		Msg("payout-ready reorg-compensation row inserted")

	writeJSON(w, http.StatusCreated, map[string]any{"id": newID})
}

// respondPayoutReadyReplay re-reads the winning row's id by
// idempotency_key and returns the original 201-shaped body with a 409.
// The caller MUST release the tx conn before calling this.
func (h *handler) respondPayoutReadyReplay(w http.ResponseWriter, ctx context.Context, idempotencyKey string) {
	var id int64
	err := h.store.db.QueryRowContext(ctx, `
SELECT id FROM ledger_payout_ready WHERE idempotency_key = ?`, idempotencyKey).Scan(&id)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// The UNIQUE violation was on (provider_id, window_start_utc,
			// window_end_utc), not idempotency_key — a genuine window
			// collision with a different key. Report a conflict rather
			// than fabricating a replay body.
			writeError(w, http.StatusConflict, "window_conflict", "compensation window collides with an existing row")
			return
		}
		writeError(w, http.StatusInternalServerError, "internal_error", "re-read payout_ready: "+err.Error())
		return
	}
	writeJSON(w, http.StatusConflict, map[string]any{"id": id})
}

// writeOrphanMismatch emits the §9.5b.1 422 orphan_mismatch naming the
// failed binding field.
func writeOrphanMismatch(w http.ResponseWriter, field string) {
	writeValidationError(w, "orphan_mismatch", "orphan binding mismatch on field: "+field)
}

// decodePayoutReadyBody decodes the request body into a
// payoutReadyRequest, rejecting unknown fields and trailing content
// with a 400 and distinguishing 413 (body too large).
func decodePayoutReadyBody(w http.ResponseWriter, r *http.Request) (payoutReadyRequest, bool) {
	body := payoutReadyRequest{}
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(&body); err != nil {
		var mbErr *http.MaxBytesError
		if errors.As(err, &mbErr) {
			writeError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 4 KiB")
			return body, false
		}
		writeError(w, http.StatusBadRequest, "bad_request", "invalid json body")
		return body, false
	}
	// Reject trailing tokens after the top-level object (`{...} 42`).
	if _, err := dec.Token(); err != io.EOF {
		writeError(w, http.StatusBadRequest, "bad_request", "body must contain a single JSON object")
		return body, false
	}
	return body, true
}
