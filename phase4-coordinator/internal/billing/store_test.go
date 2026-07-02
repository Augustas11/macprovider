package billing

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	_ "modernc.org/sqlite"
)

func TestBillingMigration(t *testing.T) {
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "migration.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	createRequestLogForTest(t, db)
	if _, err := NewStore(db); err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	for _, table := range []string{
		"ledger_request_credits",
		"ledger_operator_credits",
		"ledger_payout_ready",
		"ledger_reconciliation_runs",
		"ledger_config_snapshots",
		"ledger_provider_identity_snapshots",
		"settlement_route_snapshots",
		"settlement_attempt_outputs",
	} {
		rows, err := db.Query(`PRAGMA table_info(` + table + `)`)
		if err != nil {
			t.Fatal(err)
		}
		if !rows.Next() {
			t.Fatalf("%s has no columns", table)
		}
		rows.Close()
	}
	for _, idx := range []string{"idx_request_log_ts_utc", "idx_request_log_request_id_id"} {
		if !indexExists(t, db, "request_log", idx) {
			t.Fatalf("missing request_log index %s", idx)
		}
	}
}

func TestInsertConfigSnapshot_AppendsReloadEvents(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	firstID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(10, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	secondID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(20, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	if firstID == secondID {
		t.Fatalf("snapshot ids equal after reload: %d", firstID)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_config_snapshots`); got != 2 {
		t.Fatalf("snapshots=%d want 2", got)
	}
}

func TestSnapshotAt_UsesRollbackReloadEffectiveTime(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfgA := testRewards()
	cfgB := testRewards()
	cfgB.RateCard = map[string]RateCardEntry{"model-a": {PromptCreditsPerMtok: 3000000, CompletionCreditsPerMtok: 4000000}}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfgA, time.Unix(10, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfgB, time.Unix(20, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfgA, time.Unix(30, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	_, rewards, _, _, err := store.snapshotAt(context.Background(), time.Unix(35, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	if got := RateFor(rewards.RateCard, "model-a").PromptCreditsPerMtok; got != 1000000 {
		t.Fatalf("rollback prompt rate=%d want 1000000", got)
	}
}

func TestWriteHotPath_ACID(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"request_log", "ledger_request_credits", "ledger_operator_credits", "ledger_provider_identity_snapshots"} {
		if got := scalar(t, store.db, `SELECT COUNT(*) FROM `+table); got != 1 {
			t.Fatalf("%s count=%d want 1", table, got)
		}
	}
	var reqCreditID, operatorRef int64
	if err := store.db.QueryRow(`SELECT id FROM ledger_request_credits`).Scan(&reqCreditID); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`SELECT request_credit_id FROM ledger_operator_credits`).Scan(&operatorRef); err != nil {
		t.Fatal(err)
	}
	if reqCreditID != operatorRef {
		t.Fatalf("operator ref=%d request id=%d", operatorRef, reqCreditID)
	}
}

func TestWriteHotPath_503_NoLedgerRows(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	input.ProviderAssignedID = ""
	row.ProviderAssignedID = ""
	input.Status = 503
	row.Status = 503
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM request_log`); got != 1 {
		t.Fatalf("request_log count=%d want 1", got)
	}
	for _, table := range []string{"ledger_request_credits", "ledger_operator_credits", "ledger_provider_identity_snapshots"} {
		if got := scalar(t, store.db, `SELECT COUNT(*) FROM `+table); got != 0 {
			t.Fatalf("%s count=%d want 0", table, got)
		}
	}
}

func TestWriteRequestLogWithIdentity_AllowsRecoveryAfterHotPathFailure(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "fallback-recover"
	input.RequestID = row.RequestID
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); got != 0 {
		t.Fatalf("ledger rows before recovery=%d want 0", got)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND provider_id = ? AND quarantined = 0`, row.RequestID, input.ProviderID); got != 1 {
		t.Fatalf("recovered ledger rows=%d want 1", got)
	}
}

func TestWriteHotPath_NullError_ZeroCredits(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	input.ErrorCode = "error_model_not_loaded"
	row.ErrorCode = input.ErrorCode
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	var gross, provider, operator int64
	var usage string
	if err := store.db.QueryRow(`SELECT gross_credits, provider_credits, gross_credits-provider_credits, usage_source FROM ledger_request_credits`).Scan(&gross, &provider, &operator, &usage); err != nil {
		t.Fatal(err)
	}
	if gross != 0 || provider != 0 || operator != 0 || usage != UsageNullError {
		t.Fatalf("null error row got gross=%d provider=%d operator=%d usage=%s", gross, provider, operator, usage)
	}
}

func TestWriteHotPath_ClampsProviderCompletionToObservedEstimateAndRecoveryPreservesClamp(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "inflated-provider-usage"
	input.RequestID = row.RequestID
	inflatedCompletion := int64(10000000)
	observedEstimate := int64(2)
	row.CompletionTokens = &inflatedCompletion
	row.EstimatedCompTokens = &observedEstimate
	input.CompletionTokens = &inflatedCompletion
	input.EstimatedCompTokens = &observedEstimate
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	assertInflatedUsageClamped(t, store.db, row.RequestID, 1004)
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "nightly_reconcile"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	assertInflatedUsageClamped(t, store.db, row.RequestID, 1004)
	if _, err := store.db.Exec(`DELETE FROM ledger_operator_credits WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DELETE FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	assertInflatedUsageClamped(t, store.db, row.RequestID, 1004)
}

func TestWriteHotPath_DuplicateRequestIDWithoutRetryQuarantinesAttempt(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "buyer-controlled-duplicate"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	input2 := input
	row2 := row
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1 AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 1 {
		t.Fatalf("quarantined duplicate attempts=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits WHERE request_id = ? AND attempt_n = 1`, row.RequestID); got != 0 {
		t.Fatalf("operator rows for ambiguous attempt=%d want 0", got)
	}
}

// SPEC-002 v1.5.0 / issue #211 defense-in-depth regression: should
// the same coordinator-internal request_id ever recur across rows
// belonging to different accounts (UUID v4 collision, retry-loop
// bug, future schema change), RecoverLedger MUST derive attempt_n
// by scoping (account_id, request_id), not request_id alone.
// Note that internal request_id is server-minted
// (uuid.NewString() per buyer request) — this is NOT the actual
// #211 buyer-supplied collision class on external_request_id; it's
// defense-in-depth against any future internal-id recurrence.
// ISS-211 R1 architect HIGH spotted the scoping gap; R6 reframed
// from "cross-account collision class" to "defense-in-depth".
func TestRecoverLedger_AccountScopedInternalRequestIDDefenseInDepth(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "synthetic-internal-uuid-collision-recovery"
	input.RequestID = row.RequestID
	row.AccountID = "acct_A"
	// Use the hot-path-failure fallback so RecoverLedger does the
	// derivation work (rather than hotpath.go's in-line check).
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	input2 := input
	row2 := row
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	row2.AccountID = "acct_B"
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 0 {
		t.Fatalf("synthetic internal request_id recurrence quarantined rows after recovery=%d, want 0 (issue #211 defense-in-depth regression)", got)
	}
	// Both accounts' rows should have produced a clean credit row.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0`, row.RequestID); got != 2 {
		t.Fatalf("non-quarantined ledger rows for synthetic internal request_id recurrence=%d, want 2 (one per account)", got)
	}
}

// SPEC-002 v1.5.0 / issue #211 defense-in-depth regression: should
// the same coordinator-internal request_id ever recur across writes
// belonging to different accounts, the AttemptN-derivation COUNT in
// hotpath.go MUST scope by (account_id, request_id) and NOT trip the
// `ambiguous_attempt_n` zero-credit path that would fire under the
// unscoped COUNT. Note that internal request_id is server-minted, so
// this scenario is hypothetical — the actual #211 collision class
// lives on external_request_id and is addressed by the reconciliation
// key. The parallel adjacent test
// TestWriteHotPath_DuplicateRequestIDWithoutRetryQuarantinesAttempt
// covers the legacy NULL-`account_id` clustering case where the
// quarantine fires by design.
func TestWriteHotPath_AccountScopedInternalRequestIDDefenseInDepth(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "synthetic-internal-uuid-collision-hotpath"
	input.RequestID = row.RequestID
	row.AccountID = "acct_A"
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	input2 := input
	row2 := row
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	row2.AccountID = "acct_B" // different account, same request_id
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	// Pre-#211 (unscoped COUNT): would have counted 2 rows for the
	// same request_id, derived AttemptN=1, and quarantined the second
	// row as `ambiguous_attempt_n` → zero credit for acct_B. With the
	// account-scoped count, acct_B sees only its own one row and the
	// derived AttemptN matches input.AttemptN, so no quarantine fires.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 0 {
		t.Fatalf("synthetic internal request_id recurrence quarantined rows=%d, want 0 (issue #211 defense-in-depth regression)", got)
	}
}

func TestWriteHotPath_DerivedBillingAttemptAllowedWhenAttemptMatches(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "failover-attempt"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	input2 := input
	row2 := row
	input2.AttemptN = 1
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	row2.Retried = 1
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1 AND quarantined = 0`, row.RequestID); got != 1 {
		t.Fatalf("payable derived attempt rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits WHERE request_id = ? AND attempt_n = 1`, row.RequestID); got != 1 {
		t.Fatalf("operator rows for derived attempt=%d want 1", got)
	}
}

