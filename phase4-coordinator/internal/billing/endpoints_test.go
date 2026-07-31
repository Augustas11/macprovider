package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	statsprewarm "github.com/augstar/macprovider-coordinator/internal/stats/prewarm"
)

type fakeTokens map[string]string

func (f fakeTokens) ValidateToken(_ context.Context, raw string) (string, bool, error) {
	providerID, ok := f[raw]
	return providerID, ok, nil
}

func (f fakeTokens) ValidateAndMarkTokenUsed(ctx context.Context, raw string) (string, bool, error) {
	return f.ValidateToken(ctx, raw)
}

type markingTokens struct {
	providerID string
	marked     int
}

func (m *markingTokens) ValidateToken(context.Context, string) (string, bool, error) {
	return "", false, nil
}

func (m *markingTokens) ValidateAndMarkTokenUsed(context.Context, string) (string, bool, error) {
	m.marked++
	return m.providerID, true, nil
}

type validateOnlyTokens map[string]string

func (v validateOnlyTokens) ValidateToken(_ context.Context, raw string) (string, bool, error) {
	providerID, ok := v[raw]
	return providerID, ok, nil
}

type fakeIdlePrewarmReader struct {
	summary statsprewarm.Summary
	err     error
}

func (f fakeIdlePrewarmReader) ProviderIdlePrewarm(context.Context, string) (statsprewarm.Summary, error) {
	if f.err != nil {
		return statsprewarm.Summary{}, f.err
	}
	return f.summary, nil
}

type blockingIdlePrewarmReader struct {
	started chan struct{}
}

