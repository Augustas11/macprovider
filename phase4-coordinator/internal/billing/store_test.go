package billing

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
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
	if !columnExists(t, db, "ledger_request_credits", "cached_prompt_tokens") {
		t.Fatalf("missing ledger_request_credits.cached_prompt_tokens")
	}
	if !columnExists(t, db, "ledger_provider_identity_snapshots", "config_snapshot_id") {
		t.Fatalf("missing ledger_provider_identity_snapshots.config_snapshot_id")
	}
	if !columnExists(t, db, "ledger_provider_identity_snapshots", "provider_reported_prompt_tokens") {
		t.Fatalf("missing ledger_provider_identity_snapshots.provider_reported_prompt_tokens")
	}
	if columnExists(t, db, "ledger_request_credits", "prompt_cache_hit_rate_per_mtok") {
		t.Fatalf("ledger_request_credits.prompt_cache_hit_rate_per_mtok must not be persisted")
	}
}

func TestBillingMigrationUpgradesQuarantineResolutionsV04ToV05(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	insertCreditWithRequest(t, store.db, "legacy-resolution-row", "provider-a", time.Now().UTC(), 100)
	id := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id='legacy-resolution-row'`)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason='legacy' WHERE id=?`, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
DROP VIEW IF EXISTS spec022_payable_request_credits;
DROP TABLE ledger_quarantine_resolutions;
CREATE TABLE ledger_quarantine_resolutions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_credit_id INTEGER NOT NULL REFERENCES ledger_request_credits(id),
    resolution_kind TEXT NOT NULL CHECK(resolution_kind IN ('force_void')),
    operator_id TEXT NOT NULL CHECK(length(operator_id) BETWEEN 1 AND 64),
    resolution_reason TEXT NOT NULL CHECK(length(resolution_reason) BETWEEN 1 AND 500),
    created_at_utc TEXT NOT NULL,
    UNIQUE(request_credit_id)
);
CREATE INDEX IF NOT EXISTS idx_lqr_kind_created ON ledger_quarantine_resolutions(resolution_kind, created_at_utc);
INSERT INTO ledger_quarantine_resolutions (
    request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc
) VALUES (?, 'force_void', 'alice', 'legacy void', '2026-07-01T00:00:00.000000000Z')`, id); err != nil {
		t.Fatal(err)
	}
	upgraded, err := NewStore(store.db)
	if err != nil {
		t.Fatal(err)
	}
	if !columnExists(t, store.db, "ledger_quarantine_resolutions", "force_credit_matures_at_utc") {
		t.Fatal("missing force_credit_matures_at_utc after v0.5 migration")
	}
	if !columnExists(t, store.db, "ledger_quarantine_resolutions", "correction_deadline_at_utc") {
		t.Fatal("missing correction_deadline_at_utc after v0.5 migration")
	}
	hasUnique, err := upgraded.hasUniqueIndexOnColumns(context.Background(), "ledger_quarantine_resolutions", []string{"request_credit_id"})
	if err != nil {
		t.Fatal(err)
	}
	if hasUnique {
		t.Fatal("UNIQUE(request_credit_id) survived v0.5 migration")
	}
	if !indexExists(t, store.db, "ledger_quarantine_resolutions", "idx_lqr_request_latest") {
		t.Fatal("missing idx_lqr_request_latest after v0.5 migration")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_quarantine_resolutions WHERE request_credit_id=? AND resolution_kind='force_void'`, id); got != 1 {
		t.Fatalf("preserved legacy rows=%d want 1", got)
	}
	if _, err := store.db.Exec(`
INSERT INTO ledger_quarantine_resolutions (
    request_credit_id, resolution_kind, operator_id, resolution_reason,
    created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc
) VALUES (?, 'force_credit', 'bob', 'corrected', '2026-07-01T00:00:01.000000000Z', '2026-07-02T00:00:01.000000000Z', '2026-07-02T00:00:01.000000000Z')`, id); err != nil {
		t.Fatalf("append force_credit after migration: %v", err)
	}
}