func TestWriteHotPath_AttemptOneWithoutRetriedEvidenceIsQuarantined(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "attempt-one-no-retry"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	input2 := input
	row2 := row
	input2.AttemptN = 1
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	row2.Retried = 0
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 1 AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`, row.RequestID); got != 1 {
		t.Fatalf("ambiguous attempt one rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits WHERE request_id = ? AND attempt_n = 1`, row.RequestID); got != 0 {
		t.Fatalf("operator rows for ambiguous attempt one=%d want 0", got)
	}
}

// TestWriteHotPath_ThirdDerivedAttemptIsCreditedUnderMonotonicAttemptN
// pins SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168): with persisted
// monotonic attempt_n, row 3+ is no longer quarantined. The prior
// v0.3.1 "row 3+ MUST quarantine until SPEC-002 gains monotonic
// attempt_n" rule is satisfied by the persisted column. Test was
// previously TestWriteHotPath_ThirdDerivedAttemptIsAlwaysQuarantined.
func TestWriteHotPath_ThirdDerivedAttemptIsCreditedUnderMonotonicAttemptN(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "third-attempt"
	input.RequestID = row.RequestID
	// Row 1 receives attempt_n=0, retried=0 — credited.
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	// Row 2 receives attempt_n=1; carry retried=1 so it doesn't trip
	// the legitimate-retry-without-marker quarantine class.
	input2 := input
	row2 := row
	row2.Retried = 1
	input2.AttemptN = 1
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	// Row 3 receives attempt_n=2. Under v0.3.3 this is credited
	// normally (was quarantined under v0.3.1).
	input3 := input
	row3 := row
	row3.Retried = 1
	input3.AttemptN = 2
	input3.ProviderID = "provider-c"
	input3.ProviderAssignedID = "assigned-c"
	row3.ProviderAssignedID = "assigned-c"
	if err := store.WriteHotPath(context.Background(), reqStore, row3, input3); err != nil {
		t.Fatal(err)
	}
	// v0.3.3 contract: third attempt has NO quarantine row and HAS a
	// non-quarantined credit row.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 2 AND quarantined = 1`, row.RequestID); got != 0 {
		t.Fatalf("third attempt quarantine rows=%d want 0 (v0.3.3 credits row 3+)", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n = 2 AND quarantined = 0`, row.RequestID); got != 1 {
		t.Fatalf("third attempt credited rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_provider_identity_snapshots WHERE request_id = ? AND attempt_n = 2 AND provider_assigned_id = 'assigned-c'`, row.RequestID); got != 1 {
		t.Fatalf("third attempt identity snapshots=%d want 1", got)
	}
}

