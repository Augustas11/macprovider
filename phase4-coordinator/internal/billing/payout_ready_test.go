package billing

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// SPEC-005 vX.Y+1 §9.5b acceptance tests for
// `POST /admin/ledger/payout-ready` (SPEC-016 §9.5b HARD prereq for
// USDC payouts). Mirrors quarantine_test.go: in-package httptest with
// an operator bearer, a single SQLite file shared by
// ledger_payout_ready + payout_reorg_orphans + provider_tokens.

const testPerPayoutCap int64 = 500_000_000

// payoutReadyFixture builds a billing store and creates the sibling
// tables the endpoint queries in-transaction. In production these are
// created on the same DB file by auth.OpenStore (provider_tokens) and
// the SPEC-016 payout migrations (payout_attempts, payout_reorg_orphans);
// here we create them by hand.
func payoutReadyFixture(t *testing.T) *Store {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	createAuditLogForTest(t, store.db)
	createPayoutReadySiblingTables(t, store.db)
	return store
}

func createPayoutReadySiblingTables(t *testing.T, db *sql.DB) {
	t.Helper()
	stmts := []string{
		`CREATE TABLE IF NOT EXISTS provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);`,
		`CREATE TABLE IF NOT EXISTS payout_attempts (
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL CHECK(attempt_seq >= 1),
    chain            TEXT NOT NULL CHECK(chain = 'base-mainnet'),
    from_address     TEXT NOT NULL,
    to_address       TEXT NOT NULL,
    amount_base_units INTEGER NOT NULL CHECK(amount_base_units > 0),
    nonce            INTEGER NOT NULL CHECK(nonce >= 0),
    raw_signed_tx    BLOB NULL,
    tx_hash          TEXT NULL,
    broadcast_at_utc TEXT NULL,
    confirmed_at_utc TEXT NULL,
    block_number     INTEGER NULL,
    gas_used_native_wei INTEGER NULL,
    is_cancel_self_transfer INTEGER NOT NULL DEFAULT 0 CHECK(is_cancel_self_transfer IN (0,1)),
    last_error       TEXT NULL,
    abandoned_at_utc TEXT NULL,
    abandoned_reason TEXT NULL,
    cancel_reconfirm_stale_paged_at_utc TEXT NULL,
    updated_at_utc   TEXT NOT NULL,
    PRIMARY KEY(payout_id, attempt_seq)
);`,
		`CREATE TABLE IF NOT EXISTS payout_reorg_orphans (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    payout_id        INTEGER NOT NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    attempt_seq      INTEGER NOT NULL,
    orphan_tx_hash   TEXT NOT NULL,
    last_seen_block  INTEGER NOT NULL,
    observed_at_utc  TEXT NOT NULL,
    rpc_source       TEXT NOT NULL,
    observed_provider_id           TEXT    NOT NULL,
    observed_provider_credits      INTEGER NOT NULL,
    observed_gross_credits         INTEGER NOT NULL,
    observed_amount_base_units     INTEGER NOT NULL,
    operator_resolution TEXT NULL,
    compensation_settlement_id INTEGER NULL REFERENCES ledger_payout_ready(id) ON DELETE RESTRICT,
    resolved_at_utc  TEXT NULL,
    FOREIGN KEY(payout_id, attempt_seq) REFERENCES payout_attempts(payout_id, attempt_seq) ON DELETE RESTRICT
);`,
	}
	for _, s := range stmts {
		if _, err := db.Exec(s); err != nil {
			t.Fatalf("create sibling table: %v", err)
		}
	}
}

func seedProviderToken(t *testing.T, db *sql.DB, providerID string) {
	t.Helper()
	if _, err := db.Exec(`
INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name)
VALUES (?, 'mp_', ?, ?)`, "hash-"+providerID, providerID, providerID); err != nil {
		t.Fatalf("seed provider token: %v", err)
	}
}