func TestBillingMigration_ReplacesSettledMoneyTrigger(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	if _, err := store.db.Exec(`
DROP TRIGGER IF EXISTS trg_lrc_settled_money_immutable;
CREATE TRIGGER trg_lrc_settled_money_immutable
BEFORE UPDATE OF gross_credits, provider_credits ON ledger_request_credits
WHEN OLD.settled = 1
  AND (
      OLD.gross_credits != NEW.gross_credits
      OR OLD.provider_credits != NEW.provider_credits
  )
BEGIN
    SELECT RAISE(ABORT, 'old settled money trigger');
END;`); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(store.db); err != nil {
		t.Fatal(err)
	}
	ts := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithRequest(t, store.db, "settled-money-upgrade", "provider-a", ts, 500)
	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET settled = 1,
       settlement_id = 42,
       gross_credits = 900,
       provider_credits = 900
 WHERE request_id = 'settled-money-upgrade'`); err == nil {
		t.Fatal("upgraded settled money trigger allowed transition-time amount mutation")
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = 'settled-money-upgrade' AND settled = 0 AND settlement_id IS NULL`); got != 500 {
		t.Fatalf("source row after failed upgraded trigger mutation=%d want 500", got)
	}
}

func TestBillingMigration_BackfillsExistingPromptSplitColumns(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ts := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithRequest(t, store.db, "partial-prompt-split-migration", "provider-a", ts, 500)
	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET prompt_tokens = 100,
       charged_prompt_tokens = NULL,
       provider_reported_prompt_tokens = NULL
 WHERE request_id = 'partial-prompt-split-migration'`); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(store.db); err != nil {
		t.Fatal(err)
	}
	var prompt, charged, reported int64
	if err := store.db.QueryRow(`
SELECT prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens
  FROM ledger_request_credits
 WHERE request_id = 'partial-prompt-split-migration'`).Scan(&prompt, &charged, &reported); err != nil {
		t.Fatal(err)
	}
	if prompt != 100 || charged != prompt || reported != prompt {
		t.Fatalf("prompt split after rerun migration=%d/%d/%d want 100/100/100", prompt, charged, reported)
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

func TestSnapshotAtUsesChronologicalRFC3339NanoOrdering(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	effectiveAt := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, effectiveAt); err != nil {
		t.Fatal(err)
	}
	_, rewards, _, _, err := store.snapshotAt(context.Background(), effectiveAt.Add(500*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	if got := RateFor(rewards.RateCard, "model-a").PromptCreditsPerMtok; got != 1000000 {
		t.Fatalf("prompt rate=%d want 1000000", got)
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

func TestWriteHotPath_StickyHitPersistsCachedPromptDiscount(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	cached := int64(400)
	input.CachedPromptTokens = &cached
	input.StickyResult = "hit"
	input.RateEntry.PromptCacheHitCreditsPerMtok = 250000
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	var gotCached, gross, provider int64
	if err := store.db.QueryRow(`
SELECT cached_prompt_tokens, gross_credits, provider_credits
  FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 0`, row.RequestID).Scan(&gotCached, &gross, &provider); err != nil {
		t.Fatal(err)
	}
	if gotCached != cached || gross != 4700 || provider != 4230 {
		t.Fatalf("cached/gross/provider=%d/%d/%d want 400/4700/4230", gotCached, gross, provider)
	}
}

func TestWriteHotPath_BoundsProviderReportedPromptTokens(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	bound := int64(100)
	input.PromptTokenUpperBound = &bound

	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}

	var prompt, charged, reported, gross int64
	if err := store.db.QueryRow(`
SELECT prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens, gross_credits
  FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 0`, row.RequestID).Scan(&prompt, &charged, &reported, &gross); err != nil {
		t.Fatal(err)
	}
	if prompt != bound || charged != bound || reported != 1000 || gross != 4100 {
		t.Fatalf("prompt/charged/reported/gross=%d/%d/%d/%d want 100/100/1000/4100", prompt, charged, reported, gross)
	}
	if got := scalar(t, store.db, `SELECT prompt_tokens FROM request_log WHERE request_id = ?`, row.RequestID); got != bound {
		t.Fatalf("request_log prompt_tokens=%d want bounded %d for recovery", got, bound)
	}
}

func TestWriteHotPath_UsesFullRateCardForServedAlias(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard = map[string]RateCardEntry{
		"qwen3-8b": {
			PromptCreditsPerMtok:     13500,
			CompletionCreditsPerMtok: 27000,
		},
		"default": {
			PromptCreditsPerMtok:     500000,
			CompletionCreditsPerMtok: 1000000,
		},
	}
	ts := recoveryLegacyDefaultRateCutoffUTC.Add(time.Hour)
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, ts.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(12), int64(8)
	row := requestlog.Row{
		TSUtc:              ts,
		RequestID:          "hotpath-served-alias-rate-card",
		AccountID:          "buyer-a",
		Model:              "mlx-community/Qwen3-8B-4bit",
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}
	input := HotPathInput{
		RequestID:                  row.RequestID,
		AttemptN:                   0,
		ProviderAssignedID:         row.ProviderAssignedID,
		ProviderID:                 "provider-a",
		Model:                      row.Model,
		Status:                     row.Status,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  cfg.RateCard["default"],
		RateCard:                   cfg.RateCard,
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(AccountScopeForSettlement(row.AccountID)),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	var promptRate, completionRate int64
	if err := store.db.QueryRow(`
SELECT prompt_rate_per_mtok, completion_rate_per_mtok
  FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 0`, row.RequestID).Scan(&promptRate, &completionRate); err != nil {
		t.Fatal(err)
	}
	if promptRate != 13500 || completionRate != 27000 {
		t.Fatalf("stored rates=%d/%d want normalized qwen3-8b 13500/27000", promptRate, completionRate)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1`, row.RequestID); got != 0 {
		t.Fatalf("quarantined rows after recovery=%d want 0", got)
	}
}