func TestRecoverLedger_Idempotent(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(1000), int64(1000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "recover-1", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	_ = snapshotID
	_, err = store.db.Exec(`INSERT INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc) VALUES ('recover-1', 0, 'assigned-a', 'provider-a', 'pool_entry', ?)`, ts.Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 1 {
		t.Fatalf("recovered rows=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesMissingIdentity(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(1000), int64(1000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "missing-identity", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'missing-identity' AND quarantined = 1 AND quarantine_reason = 'missing_provider_identity'`); got != 1 {
		t.Fatalf("quarantined rows=%d want 1", got)
	}
}

func TestRecoverLedger_OrphanQuarantineIsWindowBounded(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	inWindow := time.Unix(200, 0).UTC()
	outsideWindow := time.Unix(400, 0).UTC()
	insertCreditWithRequest(t, store.db, "orphan-in", "provider-a", inWindow, 500)
	insertCreditWithRequest(t, store.db, "orphan-out", "provider-b", outsideWindow, 500)
	in := RecoverInput{ScanFrom: inWindow.Add(-time.Minute), ScanTo: inWindow.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'orphan-in' AND quarantined = 1`); got != 1 {
		t.Fatalf("in-window orphan quarantined=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'orphan-out' AND quarantined = 1`); got != 0 {
		t.Fatalf("out-of-window orphan quarantined=%d want 0", got)
	}
}

func TestRecoverLedger_QuarantinesOrphanLedgerRows(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ts := time.Unix(200, 0).UTC()
	insertCredit(t, store.db, "orphan-provider", ts, 500)
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'orphan-provider' AND quarantined = 1 AND quarantine_reason = 'missing_request_log'`); got != 1 {
		t.Fatalf("orphan quarantined rows=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesLedgerRowsWithoutMatchingAttemptProviderEvidence(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ts := time.Unix(200, 0).UTC()
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "shared-request", Model: "model-a", ProviderAssignedID: "assigned-a",
		Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	insertCreditWithRequest(t, store.db, "shared-request", "bogus-provider", ts, 500)
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'shared-request' AND provider_id = 'bogus-provider' AND quarantined = 1 AND quarantine_reason = 'missing_request_log'`); got != 1 {
		t.Fatalf("bogus ledger quarantine rows=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesInvalidUsageTokens(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(-1), int64(1000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "invalid-usage", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`INSERT INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc) VALUES ('invalid-usage', 0, 'assigned-a', 'provider-a', 'pool_entry', ?)`, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-usage' AND quarantined = 1 AND quarantine_reason = 'invalid_usage_tokens'`); got != 1 {
		t.Fatalf("invalid usage quarantine rows=%d want 1", got)
	}
}

func TestRecoverLedger_InvalidUsageQuarantinesExistingActiveRows(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(-1), int64(1000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "invalid-existing", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`INSERT INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc) VALUES ('invalid-existing', 0, 'assigned-a', 'provider-a', 'pool_entry', ?)`, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	insertCreditWithRequest(t, store.db, "invalid-existing", "provider-a", ts, 500)
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-existing' AND provider_id = 'provider-a' AND quarantined = 1 AND quarantine_reason = 'invalid_usage_tokens'`); got != 1 {
		t.Fatalf("existing invalid usage quarantine rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-existing'`); got != 1 {
		t.Fatalf("invalid usage rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'invalid-existing' AND provider_id LIKE '__unresolved__%'`); got != 0 {
		t.Fatalf("unresolved placeholder rows=%d want 0", got)
	}
}

func TestRecoverLedger_QuarantinesExistingSplitMismatch(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "split-mismatch"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DELETE FROM ledger_operator_credits WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "nightly_reconcile"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'split-mismatch' AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`); got != 1 {
		t.Fatalf("mismatch quarantine rows=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesExistingContractMismatch(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "contract-mismatch"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET usage_source = 'null_error', gross_credits = 0, provider_credits = 0, fault_flag = 'null_usage_error'
 WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_operator_credits SET gross_credits = 0, operator_credits = 0, fault_flag = 'null_usage_error' WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "nightly_reconcile"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'contract-mismatch' AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`); got != 1 {
		t.Fatalf("contract mismatch quarantine rows=%d want 1", got)
	}
}

func TestRecoverLedger_MissingSnapshotQuarantinesExistingRow(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	ts := time.Unix(50, 0).UTC()
	prompt, completion := int64(1000), int64(1000)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "missing-snapshot-existing", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`INSERT INTO ledger_provider_identity_snapshots (request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc) VALUES ('missing-snapshot-existing', 0, 'assigned-a', 'provider-a', 'pool_entry', ?)`, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	insertCreditWithRequest(t, store.db, "missing-snapshot-existing", "provider-a", ts, 500)
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'missing-snapshot-existing' AND quarantined = 1 AND quarantine_reason = 'missing_config_snapshot'`); got != 1 {
		t.Fatalf("missing snapshot quarantine rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'missing-snapshot-existing'`); got != 1 {
		t.Fatalf("missing snapshot rows=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesExistingFailoverAttemptWithoutRetriedFlag(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "recover-failover"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	input2 := input
	row2 := row
	input2.AttemptN = 1
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "nightly_reconcile"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'recover-failover' AND attempt_n = 1 AND quarantined = 1 AND quarantine_reason = 'ambiguous_attempt_n'`); got != 1 {
		t.Fatalf("quarantined failover rows=%d want 1", got)
	}
}

// TestRecoverLedger_CreditsExistingThirdAttemptUnderMonotonicAttemptN
// pins SPEC-005 v0.3.3 / SPEC-002 v1.5.2 (issue #168) on the recovery
// path: row 3+ with persisted monotonic attempt_n is reconciled normally
// (not quarantined). Test was previously
// TestRecoverLedger_QuarantinesExistingThirdAttempt under the v0.3.1
// "row 3+ MUST quarantine" rule. Seeding uses WriteHotPath so the
// pre-existing credits are byte-correct under the active rate card,
// letting RecoverLedger's reconciliation pass without a
// credit-mismatch quarantine.
func TestRecoverLedger_CreditsExistingThirdAttemptUnderMonotonicAttemptN(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "recover-third"
	input.RequestID = row.RequestID
	// First attempt (attempt_n=0).
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	// Second attempt (attempt_n=1, retried=1 to avoid the legitimate-
	// retry-without-marker quarantine class).
	input2 := input
	row2 := row
	row2.Retried = 1
	input2.AttemptN = 1
	input2.ProviderID = "provider-b"
	input2.ProviderAssignedID = "assigned-b"
	row2.ProviderAssignedID = "assigned-b"
	if err := store.WriteHotPath(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	// Third attempt (attempt_n=2). Under v0.3.3 this is credited
	// normally; under v0.3.1 it would have been quarantined.
	input3 := input
	row3 := row
	row3.Retried = 1
	input3.AttemptN = 2
	input3.ProviderID = "provider-c"
	input3.ProviderAssignedID = "assigned-c"
	row3.ProviderAssignedID = "assigned-c"
	if err := store.WriteHotPath(context.Background(), reqStore, row3, input3); err != nil {
		t.Fatal(err)
	}
	// Now drive recovery over the same window.
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "nightly_reconcile"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	// v0.3.3 contract: row 3+ is NOT quarantined post-recovery.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'recover-third' AND attempt_n = 2 AND quarantined = 1`); got != 0 {
		t.Fatalf("third attempt quarantine rows=%d want 0 (v0.3.3 credits row 3+)", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'recover-third' AND attempt_n = 2 AND quarantined = 0`); got != 1 {
		t.Fatalf("third attempt credited rows=%d want 1", got)
	}
}

func TestRecoverLedger_DoesNotQuarantineSettledMismatch(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "settled-mismatch"
	input.RequestID = row.RequestID
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settled = 1, settlement_id = 42 WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET gross_credits = gross_credits + 1 WHERE request_id = ?`, row.RequestID); err == nil {
		t.Fatal("settled money mutation succeeded")
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "nightly_reconcile"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = 'settled-mismatch' AND quarantined = 1`); got != 0 {
		t.Fatalf("settled mismatch quarantined rows=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type = 'nightly_reconcile' AND status = 'failed'`); got != 0 {
		t.Fatalf("failed reconciliation rows=%d want 0", got)
	}
}

func TestSettlement_ThresholdEnforced(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCredit(t, store.db, "low", start.Add(time.Hour), 400)
	insertCredit(t, store.db, "at", start.Add(time.Hour), 500)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 1 {
		t.Fatalf("payout rows=%d want 1", got)
	}
}

func TestSettlement_Idempotency(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCredit(t, store.db, "provider-a", start.Add(time.Hour), 500)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	for i := 0; i < 2; i++ {
		if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
			t.Fatal(err)
		}
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 1 {
		t.Fatalf("payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(DISTINCT settlement_id) FROM ledger_request_credits WHERE settlement_id IS NOT NULL`); got != 1 {
		t.Fatalf("distinct settlement IDs=%d want 1", got)
	}
}

func TestSettlement_RollsForwardBelowThresholdCredits(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	insertCredit(t, store.db, "provider-a", start.Add(time.Hour), 300)
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("payout rows after under-threshold week=%d want 0", got)
	}
	insertCredit(t, store.db, "provider-a", start.AddDate(0, 0, 8), 300)
	if err := store.RunSettlement(context.Background(), cfg, start.AddDate(0, 0, 7), start.AddDate(0, 0, 14)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = 'provider-a'`); got != 600 {
		t.Fatalf("rolled provider credits=%d want 600", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND settled = 1`); got != 2 {
		t.Fatalf("settled rows=%d want 2", got)
	}
}

func TestSettlement_RerunAddsLateRowsToExistingPayout(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	insertCredit(t, store.db, "provider-a", start.Add(time.Hour), 500)
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	insertCredit(t, store.db, "provider-a", start.Add(2*time.Hour), 600)
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE provider_id = 'provider-a'`); got != 1 {
		t.Fatalf("payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = 'provider-a'`); got != 1100 {
		t.Fatalf("upserted provider credits=%d want 1100", got)
	}
	if got := scalar(t, store.db, `SELECT source_credit_count FROM ledger_payout_ready WHERE provider_id = 'provider-a'`); got != 2 {
		t.Fatalf("source count=%d want 2", got)
	}
}

func TestSettlement_RerunDoesNotMutateConsumedPayout(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	insertCredit(t, store.db, "provider-a", start.Add(time.Hour), 500)
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_payout_ready SET status = 'consumed' WHERE provider_id = 'provider-a'`); err != nil {
		t.Fatal(err)
	}
	insertCredit(t, store.db, "provider-a", start.Add(2*time.Hour), 600)
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = 'provider-a'`); got != 500 {
		t.Fatalf("consumed payout provider credits=%d want 500", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND settled = 0`); got != 1 {
		t.Fatalf("unsettled late rows=%d want 1", got)
	}
}

func TestSettlement_QuarantinesUnsettledRowsWithSettlementID(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCredit(t, store.db, "provider-a", start.Add(time.Hour), 500)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settlement_id = 123 WHERE provider_id = 'provider-a'`); err != nil {
		t.Fatal(err)
	}
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("payout rows=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND quarantined = 1 AND quarantine_reason = 'conflicting_settlement_id'`); got != 1 {
		t.Fatalf("conflicting settlement quarantine rows=%d want 1", got)
	}
}

func TestSettlement_QuarantinesMissingOperatorSplit(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithRequest(t, store.db, "missing-split", "provider-a", start.Add(time.Hour), 500)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("payout rows=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id = 'provider-a' AND quarantined = 1 AND quarantine_reason = 'operator_split_mismatch'`); got != 1 {
		t.Fatalf("split mismatch quarantine rows=%d want 1", got)
	}
}

func TestClaimPayoutReady_TransitionsAndAudits(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	input, row := testHotPathInput(t, store)
	_ = input
	insertCreditWithOperator(t, store.db, row.RequestID, "provider-a", start.Add(time.Hour), 500)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = 'provider-a'`)
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-1", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if !claimed {
		t.Fatal("first claim returned false, want true")
	}
	claimed, err = store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-2", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("second claim returned true, want false")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type = 'spec_007_claim' AND status = 'complete'`); got != 1 {
		t.Fatalf("complete claim audits=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type = 'spec_007_claim' AND status = 'failed'`); got != 1 {
		t.Fatalf("failed claim audits=%d want 1", got)
	}
	if _, err := store.db.Exec(`UPDATE ledger_payout_ready SET status = 'ready' WHERE id = ?`, payoutID); err == nil {
		t.Fatal("terminal status update succeeded, want error")
	}
}

func TestClaimPayoutReady_RejectsStaleAmount(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	start := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "claim-stale-1", "provider-a", start.Add(time.Hour), 500)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 500}
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = 'provider-a'`)
	insertCreditWithOperator(t, store.db, "claim-stale-2", "provider-a", start.Add(2*time.Hour), 600)
	if err := store.RunSettlement(context.Background(), cfg, start, start.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-stale", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("stale amount claim returned true, want false")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status = 'ready' AND gross_credits = 1100`, payoutID); got != 1 {
		t.Fatalf("ready updated payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type = 'spec_007_claim' AND status = 'failed'`); got != 1 {
		t.Fatalf("failed stale claim audits=%d want 1", got)
	}
}

func TestNextMondayUTC(t *testing.T) {
	in := time.Date(2026, 6, 3, 12, 0, 0, 0, time.UTC)
	want := time.Date(2026, 6, 8, 0, 0, 0, 0, time.UTC)
	if got := NextMondayUTC(in); !got.Equal(want) {
		t.Fatalf("NextMondayUTC=%s want %s", got, want)
	}
}

func newRequestAndBillingStores(t *testing.T) (*requestlog.Store, *Store) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "test.db")
	reqStore, err := requestlog.OpenStore(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqStore.Close() })
	store, err := NewStore(reqStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	return reqStore, store
}