// seedOrphan inserts the original ledger_payout_ready row, a
// payout_attempts row, and an unresolved payout_reorg_orphans row with
// the given observed snapshot values. Returns (origPayoutID, attemptSeq).
//
// FIX 11: the original (mutable) ledger_payout_ready row is deliberately
// seeded with DIFFERENT provider_id / provider_credits / gross_credits
// than the immutable observed_* orphan snapshot. The endpoint binds to
// observed_*, so a regression that read the mutable lpr.* row instead
// would bind to these divergent values and fail the binding tests.
func seedOrphan(t *testing.T, store *Store, providerID string, observedProviderCredits, observedGrossCredits, observedAmountBaseUnits int64) (int64, int64) {
	t.Helper()
	db := store.db
	// Original payout row (the one that got reorged) — mutable values
	// intentionally divergent from the observed_* snapshot below.
	res, err := db.Exec(`
INSERT INTO ledger_payout_ready
    (provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
     gross_credits, provider_credits, operator_credits, min_payout_credits,
     status, idempotency_key, created_at_utc)
VALUES (?, ?, ?, 1, 1, ?, ?, 0, 0, 'ready', ?, ?)`,
		providerID+"-lpr-mutable", "2026-01-01T00:00:00.000000000Z", "2026-01-02T00:00:00.000000000Z",
		observedGrossCredits+500, observedProviderCredits+500,
		"settle:"+providerID+":orig-"+time.Now().UTC().Format("20060102150405.000000000"),
		"2026-01-01T00:00:00.000000000Z")
	if err != nil {
		t.Fatalf("seed orig payout: %v", err)
	}
	origPayoutID, _ := res.LastInsertId()
	const attemptSeq int64 = 1
	if _, err := db.Exec(`
INSERT INTO payout_attempts
    (payout_id, attempt_seq, chain, from_address, to_address,
     amount_base_units, nonce, tx_hash, broadcast_at_utc, is_cancel_self_transfer, updated_at_utc)
VALUES (?, ?, 'base-mainnet', '0xfrom', '0xto', ?, 1, '0xorphan', '2026-01-03T00:00:00Z', 0, '2026-01-03T00:00:00Z')`,
		origPayoutID, attemptSeq, observedAmountBaseUnits); err != nil {
		t.Fatalf("seed attempt: %v", err)
	}
	insertOrphanRow(t, db, origPayoutID, attemptSeq, "0xorphan", providerID,
		observedProviderCredits, observedGrossCredits, observedAmountBaseUnits)
	return origPayoutID, attemptSeq
}

func insertOrphanRow(t *testing.T, db *sql.DB, payoutID, attemptSeq int64, txHash, providerID string, observedProviderCredits, observedGrossCredits, observedAmountBaseUnits int64) {
	t.Helper()
	if _, err := db.Exec(`
INSERT INTO payout_reorg_orphans
    (payout_id, attempt_seq, orphan_tx_hash, last_seen_block, observed_at_utc, rpc_source,
     observed_provider_id, observed_provider_credits, observed_gross_credits, observed_amount_base_units)
VALUES (?, ?, ?, 100, '2026-01-03T00:00:00Z', 'both', ?, ?, ?, ?)`,
		payoutID, attemptSeq, txHash, providerID,
		observedProviderCredits, observedGrossCredits, observedAmountBaseUnits); err != nil {
		t.Fatalf("insert orphan row: %v", err)
	}
}

func markAttemptCancel(t *testing.T, db *sql.DB, payoutID, attemptSeq int64) {
	t.Helper()
	if _, err := db.Exec(`
UPDATE payout_attempts SET is_cancel_self_transfer = 1 WHERE payout_id = ? AND attempt_seq = ?`,
		payoutID, attemptSeq); err != nil {
		t.Fatalf("mark attempt cancel: %v", err)
	}
}

func compensationKey(origPayoutID, attemptSeq int64) string {
	return "reorg_compensation:" + itoa(origPayoutID) + ":" + itoa(attemptSeq)
}

// payoutReadyBodyMap builds a well-formed request body for the given
// orphan; callers mutate individual fields to exercise error paths.
func payoutReadyBodyMap(providerID, key string, providerCredits int64) map[string]any {
	return map[string]any{
		"provider_id":                 providerID,
		"gross_credits":               providerCredits,
		"provider_credits":            providerCredits,
		"operator_credits":            0,
		"cadence_days":                1,
		"source_credit_count":         1,
		"min_payout_credits_override": 0,
		"idempotency_key":             key,
		"window_start_utc":            "2026-01-03T00:00:00.000000000Z",
		"window_end_utc":              "2026-01-03T00:00:00.000001000Z",
		"reason":                      "reorg compensation for orphaned payout",
	}
}

func doPayoutReady(t *testing.T, store *Store, headerKey string, bodyObj any, ct, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	var reader *strings.Reader
	switch b := bodyObj.(type) {
	case string:
		reader = strings.NewReader(b)
	default:
		raw, err := json.Marshal(b)
		if err != nil {
			t.Fatalf("marshal body: %v", err)
		}
		reader = strings.NewReader(string(raw))
	}
	req := httptest.NewRequest(http.MethodPost, payoutReadyPath, reader)
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	if headerKey != "" {
		req.Header.Set("Idempotency-Key", headerKey)
	}
	w := httptest.NewRecorder()
	store.HandlersWithQuarantineGatesIdlePrewarmAndPayoutCap("operator", fakeTokens{}, true, 60, false, false, nil, testPerPayoutCap).ServeHTTP(w, req)
	return w
}

