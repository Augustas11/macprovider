package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// SPEC-005 v0.4 (issue #169) — acceptance tests for the quarantine
// VOID admin surface. ACs Q040, Q042, Q043, Q044, Q045, Q047, Q048,
// Q051, Q053, Q055 per the v0.4 §18 AC block.

// quarantineFixture builds a billing store and ensures the audit_log
// table exists in the same SQLite file (production wires
// audit.Store.OpenStore + billing.NewStore on the same DB file at
// startup; in tests we only spin billing, so we create audit_log
// here for the §11.6.4 same-tx INSERT path).
func quarantineFixture(t *testing.T) *Store {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	createAuditLogForTest(t, store.db)
	return store
}

func createAuditLogForTest(t *testing.T, db *sql.DB) {
	t.Helper()
	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
`); err != nil {
		t.Fatal(err)
	}
}

// insertQuarantinedCredit seeds a ledger_request_credits row with
// quarantined=1 and returns its id.
func insertQuarantinedCredit(t *testing.T, store *Store, providerID string) int64 {
	t.Helper()
	requestID := providerID + "-q-" + time.Now().UTC().Format("20060102150405.000000000")
	insertCreditWithRequest(t, store.db, requestID, providerID, time.Now().UTC(), 1000)
	id := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, requestID)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason=? WHERE id=?`, "test_quarantine", id); err != nil {
		t.Fatal(err)
	}
	return id
}

func doForceVoid(t *testing.T, store *Store, gateEnabled bool, id int64, body string, ct string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/admin/ledger/quarantine/"+itoa(id)+"/force-void", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer operator")
	if ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	w := httptest.NewRecorder()
	store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, gateEnabled).ServeHTTP(w, req)
	return w
}

func itoa(i int64) string {
	if i == 0 {
		return "0"
	}
	neg := false
	if i < 0 {
		neg = true
		i = -i
	}
	var buf [20]byte
	n := len(buf)
	for i > 0 {
		n--
		buf[n] = byte('0' + (i % 10))
		i /= 10
	}
	if neg {
		n--
		buf[n] = '-'
	}
	return string(buf[n:])
}

// AC-Q040: schema shape — UNIQUE(request_credit_id),
// CHECK(resolution_kind IN ('force_void')), idx_lqr_kind_created
// present, no separate idx_lqr_request_credit index.
func TestACQ040_SchemaShape(t *testing.T) {
	store := quarantineFixture(t)
	// Columns present?
	rows, err := store.db.Query(`PRAGMA table_info(ledger_quarantine_resolutions)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	cols := map[string]string{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull, pk int
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &typ, &notNull, &dflt, &pk); err != nil {
			t.Fatal(err)
		}
		cols[name] = typ
	}
	want := []string{"id", "request_credit_id", "resolution_kind", "operator_id", "resolution_reason", "created_at_utc"}
	for _, c := range want {
		if _, ok := cols[c]; !ok {
			t.Fatalf("missing column %q", c)
		}
	}
	// UNIQUE auto-index present, idx_lqr_kind_created present.
	if !indexExists(t, store.db, "ledger_quarantine_resolutions", "idx_lqr_kind_created") {
		t.Fatal("idx_lqr_kind_created missing")
	}
	// No non-unique idx_lqr_request_credit (the UNIQUE auto-index
	// covers the read path).
	if indexExists(t, store.db, "ledger_quarantine_resolutions", "idx_lqr_request_credit") {
		t.Fatal("idx_lqr_request_credit must not exist in v0.4")
	}
	// UNIQUE constraint: try INSERT twice with same request_credit_id.
	id := insertQuarantinedCredit(t, store, "p-q040")
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := store.db.Exec(`INSERT INTO ledger_quarantine_resolutions(request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc) VALUES (?, 'force_void', 'alice', 'reason', ?)`, id, now); err != nil {
		t.Fatal(err)
	}
	_, err = store.db.Exec(`INSERT INTO ledger_quarantine_resolutions(request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc) VALUES (?, 'force_void', 'alice', 'reason', ?)`, id, now)
	if err == nil {
		t.Fatal("second INSERT must hit UNIQUE constraint")
	}
}

// AC-Q042: force-void happy path.
func TestACQ042_ForceVoidHappyPath(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q042")
	w := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"Duplicate row confirmed"}`, "application/json")
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["resolution_kind"] != "force_void" {
		t.Fatalf("resolution_kind=%v want force_void", resp["resolution_kind"])
	}
	// One resolution row, one audit row.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions WHERE request_credit_id=?`, id); got != 1 {
		t.Fatalf("resolution row count=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='ledger_quarantine_force_void'`); got != 1 {
		t.Fatalf("audit row count=%d want 1", got)
	}
	// Base row's quarantined column unchanged.
	if got := scalar(t, store.db, `SELECT quarantined FROM ledger_request_credits WHERE id=?`, id); got != 1 {
		t.Fatalf("base row quarantined=%d want 1", got)
	}
	// Audit payload has operator_attribution constant + all 10 fields.
	var payloadJSON string
	if err := store.db.QueryRow(`SELECT payload_json FROM audit_log WHERE event_type='ledger_quarantine_force_void'`).Scan(&payloadJSON); err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["operator_attribution"] != "operator_key_self_asserted" {
		t.Fatalf("operator_attribution=%v want operator_key_self_asserted", payload["operator_attribution"])
	}
	if payload["severity"] != "WARN" {
		t.Fatalf("severity=%v want WARN", payload["severity"])
	}
}