func testRewards() RewardsConfig {
	return RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]RateCardEntry{
			"default": {PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000},
			"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
		},
	}
}

func testHotPathInput(t *testing.T, store *Store) (HotPathInput, requestlog.Row) {
	t.Helper()
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(1000), int64(2000)
	row := requestlog.Row{
		TSUtc: ts, RequestID: "req-1", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CompletionTokens: &completion, Status: 200, Stream: false,
		BuyerIP: "127.0.0.1",
	}
	input := HotPathInput{
		RequestID: row.RequestID, AttemptN: 0, ProviderAssignedID: row.ProviderAssignedID,
		ProviderID: "provider-a", Model: row.Model, Status: row.Status, Stream: row.Stream,
		TSUtc: row.TSUtc, PromptTokens: &prompt, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, row.Model),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
	}
	return input, row
}

func createRequestLogForTest(t *testing.T, db *sql.DB) {
	t.Helper()
	_, err := db.Exec(`
CREATE TABLE request_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    request_id TEXT NOT NULL,
    model TEXT NOT NULL,
    provider_assigned_id TEXT NULL,
    prompt_tokens INTEGER NULL,
    completion_tokens INTEGER NULL,
    estimated_completion_tokens INTEGER NULL,
    error_code TEXT NULL,
    retried INTEGER NOT NULL DEFAULT 0,
    status INTEGER NOT NULL DEFAULT 0,
    stream INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_request_log_ts_utc ON request_log(ts_utc);
CREATE INDEX idx_request_log_request_id_id ON request_log(request_id, id);
`)
	if err != nil {
		t.Fatal(err)
	}
}