func decodeErrCode(t *testing.T, w *httptest.ResponseRecorder) string {
	t.Helper()
	var env struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &env); err != nil {
		t.Fatalf("decode error envelope: %v (body=%s)", err, w.Body.String())
	}
	return env.Error.Code
}

// assertNoPayoutReadySideEffects locks the no-durable-side-effect
// invariant on rejection paths: no ledger_payout_ready row for the key
// and no ledger_payout_ready_admin_inserted audit row.
func assertNoPayoutReadySideEffects(t *testing.T, store *Store, key string) {
	t.Helper()
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key); n != 0 {
		t.Errorf("ledger_payout_ready rows for key=%q = %d want 0 (rejection must not insert)", key, n)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted); n != 0 {
		t.Errorf("audit rows=%d want 0 (rejection must not audit)", n)
	}
}

// --- 1. happy path ---------------------------------------------------

func TestPayoutReady_HappyPath(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-happy"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)

	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusCreated {
		t.Fatalf("code=%d body=%s want 201", w.Code, w.Body.String())
	}
	var resp struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("decode 201 body: %v", err)
	}
	if resp.ID <= 0 {
		t.Fatalf("expected positive id, got %d", resp.ID)
	}
	// Assert the inserted row shape.
	var (
		status          string
		minPayout       int64
		operatorCredits int64
		gross           int64
		providerCredits int64
		currency        sql.NullString
		externalID      sql.NullString
		idem            string
	)
	if err := store.db.QueryRow(`
SELECT status, min_payout_credits, operator_credits, gross_credits, provider_credits,
       payout_currency, payout_external_id, idempotency_key
  FROM ledger_payout_ready WHERE id = ?`, resp.ID).Scan(
		&status, &minPayout, &operatorCredits, &gross, &providerCredits,
		&currency, &externalID, &idem); err != nil {
		t.Fatalf("read inserted row: %v", err)
	}
	if status != "ready" {
		t.Errorf("status=%q want ready", status)
	}
	if minPayout != 0 || operatorCredits != 0 {
		t.Errorf("min_payout=%d operator_credits=%d want 0/0", minPayout, operatorCredits)
	}
	if gross != 900 || providerCredits != 900 {
		t.Errorf("gross=%d provider=%d want 900/900", gross, providerCredits)
	}
	if currency.Valid || externalID.Valid {
		t.Errorf("expected NULL currency/external_id, got currency=%v external=%v", currency, externalID)
	}
	if idem != key {
		t.Errorf("idempotency_key=%q want %q", idem, key)
	}
	// compensation_settlement_id MUST remain NULL — the two-call flow
	// links it later.
	var compID sql.NullInt64
	if err := store.db.QueryRow(`
SELECT compensation_settlement_id FROM payout_reorg_orphans WHERE payout_id=? AND attempt_seq=?`,
		origID, seq).Scan(&compID); err != nil {
		t.Fatalf("read orphan: %v", err)
	}
	if compID.Valid {
		t.Errorf("compensation_settlement_id must stay NULL, got %d", compID.Int64)
	}
}

// --- 13. audit event emitted with 6 fields ---------------------------