func TestRunSettlementUsesNanosecondOrderedTimestampText(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "nanosecond-boundary"
	input.RequestID = row.RequestID
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	row.TSUtc = base.Add(time.Nanosecond)
	input.TSUtc = row.TSUtc
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET ts_utc = ? WHERE request_id = ?`, row.TSUtc.Format(time.RFC3339Nano), row.RequestID); err != nil {
		t.Fatal(err)
	}
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, base, base.Add(2*time.Nanosecond)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, row.RequestID); got != 1 {
		t.Fatalf("settled nanosecond boundary rows=%d want 1", got)
	}
}

func TestWriteHotPath_EmitsCacheBillingRoutingDecision(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	cached := int64(400)
	var got CacheBillingRoutingDecision
	input.CachedPromptTokens = &cached
	input.StickyResult = "hit"
	input.RoutingDecisionLog = func(d CacheBillingRoutingDecision) {
		got = d
	}

	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}

	if got.RequestID != row.RequestID || got.ProviderID != "provider-a" || got.ProviderAssignedID != "assigned-a" {
		t.Fatalf("identity fields=%#v", got)
	}
	if got.AttemptN != 0 || got.CachedPromptTokens != 400 || got.StickyResult != "hit" || got.ValidationReason != "" {
		t.Fatalf("cache routing decision=%#v, want sticky hit cached=400 with no validation reason", got)
	}
}

func TestWriteHotPath_AmbiguousPositiveCacheQuarantinesCredit(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	cached := int64(400)
	input.CachedPromptTokens = &cached
	input.StickyResult = "miss"
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_cache' AND gross_credits = 0`, row.RequestID); got != 1 {
		t.Fatalf("ambiguous-cache quarantine rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits`); got != 0 {
		t.Fatalf("operator rows=%d want 0 for quarantined cache claim", got)
	}
}

func TestWriteHotPath_EmitsCacheBillingRoutingDecisionForInvalidCache(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	cached := int64(1001)
	var got CacheBillingRoutingDecision
	input.CachedPromptTokens = &cached
	input.StickyResult = "hit"
	input.RoutingDecisionLog = func(d CacheBillingRoutingDecision) {
		got = d
	}

	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}

	if got.CachedPromptTokens != 0 || got.ValidationReason != "invalid_cached_prompt_tokens" || got.StickyResult != "hit" {
		t.Fatalf("cache routing decision=%#v, want effective cached=0 invalid_cached_prompt_tokens", got)
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
	bound := int64(100)
	input.PromptTokenUpperBound = &bound
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
	var prompt, charged, reported int64
	if err := store.db.QueryRow(`
SELECT prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens
  FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 0`, row.RequestID).Scan(&prompt, &charged, &reported); err != nil {
		t.Fatal(err)
	}
	rawProviderPrompt := int64(1000)
	if prompt != bound || charged != bound || reported != rawProviderPrompt {
		t.Fatalf("recovered prompt split=%d/%d/%d want charged %d and reported %d", prompt, charged, reported, bound, rawProviderPrompt)
	}
}