func (b blockingIdlePrewarmReader) ProviderIdlePrewarm(ctx context.Context, _ string) (statsprewarm.Summary, error) {
	close(b.started)
	<-ctx.Done()
	return statsprewarm.Summary{}, ctx.Err()
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
	var resp struct {
		TotalProviderCredits      int64                      `json:"total_provider_credits"`
		SettlementVerdictCounters []settlementVerdictCounter `json:"settlement_verdict_counters"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.TotalProviderCredits != 4500 {
		t.Fatalf("total_provider_credits=%d want 4500", resp.TotalProviderCredits)
	}
	if resp.SettlementVerdictCounters == nil {
		t.Fatal("settlement_verdict_counters missing from summary response")
	}
}

func TestSummaryEndpointIncludesSettlementVerdictCounters(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
	_, store := newRequestAndBillingStores(t)

	counterRows := []struct {
		suffix         string
		receiptPresent int
		receiptVersion any
		receiptResult  string
		outcome        string
		reason         string
		spec008Status  string
		closed         int
		wantField      string
		wantValue      int64
	}{
		{"verified", 1, "4", "valid", SettlementOutcomeVerified, "verified_settlement", input.RouteSnapshot.Spec008HashStatus, 1, "verified", 1},
		{"pending", 0, nil, SettlementReceiptResultInconclusive, SettlementOutcomePending, "missing_receipt", input.RouteSnapshot.Spec008HashStatus, 0, "pending", 1},
		{"quarantined", 1, "spec015-v0.4", SettlementReceiptResultInvalid, SettlementOutcomeQuarantined, "catalog_snapshot_mismatch", input.RouteSnapshot.Spec008HashStatus, 1, "catalog", 1},
		{"zero", 1, "spec015-v0.4", "valid", SettlementOutcomeZeroSettled, "verified_zero_settlement", input.RouteSnapshot.Spec008HashStatus, 1, "zero", 1},
		{"legacy", 1, "v0.3", SettlementReceiptResultInconclusive, SettlementOutcomeQuarantined, "unknown_receipt_version", input.RouteSnapshot.Spec008HashStatus, 1, "legacy", 1},
		{"missing", 0, nil, SettlementReceiptResultInconclusive, SettlementOutcomeQuarantined, "missing_receipt_deadline_elapsed", input.RouteSnapshot.Spec008HashStatus, 1, "missing", 1},
		{"model-null", 1, "spec015-v0.4", SettlementReceiptResultInvalid, SettlementOutcomeQuarantined, "model_hash_null", "null", 1, "model_hash_null", 1},
		{"receipt-key", 1, "spec015-v0.4", SettlementReceiptResultInvalid, SettlementOutcomeQuarantined, "provider_receipt_key_id_mismatch", input.RouteSnapshot.Spec008HashStatus, 1, "receipt_key", 1},
	}

	for _, row := range counterRows {
		rowInput := input
		rowInput.RequestID = input.RequestID + "-" + row.suffix
		rowInput.RouteSnapshot.RequestID = rowInput.RequestID
		rowInput.RouteSnapshot.Spec008HashStatus = row.spec008Status
		seedSettlementVerdictCounterRow(t, store, rowInput, row.receiptPresent,
			row.receiptVersion, row.receiptResult, row.outcome, row.reason,
			row.spec008Status, row.closed)
	}

	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		SettlementVerdictCounters []settlementVerdictCounter `json:"settlement_verdict_counters"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.SettlementVerdictCounters) != len(counterRows) {
		t.Fatalf("counter rows=%d want %d: %#v", len(resp.SettlementVerdictCounters), len(counterRows), resp.SettlementVerdictCounters)
	}
	byReason := map[string]settlementVerdictCounter{}
	for _, counter := range resp.SettlementVerdictCounters {
		if counter.PolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
			counter.ModelID != input.RouteSnapshot.ModelID ||
			counter.Entrypoint != input.RouteSnapshot.PaidEntrypoint {
			t.Fatalf("counter grouping fields=%#v want route policy/model/entrypoint", counter)
		}
		// Item 19: the effective deadline is resolved from the route snapshot,
		// not the policy-version literal.
		if counter.PendingDeadlineSeconds != input.RouteSnapshot.PendingDeadlineSeconds {
			t.Fatalf("counter pending_deadline_seconds=%d want %d (from route snapshot)", counter.PendingDeadlineSeconds, input.RouteSnapshot.PendingDeadlineSeconds)
		}
		byReason[counter.ReasonCode] = counter
	}
	for _, row := range counterRows {
		counter, ok := byReason[row.reason]
		if !ok {
			t.Fatalf("missing counter reason %s in %#v", row.reason, byReason)
		}
		switch row.wantField {
		case "verified":
			if counter.VerifiedCount != row.wantValue {
				t.Fatalf("%s verified_count=%d want %d", row.reason, counter.VerifiedCount, row.wantValue)
			}
		case "pending":
			if counter.PendingCount != row.wantValue {
				t.Fatalf("%s pending_count=%d want %d", row.reason, counter.PendingCount, row.wantValue)
			}
		case "catalog":
			if counter.QuarantinedCount != row.wantValue || counter.CatalogMismatchCount != row.wantValue {
				t.Fatalf("%s quarantined/catalog counters=%#v want %d", row.reason, counter, row.wantValue)
			}
		case "zero":
			if counter.ZeroSettledCount != row.wantValue {
				t.Fatalf("%s zero_settled_count=%d want %d", row.reason, counter.ZeroSettledCount, row.wantValue)
			}
		case "legacy":
			if counter.LegacyReceiptCount != row.wantValue {
				t.Fatalf("%s legacy_receipt_count=%d want %d", row.reason, counter.LegacyReceiptCount, row.wantValue)
			}
		case "missing":
			if counter.MissingReceiptCount != row.wantValue {
				t.Fatalf("%s missing_receipt_count=%d want %d", row.reason, counter.MissingReceiptCount, row.wantValue)
			}
		case "model_hash_null":
			if counter.ModelHashNullCount != row.wantValue {
				t.Fatalf("%s model_hash_null_count=%d want %d", row.reason, counter.ModelHashNullCount, row.wantValue)
			}
		case "receipt_key":
			if counter.ReceiptKeyMismatchCount != row.wantValue {
				t.Fatalf("%s receipt_key_mismatch_count=%d want %d", row.reason, counter.ReceiptKeyMismatchCount, row.wantValue)
			}
		default:
			t.Fatalf("unhandled counter assertion %s", row.wantField)
		}
	}
}