func TestPayoutReady_AuditEventSixFields(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-audit"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)

	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusCreated {
		t.Fatalf("code=%d want 201", w.Code)
	}
	var payloadJSON string
	if err := store.db.QueryRow(`
SELECT payload_json FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted).Scan(&payloadJSON); err != nil {
		t.Fatalf("read audit row: %v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		t.Fatalf("decode audit payload: %v", err)
	}
	want := []string{"provider_id", "id", "idempotency_key", "reason", "actor", "ts_utc"}
	if len(payload) != len(want) {
		t.Fatalf("audit payload has %d fields %v, want exactly %d %v", len(payload), payload, len(want), want)
	}
	for _, k := range want {
		if _, ok := payload[k]; !ok {
			t.Errorf("audit payload missing field %q", k)
		}
	}
	if payload["actor"] != payoutReadyActor {
		t.Errorf("actor=%v want %q (principal marker, not the secret)", payload["actor"], payoutReadyActor)
	}
	if payload["provider_id"] != provider {
		t.Errorf("provider_id=%v want %q", payload["provider_id"], provider)
	}
	if payload["idempotency_key"] != key {
		t.Errorf("idempotency_key=%v want %q", payload["idempotency_key"], key)
	}
}

// --- 4. replay -> 409 with original body -----------------------------

func TestPayoutReady_Replay409(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-replay"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	body := payoutReadyBodyMap(provider, key, 900)

	w1 := doPayoutReady(t, store, key, body, "application/json", "operator")
	if w1.Code != http.StatusCreated {
		t.Fatalf("first call code=%d want 201", w1.Code)
	}
	var first struct {
		ID int64 `json:"id"`
	}
	_ = json.Unmarshal(w1.Body.Bytes(), &first)

	w2 := doPayoutReady(t, store, key, body, "application/json", "operator")
	if w2.Code != http.StatusConflict {
		t.Fatalf("replay code=%d body=%s want 409", w2.Code, w2.Body.String())
	}
	var second struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(w2.Body.Bytes(), &second); err != nil {
		t.Fatalf("decode replay body: %v", err)
	}
	if second.ID != first.ID {
		t.Errorf("replay id=%d want original %d", second.ID, first.ID)
	}
	// Exactly one row must exist for the key.
	n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key)
	if n != 1 {
		t.Errorf("row count for key=%d want 1 (no double-insert)", n)
	}
}

// --- 4b. replay AFTER the orphan is resolved/linked -> still 409 -----
// §9.5b.1 lines 4386–4387: a repeated idempotency_key MUST return 409
// with the ORIGINAL 201 body regardless of the orphan's current state.
// Once the compensation is recorded and its orphan linked+resolved, the
// orphan preconditions would reject a replay as 422 — the top-of-txn
// ledger-key probe must make the replay win instead.
func TestPayoutReady_ReplayAfterOrphanResolved409(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-replay-resolved"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	body := payoutReadyBodyMap(provider, key, 900)

	w1 := doPayoutReady(t, store, key, body, "application/json", "operator")
	if w1.Code != http.StatusCreated {
		t.Fatalf("first call code=%d want 201", w1.Code)
	}
	var first struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(w1.Body.Bytes(), &first); err != nil {
		t.Fatalf("decode 201 body: %v", err)
	}

	// Simulate the /admin/payout/record-orphan link+resolve step: the
	// orphan is now compensated AND resolved (both preconditions that
	// would otherwise 422 a replay).
	if _, err := store.db.Exec(`
UPDATE payout_reorg_orphans
   SET compensation_settlement_id = ?, resolved_at_utc = '2026-01-05T00:00:00Z'
 WHERE payout_id = ? AND attempt_seq = ?`, first.ID, origID, seq); err != nil {
		t.Fatalf("link+resolve orphan: %v", err)
	}

	w2 := doPayoutReady(t, store, key, body, "application/json", "operator")
	if w2.Code != http.StatusConflict {
		t.Fatalf("replay code=%d body=%s want 409 (not 422)", w2.Code, w2.Body.String())
	}
	var second struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(w2.Body.Bytes(), &second); err != nil {
		t.Fatalf("decode replay body: %v", err)
	}
	if second.ID != first.ID {
		t.Errorf("replay id=%d want original %d", second.ID, first.ID)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key); n != 1 {
		t.Errorf("row count=%d want 1 (replay must not insert)", n)
	}
}

// --- 2. header != body key -> 400 ------------------------------------

func TestPayoutReady_HeaderKeyMismatch400(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-hdr"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, "reorg_compensation:999:999", payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s want 400", w.Code, w.Body.String())
	}
}

// --- 3. bad key regex -> 400 -----------------------------------------

func TestPayoutReady_BadKeyRegex400(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-badkey"
	seedProviderToken(t, store.db, provider)
	seedOrphan(t, store, provider, 900, 950, 900)
	bad := "settlement:1:1"
	body := payoutReadyBodyMap(provider, bad, 900)
	w := doPayoutReady(t, store, bad, body, "application/json", "operator")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s want 400", w.Code, w.Body.String())
	}
}

// --- 3b. non-canonical (leading-zero) key -> 400, no double-pay ------
// The regex admits leading zeros, so `reorg_compensation:05:1` parses
// to the SAME orphan (5,1) as the canonical `reorg_compensation:5:1`
// yet is a DISTINCT TEXT key — accepting it would let two ledger rows
// bind to one orphan (double-pay) since UNIQUE(idempotency_key) and the
// exact-text replay probe both key on the raw string. It MUST 400.
func TestPayoutReady_NonCanonicalKey400(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-canon"
	seedProviderToken(t, store.db, provider)
	// Seed an orphan whose (payout_id, attempt_seq) is exactly (N, 1);
	// then alias its key with a leading zero on the payout_id.
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	canonical := compensationKey(origID, seq)
	aliased := "reorg_compensation:0" + itoa(origID) + ":" + itoa(seq)
	if aliased == canonical {
		t.Fatalf("aliased key %q unexpectedly equals canonical %q", aliased, canonical)
	}
	w := doPayoutReady(t, store, aliased, payoutReadyBodyMap(provider, aliased, 900), "application/json", "operator")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s want 400", w.Code, w.Body.String())
	}
	// No row for EITHER encoding.
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key IN (?, ?)`, aliased, canonical); n != 0 {
		t.Errorf("ledger rows for aliased/canonical=%d want 0", n)
	}

	// Positive control: the canonical key still succeeds against the
	// same orphan.
	w2 := doPayoutReady(t, store, canonical, payoutReadyBodyMap(provider, canonical, 900), "application/json", "operator")
	if w2.Code != http.StatusCreated {
		t.Fatalf("canonical code=%d body=%s want 201", w2.Code, w2.Body.String())
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, canonical); n != 1 {
		t.Errorf("canonical rows=%d want 1", n)
	}
}