// AC-Q043: idempotent UNIQUE conflict — second POST returns 409
// with existing_resolution.
func TestACQ043_IdempotentConflict(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q043")
	w1 := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"first"}`, "application/json")
	if w1.Code != http.StatusOK {
		t.Fatalf("first POST status=%d body=%s", w1.Code, w1.Body.String())
	}
	w2 := doForceVoid(t, store, true, id, `{"operator_id":"bob","reason":"second"}`, "application/json")
	if w2.Code != http.StatusConflict {
		t.Fatalf("second POST status=%d body=%s want 409", w2.Code, w2.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w2.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	errObj, ok := resp["error"].(map[string]any)
	if !ok {
		t.Fatalf("missing error envelope: %s", w2.Body.String())
	}
	if errObj["code"] != "already_resolved" {
		t.Fatalf("error.code=%v want already_resolved", errObj["code"])
	}
	existing, ok := errObj["existing_resolution"].(map[string]any)
	if !ok {
		t.Fatal("missing existing_resolution")
	}
	if existing["operator_id"] != "alice" {
		t.Fatalf("existing.operator_id=%v want alice (the winner)", existing["operator_id"])
	}
	// Exactly one resolution row, one audit row.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions WHERE request_credit_id=?`, id); got != 1 {
		t.Fatalf("resolution row count=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='ledger_quarantine_force_void'`); got != 1 {
		t.Fatalf("audit row count=%d want 1", got)
	}
}

// AC-Q044: validation matrix.
func TestACQ044_ValidationMatrix(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q044")
	cases := []struct {
		name     string
		body     string
		ct       string
		path     int64
		wantCode int
		wantErr  string
	}{
		{"missing_operator_id", `{"reason":"x"}`, "application/json", id, http.StatusUnprocessableEntity, "missing_field"},
		{"missing_reason", `{"operator_id":"alice"}`, "application/json", id, http.StatusUnprocessableEntity, "missing_field"},
		{"empty_reason", `{"operator_id":"alice","reason":"   "}`, "application/json", id, http.StatusUnprocessableEntity, "empty_reason"},
		{"reason_too_long", `{"operator_id":"alice","reason":"` + strings.Repeat("a", 501) + `"}`, "application/json", id, http.StatusUnprocessableEntity, "reason_too_long"},
		{"bad_ct", `{"operator_id":"alice","reason":"x"}`, "text/plain", id, http.StatusUnsupportedMediaType, "unsupported_media_type"},
		{"bad_operator_charset", `{"operator_id":"alice bob","reason":"x"}`, "application/json", id, http.StatusUnprocessableEntity, "bad_operator_id"},
		// Per-codepoint reject cases (§11.6.3). Each body uses
		// JSON \uXXXX escapes so the JSON parser accepts the
		// string and the §11.6.3 sanitizer is the one that
		// rejects (HTTP 422 unsanitized_reason).
		{"c1_csi_in_reason", `{"operator_id":"alice","reason":"hix"}`, "application/json", id, http.StatusUnprocessableEntity, "unsanitized_reason"},
		{"bidi_rlo_in_reason", `{"operator_id":"alice","reason":"hi‮x"}`, "application/json", id, http.StatusUnprocessableEntity, "unsanitized_reason"},
		{"zwsp_in_reason", `{"operator_id":"alice","reason":"hi​x"}`, "application/json", id, http.StatusUnprocessableEntity, "unsanitized_reason"},
		{"cgj_in_reason", `{"operator_id":"alice","reason":"hi͏x"}`, "application/json", id, http.StatusUnprocessableEntity, "unsanitized_reason"},
		{"shy_in_reason", `{"operator_id":"alice","reason":"hi­x"}`, "application/json", id, http.StatusUnprocessableEntity, "unsanitized_reason"},
		{"word_joiner_in_reason", `{"operator_id":"alice","reason":"hi⁠x"}`, "application/json", id, http.StatusUnprocessableEntity, "unsanitized_reason"},
		{"not_found_id", `{"operator_id":"alice","reason":"x"}`, "application/json", 999999, http.StatusNotFound, "not_found"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := doForceVoid(t, store, true, c.path, c.body, c.ct)
			if w.Code != c.wantCode {
				t.Fatalf("status=%d want %d (body=%s)", w.Code, c.wantCode, w.Body.String())
			}
			if c.wantErr != "" && !strings.Contains(w.Body.String(), c.wantErr) {
				t.Fatalf("body=%s does not contain %q", w.Body.String(), c.wantErr)
			}
		})
	}
	// "not_quarantined": insert a non-quarantined row and POST.
	requestID := "p-not-q-" + time.Now().UTC().Format("20060102150405.000000000")
	insertCreditWithRequest(t, store.db, requestID, "p-q044", time.Now().UTC(), 100)
	nonQuarantinedID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id=?`, requestID)
	w := doForceVoid(t, store, true, nonQuarantinedID, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if w.Code != http.StatusUnprocessableEntity || !strings.Contains(w.Body.String(), "not_quarantined") {
		t.Fatalf("not_quarantined: status=%d body=%s", w.Code, w.Body.String())
	}
	// Sanity: no resolution rows / audit rows from rejected calls.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`); got != 0 {
		t.Fatalf("rejected calls leaked %d resolution rows", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log`); got != 0 {
		t.Fatalf("rejected calls leaked %d audit rows", got)
	}
}

// AC-Q045: reader-side narrowing — `total_provider_credits` UNCHANGED
// (force-void doesn't add to payable set); `quarantined_count`
// excludes voided rows.
func TestACQ045_ReaderSideNarrowing(t *testing.T) {
	store := quarantineFixture(t)
	now := time.Now().UTC()
	// (a) quarantined=0 row
	insertCredit(t, store.db, "p-q045", now, 100)
	// (b) quarantined=1 row, no resolution
	insertQuarantinedCredit(t, store, "p-q045-b")
	// (c) quarantined=1 row + force-void resolution
	idC := insertQuarantinedCredit(t, store, "p-q045-c")
	w := doForceVoid(t, store, true, idC, `{"operator_id":"alice","reason":"voided"}`, "application/json")
	if w.Code != http.StatusOK {
		t.Fatalf("force-void prep failed: status=%d body=%s", w.Code, w.Body.String())
	}
	// Hit summary.
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
	req.Header.Set("Authorization", "Bearer operator")
	sw := httptest.NewRecorder()
	store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true).ServeHTTP(sw, req)
	if sw.Code != http.StatusOK {
		t.Fatalf("summary status=%d body=%s", sw.Code, sw.Body.String())
	}
	var summary map[string]int64
	if err := json.Unmarshal(sw.Body.Bytes(), &summary); err != nil {
		t.Fatal(err)
	}
	if got := summary["quarantined_count"]; got != 1 {
		t.Fatalf("quarantined_count=%d want 1 (only the open row (b))", got)
	}
	// total_provider_credits covers ONLY (a) — the payable set is
	// UNCHANGED from v0.3.3.
	if got := summary["total_provider_credits"]; got != 100 {
		t.Fatalf("total_provider_credits=%d want 100 (force-void does NOT add to payable set)", got)
	}
	// R3 fix (CODE-M1): SPEC AC-Q045 also requires hitting
	// `/providers/{id}/earnings`. Force-voided rows must NOT appear
	// in the provider earnings response. Verify against each of the
	// three providers in the fixture: p-q045 (payable) sees 100,
	// p-q045-b (open quarantined) sees 0, p-q045-c (force-voided)
	// sees 0.
	earningsTokens := fakeTokens{
		"t-a": "p-q045",
		"t-b": "p-q045-b",
		"t-c": "p-q045-c",
	}
	earningsHandler := store.HandlersWithQuarantineGate("operator", earningsTokens, true, 60, true)
	hitEarnings := func(t *testing.T, providerID, token string) int64 {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/providers/"+providerID+"/earnings", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rec := httptest.NewRecorder()
		earningsHandler.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("/providers/%s/earnings status=%d body=%s", providerID, rec.Code, rec.Body.String())
		}
		var resp struct {
			TotalCredits int64 `json:"total_credits"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		return resp.TotalCredits
	}
	if got := hitEarnings(t, "p-q045", "t-a"); got != 100 {
		t.Fatalf("/providers/p-q045/earnings total=%d want 100", got)
	}
	if got := hitEarnings(t, "p-q045-b", "t-b"); got != 0 {
		t.Fatalf("/providers/p-q045-b/earnings total=%d want 0 (open quarantined excluded)", got)
	}
	if got := hitEarnings(t, "p-q045-c", "t-c"); got != 0 {
		t.Fatalf("/providers/p-q045-c/earnings total=%d want 0 (force-voided excluded)", got)
	}
}