func indexExists(t *testing.T, db *sql.DB, table, index string) bool {
	t.Helper()
	rows, err := db.Query(`PRAGMA index_list(` + table + `)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var seq int
		var name string
		var unique int
		var origin, partial any
		if err := rows.Scan(&seq, &name, &unique, &origin, &partial); err != nil {
			t.Fatal(err)
		}
		if name == index {
			return true
		}
	}
	return false
}

func scalar(t *testing.T, db *sql.DB, query string, args ...any) int64 {
	t.Helper()
	var n sql.NullInt64
	if err := db.QueryRow(query, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	if !n.Valid {
		return 0
	}
	return n.Int64
}

func assertInflatedUsageClamped(t *testing.T, db *sql.DB, requestID string, wantGross int64) {
	t.Helper()
	var gross, providerCredits, completion, estimated int64
	var usage string
	if err := db.QueryRow(`
SELECT gross_credits, provider_credits, usage_source, completion_tokens, estimated_completion_tokens
  FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 0`, requestID).Scan(&gross, &providerCredits, &usage, &completion, &estimated); err != nil {
		t.Fatal(err)
	}
	if gross != wantGross || providerCredits != 904 || usage != UsageByteEstimated || completion != 10000000 || estimated != 2 {
		t.Fatalf("clamped ledger row got gross=%d provider=%d usage=%s completion=%d estimated=%d", gross, providerCredits, usage, completion, estimated)
	}
	if got := scalar(t, db, `SELECT gross_credits FROM ledger_operator_credits WHERE request_id = ?`, requestID); got != wantGross {
		t.Fatalf("operator gross=%d want %d", got, wantGross)
	}
	if got := scalar(t, db, `SELECT estimated_completion_tokens FROM request_log WHERE request_id = ?`, requestID); got != 2 {
		t.Fatalf("request_log estimated completion=%d want 2", got)
	}
}

func insertCredit(t *testing.T, db *sql.DB, providerID string, ts time.Time, providerCredits int64) {
	t.Helper()
	requestID := providerID + "-" + ts.UTC().Format("20060102150405.000000000") + "-req"
	insertCreditWithOperator(t, db, requestID, providerID, ts, providerCredits)
}

func insertCreditWithRequest(t *testing.T, db *sql.DB, requestID, providerID string, ts time.Time, providerCredits int64) {
	t.Helper()
	_, err := db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, recovery_source, created_at_utc
) VALUES (?, 0, ?, 'assigned', ?, 'model-a', 200, 0, 'provider_reported', 1, 1, 1000000, ?, 9000, ?, 'none', 'hot_path', ?)`,
		requestID, providerID, ts.Format(time.RFC3339Nano), providerCredits, providerCredits, ts.Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
}

func insertCreditWithOperator(t *testing.T, db *sql.DB, requestID, providerID string, ts time.Time, providerCredits int64) {
	t.Helper()
	insertCreditWithRequest(t, db, requestID, providerID, ts, providerCredits)
	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND provider_id = ?`, requestID, providerID)
	_, err := db.Exec(`
INSERT INTO ledger_operator_credits (
    request_credit_id, request_id, attempt_n, provider_id, ts_utc,
    gross_credits, operator_share_bps, operator_credits, fault_flag, created_at_utc
) VALUES (?, ?, 0, ?, ?, ?, 0, 0, 'none', ?)`,
		requestCreditID, requestID, providerID, ts.Format(time.RFC3339Nano), providerCredits, ts.Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
}