// --- 5. no matching orphan -> 422 ------------------------------------

func TestPayoutReady_NoMatchingOrphan422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-noorphan"
	seedProviderToken(t, store.db, provider)
	// No orphan seeded; craft a key pointing at a nonexistent orphan.
	key := compensationKey(4242, 1)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "no_matching_orphan" {
		t.Errorf("code=%q want no_matching_orphan", code)
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- 6. already compensated -> 422 -----------------------------------

func TestPayoutReady_AlreadyCompensated422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-comp"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	// Simulate the later /admin/payout/record-orphan link step.
	if _, err := store.db.Exec(`
UPDATE payout_reorg_orphans SET compensation_settlement_id = ? WHERE payout_id=? AND attempt_seq=?`,
		origID, origID, seq); err != nil {
		t.Fatalf("set compensation id: %v", err)
	}
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "orphan_already_compensated" {
		t.Errorf("code=%q want orphan_already_compensated", code)
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- 7. each binding mismatch -> 422 orphan_mismatch (named field) ---

func TestPayoutReady_BindingMismatch422(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(m map[string]any)
		field  string
	}{
		{"provider_id", func(m map[string]any) { m["provider_id"] = "other-prov" }, "provider_id"},
		{"provider_credits", func(m map[string]any) { m["provider_credits"] = 800; m["gross_credits"] = 800 }, "provider_credits"},
		{"gross_credits", func(m map[string]any) { m["gross_credits"] = 800 }, "gross_credits"},
		{"operator_credits", func(m map[string]any) { m["operator_credits"] = 5 }, "operator_credits"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store := payoutReadyFixture(t)
			provider := "prov-bind-" + tc.name
			seedProviderToken(t, store.db, provider)
			// Seed a second provider token so a provider_id mismatch is
			// not itself a provider_not_found.
			seedProviderToken(t, store.db, "other-prov")
			origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
			key := compensationKey(origID, seq)
			body := payoutReadyBodyMap(provider, key, 900)
			tc.mutate(body)
			w := doPayoutReady(t, store, key, body, "application/json", "operator")
			if w.Code != http.StatusUnprocessableEntity {
				t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
			}
			if code := decodeErrCode(t, w); code != "orphan_mismatch" {
				t.Fatalf("code=%q want orphan_mismatch", code)
			}
			// The message must name the failed field.
			if !strings.Contains(w.Body.String(), tc.field) {
				t.Errorf("body %s does not name field %q", w.Body.String(), tc.field)
			}
			assertNoPayoutReadySideEffects(t, store, key)
		})
	}
}

// --- 8. provider_credits > cap -> 422 --------------------------------

