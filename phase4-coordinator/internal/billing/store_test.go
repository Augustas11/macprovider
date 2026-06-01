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

func TestInsertConfigSnapshot_Idempotent(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(10, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(20, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_config_snapshots`); got != 1 {
		t.Fatalf("snapshots=%d want 1", got)
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

func TestWriteHotPath_DuplicateRequestIDDerivesAttempt(t *testing.T) {
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
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND attempt_n IN (0, 1)`, row.RequestID); got != 2 {
		t.Fatalf("ledger attempts=%d want 2", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_provider_identity_snapshots WHERE request_id = ? AND attempt_n IN (0, 1)`, row.RequestID); got != 2 {
		t.Fatalf("identity attempts=%d want 2", got)
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

func insertCredit(t *testing.T, db *sql.DB, providerID string, ts time.Time, providerCredits int64) {
	t.Helper()
	requestID := providerID + "-" + ts.UTC().Format("20060102150405.000000000") + "-req"
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