func TestInsertProviderIdentitySnapshotDoesNotRetrofillConfigSnapshot(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	input, row := testHotPathInput(t, store)
	input.RequestID = "identity-no-retrofill"
	row.RequestID = input.RequestID
	input.ConfigSnapshotID = snapshotID
	if _, err := store.db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc
) VALUES (?, ?, ?, ?, 'pool_entry', ?)`,
		input.RequestID,
		input.AttemptN,
		input.ProviderAssignedID,
		input.ProviderID,
		row.TSUtc.Format(time.RFC3339Nano),
	); err != nil {
		t.Fatal(err)
	}
	if err := insertProviderIdentitySnapshotTx(context.Background(), store.db, input, row.TSUtc.Add(time.Second).Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	var got sql.NullInt64
	if err := store.db.QueryRow(`
SELECT config_snapshot_id
  FROM ledger_provider_identity_snapshots
 WHERE request_id = ? AND attempt_n = ? AND provider_assigned_id = ?`,
		input.RequestID,
		input.AttemptN,
		input.ProviderAssignedID,
	).Scan(&got); err != nil {
		t.Fatal(err)
	}
	if got.Valid {
		t.Fatalf("config_snapshot_id retrofilled to %d, want NULL", got.Int64)
	}
}

func TestRecoverLedger_ReplaysCachedPromptTokensFromRequestLogFallback(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard["model-a"] = RateCardEntry{
		PromptCreditsPerMtok:         1000000,
		PromptCacheHitCreditsPerMtok: 250000,
		CompletionCreditsPerMtok:     2000000,
	}
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	prompt, cached, completion := int64(10), int64(4), int64(2)
	row := requestlog.Row{
		TSUtc: time.Unix(200, 0).UTC(), RequestID: "fallback-cache-hit", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, Status: 200, Stream: false,
		BuyerIP: "127.0.0.1",
	}
	input := HotPathInput{
		RequestID: row.RequestID, AttemptN: 0, ProviderAssignedID: row.ProviderAssignedID,
		ProviderID: "provider-a", Model: row.Model, Status: row.Status, Stream: row.Stream,
		TSUtc: row.TSUtc, PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, row.Model),
		MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier), ProviderShareBps: ParseShareBps(cfg.ProviderShare),
	}
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	cfgReload := cfg
	cfgReload.RateCard["model-a"] = RateCardEntry{
		PromptCreditsPerMtok:         1000000,
		PromptCacheHitCreditsPerMtok: 1000000,
		CompletionCreditsPerMtok:     2000000,
	}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfgReload, time.Unix(150, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	var gotCached, gross int64
	if err := store.db.QueryRow(`SELECT cached_prompt_tokens, gross_credits FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0`, row.RequestID).Scan(&gotCached, &gross); err != nil {
		t.Fatal(err)
	}
	if gotCached != cached || gross != 11 {
		t.Fatalf("recovered cached/gross=%d/%d want 4/11", gotCached, gross)
	}
}

func TestRecoverLedger_CachedFallbackWithoutSnapshotProvenanceQuarantines(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard["model-a"] = RateCardEntry{
		PromptCreditsPerMtok:         1000000,
		PromptCacheHitCreditsPerMtok: 250000,
		CompletionCreditsPerMtok:     2000000,
	}
	if _, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, cached, completion := int64(10), int64(4), int64(2)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "fallback-cache-missing-snapshot", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc
) VALUES ('fallback-cache-missing-snapshot', 0, 'assigned-a', 'provider-a', 'pool_entry', ?)`, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	var gotCached sql.NullInt64
	var gross int64
	var reason string
	if err := store.db.QueryRow(`
SELECT cached_prompt_tokens, gross_credits, quarantine_reason
  FROM ledger_request_credits
 WHERE request_id = 'fallback-cache-missing-snapshot'`).Scan(&gotCached, &gross, &reason); err != nil {
		t.Fatal(err)
	}
	if gotCached.Valid || gross != 0 || reason != "missing_cache_config_snapshot" {
		t.Fatalf("cached/gross/reason=%#v/%d/%s want NULL/0/missing_cache_config_snapshot", gotCached, gross, reason)
	}
}

func TestRecoverLedger_RejectsInvalidCachedPromptTokensWithoutStoredReason(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, cached, completion := int64(3), int64(4), int64(2)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc: ts, RequestID: "fallback-cache-invalid", Model: "model-a", ProviderAssignedID: "assigned-a",
		PromptTokens: &prompt, CachedPromptTokens: &cached, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, config_snapshot_id, created_at_utc
) VALUES ('fallback-cache-invalid', 0, 'assigned-a', 'provider-a', 'pool_entry', ?, ?)`, snapshotID, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	var gotCached sql.NullInt64
	var gross int64
	var reason string
	if err := store.db.QueryRow(`