func TestPayoutReady_OverCap422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-cap"
	seedProviderToken(t, store.db, provider)
	over := testPerPayoutCap + 1
	origID, seq := seedOrphan(t, store, provider, over, over, over)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, over), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "per_payout_cap_exceeded" {
		t.Errorf("code=%q want per_payout_cap_exceeded", code)
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- 9. gross != provider strict -> 422 ------------------------------
// Both the orphan binding (gross must equal observed_provider_credits)
// and the standalone strict check (gross must equal provider_credits)
// reject gross != provider. Binding is evaluated first, so a gross !=
// provider request 422s as orphan_mismatch; the standalone
// gross_provider_mismatch check is defense-in-depth against a future
// binding change. Accept either code.
func TestPayoutReady_GrossProviderStrict_CoveredByBinding(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-strict"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	body := payoutReadyBodyMap(provider, key, 900)
	// gross != provider; binding pins gross to observed_provider_credits(900)
	// so gross=800 trips gross_credits binding first.
	body["gross_credits"] = 800
	w := doPayoutReady(t, store, key, body, "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d want 422", w.Code)
	}
	code := decodeErrCode(t, w)
	if code != "orphan_mismatch" && code != "gross_provider_mismatch" {
		t.Errorf("code=%q want orphan_mismatch or gross_provider_mismatch", code)
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- 10. unknown provider -> 422 -------------------------------------

func TestPayoutReady_UnknownProvider422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-unknown"
	// Deliberately do NOT seed provider_tokens for this provider.
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "provider_not_found" {
		t.Errorf("code=%q want provider_not_found", code)
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- 11. missing bearer -> 403 ---------------------------------------

func TestPayoutReady_MissingBearer403(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-noauth"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "")
	if w.Code != http.StatusForbidden {
		t.Fatalf("code=%d body=%s want 403", w.Code, w.Body.String())
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- 12. wrong method -> 405 -----------------------------------------

func TestPayoutReady_WrongMethod405(t *testing.T) {
	store := payoutReadyFixture(t)
	req := httptest.NewRequest(http.MethodGet, payoutReadyPath, nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.HandlersWithQuarantineGatesIdlePrewarmAndPayoutCap("operator", fakeTokens{}, true, 60, false, false, nil, testPerPayoutCap).ServeHTTP(w, req)
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("code=%d body=%s want 405", w.Code, w.Body.String())
	}
}

// mountedPayoutReadyHandler builds a single persistent handler (shared
// admin rate-limit bucket) with the given cap. Reuse it across requests
// to exercise rate-limit exhaustion.
func mountedPayoutReadyHandler(store *Store, cap int64) http.Handler {
	return store.HandlersWithQuarantineGatesIdlePrewarmAndPayoutCap("operator", fakeTokens{}, true, 60, false, false, nil, cap)
}

func payoutReadyReq(method, bearer, headerKey, bodyJSON string) *http.Request {
	req := httptest.NewRequest(method, payoutReadyPath, strings.NewReader(bodyJSON))
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	req.Header.Set("Content-Type", "application/json")
	if headerKey != "" {
		req.Header.Set("Idempotency-Key", headerKey)
	}
	return req
}

// --- FIX 12a. wrong bearer -> 403 (auth precedes method) -------------

func TestPayoutReady_WrongBearer403(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-wrongbearer"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	// Wrong bearer on a POST → 403.
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "not-the-operator")
	if w.Code != http.StatusForbidden {
		t.Fatalf("code=%d body=%s want 403", w.Code, w.Body.String())
	}
	assertNoPayoutReadySideEffects(t, store, key)

	// Order: auth precedes method — a GET with a wrong bearer is 403,
	// NOT 405.
	h := mountedPayoutReadyHandler(store, testPerPayoutCap)
	wg := httptest.NewRecorder()
	h.ServeHTTP(wg, payoutReadyReq(http.MethodGet, "not-the-operator", key, "{}"))
	if wg.Code != http.StatusForbidden {
		t.Fatalf("GET+wrong-bearer code=%d want 403 (auth before method)", wg.Code)
	}
	assertNoPayoutReadySideEffects(t, store, key)
}

// --- FIX 12c. non-POST (PUT) -> 405 ----------------------------------

func TestPayoutReady_PutMethod405(t *testing.T) {
	store := payoutReadyFixture(t)
	h := mountedPayoutReadyHandler(store, testPerPayoutCap)
	w := httptest.NewRecorder()
	h.ServeHTTP(w, payoutReadyReq(http.MethodPut, "operator", "reorg_compensation:1:1", "{}"))
	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("PUT code=%d body=%s want 405", w.Code, w.Body.String())
	}
	assertNoPayoutReadySideEffects(t, store, "reorg_compensation:1:1")
}

// --- FIX 12d. admin rate-limit exhausted -> 429 (precedes method) ----

func TestPayoutReady_RateLimit429(t *testing.T) {
	store := payoutReadyFixture(t)
	h := mountedPayoutReadyHandler(store, testPerPayoutCap)
	// Drain the shared bucket (capacity 128). Each AUTHENTICATED request
	// consumes a token regardless of outcome; these all 400 on the bad
	// key (post-auth, post-ratelimit) so they never insert.
	var got429 bool
	for i := 0; i < 200; i++ {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, payoutReadyReq(http.MethodPost, "operator", "bad-key", `{"idempotency_key":"bad-key"}`))
		if w.Code == http.StatusTooManyRequests {
			got429 = true
		}
	}
	if !got429 {
		t.Fatalf("expected at least one 429 after draining the admin bucket")
	}
	// Order: rate-limit precedes method — a GET on the drained bucket is
	// 429, NOT 405.
	wg := httptest.NewRecorder()
	h.ServeHTTP(wg, payoutReadyReq(http.MethodGet, "operator", "reorg_compensation:1:1", "{}"))
	if wg.Code != http.StatusTooManyRequests {
		t.Fatalf("GET on drained bucket code=%d want 429 (rate-limit before method)", wg.Code)
	}
	// No durable side-effects from any of the above.
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); n != 0 {
		t.Errorf("ledger rows=%d want 0", n)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted); n != 0 {
		t.Errorf("audit rows=%d want 0", n)
	}
}

// --- FIX 13. cap <= 0 -> fail-closed 404 (endpoint not mounted) ------

func TestPayoutReady_CapZeroFailsClosed(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-capzero"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	bodyJSON, _ := json.Marshal(payoutReadyBodyMap(provider, key, 900))
	for _, cap := range []int64{0, -1} {
		h := mountedPayoutReadyHandler(store, cap)
		w := httptest.NewRecorder()
		h.ServeHTTP(w, payoutReadyReq(http.MethodPost, "operator", key, string(bodyJSON)))
		if w.Code != http.StatusNotFound {
			t.Fatalf("cap=%d code=%d body=%s want 404 (fail-closed)", cap, w.Code, w.Body.String())
		}
		assertNoPayoutReadySideEffects(t, store, key)
	}
}

// --- FIX 11. binds to immutable observed_* snapshot, not mutable lpr --
// After the orphan snapshot is recorded, mutating the original
// ledger_payout_ready row's provider_credits MUST NOT change the
// accept/reject decision: the endpoint binds to observed_*.
func TestPayoutReady_BindsToSnapshotNotMutableRow(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-snapshot"
	seedProviderToken(t, store.db, provider)
	// observed_provider_credits = 900. seedOrphan already seeds the
	// original lpr row with a DIVERGENT value (900+500=1400).
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)

	// Mutate the original (mutable) lpr row's provider_credits to 800.
	if _, err := store.db.Exec(`
UPDATE ledger_payout_ready SET provider_credits = 800 WHERE id = ?`, origID); err != nil {
		t.Fatalf("mutate lpr: %v", err)
	}

	// A request matching the MUTATED lpr (800) but NOT observed_* (900)
	// must be rejected — proves the endpoint does not read lpr.*.
	rejBody := payoutReadyBodyMap(provider, key, 800)
	wRej := doPayoutReady(t, store, key, rejBody, "application/json", "operator")
	if wRej.Code != http.StatusUnprocessableEntity {
		t.Fatalf("lpr-matching request code=%d body=%s want 422", wRej.Code, wRej.Body.String())
	}
	if code := decodeErrCode(t, wRej); code != "orphan_mismatch" {
		t.Errorf("code=%q want orphan_mismatch", code)
	}
	assertNoPayoutReadySideEffects(t, store, key)

	// A request matching observed_* (900) still succeeds despite the
	// mutated lpr row — decision unchanged, bound to the snapshot.
	wOK := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if wOK.Code != http.StatusCreated {
		t.Fatalf("observed-matching request code=%d body=%s want 201", wOK.Code, wOK.Body.String())
	}
}

