package billing

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
)

// insertServedModelSnapshot records the route snapshot of requestID's
// attempt 0 on providerID, served by model; flagged marks a warm-set entry
// dispatch (SPEC-002-R011).
func insertServedModelSnapshot(t *testing.T, store *Store, requestID, providerID, model string, flagged bool) {
	t.Helper()
	snapshot := testRouteSnapshot()
	snapshot.RequestID = requestID
	snapshot.ProviderID = providerID
	snapshot.ModelID = model
	snapshot.ServedModelDispatch = flagged
	if _, err := store.InsertRouteSnapshot(context.Background(), snapshot); err != nil {
		t.Fatal(err)
	}
}

// SPEC-022 R-16.2a: on a multi-model provider a hold for one served model
// withholds only that model's entry-dispatched credits; the other model's
// credits settle. Credits without a flagged snapshot keep the provider-wide
// R-16.2 match.
func TestComputeIntegrityHoldWithholdsOnlyTheServedModel(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	t0 := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	credits := []struct {
		request string
		model   string
		flagged bool
		amount  int64
	}{
		{"entry-a", "model-a", true, 100},
		{"entry-a-case", "MODEL-A", true, 200}, // case-folded match
		{"entry-b", "model-b", true, 400},
		{"unflagged-b", "model-b", false, 800}, // single-model dispatch
		{"no-snapshot", "", false, 1600},       // legacy credit
	}
	for i, c := range credits {
		insertCreditWithOperator(t, store.db, c.request, "p-a", t0.Add(time.Duration(i+1)*time.Minute), c.amount)
		if c.model != "" {
			insertServedModelSnapshot(t, store, c.request, "p-a", c.model, c.flagged)
		}
	}
	payable := func() int64 {
		return scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`)
	}
	if got := payable(); got != 3100 {
		t.Fatalf("baseline payable=%d want 3100", got)
	}
	end := t0.Add(time.Hour)
	if _, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-a", computeintegrity.HoldKindFailure, t0, &end, "confirmed_failure", end); err != nil {
		t.Fatal(err)
	}
	if got := payable(); got != 400 {
		t.Fatalf("held payable=%d want 400 (only the model-b entry credit)", got)
	}
	holds, err := store.ComputeIntegrityHolds(ctx, "p-a")
	if err != nil || len(holds) != 1 || holds[0].HeldCredits != 2700 {
		t.Fatalf("holds=%+v err=%v, want 2700 held", holds, err)
	}
	// Retention keeps the evidence of every credit the provider-wide hold
	// covers hot, so the flagged snapshot that keeps entry-b payable is
	// never archived from under a held hold.
	bundle, err := collectRequestEvidence(ctx, store.db, "entry-b")
	if err != nil || len(bundle.credits) != 1 || bundle.credits[0].payable {
		t.Fatalf("retention payable for entry-b under a held hold: %+v err=%v", bundle.credits, err)
	}
	if err := store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, t0, t0.AddDate(0, 0, 7)); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 1 AND request_id = 'entry-b'`); got != 1 {
		t.Fatal("the other model's credit must settle")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 0`); got != 4 {
		t.Fatalf("unsettled=%d want 4 held credits", got)
	}
}

// A hold for model-b on the same provider leaves model-a's entry credits
// payable and legacy credits held, symmetrically.
func TestComputeIntegrityHoldOtherModelSymmetric(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	t0 := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	insertCreditWithOperator(t, store.db, "entry-a", "p-a", t0.Add(time.Minute), 100)
	insertServedModelSnapshot(t, store, "entry-a", "p-a", "model-a", true)
	insertCreditWithOperator(t, store.db, "legacy", "p-a", t0.Add(2*time.Minute), 200)
	if _, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-b", computeintegrity.HoldKindRecovery, t0, nil, "cooldown_elapsed", t0); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`); got != 100 {
		t.Fatalf("payable=%d want 100", got)
	}
}