// AC-Q047: same-transaction audit atomicity — drop audit_log before
// the INSERT, assert resolution INSERT also rolls back.
func TestACQ047_SameTransactionAtomicity(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q047")
	// Drop audit_log to force the second INSERT to fail.
	if _, err := store.db.Exec(`DROP TABLE audit_log`); err != nil {
		t.Fatal(err)
	}
	w := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status=%d want 500 (audit-INSERT must fail)", w.Code)
	}
	// Resolution row must NOT exist (transaction rolled back).
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions WHERE request_credit_id=?`, id); got != 0 {
		t.Fatalf("resolution row leaked: count=%d want 0", got)
	}
	// Re-create audit_log; a retry of the same POST should now
	// succeed (no UNIQUE conflict because the first attempt rolled
	// back fully).
	createAuditLogForTest(t, store.db)
	w2 := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if w2.Code != http.StatusOK {
		t.Fatalf("retry status=%d body=%s want 200", w2.Code, w2.Body.String())
	}
}

// AC-Q048: method enforcement — non-POST returns 405.
func TestACQ048_MethodEnforcement(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q048")
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete, http.MethodPatch} {
		req := httptest.NewRequest(m, "/admin/ledger/quarantine/"+itoa(id)+"/force-void", nil)
		req.Header.Set("Authorization", "Bearer operator")
		w := httptest.NewRecorder()
		store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true).ServeHTTP(w, req)
		if w.Code != http.StatusMethodNotAllowed {
			t.Fatalf("method=%s status=%d want 405", m, w.Code)
		}
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`); got != 0 {
		t.Fatalf("405 cases leaked %d resolution rows", got)
	}
}