// --- extra: missing reason -> 400 ------------------------------------

func TestPayoutReady_MissingReason400(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-reason"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	body := payoutReadyBodyMap(provider, key, 900)
	body["reason"] = "   "
	w := doPayoutReady(t, store, key, body, "application/json", "operator")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("code=%d body=%s want 400", w.Code, w.Body.String())
	}
}

// --- 14. same-DB cross-txn atomicity: a failed insert leaves no
//         audit row and no ledger row (all-or-nothing). -------------

func TestPayoutReady_AtomicityNoPartialWrites(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-atomic"
	seedProviderToken(t, store.db, provider)
	// over-cap request: fails AFTER orphan lookup + provider check but
	// BEFORE any INSERT — no ledger row, no audit row must persist.
	over := testPerPayoutCap + 1
	origID, seq := seedOrphan(t, store, provider, over, over, over)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, over), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d want 422", w.Code)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key); n != 0 {
		t.Errorf("ledger rows for failed request=%d want 0", n)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted); n != 0 {
		t.Errorf("audit rows for failed request=%d want 0", n)
	}

	// Now prove the SUCCESS path writes BOTH rows atomically in the same
	// SQLite DB (ledger row + audit row appear together).
	store2 := payoutReadyFixture(t)
	seedProviderToken(t, store2.db, provider)
	oID, s2 := seedOrphan(t, store2, provider, 900, 950, 900)
	k2 := compensationKey(oID, s2)
	w2 := doPayoutReady(t, store2, k2, payoutReadyBodyMap(provider, k2, 900), "application/json", "operator")
	if w2.Code != http.StatusCreated {
		t.Fatalf("code=%d want 201", w2.Code)
	}
	ledgerN := scalar(t, store2.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, k2)
	auditN := scalar(t, store2.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted)
	if ledgerN != 1 || auditN != 1 {
		t.Errorf("atomic success wrote ledger=%d audit=%d want 1/1", ledgerN, auditN)
	}
}

