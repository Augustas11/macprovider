package billing

import (
	"context"
	"database/sql"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

func newJournalPruneStore(t *testing.T) (*Store, *sql.DB) {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(filepath.Join(t.TempDir(), "coordinator.db.route-snapshots")))
	if err != nil {
		t.Fatal(err)
	}
	journalDB.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = journalDB.Close() })
	store.SetRouteSnapshotJournalDB(journalDB)
	if err := store.InitRouteSnapshotJournal(context.Background()); err != nil {
		t.Fatal(err)
	}
	return store, journalDB
}

func insertJournalSnapshot(t *testing.T, store *Store, requestID string) RouteSnapshot {
	t.Helper()
	snapshot := testRouteSnapshot()
	snapshot.RequestID = requestID
	if _, err := store.InsertRouteSnapshot(context.Background(), snapshot); err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func journalPruneOptions() RouteSnapshotJournalPruneOptions {
	return RouteSnapshotJournalPruneOptions{Grace: time.Hour, BatchSize: 2, MaxBatches: 100}
}

func backdateJournal(t *testing.T, db *sql.DB, requestID string, age time.Duration) {
	t.Helper()
	ts := time.Now().UTC().Add(-age).Format(routeSnapshotJournalTimeLayout)
	// created_at_utc is immutable by trigger; recreate the trigger-free
	// state by dropping and restoring the trigger around the backdate.
	var trigger string
	if err := db.QueryRow(`SELECT sql FROM sqlite_master WHERE type='trigger' AND name='trg_srsj_immutable'`).Scan(&trigger); err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		`DROP TRIGGER trg_srsj_immutable`,
		`UPDATE settlement_route_snapshot_journal SET created_at_utc = '` + ts + `', mirrored_at_utc = CASE WHEN mirrored_at_utc IS NULL THEN NULL ELSE '` + ts + `' END WHERE request_id = '` + requestID + `'`,
		trigger,
	} {
		if _, err := db.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
}

func journalRows(t *testing.T, db *sql.DB, requestID string) int64 {
	t.Helper()
	return scalar(t, db, `SELECT COUNT(*) FROM settlement_route_snapshot_journal WHERE request_id = ?`, requestID)
}

// SPEC-022 R-15.10: only rows mirrored past the grace period whose primary
// copy is verified leave the journal.
func TestPruneMirroredRouteSnapshotJournalDeletesOnlyVerifiedMirroredRows(t *testing.T) {
	ctx := context.Background()
	store, journalDB := newJournalPruneStore(t)
	// Ids follow insertion time, so the row inside the grace period is last.
	for _, id := range []string{"req-old-a", "req-old-b", "req-old-c", "req-unmirrored", "req-mismatch", "req-no-primary", "req-recent"} {
		insertJournalSnapshot(t, store, id)
	}
	if _, err := store.MirrorPendingRouteSnapshots(ctx, 100); err != nil {
		t.Fatal(err)
	}
	// Unmirrored: clear the stamp. Mismatch: the primary JSON differs.
	// No primary: the primary row is gone.
	if _, err := journalDB.Exec(`UPDATE settlement_route_snapshot_journal SET mirrored_at_utc = NULL WHERE request_id = 'req-unmirrored'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DROP TRIGGER IF EXISTS trg_srs_immutable`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE settlement_route_snapshots SET route_snapshot_json = route_snapshot_json || ' ' WHERE request_id = 'req-mismatch'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DELETE FROM settlement_route_snapshots WHERE request_id = 'req-no-primary'`); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"req-old-a", "req-old-b", "req-old-c", "req-unmirrored", "req-mismatch", "req-no-primary"} {
		backdateJournal(t, journalDB, id, 2*time.Hour)
	}
	backdateJournal(t, journalDB, "req-recent", 10*time.Minute)

	result, err := store.PruneMirroredRouteSnapshotJournal(ctx, journalPruneOptions())
	if err != nil {
		t.Fatal(err)
	}
	if result.Deleted != 3 || result.Kept != 2 {
		t.Fatalf("result=%+v want deleted=3 kept=2", result)
	}
	for id, want := range map[string]int64{"req-old-a": 0, "req-old-b": 0, "req-old-c": 0, "req-recent": 1, "req-unmirrored": 1, "req-mismatch": 1, "req-no-primary": 1} {
		if got := journalRows(t, journalDB, id); got != want {
			t.Fatalf("%s journal rows=%d want %d", id, got, want)
		}
	}
	// Primary rows are untouched; a repeat run deletes nothing more.
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_route_snapshots WHERE request_id LIKE 'req-old-%'`); got != 3 {
		t.Fatalf("primary rows=%d want 3", got)
	}
	again, err := store.PruneMirroredRouteSnapshotJournal(ctx, journalPruneOptions())
	if err != nil || again.Deleted != 0 {
		t.Fatalf("second run=%+v err=%v", again, err)
	}
	// A mirror call for a pruned attempt is a no-op.
	if err := store.MirrorRouteSnapshotForAttempt(ctx, SettlementReceiptIdentity{AccountScope: testRouteSnapshot().AccountScope, RequestID: "req-old-a", ProviderID: "provider-a"}); err != nil {
		t.Fatalf("mirror of pruned attempt: %v", err)
	}
}

// The walk is bounded per run and resumes from its cursor, so rows that stay
// behind never stop later rows from being pruned.
func TestPruneMirroredRouteSnapshotJournalResumesAcrossBoundedRuns(t *testing.T) {
	ctx := context.Background()
	store, journalDB := newJournalPruneStore(t)
	for _, id := range []string{"req-stuck-1", "req-stuck-2", "req-stuck-3", "req-ok-1", "req-ok-2"} {
		insertJournalSnapshot(t, store, id)
	}
	if _, err := store.MirrorPendingRouteSnapshots(ctx, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := journalDB.Exec(`UPDATE settlement_route_snapshot_journal SET mirrored_at_utc = NULL WHERE request_id LIKE 'req-stuck-%'`); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"req-stuck-1", "req-stuck-2", "req-stuck-3", "req-ok-1", "req-ok-2"} {
		backdateJournal(t, journalDB, id, 2*time.Hour)
	}
	opts := RouteSnapshotJournalPruneOptions{Grace: time.Hour, BatchSize: 2, MaxBatches: 1}
	var deleted int64
	for run := 0; run < 3; run++ {
		result, err := store.PruneMirroredRouteSnapshotJournal(ctx, opts)
		if err != nil {
			t.Fatal(err)
		}
		deleted += result.Deleted
	}
	if deleted != 2 || journalRows(t, journalDB, "req-ok-1")+journalRows(t, journalDB, "req-ok-2") != 0 {
		t.Fatalf("deleted=%d, ok rows remain", deleted)
	}
	if got := scalar(t, journalDB, `SELECT COUNT(*) FROM settlement_route_snapshot_journal WHERE request_id LIKE 'req-stuck-%'`); got != 3 {
		t.Fatalf("stuck rows=%d want 3", got)
	}
}

func TestPruneMirroredRouteSnapshotJournalWithoutJournalIsNoop(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	result, err := store.PruneMirroredRouteSnapshotJournal(context.Background(), journalPruneOptions())
	if err != nil || result != (RouteSnapshotJournalPruneResult{}) {
		t.Fatalf("result=%+v err=%v", result, err)
	}
	if _, err := (&Store{}).PruneMirroredRouteSnapshotJournal(context.Background(), RouteSnapshotJournalPruneOptions{}); err != nil {
		t.Fatalf("nil journal must be a no-op: %v", err)
	}
}

// Retention loops over journal rows that exist: a request whose journal rows
// were pruned before the run, or between export and deletion, still leaves.
func TestEvidenceRetentionAfterRouteJournalPrune(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, true)
	f.seed(t, "first")
	f.seed(t, "b")
	f.seed(t, "c")
	if n, err := f.store.MirrorPendingRouteSnapshots(ctx, 100); err != nil || n != 3 {
		t.Fatalf("mirror n=%d err=%v", n, err)
	}
	f.settle(t)
	fixtureNow := f.store.now
	prune := func() RouteSnapshotJournalPruneResult {
		f.store.now = func() time.Time { return time.Now().Add(2 * time.Hour) }
		defer func() { f.store.now = fixtureNow }()
		result, err := f.store.PruneMirroredRouteSnapshotJournal(ctx, journalPruneOptions())
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	// Request b's journal row is pruned before the run; c's between the
	// archive export and the deletion.
	if _, err := f.journalDB.Exec(`UPDATE settlement_route_snapshot_journal SET mirrored_at_utc = NULL WHERE request_id <> ?`, f.inputs["b"].RequestID); err != nil {
		t.Fatal(err)
	}
	if got := prune(); got.Deleted != 1 {
		t.Fatalf("pre-run prune=%+v want 1 deleted", got)
	}
	if _, err := f.journalDB.Exec(`UPDATE settlement_route_snapshot_journal SET mirrored_at_utc = '2000-01-01T00:00:00.000Z'`); err != nil {
		t.Fatal(err)
	}
	verifier := &recordingVerifier{hook: func() {
		if got := prune(); got.Deleted != 2 {
			t.Errorf("mid-run prune=%+v want 2 deleted", got)
		}
	}}
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), verifier.verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || report.DeletedRequests != 2 {
		t.Fatalf("run report=%+v", report)
	}
	if f.hotRows(t, "b") != 0 || f.hotRows(t, "c") != 0 {
		t.Fatalf("hot rows b=%d c=%d want 0", f.hotRows(t, "b"), f.hotRows(t, "c"))
	}
	if got := scalar(t, f.journalDB, `SELECT COUNT(*) FROM settlement_route_snapshot_journal`); got != 0 {
		t.Fatalf("journal rows=%d want 0", got)
	}
	if strings.TrimSpace(report.ArchiveFile) == "" {
		t.Fatal("archive file missing")
	}
}