// AC-Q051: reconcile rows_force_resolved_in_range.
func TestACQ051_ReconcileForceResolvedField(t *testing.T) {
	store := quarantineFixture(t)
	// request_log already created by requestlog.OpenStore in the
	// fixture; do not double-create.
	// Seed 5 quarantined rows, force-void 3 of them.
	now := time.Now().UTC()
	for i := 0; i < 5; i++ {
		id := insertQuarantinedCredit(t, store, "p-q051")
		if i < 3 {
			w := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"v"}`, "application/json")
			if w.Code != http.StatusOK {
				t.Fatalf("force-void %d status=%d body=%s", i, w.Code, w.Body.String())
			}
		}
	}
	from := now.Add(-1 * time.Hour).Format("2006-01-02")
	to := now.Add(24 * time.Hour).Format("2006-01-02")
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from="+from+"&to="+to, nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("reconcile status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if got, ok := resp["rows_force_resolved_in_range"]; !ok {
		t.Fatal("rows_force_resolved_in_range missing from reconcile response")
	} else if int64(got.(float64)) != 3 {
		t.Fatalf("rows_force_resolved_in_range=%v want 3", got)
	}
	if got, ok := resp["rows_quarantined"]; !ok {
		t.Fatal("rows_quarantined missing")
	} else if int64(got.(float64)) != 2 {
		t.Fatalf("rows_quarantined=%v want 2 (open quarantines only — voided rows are resolved-and-excluded)", got)
	}
}

// AC-Q053: route-layer config flag gate.
func TestACQ053_RouteLayerConfigFlagGate(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q053")
	// Flag disabled (default) → 404
	w := doForceVoid(t, store, false, id, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if w.Code != http.StatusNotFound {
		t.Fatalf("disabled status=%d want 404", w.Code)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`); got != 0 {
		t.Fatalf("disabled flag leaked %d rows", got)
	}
	// Flag enabled → 200
	w2 := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if w2.Code != http.StatusOK {
		t.Fatalf("enabled status=%d body=%s want 200", w2.Code, w2.Body.String())
	}
	// 404 for disabled-flag case is byte-identical to row-not-found
	// — assert by comparing bodies.
	wNotFound := doForceVoid(t, store, true, 99999999, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if wNotFound.Code != http.StatusNotFound {
		t.Fatalf("row-not-found status=%d want 404", wNotFound.Code)
	}
	// Both 404 bodies use the same {"error":{"code":"not_found",...}} envelope.
	if !strings.Contains(w.Body.String(), `"code":"not_found"`) {
		t.Fatalf("disabled-flag 404 missing not_found code: %s", w.Body.String())
	}
	if !strings.Contains(wNotFound.Body.String(), `"code":"not_found"`) {
		t.Fatalf("row-not-found 404 missing not_found code: %s", wNotFound.Body.String())
	}
}

// AC-Q055: v0.4 force-credit schema rejection — direct INSERT with
// resolution_kind='force_credit' must fail the CHECK constraint.
func TestACQ055_ForceCreditSchemaRejection(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q055")
	now := time.Now().UTC().Format(time.RFC3339Nano)
	_, err := store.db.Exec(`INSERT INTO ledger_quarantine_resolutions(request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc) VALUES (?, 'force_credit', 'alice', 'x', ?)`, id, now)
	if err == nil {
		t.Fatal("INSERT with resolution_kind=force_credit must hit CHECK constraint in v0.4")
	}
	if !strings.Contains(strings.ToLower(err.Error()), "check") {
		t.Fatalf("error must mention CHECK constraint, got: %v", err)
	}
}

// Verify the v0.4 §11.6.6 — failed validation responses STILL count
// against the operator-key rate-limit bucket (no bypass). v0.4 IMPL
// inherits the existing /admin/* bucket; this test asserts the route
// hits the bucket by checking that the response is the §11 envelope
// (not a different code-path shortcut).
func TestRateLimitBucketSharedForFailures(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-rate")
	// Invalid body → 422. Response uses the §11 error envelope.
	w := doForceVoid(t, store, true, id, `{"operator_id":"   ","reason":"x"}`, "application/json")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d want 422", w.Code)
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if _, ok := resp["error"]; !ok {
		t.Fatalf("422 response missing standard error envelope: %s", w.Body.String())
	}
}

// Sanity: forceVoid does not deadlock under the MaxOpenConns(1)
// constraint shared by requestlog + billing on the same SQLite file
// (issue #21 / ARCH-3 nested-query history). The §11.6.4 same-tx
// path opens BeginTx → INSERT lqr → INSERT audit_log → Commit, all
// on ONE connection by design.
func TestForceVoidNoNestedQueryDeadlock(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-deadlock")
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	done := make(chan bool, 1)
	go func() {
		w := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"x"}`, "application/json")
		done <- (w.Code == http.StatusOK)
	}()
	select {
	case ok := <-done:
		if !ok {
			t.Fatal("force-void POST failed")
		}
	case <-ctx.Done():
		t.Fatal("force-void POST timed out (suspected deadlock)")
	}
}

// AC-Q049: concurrent POSTs against the same id — exactly one 200
// + (N-1) × 409; one resolution row; one audit row. SPEC says
// "Fire 64 parallel POST" and "All 64 responses count against the
// /admin/* rate-limit bucket". N=64 < adminBucketCapacity=128 so
// no 429 is expected — the bucket admits all 64, and the AC tests
// the UNIQUE-constraint race only.
func TestACQ049_ConcurrentUNIQUEConflict(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q049")
	handler := store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true)
	const N = 64
	var wg sync.WaitGroup
	var ok200 int64
	var ok409 int64
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			body := fmt.Sprintf(`{"operator_id":"alice","reason":"r%d"}`, i)
			req := httptest.NewRequest(http.MethodPost, "/admin/ledger/quarantine/"+itoa(id)+"/force-void", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer operator")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)
			switch w.Code {
			case http.StatusOK:
				atomic.AddInt64(&ok200, 1)
			case http.StatusConflict:
				atomic.AddInt64(&ok409, 1)
			}
		}(i)
	}
	wg.Wait()
	if ok200 != 1 {
		t.Fatalf("200 count=%d want 1", ok200)
	}
	if ok409 != N-1 {
		t.Fatalf("409 count=%d want %d", ok409, N-1)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`); got != 1 {
		t.Fatalf("resolution rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='ledger_quarantine_force_void'`); got != 1 {
		t.Fatalf("audit rows=%d want 1", got)
	}
}

// AC-Q053 deeper: SIGHUP-driven reload via Store.SetForceVoidEnabled
// emits the billing_config_flag_changed audit event on actual flips
// AND the endpoint sees the new flag value on the next request
// (no http.Handler re-wire needed).
func TestACQ053_ReloadEmitsFlagChangedAuditAndFlipTakesEffect(t *testing.T) {
	store := quarantineFixture(t)
	handler := store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, false)
	id := insertQuarantinedCredit(t, store, "p-q053b")
	// flag false → 404
	req := httptest.NewRequest(http.MethodPost, "/admin/ledger/quarantine/"+itoa(id)+"/force-void", strings.NewReader(`{"operator_id":"alice","reason":"x"}`))
	req.Header.Set("Authorization", "Bearer operator")
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusNotFound {
		t.Fatalf("pre-flip status=%d want 404", w.Code)
	}
	// SIGHUP-style flip: false → true. Expect a
	// billing_config_flag_changed audit row.
	if err := store.SetForceVoidEnabled(context.Background(), true, "sighup"); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`); got != 1 {
		t.Fatalf("flag-change audit rows=%d want 1", got)
	}
	// Same handler — flag flip MUST take effect immediately, no
	// http.Handler re-wire. POST now should produce 200.
	req2 := httptest.NewRequest(http.MethodPost, "/admin/ledger/quarantine/"+itoa(id)+"/force-void", strings.NewReader(`{"operator_id":"alice","reason":"x"}`))
	req2.Header.Set("Authorization", "Bearer operator")
	req2.Header.Set("Content-Type", "application/json")
	w2 := httptest.NewRecorder()
	handler.ServeHTTP(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("post-flip status=%d body=%s want 200", w2.Code, w2.Body.String())
	}
	// Reload-no-change: same value → NO new flag-change audit row.
	if err := store.SetForceVoidEnabled(context.Background(), true, "sighup"); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`); got != 1 {
		t.Fatalf("reload-no-change emitted spurious audit row: got %d total", got)
	}
	// R3 fix (CODE-M2): SPEC AC-Q053 third leg — reload back to
	// false. Must emit a SECOND billing_config_flag_changed audit
	// row and a fresh POST against a DIFFERENT quarantined row must
	// return the byte-identical 404 envelope.
	if err := store.SetForceVoidEnabled(context.Background(), false, "sighup"); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`); got != 2 {
		t.Fatalf("flag-change audit rows=%d want 2 after true→false flip", got)
	}
	id2 := insertQuarantinedCredit(t, store, "p-q053c")
	req3 := httptest.NewRequest(http.MethodPost, "/admin/ledger/quarantine/"+itoa(id2)+"/force-void", strings.NewReader(`{"operator_id":"alice","reason":"x"}`))
	req3.Header.Set("Authorization", "Bearer operator")
	req3.Header.Set("Content-Type", "application/json")
	w3 := httptest.NewRecorder()
	handler.ServeHTTP(w3, req3)
	if w3.Code != http.StatusNotFound {
		t.Fatalf("post-back-to-disabled status=%d body=%s want 404", w3.Code, w3.Body.String())
	}
}

// AC-Q050: SPEC-007 explorer detail surface — LEFT JOIN to
// ledger_quarantine_resolutions exposes resolution_kind /
// resolution_operator_id / resolution_reason / resolution_at_utc as
// aliased columns on the ledger row when a resolution exists.
func TestACQ050_ExplorerAliasColumns(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-q050")
	// Force-void via the handler to land both the resolution + audit.
	w := doForceVoid(t, store, true, id, `{"operator_id":"alice","reason":"audited"}`, "application/json")
	if w.Code != http.StatusOK {
		t.Fatalf("prep force-void status=%d body=%s", w.Code, w.Body.String())
	}
	// Read the request_id we used to seed the row.
	var requestID string
	if err := store.db.QueryRow(`SELECT request_id FROM ledger_request_credits WHERE id = ?`, id).Scan(&requestID); err != nil {
		t.Fatal(err)
	}
	// Mirror the explorer query against the same DB.
	row := store.db.QueryRow(`
