package payout

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/rs/zerolog"
)

// providerIDPattern enforces SPEC-016 §3.2 step 5: `provider_id`
// MUST match ^[A-Za-z0-9_-]{1,128}$. The regex is the strict
// belt-and-braces guard; even though EIP-712 structured signing
// makes raw concatenation moot, the pattern denies newline /
// control-char injection on the audit-log surface.
var providerIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,128}$`)

// nonceTableRetention is the §3.2 step 5 pruning window for
// provider_payout_address_nonces. Per SPEC: 10 minutes = 2×
// the ts_utc skew bound. Extending one without the other re-opens
// the replay window.
const nonceTableRetention = 10 * time.Minute

// timestampSkewBound is the §3.2 step 5 ±5-minute skew window
// the request's ts_utc must satisfy against the coordinator
// clock. Tightly coupled to nonceTableRetention.
const timestampSkewBound = 5 * time.Minute

// providerTokenValidator is satisfied by *auth.TokenStore. The
// interface is local to the payout package to keep the import
// graph one-way (payout → auth is permitted; the reverse is
// not). SPEC-016 §3.3 requires authentication via per-Mac
// provider_token (not operator key).
type providerTokenValidator interface {
	ValidateToken(ctx context.Context, raw string) (providerID string, ok bool, err error)
}

// providerIdentityChecker reports whether a provider_id has an
// active (unrevoked) row in the provider_tokens table. SPEC-016
// §3.2 step 3 requires the URL-path provider_id to already
// exist there; rejection on miss emits
// `provider_payout_address_rejected_unknown_provider`.
//
// Satisfied by *auth.Store.HasActiveTokenForProvider at
// internal/auth/tokens.go:472.
type providerIdentityChecker interface {
	HasActiveTokenForProvider(ctx context.Context, providerID string) (bool, error)
}

// pauseFlagReader returns the current runtime.registration_paused
// value (0 = unpaused, 1 = paused). SPEC-016 §3.3 requires this
// value to be read BEFORE the per-Mac provider_token is
// evaluated — see the pre-auth pause check in ServePayoutAddress.
type pauseFlagReader interface {
	IsRegistrationPaused(ctx context.Context) (bool, error)
}

// addressEvent is the structured-log event emitted on every
// successful and failed §3.3 attempt. Field names match
// SPEC-016 §3.4 / §7.1 exactly.
type addressEvent struct {
	Event                string `json:"event"`
	ProviderID           string `json:"provider_id"`
	Chain                string `json:"chain,omitempty"`
	OldAddress           string `json:"old_address,omitempty"`
	NewAddress           string `json:"new_address,omitempty"`
	PendingUntilUtc      string `json:"pending_until_utc,omitempty"`
	Actor                string `json:"actor,omitempty"`
	TsUtc                string `json:"ts_utc"`
	Reason               string `json:"reason,omitempty"`
	SrcIP                string `json:"src_ip,omitempty"`
	SubmittedFingerprint string `json:"submitted_fingerprint,omitempty"`
}

// AddressesService bundles the dependencies required by the
// §3.3 / §3.2 handler. The struct is constructed once at
// startup; it holds zero per-request state of its own.
//
// Step 4 r1 [code:r1-1]/[arch:4.2] closure: when Tuning is non-nil
// (production path), the §3.3 write reads the live cooling-off
// from Tuning.Snapshot() at the moment of registration. New
// registrations cool off against the NEW value after SIGHUP;
// in-flight `pending_until_utc` values on existing rows are NOT
// recomputed (SPEC §6.5 normative — addresses.go reads at
// write-time, not at runner-cycle time). CoolingOffPeriod remains
// for the test path that doesn't wire a TuningProvider.
type AddressesService struct {
	DB               *sql.DB
	Security         SecurityConfig
	DenyList         *DenyList
	Tokens           providerTokenValidator
	Identity         providerIdentityChecker
	Pause            pauseFlagReader
	CoolingOffPeriod time.Duration // fallback when Tuning == nil (test path)
	Tuning           *TuningProvider
	Log              zerolog.Logger
	Now              func() time.Time // injectable for tests
}

// currentCoolingOff returns the live address-registration
// cooling-off period. When TuningProvider is wired (production),
// reads the §6.5 SIGHUP-reloadable atomic snapshot. When nil
// (test), returns the static CoolingOffPeriod field.
func (s *AddressesService) currentCoolingOff() time.Duration {
	if s.Tuning != nil {
		return s.Tuning.Snapshot().AddressCoolingOffPeriod
	}
	return s.CoolingOffPeriod
}

// NewAddressesService validates the wiring and returns a usable
// service. Co-residency assertions (the runner sharing the same
// process as the handler) are enforced by
// AssertPayoutRuntimeTopology in `topology.go` — main.go
// invokes that hook BEFORE mounting the §3.3 handler. This
// constructor only validates that the SecurityConfig + per-call
// dependencies are non-nil.
func NewAddressesService(db *sql.DB, sec SecurityConfig, dl *DenyList, tokens providerTokenValidator, identity providerIdentityChecker, pause pauseFlagReader, coolingOff time.Duration, log zerolog.Logger) (*AddressesService, error) {
	if db == nil {
		return nil, fmt.Errorf("payout.NewAddressesService: db is required")
	}
	if sec.HotWalletAddress == "" {
		return nil, fmt.Errorf("payout.NewAddressesService: SecurityConfig.HotWalletAddress is required")
	}
	if dl == nil {
		return nil, fmt.Errorf("payout.NewAddressesService: DenyList is required")
	}
	if tokens == nil {
		return nil, fmt.Errorf("payout.NewAddressesService: providerTokenValidator is required")
	}
	if identity == nil {
		return nil, fmt.Errorf("payout.NewAddressesService: providerIdentityChecker is required")
	}
	if pause == nil {
		return nil, fmt.Errorf("payout.NewAddressesService: pauseFlagReader is required")
	}
	if coolingOff < time.Hour {
		// §3.1: minimum 1 hour at config-parse. Default 24h.
		return nil, fmt.Errorf("payout.NewAddressesService: coolingOff (%s) below SPEC §3.1 floor of 1h", coolingOff)
	}
	now := time.Now
	return &AddressesService{
		DB: db, Security: sec, DenyList: dl, Tokens: tokens, Identity: identity,
		Pause: pause, CoolingOffPeriod: coolingOff, Log: log, Now: now,
	}, nil
}

// LookupPayoutAddress satisfies billing.PayoutAddressReader.
// Returns (canonical EIP-55 address, payout_allowed) for the
// provider on the chain, or (nil) if the row does not exist.
// Filters by registered_against_hot_wallet = current hot wallet
// per SPEC §4.3 step 1.
func (s *AddressesService) LookupPayoutAddress(ctx context.Context, providerID, chain string) (address string, payoutAllowed bool, err error) {
	row := s.DB.QueryRowContext(ctx, `