SELECT cached_prompt_tokens, gross_credits, quarantine_reason
  FROM ledger_request_credits
 WHERE request_id = 'fallback-cache-invalid'`).Scan(&gotCached, &gross, &reason); err != nil {
		t.Fatal(err)
	}
	if gotCached.Valid || gross != 0 || reason != "invalid_cached_prompt_tokens" {
		t.Fatalf("cached/gross/reason=%#v/%d/%s want NULL/0/invalid_cached_prompt_tokens", gotCached, gross, reason)
	}
}

func TestRecoverLedger_RecreatesCacheQuarantineFromRequestLogFallback(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "fallback-cache-quarantine"
	row.CacheQuarantineReason = "ambiguous_cache"
	input.RequestID = row.RequestID
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_cache' AND gross_credits = 0`, row.RequestID); got != 1 {
		t.Fatalf("cache quarantine rows=%d want 1", got)
	}
}

func TestRecoverLedger_RecreatesCacheQuarantineWithByteEstimateProvenance(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	row.RequestID = "fallback-cache-quarantine-estimated"
	estimate := int64(7)
	row.CompletionTokens = nil
	row.EstimatedCompTokens = &estimate
	row.CacheQuarantineReason = "ambiguous_cache"
	input.RequestID = row.RequestID
	input.CompletionTokens = nil
	input.EstimatedCompTokens = &estimate
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	in := RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "startup_scan"}
	if err := store.RecoverLedger(context.Background(), in); err != nil {
		t.Fatal(err)
	}
	var usage string
	var gotEstimate int64
	if err := store.db.QueryRow(`
SELECT usage_source, estimated_completion_tokens
  FROM ledger_request_credits
 WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'ambiguous_cache'`, row.RequestID).Scan(&usage, &gotEstimate); err != nil {
		t.Fatal(err)
	}
	if usage != UsageByteEstimated || gotEstimate != estimate {
		t.Fatalf("usage/estimate=%s/%d want %s/%d", usage, gotEstimate, UsageByteEstimated, estimate)
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

func TestRecoverLedger_PreservesBreakerQualifyingExistingCredit(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	prompt := int64(36)
	row.RequestID = "breaker-qualifying-recovery"
	row.Status = 502
	row.PromptTokens = &prompt
	row.CompletionTokens = nil
	input.RequestID = row.RequestID
	input.Status = row.Status
	input.PromptTokens = &prompt
	input.CompletionTokens = nil
	input.FaultFlag = FaultBreakerQualifying
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: row.TSUtc.Add(-time.Minute), ScanTo: row.TSUtc.Add(time.Minute), Source: "startup_scan"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND fault_flag = ? AND gross_credits = 0 AND provider_credits = 0`, row.RequestID, FaultBreakerQualifying); got != 1 {
		t.Fatalf("active breaker-qualifying rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 0 {
		t.Fatalf("reconciliation mismatch rows=%d want 0", got)
	}
}

func TestRecoverLedger_AcceptsVerifiedReceiptSyncedCompletionAboveEstimate(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := RewardsConfig{
		GlobalMultiplier: 1.0,
		ProviderShare:    0.90,
		RateCard: map[string]RateCardEntry{
			"default": {PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000},
			"qwen3-8b": {
				PromptCreditsPerMtok:     13500,
				CompletionCreditsPerMtok: 27000,
			},
		},
	}
	ts := time.Date(2026, 8, 5, 9, 21, 42, 0, time.UTC)
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, ts.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	route := testRouteSnapshot()
	route.RequestID = "verified-receipt-recovery"
	route.ProviderID = "provider-qwen"
	route.ModelID = "mlx-community/Qwen3-8B-4bit"
	route.RouteSnapshotMode = RouteSnapshotModeEnforce
	route.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	route.RouteDecisionTSUnixMS = ts.UnixMilli()
	route.RequestStartTSUnixMS = ts.UnixMilli()
	route.PendingDeadlineSeconds = 30
	route.AccountScope = "acct_sha256:" + strings.Repeat("7", 64)
	routeDigest, err := store.InsertRouteSnapshot(context.Background(), route)
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion, estimate := int64(20), int64(120), int64(65)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:               ts,
		RequestID:           route.RequestID,
		AccountID:           "buyer-a",
		Model:               route.ModelID,
		ProviderAssignedID:  "assigned-qwen",
		PromptTokens:        &prompt,
		CompletionTokens:    &completion,
		EstimatedCompTokens: &estimate,
		Status:              200,
		BuyerIP:             "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	input := HotPathInput{
		RequestID:                  route.RequestID,
		ProviderAssignedID:         "assigned-qwen",
		ProviderID:                 route.ProviderID,
		Model:                      route.ModelID,
		Status:                     200,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  RateFor(cfg.RateCard, route.ModelID),
		RateCard:                   cfg.RateCard,
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(route.AccountScope),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	result := ComputeCreditsWithCache(&prompt, nil, &completion, nil, UsageProviderReported, FaultNone, input.RateEntry, input.MultiplierPPM, input.ProviderShareBps)
	if result.GrossCredits != 4 || result.ProviderCredits != 4 {
		t.Fatalf("fixture credits=%d/%d want 4/4", result.GrossCredits, result.ProviderCredits)
	}
	requestCreditID, err := insertRequestCreditTx(context.Background(), store.db, input, result, "hot_path", ts.Format(time.RFC3339Nano), false, "")
	if err != nil {
		t.Fatal(err)
	}
	if err := insertOperatorCreditTx(context.Background(), store.db, requestCreditID, input, result, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	if err := insertProviderIdentitySnapshotTx(context.Background(), store.db, input, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	usage := SettlementUsage{
		BillableInputTokens:  prompt,
		BillableOutputTokens: completion,
		DeliveredOutputBytes: 603,
		ObservedInputTokens:  prompt,
		ObservedOutputTokens: completion,
	}
	usageHash, usageCanonical, err := usage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	outputHash := strings.Repeat("8", 64)
	if _, err := store.db.Exec(`
INSERT INTO settlement_attempt_outputs (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_available, output_prefix_start_byte, output_prefix_end_byte,
    output_hash, usage_hash, usage_canonical_json, usage_source,
    overlapping_or_duplicate, created_at_utc
) VALUES (?, ?, 0, ?, ?, ?, 1, 0, 603, ?, ?, ?, ?, 0, ?)`,
		route.AccountScope, route.RequestID, route.ProviderID, TerminalStateNormalDone, ts.UnixMilli(),
		outputHash, usageHash, string(usageCanonical), UsageSourceCoordinatorObserved, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	deadline := ts.Add(time.Duration(route.PendingDeadlineSeconds) * time.Second).UnixMilli()
	if _, err := store.db.Exec(`
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
) VALUES (?, ?, 0, ?, 1, 'spec015-v0.4', 'valid', 'verified',
          'verified_settlement', 'first_terminal', 1, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, NULL, 'spec015-v0.4', 'no_money_movement_step5',
          'no_money_movement_step5', 'excluded_until_spec022_verified',
          ?, ?, ?, NULL, '{}', '{}', NULL, ?)`,
		SettlementAccountScopeHash(route.AccountScope), route.RequestID, route.ProviderID,
		TerminalStateNormalDone, ts.UnixMilli(), deadline, ts.UnixMilli(), routeDigest,
		RouteSnapshotPolicyVersion, RouteSnapshotModeEnforce, route.PaidEntrypoint,
		route.Spec008HashStatus, route.ProviderReportedModelHash, route.ProviderReceiptKeyID,
		route.CatalogID, route.CatalogBodyDigest, route.ExpectedCatalogModelHash, route.ModelID,
		route.PromptHash, outputHash, usageHash, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND gross_credits = 4 AND provider_credits = 4`, route.RequestID); got != 1 {
		t.Fatalf("active verified-receipt rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantine_reason = 'reconciliation_mismatch'`, route.RequestID); got != 0 {
		t.Fatalf("reconciliation mismatch rows=%d want 0", got)
	}
}

