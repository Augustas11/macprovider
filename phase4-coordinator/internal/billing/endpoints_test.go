package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

type fakeTokens map[string]string

func (f fakeTokens) ValidateToken(_ context.Context, raw string) (string, bool, error) {
	providerID, ok := f[raw]
	return providerID, ok, nil
}

func TestSummaryEndpoint(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	insertCredit(t, store.db, "provider-a", now, 4500)
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]int64
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["total_provider_credits"] != 4500 {
		t.Fatalf("total_provider_credits=%d want 4500", resp["total_provider_credits"])
	}
}

// Regression: M1-5 / SECU-5. The admin gate must fail closed when the
// configured operator key is empty. Pre-fix the `if operatorKey != ""`
// short-circuit allowed every caller; we relied on config.Validate to
// refuse to start. This test constructs Handlers with operatorKey="" and
// asserts /admin/ledger/* denies — locking the local invariant so future
// entry points cannot bypass Validate and silently fail open.
func TestAdminLedgerDeniesWhenOperatorKeyEmpty(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	handler := store.Handlers("", fakeTokens{}, true, 60)

	paths := []string{
		"/admin/ledger/summary",
		"/admin/ledger/providers",
		"/admin/ledger/reconcile?from=2026-06-01&to=2026-06-08",
	}
	for _, p := range paths {
		// No Authorization header.
		req := httptest.NewRequest(http.MethodGet, p, nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != http.StatusForbidden {
			t.Fatalf("%s without bearer: status=%d body=%s, want 403 (empty operator key must deny)", p, w.Code, w.Body.String())
		}
		// Bearer-with-anything must also deny when configured key is empty.
		req2 := httptest.NewRequest(http.MethodGet, p, nil)
		req2.Header.Set("Authorization", "Bearer anything")
		w2 := httptest.NewRecorder()
		handler.ServeHTTP(w2, req2)
		if w2.Code != http.StatusForbidden {
			t.Fatalf("%s with arbitrary bearer: status=%d body=%s, want 403", p, w2.Code, w2.Body.String())
		}
	}
}

func TestProvidersEndpoint(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	insertCredit(t, store.db, "provider-a", now, 500)
	insertCredit(t, store.db, "provider-b", now, 600)
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/providers", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		Providers []struct {
			ProviderID string `json:"provider_id"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Providers) != 2 {
		t.Fatalf("providers=%d want 2", len(resp.Providers))
	}
}

func TestProvidersEndpoint_CursorStartsAfterLastEmittedProvider(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	now := time.Now().UTC()
	for _, providerID := range []string{"provider-a", "provider-b", "provider-c"} {
		insertCredit(t, store.db, providerID, now, 500)
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/providers?limit=2", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var first struct {
		NextCursor string `json:"next_cursor"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &first); err != nil {
		t.Fatal(err)
	}
	req = httptest.NewRequest(http.MethodGet, "/admin/ledger/providers?limit=2&cursor="+first.NextCursor, nil)
	req.Header.Set("Authorization", "Bearer operator")
	w = httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var second struct {
		Providers []struct {
			ProviderID string `json:"provider_id"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &second); err != nil {
		t.Fatal(err)
	}
	if len(second.Providers) != 1 || second.Providers[0].ProviderID != "provider-c" {
		t.Fatalf("second page providers=%v want provider-c", second.Providers)
	}
}

func TestReconcileEndpoint_CleanDelta(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	prompt, completion := int64(1000), int64(2000)
	input := HotPathInput{
		RequestID: "reconcile-1", AttemptN: 0, ProviderAssignedID: "assigned-a", ProviderID: "provider-a",
		Model: "model-a", Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, "model-a"),
		MultiplierPPM: 1000000, ProviderShareBps: 9000,
	}
	row := requestLogRow(input)
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-06-08", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["delta_gross_credits"].(float64) != 0 {
		t.Fatalf("delta=%v want 0", resp["delta_gross_credits"])
	}
}

// SPEC-002 v1.5.0 / issue #211 defense-in-depth regression:
// the /admin/ledger/reconcile `buyerEquivalentCredits` attempt_n
// derivation uses the same (account_id, request_id) IS-clustering as
// hotpath.go and recovery.go so all three sites produce identical
// ordinals for the same row. This test pins the contract under a
// synthetic scenario — two non-NULL distinct accounts that happen to
// share the same coordinator-internal request_id (UUID collision /
// retry-loop bug / future schema change) — and asserts the reconcile
// endpoint surfaces a clean zero delta. Note: this is NOT the actual
// #211 buyer-supplied collision class (which is on external_request_id
// and never reaches the internal request_id). It's a defense-in-depth
// regression against the underlying SQL scoping logic. Use distinct
// providers per account so the ledger_request_credits UNIQUE
// constraint (account-blind on (request_id, attempt_n, provider_id))
// does not fire — that's an orthogonal concern.
func TestReconcileEndpoint_AccountScopedInternalRequestIDDefenseInDepth(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	prompt, completion := int64(1000), int64(2000)
	inputA := HotPathInput{
		RequestID: "synthetic-internal-uuid-collision", AttemptN: 0, ProviderAssignedID: "assigned-a", ProviderID: "provider-a",
		Model: "model-a", Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, "model-a"),
		MultiplierPPM: 1000000, ProviderShareBps: 9000,
	}
	rowA := requestLogRow(inputA)
	rowA.AccountID = "acct_A"
	if err := store.WriteHotPath(context.Background(), reqStore, rowA, inputA); err != nil {
		t.Fatal(err)
	}
	inputB := inputA
	inputB.ProviderID = "provider-b"
	inputB.ProviderAssignedID = "assigned-b"
	rowB := requestLogRow(inputB)
	rowB.AccountID = "acct_B"
	if err := store.WriteHotPath(context.Background(), reqStore, rowB, inputB); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-06-08", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	// Both accounts independently derive attempt_n=0 within their
	// own (account_id, request_id) group → both ledger rows are
	// clean → reconcile delta MUST be 0. Pre-defense-in-depth
	// (when endpoints.go used unscoped request_id grouping) the
	// second account's row would have derived attempt_n=1, and the
	// ledger row's recorded attempt_n=0 would have produced a
	// non-zero reconcile delta.
	if got := resp["delta_gross_credits"].(float64); got != 0 {
		t.Fatalf("delta_gross_credits=%v want 0 (issue #211 endpoints account-scoped derivation)", got)
	}
}

func TestReconcileEndpoint_DetectsMissingOperatorSplit(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	prompt, completion := int64(1000), int64(2000)
	input := HotPathInput{
		RequestID: "reconcile-split", AttemptN: 0, ProviderAssignedID: "assigned-a", ProviderID: "provider-a",
		Model: "model-a", Status: 200, TSUtc: ts, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, "model-a"),
		MultiplierPPM: 1000000, ProviderShareBps: 9000,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, requestLogRow(input), input); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DELETE FROM ledger_operator_credits WHERE request_id = ?`, input.RequestID); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-06-08", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["split_delta_rows"].(float64) != 1 {
		t.Fatalf("split_delta_rows=%v want 1", resp["split_delta_rows"])
	}
}