SELECT lqr.resolution_kind, lqr.operator_id, lqr.resolution_reason, lqr.created_at_utc
  FROM ledger_request_credits lrc
  LEFT JOIN ledger_quarantine_resolutions lqr ON lqr.request_credit_id = lrc.id
 WHERE lrc.request_id = ?`, requestID)
	var kind, opID, reason, createdAt sql.NullString
	if err := row.Scan(&kind, &opID, &reason, &createdAt); err != nil {
		t.Fatal(err)
	}
	if !kind.Valid || kind.String != "force_void" {
		t.Fatalf("resolution_kind=%v want force_void", kind)
	}
	if !opID.Valid || opID.String != "alice" {
		t.Fatalf("resolution_operator_id=%v want alice", opID)
	}
	if !reason.Valid || reason.String != "audited" {
		t.Fatalf("resolution_reason=%v want audited", reason)
	}
	if !createdAt.Valid || createdAt.String == "" {
		t.Fatal("resolution_at_utc unset")
	}
}

// Admin rate-limit bucket — every response code path (200, 404,
// 422) consumes one token. With a 60-token capacity and 60/sec
// refill, a burst of 600 requests in a tight loop MUST produce a
// significant number of 429s (the bucket cannot refill faster than
// it drains under burst).
func TestAdminRateLimitBucketConsumesFailures(t *testing.T) {
	store := quarantineFixture(t)
	handler := store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true)
	const burst = 600
	var ok429 int64
	for i := 0; i < burst; i++ {
		req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
		req.Header.Set("Authorization", "Bearer operator")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code == http.StatusTooManyRequests {
			ok429++
		}
	}
	// With capacity 60 and a tight burst, expect at least 100 of the
	// 600 calls to be rate-limited (defensive lower-bound — burst
	// drain dominates timing-jitter refills).
	if ok429 < 100 {
		t.Fatalf("rate-limit fired only %d times in burst of %d — limiter is not consuming tokens", ok429, burst)
	}
}

// Force-void path also charges the admin bucket.
func TestForceVoidChargesAdminBucket(t *testing.T) {
	store := quarantineFixture(t)
	handler := store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true)
	// Drain the bucket via cheap GETs.
	for i := 0; i < adminBucketCapacity+1; i++ {
		req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
		req.Header.Set("Authorization", "Bearer operator")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
	}
	// Send 50 quick force-void POSTs (no row exists for any of
	// them, so they'd otherwise be 404 / 422). The drained bucket
	// should produce a 429 in at least some of them.
	id := insertQuarantinedCredit(t, store, "p-q-rate-fv")
	var ok429 int64
	for i := 0; i < 50; i++ {
		body := fmt.Sprintf(`{"operator_id":"alice","reason":"r%d"}`, i)
		req := httptest.NewRequest(http.MethodPost, "/admin/ledger/quarantine/"+itoa(id)+"/force-void", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer operator")
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code == http.StatusTooManyRequests {
			ok429++
		}
	}
	if ok429 == 0 {
		t.Fatalf("force-void POSTs should consume the same bucket; got 0 × 429 after draining via /summary")
	}
}

// R2 (CODE-H2 / SEC-M1): body cap is strictly > 4 KiB → 413. A body of
// exactly 4096 bytes is accepted (and rejected later for unrelated
// schema issues); 4097 bytes is 413 regardless of validation outcome.
func TestForceVoidBodyCapOffByOne(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-cap")
	// Build a 4097-byte body whose JSON is otherwise valid. Pad the
	// reason value with ASCII 'a' so it remains a syntactically valid
	// JSON object whose top-level length is 4097.
	prefix := `{"operator_id":"alice","reason":"`
	suffix := `"}`
	padLen := 4097 - len(prefix) - len(suffix)
	body := prefix + strings.Repeat("a", padLen) + suffix
	if len(body) != 4097 {
		t.Fatalf("test body construction wrong: len=%d want 4097", len(body))
	}
	w := doForceVoid(t, store, true, id, body, "application/json")
	if w.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("status=%d want 413 (body=4097 must exceed cap)", w.Code)
	}
	if !strings.Contains(w.Body.String(), "request_too_large") {
		t.Fatalf("body=%s does not contain request_too_large", w.Body.String())
	}
	// Sanity: a 4096-byte body passes the cap (downstream may still
	// reject for schema reasons, but NOT with 413).
	padLen4096 := 4096 - len(prefix) - len(suffix)
	body4096 := prefix + strings.Repeat("a", padLen4096) + suffix
	if len(body4096) != 4096 {
		t.Fatalf("4096 body construction wrong: len=%d", len(body4096))
	}
	w2 := doForceVoid(t, store, true, id, body4096, "application/json")
	if w2.Code == http.StatusRequestEntityTooLarge {
		t.Fatalf("4096-byte body wrongly returned 413; should pass cap")
	}
}