func TestRecoverLedger_ExistingCreditUsesPersistedRateContract(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard["meta-llama/llama-3.2-3b-instruct"] = RateCardEntry{
		PromptCreditsPerMtok:     13500,
		CompletionCreditsPerMtok: 27000,
	}
	ts := time.Date(2026, 8, 5, 5, 11, 0, 0, time.UTC)
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, ts.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(40), int64(34)
	model := "mlx-community/Llama-3.2-3B-Instruct-4bit"
	row := requestlog.Row{
		TSUtc:              ts,
		RequestID:          "historical-rate-contract",
		AccountID:          "buyer-a",
		Model:              model,
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}
	input := HotPathInput{
		RequestID:                  row.RequestID,
		AttemptN:                   0,
		ProviderAssignedID:         row.ProviderAssignedID,
		ProviderID:                 "provider-a",
		Model:                      model,
		Status:                     row.Status,
		Stream:                     row.Stream,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  RateCardEntry{PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000},
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(AccountScopeForSettlement(row.AccountID)),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); got != 54 {
		t.Fatalf("gross_credits=%d want production-shaped default-rate amount 54", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0`, row.RequestID); got != 1 {
		t.Fatalf("pre-recovery active rows=%d want 1", got)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "nightly_reconcile"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 0 AND quarantine_reason IS NULL`, row.RequestID); got != 1 {
		t.Fatalf("active rows after recovery=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, row.RequestID); got != 54 {
		t.Fatalf("post-recovery gross_credits=%d want persisted-contract amount 54", got)
	}
}

func TestRecoverLedger_QuarantinesUnknownPersistedRateContract(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(40), int64(34)
	row := requestlog.Row{
		TSUtc:              ts,
		RequestID:          "unknown-rate-contract",
		AccountID:          "buyer-a",
		Model:              "model-a",
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}
	input := HotPathInput{
		RequestID:                  row.RequestID,
		AttemptN:                   0,
		ProviderAssignedID:         row.ProviderAssignedID,
		ProviderID:                 "provider-a",
		Model:                      row.Model,
		Status:                     row.Status,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  RateFor(cfg.RateCard, row.Model),
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(AccountScopeForSettlement(row.AccountID)),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	tamperedRate := RateCardEntry{PromptCreditsPerMtok: 777777, CompletionCreditsPerMtok: 888888}
	tampered := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, tamperedRate, input.MultiplierPPM, input.ProviderShareBps)
	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
	if _, err := store.db.Exec(`
	UPDATE ledger_request_credits
	   SET prompt_rate_per_mtok = ?,
	       completion_rate_per_mtok = ?,
	       gross_credits = ?,
	       provider_credits = ?
	 WHERE id = ?`,
		tamperedRate.PromptCreditsPerMtok,
		tamperedRate.CompletionCreditsPerMtok,
		tampered.GrossCredits,
		tampered.ProviderCredits,
		requestCreditID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_operator_credits SET gross_credits = ?, operator_credits = ? WHERE request_credit_id = ?`,
		tampered.GrossCredits, tampered.OperatorCredits, requestCreditID); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "nightly_reconcile"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
		t.Fatalf("quarantined rows after recovery=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT reconciliation_delta_credits FROM ledger_reconciliation_runs ORDER BY id DESC LIMIT 1`); got == 0 {
		t.Fatal("reconciliation_delta_credits=0 want nonzero snapshot-authoritative delta for unknown-rate tamper")
	}
}

func TestRecoverLedger_QuarantinesPersistedMultiplierShareDrift(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.Unix(100, 0).UTC())
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(200, 0).UTC()
	prompt, completion := int64(40), int64(34)
	row := requestlog.Row{
		TSUtc:              ts,
		RequestID:          "historical-multiplier-share-contract",
		AccountID:          "buyer-a",
		Model:              "model-a",
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}
	input := HotPathInput{
		RequestID:                  row.RequestID,
		AttemptN:                   0,
		ProviderAssignedID:         row.ProviderAssignedID,
		ProviderID:                 "provider-a",
		Model:                      row.Model,
		Status:                     row.Status,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  RateFor(cfg.RateCard, row.Model),
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(AccountScopeForSettlement(row.AccountID)),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}

	historicalMultiplier, historicalShare := int64(1500000), int64(8000)
	replayed := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, input.RateEntry, historicalMultiplier, historicalShare)
	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
	if _, err := store.db.Exec(`
	UPDATE ledger_request_credits
	   SET global_multiplier_ppm = ?,
	       provider_share_bps = ?,
	       gross_credits = ?,
	       provider_credits = ?
	 WHERE id = ?`,
		historicalMultiplier,
		historicalShare,
		replayed.GrossCredits,
		replayed.ProviderCredits,
		requestCreditID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
	UPDATE ledger_operator_credits
	   SET gross_credits = ?,
	       operator_share_bps = ?,
	       operator_credits = ?
	 WHERE request_credit_id = ?`,
		replayed.GrossCredits,
		10000-historicalShare,
		replayed.OperatorCredits,
		requestCreditID,
	); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "nightly_reconcile"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
		t.Fatalf("quarantined rows after recovery=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesPostCutoffDefaultRateTamper(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard["llama-3.2-3b-instruct"] = RateCardEntry{
		PromptCreditsPerMtok:     13500,
		CompletionCreditsPerMtok: 27000,
	}
	ts := recoveryLegacyDefaultRateCutoffUTC.Add(time.Minute)
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, ts.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(40), int64(34)
	row := requestlog.Row{
		TSUtc:              ts,
		RequestID:          "post-cutoff-default-rate-tamper",
		AccountID:          "buyer-a",
		Model:              "mlx-community/Llama-3.2-3B-Instruct-4bit",
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}
	input := HotPathInput{
		RequestID:                  row.RequestID,
		AttemptN:                   0,
		ProviderAssignedID:         row.ProviderAssignedID,
		ProviderID:                 "provider-a",
		Model:                      row.Model,
		Status:                     row.Status,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  RateFor(cfg.RateCard, row.Model),
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(AccountScopeForSettlement(row.AccountID)),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	defaultRate := cfg.RateCard["default"]
	tampered := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, defaultRate, input.MultiplierPPM, input.ProviderShareBps)
	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
	if _, err := store.db.Exec(`
	UPDATE ledger_request_credits
	   SET prompt_rate_per_mtok = ?,
	       completion_rate_per_mtok = ?,
	       gross_credits = ?,
	       provider_credits = ?
	 WHERE id = ?`,
		defaultRate.PromptCreditsPerMtok,
		defaultRate.CompletionCreditsPerMtok,
		tampered.GrossCredits,
		tampered.ProviderCredits,
		requestCreditID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_operator_credits SET gross_credits = ?, operator_credits = ? WHERE request_credit_id = ?`,
		tampered.GrossCredits, tampered.OperatorCredits, requestCreditID); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "nightly_reconcile"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
		t.Fatalf("quarantined rows after recovery=%d want 1", got)
	}
}

