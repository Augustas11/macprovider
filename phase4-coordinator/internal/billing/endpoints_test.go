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