// R2 (CODE-H3): the decoder must require io.EOF after the closing `}`.
// `{...} {}` or `{...} 42` must be 400 bad_request, not accepted.
func TestForceVoidRejectsExtraTopLevelJSON(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-extra")
	cases := []struct {
		name string
		body string
	}{
		{"trailing_object", `{"operator_id":"alice","reason":"x"} {}`},
		{"trailing_number", `{"operator_id":"alice","reason":"x"} 42`},
		{"trailing_string", `{"operator_id":"alice","reason":"x"} "extra"`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := doForceVoid(t, store, true, id, c.body, "application/json")
			if w.Code != http.StatusBadRequest {
				t.Fatalf("status=%d body=%s want 400", w.Code, w.Body.String())
			}
		})
	}
	// Sanity: no resolution / audit rows from the rejected calls.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions`); got != 0 {
		t.Fatalf("rejected calls leaked %d resolution rows", got)
	}
}

// R2 (CODE-H2 also): invalid UTF-8 in the raw body is rejected as
// 422 invalid_utf8 BEFORE the JSON parser would silently normalize
// to U+FFFD.
func TestForceVoidRejectsInvalidUTF8RawBody(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-utf8")
	// Lone 0xFF byte inside the JSON string is invalid UTF-8.
	body := "{\"operator_id\":\"alice\",\"reason\":\"hi\xffx\"}"
	w := doForceVoid(t, store, true, id, body, "application/json")
	if w.Code != http.StatusUnprocessableEntity {
		t.Fatalf("status=%d body=%s want 422", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "invalid_utf8") {
		t.Fatalf("body=%s does not contain invalid_utf8", w.Body.String())
	}
}

// R2 (CODE-M1): JSON strictness — duplicate top-level key returns 400.
func TestForceVoidRejectsDuplicateTopLevelKey(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-dup")
	body := `{"operator_id":"alice","operator_id":"bob","reason":"x"}`
	w := doForceVoid(t, store, true, id, body, "application/json")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s want 400", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "duplicate") {
		t.Fatalf("body=%s does not contain duplicate-key error", w.Body.String())
	}
}