func TestRecoverLedger_QuarantinesPreCutoffNormalizedDefaultRateTamper(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	cfg := testRewards()
	cfg.RateCard["llama-3.2-3b-instruct"] = RateCardEntry{
		PromptCreditsPerMtok:     13500,
		CompletionCreditsPerMtok: 27000,
	}
	ts := recoveryLegacyDefaultRateCutoffUTC.Add(-time.Minute)
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, ts.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(40), int64(34)
	row := requestlog.Row{
		TSUtc:              ts,
		RequestID:          "pre-cutoff-normalized-default-rate-tamper",
		AccountID:          "buyer-a",
		Model:              "mlx-community/Llama-3.2-3B-Instruct-4bit",
		ProviderAssignedID: "assigned-a",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}
	input := HotPathInput{
		RequestID:                  row.RequestID,
		AttemptN:                   0,
		ProviderAssignedID:         row.ProviderAssignedID,
		ProviderID:                 "provider-a",
		Model:                      row.Model,
		Status:                     row.Status,
		TSUtc:                      ts,
		PromptTokens:               &prompt,
		CompletionTokens:           &completion,
		ConfigSnapshotID:           snapshotID,
		RateEntry:                  RateFor(cfg.RateCard, row.Model),
		MultiplierPPM:              ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps:           ParseShareBps(cfg.ProviderShare),
		SettlementAccountScopeHash: SettlementAccountScopeHash(AccountScopeForSettlement(row.AccountID)),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	defaultRate := cfg.RateCard["default"]
	tampered := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, defaultRate, input.MultiplierPPM, input.ProviderShareBps)
	requestCreditID := scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, row.RequestID)
	if _, err := store.db.Exec(`
	UPDATE ledger_request_credits
	   SET prompt_rate_per_mtok = ?,
	       completion_rate_per_mtok = ?,
	       gross_credits = ?,
	       provider_credits = ?
	 WHERE id = ?`,
		defaultRate.PromptCreditsPerMtok,
		defaultRate.CompletionCreditsPerMtok,
		tampered.GrossCredits,
		tampered.ProviderCredits,
		requestCreditID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_operator_credits SET gross_credits = ?, operator_credits = ? WHERE request_credit_id = ?`,
		tampered.GrossCredits, tampered.OperatorCredits, requestCreditID); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "nightly_reconcile"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND quarantined = 1 AND quarantine_reason = 'reconciliation_mismatch'`, row.RequestID); got != 1 {
		t.Fatalf("quarantined rows after recovery=%d want 1", got)
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

func columnExists(t *testing.T, db *sql.DB, table, column string) bool {
	t.Helper()
	rows, err := db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			t.Fatal(err)
		}
		if name == column {
			return true
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
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