// TestSettlementVerdictCountersDisaggregateByEffectiveDeadline is the item-19
// regression: two verdicts that share the same route_snapshot_policy_version,
// model, entrypoint and reason but were pinned to DIFFERENT effective
// settlement.pending_deadline_seconds (a runtime SIGHUP does not bump the
// policy-version literal — SPEC-022 (B)) must NOT be merged into one counter
// row. Before the fix they collapsed under the coarse policy version
// (verified_count=2); now they split by the effective deadline resolved from the
// route snapshot.
func TestSettlementVerdictCountersDisaggregateByEffectiveDeadline(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
	_, store := newRequestAndBillingStores(t)

	// Same grouping keys, different effective deadline regimes.
	for _, deadline := range []int64{300, 120} {
		rowInput := input
		rowInput.RequestID = fmt.Sprintf("%s-dl%d", input.RequestID, deadline)
		rowInput.RouteSnapshot.RequestID = rowInput.RequestID
		rowInput.RouteSnapshot.PendingDeadlineSeconds = deadline
		seedSettlementVerdictCounterRow(t, store, rowInput, 1, "4", "valid",
			SettlementOutcomeVerified, "verified_settlement",
			rowInput.RouteSnapshot.Spec008HashStatus, 1)
	}

	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		SettlementVerdictCounters []settlementVerdictCounter `json:"settlement_verdict_counters"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}

	byDeadline := map[int64]settlementVerdictCounter{}
	for _, c := range resp.SettlementVerdictCounters {
		if c.ReasonCode != "verified_settlement" ||
			c.PolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
			c.ModelID != input.RouteSnapshot.ModelID ||
			c.Entrypoint != input.RouteSnapshot.PaidEntrypoint {
			continue
		}
		if _, dup := byDeadline[c.PendingDeadlineSeconds]; dup {
			t.Fatalf("duplicate counter row for deadline %d: %#v", c.PendingDeadlineSeconds, c)
		}
		byDeadline[c.PendingDeadlineSeconds] = c
	}
	if len(byDeadline) != 2 {
		t.Fatalf("verified_settlement counters not disaggregated by effective deadline: got %d rows %#v", len(byDeadline), byDeadline)
	}
	for _, deadline := range []int64{300, 120} {
		c, ok := byDeadline[deadline]
		if !ok {
			t.Fatalf("missing counter for effective deadline %d: %#v", deadline, byDeadline)
		}
		if c.VerifiedCount != 1 {
			t.Fatalf("deadline %d verified_count=%d want 1 (rows merged across deadlines?)", deadline, c.VerifiedCount)
		}
	}
}

func seedSettlementVerdictCounterRow(t *testing.T, store *Store, input SettlementVerifyInput, receiptPresent int, receiptVersion any, receiptResult, settlementOutcome, reason, spec008Status string, closed int) {
	t.Helper()
	seedSettlementReceiptEvidence(t, store, input)
	var routeDigest string
	if err := store.db.QueryRow(`
SELECT route_snapshot_digest
  FROM settlement_route_snapshots
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	).Scan(&routeDigest); err != nil {
		t.Fatal(err)
	}
	usageDigest, _, err := input.ExpectedUsage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	_, err = store.db.Exec(`
INSERT INTO settlement_receipt_verdicts (
    account_scope_hash, request_id, attempt_n, provider_id,
    receipt_present, receipt_version, receipt_result, settlement_outcome,
    reason, idempotency_status, closed, terminal_state, terminal_state_ts_unix_ms,
    pending_deadline_unix_ms, received_at_unix_ms, route_snapshot_digest,
    route_snapshot_policy_version, route_snapshot_mode, paid_entrypoint,
    spec008_hash_status, provider_reported_model_hash, provider_receipt_key_fingerprint,
    catalog_id, catalog_body_digest, expected_catalog_model_hash, model_id, model_hash,
    receipt_profile, buyer_debit_outcome, provider_settlement_outcome,
    payout_exclusion_outcome, prompt_hash, output_hash, usage_digest,
    receipt_tuple_canonical_sha256, checks_json, verifier_diagnostics_json,
    facts_json, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'first_terminal', ?, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, NULL, 'spec015-v0.4', 'no_money_movement_step5',
          'no_money_movement_step5', 'excluded_until_spec022_verified',
          ?, ?, ?, NULL, '{}', '{}', NULL, ?)`,
		SettlementAccountScopeHash(input.AccountScope),
		input.RequestID,
		input.AttemptN,
		input.ProviderID,
		receiptPresent,
		receiptVersion,
		receiptResult,
		settlementOutcome,
		reason,
		closed,
		input.TerminalState,
		input.TerminalStateTSUnixMS,
		deadline,
		input.ReceiptReceivedUnixMS,
		routeDigest,
		input.RouteSnapshot.RouteSnapshotPolicyVersion,
		input.RouteSnapshot.RouteSnapshotMode,
		input.RouteSnapshot.PaidEntrypoint,
		spec008Status,
		input.RouteSnapshot.ProviderReportedModelHash,
		input.RouteSnapshot.ProviderReceiptKeyID,
		input.RouteSnapshot.CatalogID,
		input.RouteSnapshot.CatalogBodyDigest,
		input.RouteSnapshot.ExpectedCatalogModelHash,
		input.RouteSnapshot.ModelID,
		input.RouteSnapshot.PromptHash,
		input.OutputHash,
		usageDigest,
		time.UnixMilli(input.ReceiptReceivedUnixMS).UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		t.Fatal(err)
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

func TestAdminRateLimitRunsAfterAuthentication(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	handler := store.Handlers("operator", fakeTokens{}, true, 60)
	for i := 0; i < 200; i++ {
		req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != http.StatusForbidden {
			t.Fatalf("unauth request %d status=%d want 403", i, w.Code)
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/summary", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("authorized status=%d body=%s; unauth requests drained admin limiter", w.Code, w.Body.String())
	}
}

func TestUnknownAdminLedgerPathRequiresAuthAndAuthenticatedRequestsConsumeLimiter(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	handler := store.Handlers("operator", fakeTokens{}, true, 60)

	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/not-a-route", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("unauth status=%d body=%s want 403", w.Code, w.Body.String())
	}

	for i := 0; i < 128; i++ {
		req := httptest.NewRequest(http.MethodGet, "/admin/ledger/not-a-route", nil)
		req.Header.Set("Authorization", "Bearer operator")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != http.StatusNotFound {
			t.Fatalf("auth unknown request %d status=%d body=%s want 404", i, w.Code, w.Body.String())
		}
	}
	req = httptest.NewRequest(http.MethodGet, "/admin/ledger/not-a-route", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w = httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != http.StatusTooManyRequests {
		t.Fatalf("post-drain status=%d body=%s want 429", w.Code, w.Body.String())
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

func TestReconcileEndpointCountsFractionalRFC3339TimestampChronologically(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ts := time.Date(2026, 6, 1, 0, 0, 0, 500*int(time.Millisecond), time.UTC)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "fractional-rfc3339", Model: "model-a", ProviderAssignedID: "assigned-a",
		Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/reconcile?from=2026-06-01&to=2026-06-02", nil)
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
	if got := resp["rows_scanned"].(float64); got != 1 {
		t.Fatalf("rows_scanned=%v want 1 for fractional RFC3339 timestamp", got)
	}
}

func TestReconcileEndpoint_CacheQuarantineDoesNotCreateBuyerEquivalentDelta(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Date(2026, 6, 2, 12, 0, 0, 0, time.UTC)
	prompt, cached, completion := int64(3), int64(4), int64(1)
	input := HotPathInput{
		RequestID: "reconcile-cache-quarantine", AttemptN: 0, ProviderAssignedID: "assigned-a", ProviderID: "provider-a",
		Model: "model-a", Status: 200, TSUtc: ts, PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, "model-a"),
		MultiplierPPM: 1000000, ProviderShareBps: 9000, StickyResult: "hit",
	}
	row := requestLogRow(input)
	row.CachedPromptTokens = nil
	row.CacheQuarantineReason = "invalid_cached_prompt_tokens"
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
	if resp["buyer_equivalent_credits"].(float64) != 0 || resp["provider_gross_credits"].(float64) != 0 || resp["delta_gross_credits"].(float64) != 0 {
		t.Fatalf("reconcile response=%v, want zero buyer/provider/delta for cache quarantine", resp)
	}
	if resp["rows_quarantined"].(float64) != 1 {
		t.Fatalf("rows_quarantined=%v want 1", resp["rows_quarantined"])
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

func TestEarningsEndpointMarksProviderTokenUsed(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500)
	tokens := &markingTokens{providerID: "provider-a"}
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", tokens, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	if tokens.marked != 1 {
		t.Fatalf("token mark count=%d want 1", tokens.marked)
	}
}

func TestEarningsEndpointIncludesIdlePrewarmSummary(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500)
	reader := fakeIdlePrewarmReader{summary: statsprewarm.Summary{
		EventsLast1h: map[string]int64{
			"idle_prewarm_fired": 2,
		},
		SkipsByReasonLast1h: map[string]int64{
			"not_idle_yet": 1,
		},
	}}
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.HandlersWithQuarantineGateAndIdlePrewarm("operator", fakeTokens{"good": "provider-a"}, true, 60, false, reader).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		IdlePrewarm statsprewarm.Summary `json:"idle_prewarm"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.IdlePrewarm.EventsLast1h["idle_prewarm_fired"] != 2 ||
		resp.IdlePrewarm.SkipsByReasonLast1h["not_idle_yet"] != 1 {
		t.Fatalf("idle_prewarm=%+v, want reader summary", resp.IdlePrewarm)
	}
}

func TestEarningsEndpointKeepsServingWhenIdlePrewarmUnavailable(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500)
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.HandlersWithQuarantineGateAndIdlePrewarm(
		"operator",
		fakeTokens{"good": "provider-a"},
		true,
		60,
		false,
		fakeIdlePrewarmReader{err: errors.New("stats unavailable")},
	).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		IdlePrewarm statsprewarm.Summary `json:"idle_prewarm"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.IdlePrewarm.EventsLast1h) != 0 || len(resp.IdlePrewarm.SkipsByReasonLast1h) != 0 {
		t.Fatalf("idle_prewarm=%+v, want empty fail-open summary", resp.IdlePrewarm)
	}
}

func TestEarningsEndpointBoundsBlockingIdlePrewarmRead(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500)
	reader := blockingIdlePrewarmReader{started: make(chan struct{})}
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	start := time.Now()
	store.HandlersWithQuarantineGateAndIdlePrewarm(
		"operator",
		fakeTokens{"good": "provider-a"},
		true,
		60,
		false,
		reader,
	).ServeHTTP(w, req)
	elapsed := time.Since(start)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	if elapsed > time.Second {
		t.Fatalf("blocking idle prewarm read held earnings endpoint for %s", elapsed)
	}
	select {
	case <-reader.started:
	default:
		t.Fatal("idle prewarm reader was not called")
	}
	var resp struct {
		IdlePrewarm statsprewarm.Summary `json:"idle_prewarm"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.IdlePrewarm.EventsLast1h) != 0 || len(resp.IdlePrewarm.SkipsByReasonLast1h) != 0 {
		t.Fatalf("idle_prewarm=%+v, want empty timeout fail-open summary", resp.IdlePrewarm)
	}
}

func TestEarningsEndpointRejectsTokenStoreWithoutMarkUse(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", validateOnlyTokens{"good": "provider-a"}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s want 503 when token store cannot mark use", w.Code, w.Body.String())
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

func TestEarningsEndpointIncludesProviderSettlementReceiptReasonCodes(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base, negative := firstSettlementTupleWithNegativeFailure(t, fixtures, "normal_done", "wrong_key_signature")
	input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertCredit(t, store.db, input.ProviderID, time.Now().UTC(), 500)

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                negative.WireReceipt,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.Reason != "signature_verify_failed" {
		t.Fatalf("state reason=%s want signature_verify_failed", state.Reason)
	}
	pendingInput := input
	pendingInput.RequestID = input.RequestID + "-pending"
	pendingInput.RouteSnapshot.RequestID = pendingInput.RequestID
	seedSettlementReceiptEvidence(t, store, pendingInput)
	if _, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: pendingInput.AccountScope,
			RequestID:    pendingInput.RequestID,
			AttemptN:     pendingInput.AttemptN,
			ProviderID:   pendingInput.ProviderID,
		},
		NowUnixMS: pendingInput.TerminalStateTSUnixMS + pendingInput.RouteSnapshot.PendingDeadlineSeconds*1000 - 1,
	}); err != nil {
		t.Fatal(err)
	}
	zeroTuple := firstSettlementTupleWithTerminal(t, fixtures, "provider_error")
	zeroInput := settlementVerifierInputFromFixture(t, fixtures, zeroTuple, pubkey)
	seedSettlementReceiptEvidence(t, store, zeroInput)
	zeroState, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: zeroInput.AccountScope,
			RequestID:    zeroInput.RequestID,
			AttemptN:     zeroInput.AttemptN,
			ProviderID:   zeroInput.ProviderID,
		},
		Header:                zeroInput.Header,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: zeroInput.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if zeroState.SettlementOutcome != SettlementOutcomeZeroSettled || zeroState.ReceiptResult != SettlementReceiptResultValid {
		t.Fatalf("zero settlement state=%#v, want valid zero_settled", zeroState)
	}

	req := httptest.NewRequest(http.MethodGet, "/providers/"+input.ProviderID+"/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{"good": input.ProviderID}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		SettlementReceipts settlementReceiptSummary `json:"settlement_receipts"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.SettlementReceipts.ReceiptProfile != settlementReceiptProfileV04 ||
		resp.SettlementReceipts.FailedCount != 1 ||
		resp.SettlementReceipts.ZeroSettledCount != 1 ||
		resp.SettlementReceipts.PendingCount != 1 {
		t.Fatalf("settlement summary=%#v, want failed/zero-settled/pending v0.4 receipts", resp.SettlementReceipts)
	}
	if resp.SettlementReceipts.WindowFromUTC == "" || resp.SettlementReceipts.WindowToUTC == "" {
		t.Fatalf("settlement summary missing bounded diagnostics window: %#v", resp.SettlementReceipts)
	}
	if len(resp.SettlementReceipts.RecentFailures) != 1 || resp.SettlementReceipts.RecentFailures[0].Reason != "signature_verify_failed" {
		t.Fatalf("recent failures=%#v, want provider-facing reason code", resp.SettlementReceipts.RecentFailures)
	}
	failure := resp.SettlementReceipts.RecentFailures[0]
	if failure.RouteSnapshotMode != input.RouteSnapshot.RouteSnapshotMode ||
		failure.RouteSnapshotPolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
		failure.PaidEntrypoint != input.RouteSnapshot.PaidEntrypoint ||
		failure.Spec008HashStatus != input.RouteSnapshot.Spec008HashStatus ||
		failure.ProviderReportedModelHash != input.RouteSnapshot.ProviderReportedModelHash ||
		failure.ExpectedCatalogModelHash != input.RouteSnapshot.ExpectedCatalogModelHash {
		t.Fatalf("recent failure missing route policy/hash context: %#v", failure)
	}
	body := w.Body.String()
	rawPubkey := string(pubkey)
	for _, forbidden := range []string{
		negative.WireReceipt,
		fixtures.ProviderReceiptPubkeyB64,
		rawPubkey,
		"provider_receipt_public_key",
		"raw_receipt",
		"receipt_envelope",
		"\"account_scope\"",
		"Bearer ",
	} {
		if forbidden != "" && strings.Contains(body, forbidden) {
			t.Fatalf("provider earnings diagnostics leaked forbidden material %q: %s", forbidden, body)
		}
	}
}

func TestProvidersEndpointIncludesRedactedSettlementReceiptDiagnostics(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base, negative := firstSettlementTupleWithNegativeFailure(t, fixtures, "normal_done", "wrong_key_signature")
	input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertCredit(t, store.db, input.ProviderID, time.Now().UTC(), 500)

	if _, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                negative.WireReceipt,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: input.ReceiptReceivedUnixMS,
	}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest(http.MethodGet, "/admin/ledger/providers", nil)
	req.Header.Set("Authorization", "Bearer operator")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		Providers []struct {
			ProviderID         string                   `json:"provider_id"`
			SettlementReceipts settlementReceiptSummary `json:"settlement_receipts"`
		} `json:"providers"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Providers) != 1 || resp.Providers[0].ProviderID != input.ProviderID {
		t.Fatalf("providers=%#v want one provider %s", resp.Providers, input.ProviderID)
	}
	summary := resp.Providers[0].SettlementReceipts
	if summary.FailedCount != 1 || len(summary.RecentFailures) != 1 {
		t.Fatalf("admin settlement summary=%#v, want one redacted failure", summary)
	}
	failure := summary.RecentFailures[0]
	if failure.Reason != "signature_verify_failed" || failure.ProviderReceiptKeyFingerprint == "" || failure.RouteSnapshotDigest == "" || failure.PromptHash == "" {
		t.Fatalf("admin diagnostic=%#v, want reason code plus digests/fingerprints", failure)
	}
	if failure.RouteSnapshotMode != input.RouteSnapshot.RouteSnapshotMode ||
		failure.RouteSnapshotPolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
		failure.PaidEntrypoint != input.RouteSnapshot.PaidEntrypoint ||
		failure.Spec008HashStatus != input.RouteSnapshot.Spec008HashStatus ||
		failure.ProviderReportedModelHash != input.RouteSnapshot.ProviderReportedModelHash ||
		failure.ExpectedCatalogModelHash != input.RouteSnapshot.ExpectedCatalogModelHash {
		t.Fatalf("admin diagnostic missing route policy/hash context: %#v", failure)
	}
	body := w.Body.String()
	for _, forbidden := range []string{
		negative.WireReceipt,
		fixtures.ProviderReceiptPubkeyB64,
		string(pubkey),
		"provider_receipt_public_key",
		"raw_receipt",
		"receipt_envelope",
		"\"account_scope\"",
		"Bearer ",
	} {
		if forbidden != "" && strings.Contains(body, forbidden) {
			t.Fatalf("admin diagnostics leaked forbidden material %q: %s", forbidden, body)
		}
	}
}

func TestSettlementReceiptDiagnosticsQueryShapeIsBounded(t *testing.T) {
	endpointsRaw, err := os.ReadFile("endpoints.go")
	if err != nil {
		t.Fatal(err)
	}
	endpoints := string(endpointsRaw)
	for _, forbidden := range []string{"ROW_NUMBER()", "WITH ranked"} {
		if strings.Contains(endpoints, forbidden) {
			t.Fatalf("settlement diagnostics query must avoid unbounded ranking shape %q", forbidden)
		}
	}
	for _, want := range []string{
		"settlementReceiptDiagnosticsDefaultWindow",
		"ORDER BY received_at_unix_ms DESC, id DESC\n LIMIT ?",
	} {
		if !strings.Contains(endpoints, want) {
			t.Fatalf("settlement diagnostics query missing bounded shape marker %q", want)
		}
	}
	storeRaw, err := os.ReadFile("store.go")
	if err != nil {
		t.Fatal(err)
	}
	store := string(storeRaw)
	if !strings.Contains(store, "idx_srv_provider_failed_recent") ||
		!strings.Contains(store, "WHERE closed=1 AND settlement_outcome='quarantined'") {
		t.Fatalf("settlement diagnostics missing partial failed-receipt index")
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

// TestEarningsEndpointEmitsUsdcFields locks the contract the Malibu client
// (ProviderEarningsClient) actually decodes: usdc_today / usdc_week /
// usdc_pending / usdc_lifetime. Before this fix the endpoint emitted only
// *_credits, so every provider card rendered $0.00 despite real accrued
// credits. usd = provider_credits / 1_000_000 (SPEC-016 §4.3 payout invariant:
// provider_credits == USDC base units, 6 decimals).
func TestEarningsEndpointEmitsUsdcFields(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	// 500,000 payable credits == $0.50 USDC, all in the current day/week/life.
	insertCredit(t, store.db, "provider-a", time.Now().UTC(), 500000)

	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{"good": "provider-a"}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		TotalCredits float64  `json:"total_credits"`
		UsdcToday    *float64 `json:"usdc_today"`
		UsdcWeek     *float64 `json:"usdc_week"`
		UsdcPending  *float64 `json:"usdc_pending"`
		UsdcLifetime *float64 `json:"usdc_lifetime"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.TotalCredits != 500000 {
		t.Fatalf("total_credits=%v want 500000 (unchanged)", resp.TotalCredits)
	}
	// All four usdc_* fields must be present (a nil = the pre-fix $0.00 bug).
	for name, got := range map[string]*float64{
		"usdc_today": resp.UsdcToday, "usdc_week": resp.UsdcWeek,
		"usdc_pending": resp.UsdcPending, "usdc_lifetime": resp.UsdcLifetime,
	} {
		if got == nil {
			t.Fatalf("%s missing from earnings response (client decodes nil -> $0.00)", name)
		}
	}
	// lifetime + pending are range-/window-independent, so their conversion is
	// asserted exactly: 500000 base units / 1e6 == $0.50.
	if *resp.UsdcLifetime != 0.5 {
		t.Fatalf("usdc_lifetime=%v want 0.5", *resp.UsdcLifetime)
	}
	if *resp.UsdcPending != 0.5 {
		t.Fatalf("usdc_pending=%v want 0.5", *resp.UsdcPending)
	}
	// today/week depend on the handler's own UTC clock vs the seed time; a run
	// crossing 00:00 (or Monday 00:00) UTC would zero the window. Assert only
	// that they carry the credit's converted value or 0 — never a bogus figure.
	for name, got := range map[string]float64{"usdc_today": *resp.UsdcToday, "usdc_week": *resp.UsdcWeek} {
		if got != 0.5 && got != 0 {
			t.Fatalf("%s=%v want 0.5 or 0 (UTC-boundary tolerant)", name, got)
		}
	}
}