func TestReconcileEndpoint_DuplicateByteEstimatedRowsDoNotHideDelta(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ts := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "dup-byte", Model: "model-a", ProviderAssignedID: "assigned-a",
		Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	insertByteEstimatedCredit(t, store.db, "dup-byte", "provider-a", ts, 100)
	insertByteEstimatedCredit(t, store.db, "dup-byte", "provider-b", ts, 100)
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-06-08", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["delta_gross_credits"].(float64) == 0 {
		t.Fatalf("delta_gross_credits=%v want non-zero", resp["delta_gross_credits"])
	}
}

func TestReconcileEndpoint_RejectsOversizedRange(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-07-15", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400", w.Code)
	}
}

func TestReconcileEndpoint_MissingParams(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status=%d want 400", w.Code)
	}
}

func TestEarningsEndpoint_TokenRequired(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500)
	handler := store.Handlers("operator", fakeTokens{"good": "provider-a", "bad": "other"}, true, 60)

	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusUnauthorized {
		t.Fatalf("missing token status=%d want 401", w.Code)
	}

	req = httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer bad")
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("wrong subject status=%d want 403", w.Code)
	}
}

func TestEarningsEndpoint_DisabledWhenTokensOff(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	req := httptest.NewRequest(http.MethodGet, "/providers/x/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{"good": "x"}, false, 60).ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503", w.Code)
	}
	var resp struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.Error.Code != "unavailable" {
		t.Fatalf("code=%s want unavailable", resp.Error.Code)
	}
}