SELECT address, payout_allowed
  FROM provider_payout_addresses
 WHERE provider_id = ?
   AND chain = ?
   AND registered_against_hot_wallet = ?`, providerID, chain, s.Security.HotWalletAddress)
	var addr string
	var allowed int
	if err := row.Scan(&addr, &allowed); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return "", false, nil
		}
		return "", false, err
	}
	return addr, allowed == 1, nil
}

// registerRequest is the JSON decode target for POST
// /providers/{provider_id}/payout-address. The struct
// deliberately omits `registered_against_hot_wallet` so the
// client-supplied value is silently ignored per §3.4 (the
// probing defense — DisallowUnknownFields is FORBIDDEN here).
type registerRequest struct {
	Chain     string `json:"chain"`
	Address   string `json:"address"`
	Nonce     string `json:"nonce"`
	TsUtc     uint64 `json:"ts_utc"`
	Signature string `json:"signature"`
}

// ServePayoutAddress implements POST
// /providers/{provider_id}/payout-address per SPEC §3.3. The
// handler runs the §3.2 validation pipeline in the order:
//
//  1. Pre-auth pause check (returns 503 BEFORE evaluating
//     provider_token to defeat response-code timing probing).
//  2. Provider-token auth + URL-path provider_id ownership.
//  3. JSON decode (no DisallowUnknownFields).
//  4. EIP-55 canonicalisation of `address`.
//  5. URL-path provider_id pattern check.
//  6. Provider identity (provider_tokens row exists).
//  7. Deny-list.
//  8. ts_utc skew window.
//  9. EIP-712 verification + typed-data field-by-field equality.
//  10. BEGIN IMMEDIATE txn: TOCTOU pause re-check, anti-replay
//     INSERT, provider_payout_addresses UPSERT + stamp
//     registered_against_hot_wallet from SecurityConfig (server
//     side; the client value is silently ignored at decode).
//  11. §3.4 audit-log emission with old_address / new_address /
//     pending_until_utc in canonical EIP-55 form.
//
// Per SPEC every response — 201 / 200 / 4xx / 5xx — emits a
// structured log line per §7.1. A failed-registration burst is
// the stolen-token signal.
func (s *AddressesService) ServePayoutAddress(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	providerID := chi.URLParam(r, "provider_id")

	// 1. Pre-auth pause check (§3.3 normative).
	paused, err := s.Pause.IsRegistrationPaused(ctx)
	if err != nil {
		s.emitFailure(r, providerID, "internal_error", "")
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if paused {
		s.emitFailure(r, providerID, "registration_paused", "")
		writeError(w, http.StatusServiceUnavailable, "rotation_in_progress")
		return
	}

	// 2. Authentication.
	rawBearer := bearerFromHeader(r.Header.Get("Authorization"))
	if rawBearer == "" {
		s.emitFailure(r, providerID, "missing_token", "")
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	subject, ok, err := s.Tokens.ValidateToken(ctx, rawBearer)
	if err != nil || !ok {
		s.emitFailure(r, providerID, "invalid_token", "")
		writeError(w, http.StatusUnauthorized, "unauthorized")
		return
	}
	if subject != providerID {
		s.emitFailure(r, providerID, "token_subject_mismatch", "")
		writeError(w, http.StatusForbidden, "forbidden")
		return
	}

	// 3. JSON decode — NO DisallowUnknownFields (§3.4 silent-
	// ignore is load-bearing for probing defense). Use a strict
	// content-length cap as the cheap DoS defense.
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	defer r.Body.Close()
	var req registerRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		s.emitFailure(r, providerID, "bad_json", "")
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}
	if req.Chain == "" || req.Address == "" || req.Nonce == "" || req.Signature == "" || req.TsUtc == 0 {
		s.emitFailure(r, providerID, "missing_field", req.Address)
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}
	if req.Chain != "base-mainnet" {
		s.emitFailure(r, providerID, "bad_chain", req.Address)
		writeError(w, http.StatusBadRequest, "chain_mismatch")
		return
	}

	// 4. EIP-55 canonicalisation.
	canonical, err := ParseAndCanonicalizeEIP55(req.Address)
	if err != nil {
		if errors.Is(err, ErrChecksumMismatch) {
			s.emitFailure(r, providerID, "checksum_mismatch", req.Address)
			writeError(w, http.StatusBadRequest, "checksum_mismatch")
			return
		}
		s.emitFailure(r, providerID, "bad_format", req.Address)
		writeError(w, http.StatusBadRequest, "bad_format")
		return
	}

	// 5. URL-path provider_id pattern.
	if !providerIDPattern.MatchString(providerID) {
		s.emitFailure(r, providerID, "bad_provider_id", req.Address)
		writeError(w, http.StatusBadRequest, "bad_provider_id")
		return
	}

	// 6. Provider identity.
	exists, err := s.Identity.HasActiveTokenForProvider(ctx, providerID)
	if err != nil {
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if !exists {
		s.emitReject(r, providerID, "provider_payout_address_rejected_unknown_provider", req.Address)
		writeError(w, http.StatusBadRequest, "unknown_provider")
		return
	}

	// 7. Deny-list.
	if s.DenyList.Contains(canonical) {
		s.emitFailure(r, providerID, "denylist", req.Address)
		writeError(w, http.StatusBadRequest, "denylist")
		return
	}

	// 8. ts_utc skew window.
	now := s.Now().UTC()
	tsRequest := time.Unix(int64(req.TsUtc), 0).UTC()
	if tsRequest.Before(now.Add(-timestampSkewBound)) || tsRequest.After(now.Add(timestampSkewBound)) {
		s.emitFailure(r, providerID, "signature_skew", req.Address)
		writeError(w, http.StatusBadRequest, "signature_skew")
		return
	}

	// 9. EIP-712 verification + typed-data field-by-field
	// equality. The handler decodes the request body's `nonce`
	// (hex bytes32) into a [32]byte once and reuses it for the
	// typed-data hash AND the anti-replay PK. The hex string
	// MUST be canonicalised to lowercase before storing so the
	// PK does not vary by request-side casing.
	nonce32, err := DecodeNonce32(req.Nonce)
	if err != nil {
		s.emitFailure(r, providerID, "bad_nonce_format", req.Address)
		writeError(w, http.StatusBadRequest, "missing_field")
		return
	}
	inputs := EIP712Inputs{
		ProviderID:        providerID,
		CanonicalAddr:     canonical,
		Chain:             req.Chain,
		Nonce32:           nonce32,
		TsUtc:             req.TsUtc,
		VerifyingContract: s.Security.HotWalletAddress,
	}
	if _, err := VerifyEIP712(inputs, req.Signature); err != nil {
		s.emitFailure(r, providerID, "signature_mismatch", req.Address)
		writeError(w, http.StatusBadRequest, "signature_mismatch")
		return
	}

	// 10. BEGIN IMMEDIATE — TOCTOU pause re-check, anti-replay
	// INSERT, UPSERT row, stamp registered_against_hot_wallet.
	// SPEC §3.3 normative: the TOCTOU re-check MUST run inside
	// the SAME `BEGIN IMMEDIATE` txn that writes the row. The
	// modernc.org/sqlite driver's BeginTx surfaces BEGIN DEFERRED;
	// we use db.Conn + raw BEGIN IMMEDIATE per the auth-store
	// pattern at internal/auth/tokens.go:927 to take a write-
	// intent lock at the top of the txn.
	canonicalLower := strings.ToLower(canonical)
	// Canonicalise the anti-replay nonce key from the DECODED
	// bytes, NOT from the request-side string. The request-side
	// string accepts both "0x" and "0X" prefixes (per the
	// 0x/0X-prefix laxity in DecodeNonce32), so deriving the
	// table key from the input would split the same bytes32
	// nonce across two PK strings — the same EIP-712 signature
	// could then be replayed once per prefix variant. Encoding
	// from the post-decode bytes yields exactly one canonical
	// "0x" + 64 lowercase hex chars per nonce value. Closes
	// codex round-1 [code:1.2] MEDIUM.
	nonceLowerHex := "0x" + hex.EncodeToString(nonce32[:])

	conn, err := s.DB.Conn(ctx)
	if err != nil {
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()

	// 10a. TOCTOU pause re-check inside the same txn.
	paused2, err := s.pausedConn(ctx, conn)
	if err != nil {
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if paused2 {
		s.emitFailure(r, providerID, "registration_paused", req.Address)
		writeError(w, http.StatusServiceUnavailable, "rotation_in_progress")
		return
	}

	// 10b. Anti-replay INSERT — PK on (canonical_address, nonce).
	if _, err := conn.ExecContext(ctx,
		`INSERT INTO provider_payout_address_nonces (canonical_address, nonce, seen_at_utc) VALUES (?, ?, ?)`,
		canonicalLower, nonceLowerHex, now.Format(time.RFC3339Nano),
	); err != nil {
		if isUniqueViolation(err) {
			s.emitFailure(r, providerID, "nonce_replayed", req.Address)
			writeError(w, http.StatusBadRequest, "nonce_replayed")
			return
		}
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	// 10c. UPSERT provider_payout_addresses. First, read the
	// existing row (if any) so we can derive old_address,
	// rotated_from, status code, pending_until_utc, AND the
	// existing payout_allowed flag.
	//
	// CRITICAL: SPEC §3.3 requires a 409 Conflict when
	// payout_allowed=0 on the existing row, AND requires that
	// rotation MUST NOT silently re-enable a compliance-disabled
	// row. Reading payout_allowed inside the BEGIN IMMEDIATE
	// transaction is the only correct ordering — a read outside
	// the txn would race the §6.4.1 compliance-gate path. Closes
	// codex round-1 [code:1.1] CRITICAL.
	var existingAddress sql.NullString
	var existingPayoutAllowed sql.NullInt64
	row := conn.QueryRowContext(ctx,
		`SELECT address, payout_allowed FROM provider_payout_addresses WHERE provider_id=? AND chain=?`,
		providerID, req.Chain,
	)
	if err := row.Scan(&existingAddress, &existingPayoutAllowed); err != nil && !errors.Is(err, sql.ErrNoRows) {
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}

	pendingUntil := now.Add(s.currentCoolingOff())
	registeredAtUtcStr := now.Format(time.RFC3339Nano)
	pendingUntilStr := pendingUntil.Format(time.RFC3339Nano)

	var status int
	var oldAddress string
	if existingAddress.Valid && existingAddress.String != "" {
		// SPEC §3.3 compliance gate: payout_allowed=0 rejects
		// rotation with 409 (not 400) and emits the rejection
		// event with reason="payout_not_allowed". The row
		// remains untouched; the nonce-replay INSERT we already
		// performed earlier in this txn is rolled back via the
		// `committed=false` defer.
		if existingPayoutAllowed.Valid && existingPayoutAllowed.Int64 == 0 {
			s.emitFailure(r, providerID, "payout_not_allowed", req.Address)
			writeError(w, http.StatusConflict, "payout_not_allowed")
			return
		}
		// Rotation: 200 OK + pending_until rewritten, rotated_from set.
		// payout_allowed is PRESERVED — rotation does NOT silently
		// re-enable a row that was already disabled. (If a future
		// SPEC adds a re-enable path it MUST go through the
		// §6.4.1 compliance-gate endpoint, not §3.3 rotation.)
		oldAddress = existingAddress.String
		preservedPayoutAllowed := int64(1)
		if existingPayoutAllowed.Valid {
			preservedPayoutAllowed = existingPayoutAllowed.Int64
		}
		if _, err := conn.ExecContext(ctx, `