// TestEarningsEndpointUsdcPendingIsRangeIndependent locks the security-audit
// MEDIUM fixes: usdc_pending is all owed money and must not shrink when a
// from/to range is supplied, whereas usdc_lifetime is range-scoped. An older
// credit outside the range still counts as owed/pending.
func TestEarningsEndpointUsdcPendingIsRangeIndependent(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	// One old credit (outside the range) + one recent (inside the range).
	insertCredit(t, store.db, "provider-a", time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC), 300000)
	insertCredit(t, store.db, "provider-a", time.Date(2026, 6, 15, 12, 0, 0, 0, time.UTC), 200000)

	req := httptest.NewRequest(http.MethodGet, "/providers/provider-a/earnings?from=2026-06-01&to=2026-06-30", nil)
	req.Header.Set("Authorization", "Bearer good")
	w := httptest.NewRecorder()
	store.Handlers("operator", fakeTokens{"good": "provider-a"}, true, 60).ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		UsdcLifetime float64 `json:"usdc_lifetime"`
		UsdcPending  float64 `json:"usdc_pending"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if resp.UsdcLifetime != 0.2 { // range-scoped: only the 200000 recent credit
		t.Fatalf("usdc_lifetime=%v want 0.2 (range-scoped)", resp.UsdcLifetime)
	}
	if resp.UsdcPending != 0.5 { // all owed: (300000+200000)/1e6, ignores range
		t.Fatalf("usdc_pending=%v want 0.5 (range-independent owed total)", resp.UsdcPending)
	}
}