func TestEarningsEndpoint_AppliesDateRange(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	from := currentMondayUTC(time.Now().UTC())
	to := from.AddDate(0, 0, 7)
	insertCredit(t, store.db, "provider-a", from.Add(12*time.Hour), 500)
	insertCredit(t, store.db, "provider-a", to.Add(12*time.Hour), 700)
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings?from="+from.Format("2006-01-02")+"&to="+to.Format("2006-01-02"), nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{"good": "provider-a"}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp["total_credits"].(float64) != 500 {
		t.Fatalf("total_credits=%v want 500", resp["total_credits"])
	}
	if resp["current_window_credits"].(float64) != 500 {
		t.Fatalf("current_window_credits=%v want 500", resp["current_window_credits"])
	}
}

func requestLogRow(in HotPathInput) requestlog.Row {
	return requestlog.Row{
		TSUtc: in.TSUtc, RequestID: in.RequestID, Model: in.Model, ProviderAssignedID: in.ProviderAssignedID,
		PromptTokens: in.PromptTokens, CompletionTokens: in.CompletionTokens, EstimatedCompTokens: in.EstimatedCompTokens, Status: in.Status,
		Stream: in.Stream, BuyerIP: "127.0.0.1",
	}
}

var _ = sql.ErrNoRows

func insertByteEstimatedCredit(t *testing.T, db *sql.DB, requestID, providerID string, ts time.Time, gross int64) {
	t.Helper()
	res, err := db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, prompt_tokens, completion_tokens, estimated_completion_tokens,
    usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc
) VALUES (?, 0, ?, 'assigned', ?, 'model-a', 200, 1, NULL, NULL, 100,
          'byte_estimated', 1, 1, 1000000, ?, 9000, ?, 'none', 'hot_path', ?)`,
		requestID, providerID, ts.Format(time.RFC3339Nano), gross, gross, ts.Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`
INSERT INTO ledger_operator_credits (
    request_credit_id, request_id, attempt_n, provider_id, ts_utc,
    gross_credits, operator_share_bps, operator_credits, fault_flag, created_at_utc
) VALUES (?, ?, 0, ?, ?, ?, 1000, 0, 'none', ?)`,
		id, requestID, providerID, ts.Format(time.RFC3339Nano), gross, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
}

// TestWriteErrorEnvelopeShape verifies the billing writeError emits the
// canonical 4-field OpenAI-compatible error envelope: message, type, param, code.
func TestWriteErrorEnvelopeShape(t *testing.T) {
	w := httptest.NewRecorder()
	writeError(w, http.StatusBadRequest, "test_code", "test message")

	var outer map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &outer); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
	}
	errObj, ok := outer["error"].(map[string]any)
	if !ok {
		t.Fatalf("missing 'error' key or wrong type; body=%s", w.Body.String())
	}
	for _, required := range []string{"message", "type", "code"} {
		if _, present := errObj[required]; !present {
			t.Errorf("missing required key %q in error envelope; body=%s", required, w.Body.String())
		}
	}
	// param must be present (may be null)
	if _, present := errObj["param"]; !present {
		t.Errorf("missing 'param' key in error envelope; body=%s", w.Body.String())
	}
	// no extra keys beyond the 4-field set
	allowed := map[string]bool{"message": true, "type": true, "param": true, "code": true}
	for k := range errObj {
		if !allowed[k] {
			t.Errorf("unexpected extra key %q in error envelope", k)
		}
	}
	// 4xx status → invalid_request_error
	if got := errObj["type"]; got != "invalid_request_error" {
		t.Errorf("type for 400 = %q, want %q", got, "invalid_request_error")
	}

	// 5xx status → server_error
	w2 := httptest.NewRecorder()
	writeError(w2, http.StatusInternalServerError, "internal_error", "boom")
	var outer2 map[string]any
	if err := json.Unmarshal(w2.Body.Bytes(), &outer2); err != nil {
		t.Fatalf("unmarshal 5xx: %v", err)
	}
	errObj2 := outer2["error"].(map[string]any)
	if got := errObj2["type"]; got != "server_error" {
		t.Errorf("type for 500 = %q, want %q", got, "server_error")
	}
}