// --- 15. cancel-self-transfer orphan -> 422 orphan_not_compensable ---
// SPEC-016 lines 2043–2048: a cancel self-transfer does not consume
// ledger_payout_ready and the §9.5b compensation flow does not apply.
// record-orphan writes an orphan row for cancel attempts too, so the
// endpoint MUST reject them or it would mint USDC for a non-compensable
// event.
func TestPayoutReady_CancelOrphanNotCompensable422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-cancel"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	markAttemptCancel(t, store.db, origID, seq)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "orphan_not_compensable" {
		t.Errorf("code=%q want orphan_not_compensable", code)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key); n != 0 {
		t.Errorf("ledger rows=%d want 0 (no compensation minted)", n)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted); n != 0 {
		t.Errorf("audit rows=%d want 0", n)
	}
}

// --- 16. ambiguous orphan (two unresolved rows) -> 422 ---------------
// SPEC §9.5b.1 line 4481 requires EXACTLY ONE orphan row. The partial
// UNIQUE index keys on orphan_tx_hash, so two unresolved orphans with
// different tx hashes for the same (payout_id, attempt_seq) can coexist.
func TestPayoutReady_AmbiguousOrphan422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-ambig"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	// Second unresolved orphan for the same (payout_id, attempt_seq),
	// different orphan_tx_hash.
	insertOrphanRow(t, store.db, origID, seq, "0xorphan-2", provider, 900, 950, 900)
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "ambiguous_orphan" {
		t.Errorf("code=%q want ambiguous_orphan", code)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key); n != 0 {
		t.Errorf("ledger rows=%d want 0", n)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted); n != 0 {
		t.Errorf("audit rows=%d want 0 (ambiguity path must not audit)", n)
	}
}

// --- 17. terminally-resolved (uncompensated) orphan -> 422 -----------
// An operator can record a terminal "no compensation" resolution via
// /admin/payout/record-orphan (operator_resolution + resolved_at_utc
// set, compensation_settlement_id left NULL). Such an orphan MUST NOT
// be compensable — the endpoint filters on resolved_at_utc IS NULL and
// so returns no_matching_orphan (fail-closed), not a fresh payout.
func TestPayoutReady_ResolvedOrphanNotCompensable422(t *testing.T) {
	store := payoutReadyFixture(t)
	const provider = "prov-resolved"
	seedProviderToken(t, store.db, provider)
	origID, seq := seedOrphan(t, store, provider, 900, 950, 900)
	// Terminal record-only resolution: operator decided NOT to pay.
	if _, err := store.db.Exec(`
UPDATE payout_reorg_orphans
   SET operator_resolution = 'no compensation; provider acknowledged',
       resolved_at_utc = '2026-01-04T00:00:00Z'
 WHERE payout_id = ? AND attempt_seq = ?`, origID, seq); err != nil {
		t.Fatalf("set terminal resolution: %v", err)
	}
	key := compensationKey(origID, seq)
	w := doPayoutReady(t, store, key, payoutReadyBodyMap(provider, key, 900), "application/json", "operator")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("code=%d body=%s want 422", w.Code, w.Body.String())
	}
	if code := decodeErrCode(t, w); code != "no_matching_orphan" {
		t.Errorf("code=%q want no_matching_orphan", code)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE idempotency_key = ?`, key); n != 0 {
		t.Errorf("ledger rows=%d want 0 (resolved orphan must not mint payout)", n)
	}
	if n := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventPayoutReadyInserted); n != 0 {
		t.Errorf("audit rows=%d want 0", n)
	}
}