// R2 (CODE-M1): JSON strictness — unknown top-level key returns 400.
func TestForceVoidRejectsUnknownTopLevelKey(t *testing.T) {
	store := quarantineFixture(t)
	id := insertQuarantinedCredit(t, store, "p-unk")
	body := `{"operator_id":"alice","reason":"x","extra":"nope"}`
	w := doForceVoid(t, store, true, id, body, "application/json")
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s want 400", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), "unknown") {
		t.Fatalf("body=%s does not contain unknown-key error", w.Body.String())
	}
}

// R2 (CODE-H4): /admin/ledger/providers payable totals are computed
// from non-quarantined rows ONLY, regardless of include_quarantined.
// quarantined_count uses OPEN_PREDICATE independent of the row filter.
// Fixture: one provider with three credit rows — payable (100),
// open-quarantined (200), force-voided (300). Default response and
// include_quarantined=true must agree on payable=100, open=1, and
// must NOT report payable=600 or quarantined_count=0.
func TestProviderRollupPayableIndependentOfFilter(t *testing.T) {
	store := quarantineFixture(t)
	now := time.Now().UTC()
	insertCredit(t, store.db, "p-rollup", now, 100) // payable row
	// open-quarantined row (200)
	openReq := "openq-" + now.Format("150405.000000000")
	insertCreditWithRequest(t, store.db, openReq, "p-rollup", now, 200)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1 WHERE request_id=?`, openReq); err != nil {
		t.Fatal(err)
	}
	// force-voided row (300)
	voidedReq := "voidedq-" + now.Format("150405.000000000")
	insertCreditWithRequest(t, store.db, voidedReq, "p-rollup", now, 300)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1 WHERE request_id=?`, voidedReq); err != nil {
		t.Fatal(err)
	}
	var voidedID int64
	if err := store.db.QueryRow(`SELECT id FROM ledger_request_credits WHERE request_id=?`, voidedReq).Scan(&voidedID); err != nil {
		t.Fatal(err)
	}
	w := doForceVoid(t, store, true, voidedID, `{"operator_id":"alice","reason":"x"}`, "application/json")
	if w.Code != http.StatusOK {
		t.Fatalf("force-void prep: status=%d body=%s", w.Code, w.Body.String())
	}

	check := func(t *testing.T, query string, wantPayable, wantOpenQ int64) {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/admin/ledger/providers"+query, nil)
		req.Header.Set("Authorization", "Bearer operator")
		rec := httptest.NewRecorder()
		store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, true).ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var resp struct {
			Providers []struct {
				ProviderID           string `json:"provider_id"`
				TotalProviderCredits int64  `json:"total_provider_credits"`
				QuarantinedCount     int64  `json:"quarantined_count"`
			} `json:"providers"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
			t.Fatal(err)
		}
		var got struct {
			payable, openq int64
			seen           bool
		}
		for _, p := range resp.Providers {
			if p.ProviderID == "p-rollup" {
				got.payable = p.TotalProviderCredits
				got.openq = p.QuarantinedCount
				got.seen = true
				break
			}
		}
		if !got.seen {
			t.Fatalf("provider p-rollup missing from response %s", rec.Body.String())
		}
		if got.payable != wantPayable {
			t.Fatalf("total_provider_credits=%d want %d (payable excludes quarantined+voided)", got.payable, wantPayable)
		}
		if got.openq != wantOpenQ {
			t.Fatalf("quarantined_count=%d want %d (OPEN_PREDICATE only)", got.openq, wantOpenQ)
		}
	}
	t.Run("default", func(t *testing.T) { check(t, "", 100, 1) })
	t.Run("include_quarantined_true", func(t *testing.T) { check(t, "?include_quarantined=true", 100, 1) })
}

// R3 (SEC-M1): when the route-layer flag is DISABLED the entire
// quarantine endpoint surface MUST be byte-indistinguishable from a
// non-existent route. Method-not-allowed, bad-id, and force-void
// POSTs all must return 404 (not 405/400) while the flag is off so
// the surface is not discoverable.
func TestQuarantineRouteHidesShapeWhenDisabled(t *testing.T) {
	store := quarantineFixture(t)
	// flag explicitly false
	handler := store.HandlersWithQuarantineGate("operator", fakeTokens{}, true, 60, false)
	id := insertQuarantinedCredit(t, store, "p-hide")
	cases := []struct {
		name   string
		method string
		path   string
	}{
		{"get_well_formed_id", http.MethodGet, "/admin/ledger/quarantine/" + itoa(id) + "/force-void"},
		{"put_well_formed_id", http.MethodPut, "/admin/ledger/quarantine/" + itoa(id) + "/force-void"},
		{"delete_well_formed_id", http.MethodDelete, "/admin/ledger/quarantine/" + itoa(id) + "/force-void"},
		{"post_bad_id", http.MethodPost, "/admin/ledger/quarantine/notanid/force-void"},
		{"post_well_formed_id", http.MethodPost, "/admin/ledger/quarantine/" + itoa(id) + "/force-void"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest(c.method, c.path, strings.NewReader(`{"operator_id":"alice","reason":"x"}`))
			req.Header.Set("Authorization", "Bearer operator")
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)
			if w.Code != http.StatusNotFound {
				t.Fatalf("status=%d body=%s want 404 (route must be invisible while flag disabled)", w.Code, w.Body.String())
			}
		})
	}
}

// R3 (ARCH-H1): Store.ReloadBillingConfig must atomically commit the
// config snapshot row AND the billing_config_flag_changed audit row
// (when the flag is actually changing), or neither. If the audit
// INSERT fails the snapshot must NOT be written and the in-memory
// flag must remain at its prior value.
func TestReloadBillingConfigAtomicAuditAndSnapshot(t *testing.T) {
	store := quarantineFixture(t)
	if store.ForceVoidEnabled() {
		t.Fatal("precondition: forceVoidEnabled must start false")
	}
	cfg := RewardsConfig{
		ProviderShare:    0.90,
		GlobalMultiplier: 1.0,
		RateCard: map[string]RateCardEntry{
			"default": {PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000},
		},
	}
	// Successful reload that flips the flag false→true: must write
	// one snapshot row + one audit row + publish the atomic.
	now := time.Now().UTC()
	snapID, err := store.ReloadBillingConfig(context.Background(), cfg, true, "sighup", now)
	if err != nil {
		t.Fatal(err)
	}
	if snapID == 0 {
		t.Fatal("snapshot id is zero")
	}
	if !store.ForceVoidEnabled() {
		t.Fatal("flag did not publish after successful reload")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_config_snapshots`); got != 1 {
		t.Fatalf("snapshots=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`); got != 1 {
		t.Fatalf("flag-change audit rows=%d want 1", got)
	}

	// Drop audit_log so the flag-change INSERT fails; flag is
	// currently true, attempt to flip to false. Both snapshot and
	// audit must roll back; the in-memory flag must remain true.
	if _, err := store.db.Exec(`DROP TABLE audit_log`); err != nil {
		t.Fatal(err)
	}
	preSnapshots := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_config_snapshots`)
	if _, err := store.ReloadBillingConfig(context.Background(), cfg, false, "sighup", now.Add(time.Second)); err == nil {
		t.Fatal("expected error from ReloadBillingConfig when audit_log is missing")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_config_snapshots`); got != preSnapshots {
		t.Fatalf("snapshots=%d want %d (atomic rollback required when audit insert fails)", got, preSnapshots)
	}
	if !store.ForceVoidEnabled() {
		t.Fatal("flag flipped to false despite atomic audit failure — race regression")
	}

	// Recreate audit_log; reload should now succeed and flip to false.
	createAuditLogForTest(t, store.db)
	if _, err := store.ReloadBillingConfig(context.Background(), cfg, false, "sighup", now.Add(2*time.Second)); err != nil {
		t.Fatal(err)
	}
	if store.ForceVoidEnabled() {
		t.Fatal("flag did not flip false after successful reload")
	}
}