// The primary row must also agree on the columns outside the JSON and the
// digest, and its stored preimage must hash to the digest; a legacy row that
// stores its preimage is pruned like a new one.
func TestPruneMirroredRouteSnapshotJournalChecksTypedColumnsAndStoredPreimage(t *testing.T) {
	ctx := context.Background()
	store, journalDB := newJournalPruneStore(t)
	ids := []string{"req-legacy", "req-bad-preimage", "req-binding-differs", "req-capture-differs", "req-late-mirror"}
	for _, id := range ids {
		insertJournalSnapshot(t, store, id)
	}
	if _, err := store.MirrorPendingRouteSnapshots(ctx, 100); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DROP TRIGGER IF EXISTS trg_srs_immutable`); err != nil {
		t.Fatal(err)
	}
	var rendered string
	if err := store.db.QueryRow(`SELECT route_snapshot_json FROM settlement_route_snapshots WHERE request_id = 'req-legacy'`).Scan(&rendered); err != nil {
		t.Fatal(err)
	}
	preimage, err := RouteSnapshotCanonicalJSON("", rendered)
	if err != nil {
		t.Fatal(err)
	}
	for _, stmt := range []string{
		// A legacy row stores its preimage on both sides.
		`UPDATE settlement_route_snapshots SET route_snapshot_canonical_json = '` + string(preimage) + `' WHERE request_id = 'req-legacy'`,
		`UPDATE settlement_route_snapshots SET route_snapshot_canonical_json = '{"tampered":true}' WHERE request_id = 'req-bad-preimage'`,
		`UPDATE settlement_route_snapshots SET relay_blind_provider_binding_digest = '` + strings.Repeat("A", 43) + `' WHERE request_id = 'req-binding-differs'`,
		`UPDATE settlement_route_snapshots SET compute_integrity_sampling_profile_covered = 1 WHERE request_id = 'req-capture-differs'`,
	} {
		if _, err := store.db.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	for _, id := range ids {
		backdateJournal(t, journalDB, id, 2*time.Hour)
	}
	// Created before the cutoff, mirrored inside the grace period: skipped
	// now, pruned once its grace has passed.
	if _, err := journalDB.Exec(`UPDATE settlement_route_snapshot_journal SET mirrored_at_utc = ? WHERE request_id = 'req-late-mirror'`,
		time.Now().UTC().Add(-10*time.Minute).Format(routeSnapshotJournalTimeLayout)); err != nil {
		t.Fatal(err)
	}
	result, err := store.PruneMirroredRouteSnapshotJournal(ctx, journalPruneOptions())
	if err != nil {
		t.Fatal(err)
	}
	if result.Deleted != 1 || result.Kept != 3 {
		t.Fatalf("result=%+v want deleted=1 kept=3", result)
	}
	for id, want := range map[string]int64{"req-legacy": 0, "req-bad-preimage": 1, "req-binding-differs": 1, "req-capture-differs": 1, "req-late-mirror": 1} {
		if got := journalRows(t, journalDB, id); got != want {
			t.Fatalf("%s journal rows=%d want %d", id, got, want)
		}
	}
	later := time.Now().Add(time.Hour)
	store.now = func() time.Time { return later }
	result, err = store.PruneMirroredRouteSnapshotJournal(ctx, journalPruneOptions())
	if err != nil {
		t.Fatal(err)
	}
	if result.Deleted != 1 || journalRows(t, journalDB, "req-late-mirror") != 0 {
		t.Fatalf("late mirror prune=%+v", result)
	}
}