// The served_model_dispatch column is added to an existing table without a
// CHECK and without touching existing rows, and re-running the migration
// changes nothing.
func TestServedModelDispatchColumnMigrationIsAdditiveAndIdempotent(t *testing.T) {
	store, journalDB := newJournalPruneStore(t)
	ctx := context.Background()
	legacy := insertJournalSnapshot(t, store, "legacy-row")
	if _, err := store.MirrorPendingRouteSnapshots(ctx, 10); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `DROP VIEW spec022_payable_request_credits`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `ALTER TABLE settlement_route_snapshots DROP COLUMN served_model_dispatch`); err != nil {
		t.Fatal(err)
	}
	if _, err := journalDB.ExecContext(ctx, `ALTER TABLE settlement_route_snapshot_journal DROP COLUMN served_model_dispatch`); err != nil {
		t.Fatal(err)
	}
	digestBefore := scalarText(t, store.db, `SELECT route_snapshot_digest FROM settlement_route_snapshots WHERE request_id = ?`, legacy.RequestID)
	for i := 0; i < 2; i++ {
		if err := store.ensureSettlementRouteSnapshotComputeIntegrityColumns(ctx); err != nil {
			t.Fatal(err)
		}
		if err := store.InitRouteSnapshotJournal(ctx); err != nil {
			t.Fatal(err)
		}
		if err := store.rebuildSpec022PayableRequestCreditsView(ctx); err != nil {
			t.Fatal(err)
		}
	}
	for _, c := range []struct {
		name  string
		query func(string, ...any) int64
		ddl   func() string
	}{
		{"settlement_route_snapshots", func(q string, a ...any) int64 { return scalar(t, store.db, q, a...) }, func() string {
			return scalarText(t, store.db, `SELECT sql FROM sqlite_master WHERE type='table' AND name='settlement_route_snapshots'`)
		}},
		{"settlement_route_snapshot_journal", func(q string, a ...any) int64 { return scalar(t, journalDB, q, a...) }, func() string {
			return scalarText(t, journalDB, `SELECT sql FROM sqlite_master WHERE type='table' AND name='settlement_route_snapshot_journal'`)
		}},
	} {
		if n := c.query(`SELECT COUNT(*) FROM pragma_table_info('` + c.name + `') WHERE name = 'served_model_dispatch'`); n != 1 {
			t.Fatalf("%s: served_model_dispatch columns=%d", c.name, n)
		}
		if got := c.query(`SELECT served_model_dispatch FROM `+c.name+` WHERE request_id = ?`, legacy.RequestID); got != 0 {
			t.Fatalf("%s: legacy row served_model_dispatch=%d want 0", c.name, got)
		}
		if strings.Contains(c.ddl(), "CHECK(served_model_dispatch") {
			t.Fatalf("%s: added column must not carry a CHECK", c.name)
		}
	}
	if got := scalarText(t, store.db, `SELECT route_snapshot_digest FROM settlement_route_snapshots WHERE request_id = ?`, legacy.RequestID); got != digestBefore {
		t.Fatal("migration rewrote an existing snapshot")
	}
}

// The flag rides beside the snapshot through the journal into the primary
// row, outside the digested preimage, so receipts and the settlement
// verifier see the same digest with or without it; prune compares it.
func TestServedModelDispatchSurvivesJournalOutsideDigest(t *testing.T) {
	store, journalDB := newJournalPruneStore(t)
	ctx := context.Background()
	snapshot := testRouteSnapshot()
	snapshot.RequestID = "entry-dispatch"
	snapshot.ModelID = "model-b"
	unflagged := snapshot
	wantDigest, _, err := unflagged.Digest()
	if err != nil {
		t.Fatal(err)
	}
	snapshot.ServedModelDispatch = true
	digest, err := store.InsertRouteSnapshot(ctx, snapshot)
	if err != nil || digest != wantDigest {
		t.Fatalf("digest=%s want %s err=%v", digest, wantDigest, err)
	}
	if _, err := store.db.Exec(`DELETE FROM settlement_route_snapshots`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MirrorPendingRouteSnapshots(ctx, 10); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT served_model_dispatch FROM settlement_route_snapshots WHERE request_id = ?`, snapshot.RequestID); got != 1 {
		t.Fatalf("mirrored served_model_dispatch=%d want 1", got)
	}
	if got := scalar(t, journalDB, `SELECT served_model_dispatch FROM settlement_route_snapshot_journal WHERE request_id = ?`, snapshot.RequestID); got != 1 {
		t.Fatalf("journal served_model_dispatch=%d want 1", got)
	}
	rows, err := loadRouteSnapshotJournalPruneBatch(ctx, journalDB, 0, 10)
	if err != nil || len(rows) != 1 {
		t.Fatalf("prune batch=%d err=%v", len(rows), err)
	}
	if ok, err := store.routeSnapshotJournalRowMatchesPrimary(ctx, rows[0]); err != nil || !ok {
		t.Fatalf("journal row must match its mirror: ok=%v err=%v", ok, err)
	}
	rows[0].servedModel = 0
	if ok, err := store.routeSnapshotJournalRowMatchesPrimary(ctx, rows[0]); err != nil || ok {
		t.Fatalf("a mirror that lost the flag must not match: ok=%v err=%v", ok, err)
	}
}

// SPEC-002-R011 / SPEC-010 canonical model id: the scoring loop opens a hold
// on the canonical key (trimmed, NFC, lowercase), and the coordinator only
// accepts model ids whose ASCII lower() is that key, so an entry credit
// served under any accepted spelling of the held model is withheld.
func TestComputeIntegrityHoldWithholdsEverySpellingOfTheServedModel(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	t0 := time.Date(2026, 7, 1, 0, 0, 0, 0, time.UTC)
	for i, spelling := range []string{"model-held", "Model-Held", "MODEL-HELD"} {
		request := "entry-" + spelling
		insertCreditWithOperator(t, store.db, request, "p-a", t0.Add(time.Duration(i+1)*time.Minute), 100)
		insertServedModelSnapshot(t, store, request, "p-a", spelling, true)
	}
	insertCreditWithOperator(t, store.db, "entry-other", "p-a", t0.Add(10*time.Minute), 1000)
	insertServedModelSnapshot(t, store, "entry-other", "p-a", "model-other", true)
	end := t0.Add(time.Hour)
	if _, err := store.OpenComputeIntegrityHold(ctx, "p-a", "model-held", computeintegrity.HoldKindFailure, t0, &end, "confirmed_failure", end); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`); got != 1000 {
		t.Fatalf("payable=%d want 1000 (every spelling of model-held withheld)", got)
	}
}