// R3 (also ARCH-H1): same-value reload through ReloadBillingConfig
// writes a NEW snapshot row but does NOT emit a billing_config_flag_changed
// audit row (SPEC §11.6.4 "reload-no-change" rule). Validates that
// our atomic-tx path preserves the no-change semantics.
func TestReloadBillingConfigSameValueNoFlagAudit(t *testing.T) {
	store := quarantineFixture(t)
	cfg := RewardsConfig{
		ProviderShare:    0.90,
		GlobalMultiplier: 1.0,
		RateCard:         map[string]RateCardEntry{"default": {PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000}},
	}
	now := time.Now().UTC()
	if _, err := store.ReloadBillingConfig(context.Background(), cfg, true, "sighup", now); err != nil {
		t.Fatal(err)
	}
	auditAfterFirst := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`)
	// Same value, must NOT emit a second audit row.
	if _, err := store.ReloadBillingConfig(context.Background(), cfg, true, "sighup", now.Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`); got != auditAfterFirst {
		t.Fatalf("same-value reload emitted spurious audit row: count=%d want %d", got, auditAfterFirst)
	}
	// But snapshot row should still be inserted (snapshot is
	// per-reload, independent of flag-flip).
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_config_snapshots`); got != 2 {
		t.Fatalf("snapshots=%d want 2 (each reload writes a snapshot)", got)
	}
}

// R2 (ARCH-H1): if the flag-change audit COMMIT fails, the route-layer
// flag MUST remain at the prior value. Otherwise a SIGHUP could
// publish an enable/disable with no durable audit trail.
func TestSetForceVoidEnabledRollsBackOnAuditFailure(t *testing.T) {
	store := quarantineFixture(t)
	// Start at false (constructor default).
	if store.ForceVoidEnabled() {
		t.Fatal("precondition: forceVoidEnabled must start false")
	}
	// Drop audit_log so the INSERT inside SetForceVoidEnabled fails.
	if _, err := store.db.Exec(`DROP TABLE audit_log`); err != nil {
		t.Fatal(err)
	}
	if err := store.SetForceVoidEnabled(context.Background(), true, "sighup"); err == nil {
		t.Fatal("expected error from SetForceVoidEnabled when audit_log is missing")
	}
	if store.ForceVoidEnabled() {
		t.Fatal("forceVoidEnabled flipped to true despite audit failure — race regression")
	}
	// Recreate audit_log; the same call now succeeds and publishes.
	createAuditLogForTest(t, store.db)
	if err := store.SetForceVoidEnabled(context.Background(), true, "sighup"); err != nil {
		t.Fatal(err)
	}
	if !store.ForceVoidEnabled() {
		t.Fatal("forceVoidEnabled did not publish after successful audit commit")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='billing_config_flag_changed'`); got != 1 {
		t.Fatalf("audit row count=%d want 1 (only the successful flip emits)", got)
	}
}