UPDATE provider_payout_addresses
   SET address=?, payout_allowed=?, pending_until_utc=?, rotated_from=?,
       registered_at_utc=?, registered_against_hot_wallet=?
 WHERE provider_id=? AND chain=?`,
			canonical, preservedPayoutAllowed, pendingUntilStr, existingAddress.String,
			registeredAtUtcStr, s.Security.HotWalletAddress,
			providerID, req.Chain,
		); err != nil {
			s.emitFailure(r, providerID, "internal_error", req.Address)
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		status = http.StatusOK
	} else {
		// First-ever registration: 201 Created.
		if _, err := conn.ExecContext(ctx, `
INSERT INTO provider_payout_addresses
  (provider_id, chain, address, payout_allowed, pending_until_utc,
   rotated_from, registered_at_utc, registered_against_hot_wallet)
VALUES (?, ?, ?, 1, ?, NULL, ?, ?)`,
			providerID, req.Chain, canonical, pendingUntilStr,
			registeredAtUtcStr, s.Security.HotWalletAddress,
		); err != nil {
			s.emitFailure(r, providerID, "internal_error", req.Address)
			writeError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		status = http.StatusCreated
	}

	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		s.emitFailure(r, providerID, "internal_error", req.Address)
		writeError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	committed = true

	// 11. §3.4 audit emission.
	s.emitSuccess(providerID, req.Chain, oldAddress, canonical, pendingUntilStr)
	writeJSON(w, status, map[string]any{
		"chain":             req.Chain,
		"pending_until_utc": pendingUntilStr,
		"status":            statusName(status),
	})
}

// pausedConn reads the registration_paused flag inside the
// provided raw connection (where BEGIN IMMEDIATE is already
// active). The read shares the write-intent lock the txn
// established, serialising with any concurrent §6.4.1 pause
// endpoint hitting the same SQLite connection pool.
func (s *AddressesService) pausedConn(ctx context.Context, conn *sql.Conn) (bool, error) {
	row := conn.QueryRowContext(ctx,
		`SELECT value FROM runtime_flags WHERE name='registration_paused'`,
	)
	var v int
	if err := row.Scan(&v); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// SPEC §4.8a: missing closed-set flag at runtime
			// is a payout_invariant_violation. Surface it as
			// internal_error and let the startup-time
			// sentinel-asymmetry detector (bootstrap.go)
			// HALT the process at next boot.
			s.Log.Error().Str("event", "payout_invariant_violation").
				Str("where", "runtime_flag missing").
				Str("name", "registration_paused").Send()
			return false, fmt.Errorf("runtime flag missing")
		}
		return false, err
	}
	return v == 1, nil
}

func (s *AddressesService) emitSuccess(providerID, chain, oldAddress, newAddress, pendingUntil string) {
	ev := addressEvent{
		Event:           "provider_payout_address_changed",
		ProviderID:      providerID,
		Chain:           chain,
		OldAddress:      orNone(oldAddress),
		NewAddress:      newAddress,
		PendingUntilUtc: pendingUntil,
		Actor:           "provider_token",
		TsUtc:           s.Now().UTC().Format(time.RFC3339Nano),
	}
	s.Log.Info().
		Str("event", ev.Event).
		Str("provider_id", ev.ProviderID).
		Str("chain", ev.Chain).
		Str("old_address", ev.OldAddress).
		Str("new_address", ev.NewAddress).
		Str("pending_until_utc", ev.PendingUntilUtc).
		Str("actor", ev.Actor).
		Str("ts_utc", ev.TsUtc).
		Send()
}

func (s *AddressesService) emitFailure(r *http.Request, providerID, reason, submittedAddress string) {
	ev := addressEvent{
		Event:                "provider_payout_address_change_rejected",
		ProviderID:           providerID,
		Reason:               reason,
		SrcIP:                clientIP(r),
		SubmittedFingerprint: addressFingerprint(submittedAddress),
		TsUtc:                s.Now().UTC().Format(time.RFC3339Nano),
	}
	s.Log.Info().
		Str("event", ev.Event).
		Str("provider_id", ev.ProviderID).
		Str("reason", ev.Reason).
		Str("src_ip", ev.SrcIP).
		Str("submitted_fingerprint", ev.SubmittedFingerprint).
		Str("ts_utc", ev.TsUtc).
		Send()
}

func (s *AddressesService) emitReject(r *http.Request, providerID, eventName, submittedAddress string) {
	s.Log.Info().
		Str("event", eventName).
		Str("provider_id", providerID).
		Str("src_ip", clientIP(r)).
		Str("submitted_fingerprint", addressFingerprint(submittedAddress)).
		Str("ts_utc", s.Now().UTC().Format(time.RFC3339Nano)).
		Send()
}

// PruneNonces removes nonce-table rows older than the
// SPEC-pinned nonceTableRetention. Returns the number of rows
// deleted. Called from a background ticker in main.go.
func (s *AddressesService) PruneNonces(ctx context.Context) (int64, error) {
	cutoff := s.Now().UTC().Add(-nonceTableRetention).Format(time.RFC3339Nano)
	res, err := s.DB.ExecContext(ctx,
		`DELETE FROM provider_payout_address_nonces WHERE seen_at_utc < ?`, cutoff,
	)
	if err != nil {
		return 0, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	return n, nil
}

// addressFingerprint is the SPEC §3.4 6-prefix-4-suffix-length
// fingerprint that defeats raw-bytes log-injection while
// preserving burst-detection on enumeration probes. The format
// is: first 6 hex chars of the prefix, "...", last 4 hex chars,
// " len=N". For non-hex submissions we fall back to "<bad> len=N"
// so a control-byte-laden input cannot pivot via the log line.
func addressFingerprint(submitted string) string {
	if submitted == "" {
		return ""
	}
	stripped := submitted
	if len(submitted) > 0 && (submitted[0] == '0' && (len(submitted) > 1 && (submitted[1] == 'x' || submitted[1] == 'X'))) {
		stripped = submitted[2:]
	}
	// Strict hex-only emission: reject any control / non-hex byte.
	for i := 0; i < len(stripped); i++ {
		c := stripped[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return fmt.Sprintf("<bad> len=%d", len(submitted))
		}
	}
	const prefixLen, suffixLen = 6, 4
	totalHex := len(stripped)
	if totalHex < prefixLen+suffixLen {
		return fmt.Sprintf("0x%s len=%d", stripped, len(submitted))
	}
	return fmt.Sprintf("0x%s...%s len=%d", stripped[:prefixLen], stripped[totalHex-suffixLen:], len(submitted))
}

func bearerFromHeader(h string) string {
	const prefix = "Bearer "
	trimmed := strings.TrimSpace(h)
	if !strings.HasPrefix(trimmed, prefix) {
		return ""
	}
	return strings.TrimSpace(trimmed[len(prefix):])
}

func clientIP(r *http.Request) string {
	if r == nil {
		return ""
	}
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		// Take the first hop only; multiple-hop XFF is operator-
		// trusted because the front nginx normalises.
		if idx := strings.IndexByte(xff, ','); idx > 0 {
			return strings.TrimSpace(xff[:idx])
		}
		return xff
	}
	return r.RemoteAddr
}

func orNone(s string) string {
	if s == "" {
		return "none"
	}
	return s
}

func statusName(code int) string {
	switch code {
	case http.StatusCreated:
		return "created"
	case http.StatusOK:
		return "rotated"
	default:
		return http.StatusText(code)
	}
}

func writeError(w http.ResponseWriter, status int, code string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(`{"error":"` + jsonString(code) + `"}`))
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func jsonString(s string) string {
	// minimal escape: reject control chars by replacing with
	// "?"; this is a defense-in-depth posture for the bare
	// error-code surface (only literal codes flow through, so
	// the function is the safety net).
	out := make([]byte, 0, len(s))
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c == '"' || c == '\\' {
			out = append(out, '?')
			continue
		}
		out = append(out, c)
	}
	return string(out)
}

// isUniqueViolation pattern-matches modernc.org/sqlite's
// constraint-failure error text. The driver does not expose a
// typed sentinel for UNIQUE failures, so the text match is the
// pragmatic check. Update if modernc surfaces a typed sentinel
// upstream.
func isUniqueViolation(err error) bool {
	if err == nil {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "UNIQUE constraint failed") ||
		strings.Contains(msg, "constraint failed: UNIQUE")
}
