package billing

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestRecoverLedgerCrashResumeUsesDurableCursor(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	in := seedDenseRecoveryFixture(t, reqStore, store, recoverLedgerBatchRows+3)

	injected := errors.New("injected crash after committed batch")
	failedOnce := false
	recoverLedgerAfterBatchForTest = func(phase string, rows int, _ int64) error {
		if phase == "request" && rows == recoverLedgerBatchRows && !failedOnce {
			failedOnce = true
			return injected
		}
		return nil
	}
	t.Cleanup(func() { recoverLedgerAfterBatchForTest = nil })

	if err := store.RecoverLedger(ctx, in); !errors.Is(err, injected) {
		t.Fatalf("RecoverLedger error=%v want injected crash", err)
	}
	var runID, cursor, scanned int64
	var status, phase string
	if err := store.db.QueryRow(`
SELECT id, status, recovery_phase, recovery_request_cursor_id, request_log_rows_scanned
  FROM ledger_reconciliation_runs
 WHERE run_type='nightly_reconcile'
 ORDER BY id DESC LIMIT 1`).Scan(&runID, &status, &phase, &cursor, &scanned); err != nil {
		t.Fatal(err)
	}
	if status != "failed" || phase != "request" {
		t.Fatalf("failed run status=%q phase=%q want failed/request", status, phase)
	}
	if cursor == 0 || scanned != recoverLedgerBatchRows {
		t.Fatalf("durable progress cursor=%d scanned=%d want nonzero/%d", cursor, scanned, recoverLedgerBatchRows)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != recoverLedgerBatchRows {
		t.Fatalf("committed credits=%d want %d", got, recoverLedgerBatchRows)
	}

	recoverLedgerAfterBatchForTest = nil
	if err := store.RecoverLedger(ctx, in); err != nil {
		t.Fatalf("resumed RecoverLedger: %v", err)
	}
	var resumedID, finalCursor, finalScanned int64
	if err := store.db.QueryRow(`
SELECT id, status, recovery_phase, recovery_request_cursor_id, request_log_rows_scanned
  FROM ledger_reconciliation_runs
 WHERE run_type='nightly_reconcile'
 ORDER BY id DESC LIMIT 1`).Scan(&resumedID, &status, &phase, &finalCursor, &finalScanned); err != nil {
		t.Fatal(err)
	}
	if resumedID != runID {
		t.Fatalf("resume created run id=%d want original id=%d", resumedID, runID)
	}
	if status != "complete" || phase != "complete" {
		t.Fatalf("resumed run status=%q phase=%q want complete/complete", status, phase)
	}
	if finalCursor <= cursor || finalScanned != recoverLedgerBatchRows+3 {
		t.Fatalf("final cursor=%d scanned=%d want cursor>%d scanned=%d", finalCursor, finalScanned, cursor, recoverLedgerBatchRows+3)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != recoverLedgerBatchRows+3 {
		t.Fatalf("final credits=%d want %d", got, recoverLedgerBatchRows+3)
	}
}

func TestRecoverLedgerDenseWindowBoundsEveryWriterBatchByRows(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	rowCount := 2*recoverLedgerBatchRows + 5
	in := seedDenseRecoveryFixture(t, reqStore, store, rowCount)
	for i := 0; i < rowCount; i++ {
		insertCreditWithRequest(t, store.db, fmt.Sprintf("dense-orphan-%04d", i), "orphan-provider", in.ScanFrom.Add(time.Second), 1)
	}

	batches := map[string]int{}
	maxRows := map[string]int{}
	recoverLedgerAfterBatchForTest = func(phase string, rows int, _ int64) error {
		batches[phase]++
		if rows > maxRows[phase] {
			maxRows[phase] = rows
		}
		if rows > recoverLedgerBatchRows {
			t.Fatalf("%s batch rows=%d exceeds bound=%d", phase, rows, recoverLedgerBatchRows)
		}
		return nil
	}
	t.Cleanup(func() { recoverLedgerAfterBatchForTest = nil })

	if err := store.RecoverLedger(ctx, in); err != nil {
		t.Fatalf("RecoverLedger: %v", err)
	}
	for _, phase := range []string{"orphan", "request"} {
		if batches[phase] != 3 || maxRows[phase] != recoverLedgerBatchRows {
			t.Fatalf("%s batches=%d max rows=%d want 3/%d", phase, batches[phase], maxRows[phase], recoverLedgerBatchRows)
		}
	}
	if got := scalar(t, store.db, `SELECT request_log_rows_scanned FROM ledger_reconciliation_runs ORDER BY id DESC LIMIT 1`); got != int64(rowCount) {
		t.Fatalf("rows scanned=%d want %d", got, rowCount)
	}
	if got := scalar(t, store.db, `SELECT orphan_credit_rows_quarantined FROM ledger_reconciliation_runs ORDER BY id DESC LIMIT 1`); got != int64(rowCount) {
		t.Fatalf("orphans quarantined=%d want %d", got, rowCount)
	}
}

func TestNextRecoveryIDsCanonicalizesVariableWidthCursorTimestamp(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	scanFrom := time.Date(2026, 10, 2, 1, 2, 3, 100_000_000, time.UTC)
	row.RequestID = "cursor-boundary-row"
	row.ProviderAssignedID = "cursor-boundary-assigned"
	row.TSUtc = scanFrom.Add(time.Nanosecond)
	input.RequestID = row.RequestID
	input.ProviderAssignedID = row.ProviderAssignedID
	input.TSUtc = row.TSUtc
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	ids, next, hasMore, err := store.nextRecoveryIDs(context.Background(), "request_log", "ts_utc", recoveryCursor{
		tsUTC: scanFrom.Format(time.RFC3339Nano),
	}, RecoverInput{ScanFrom: scanFrom, ScanTo: scanFrom.Add(time.Second)})
	if err != nil {
		t.Fatal(err)
	}
	if len(ids) != 1 || hasMore || next.id != ids[0] || next.tsUTC != sqliteTimeText(row.TSUtc) {
		t.Fatalf("boundary recovery ids=%v next=%+v hasMore=%v", ids, next, hasMore)
	}
}

func TestNextRecoveryIDsPreservesNoncanonicalSelectedCursorAtBatchBoundary(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	scanFrom := time.Date(2026, 10, 2, 1, 2, 2, 0, time.UTC)
	rowTime := time.Date(2026, 10, 2, 1, 2, 3, 100_000_000, time.UTC)
	variable := rowTime.Format(time.RFC3339Nano)
	for i := 0; i < recoverLedgerBatchRows+3; i++ {
		input, row := testHotPathInput(t, store)
		row.RequestID = fmt.Sprintf("noncanonical-selected-%03d", i)
		row.ProviderAssignedID = fmt.Sprintf("noncanonical-assigned-%03d", i)
		row.TSUtc = rowTime
		input.RequestID = row.RequestID
		input.ProviderAssignedID = row.ProviderAssignedID
		input.TSUtc = row.TSUtc
		if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.db.Exec(`UPDATE request_log SET ts_utc=? WHERE request_id LIKE 'noncanonical-selected-%'`, variable); err != nil {
		t.Fatal(err)
	}
	first, cursor, hasMore, err := store.nextRecoveryIDs(context.Background(), "request_log", "ts_utc", recoveryCursor{}, RecoverInput{
		ScanFrom: scanFrom,
		ScanTo:   rowTime.Add(time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(first) != recoverLedgerBatchRows || !hasMore || cursor.tsUTC != variable || cursor.id == 0 {
		t.Fatalf("first batch len=%d cursor=%+v hasMore=%v", len(first), cursor, hasMore)
	}
	second, next, hasMore, err := store.nextRecoveryIDs(context.Background(), "request_log", "ts_utc", cursor, RecoverInput{
		ScanFrom: scanFrom,
		ScanTo:   rowTime.Add(time.Second),
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(second) != 3 || hasMore || next.tsUTC != variable || next.id <= cursor.id {
		t.Fatalf("second batch len=%d cursor=%+v previous=%+v hasMore=%v", len(second), next, cursor, hasMore)
	}
}

func TestRecoverLedgerFencesCompetingRunners(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	in := seedDenseRecoveryFixture(t, reqStore, store, 1)

	claimed := make(chan struct{})
	release := make(chan struct{})
	var once sync.Once
	recoverLedgerAfterClaimForTest = func() {
		once.Do(func() {
			close(claimed)
			<-release
		})
	}
	t.Cleanup(func() { recoverLedgerAfterClaimForTest = nil })

	firstDone := make(chan error, 1)
	go func() { firstDone <- store.RecoverLedger(ctx, in) }()
	<-claimed
	competing := in
	competing.Source = "admin_reconcile"
	if err := store.RecoverLedger(ctx, competing); !errors.Is(err, ErrRecoveryInProgress) {
		close(release)
		t.Fatalf("competing RecoverLedger error=%v want ErrRecoveryInProgress", err)
	}
	close(release)
	if err := <-firstDone; err != nil {
		t.Fatalf("first RecoverLedger: %v", err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs`); got != 1 {
		t.Fatalf("reconciliation runs=%d want 1", got)
	}
}

func TestRecoverLedgerReclaimsStaleCrashLease(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	in := seedDenseRecoveryFixture(t, reqStore, store, 1)
	run, _, err := store.acquireRecoveryRun(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
UPDATE ledger_reconciliation_runs
   SET recovery_lease_expires_at_utc=?
 WHERE id=?`, time.Now().UTC().Add(-time.Minute).Format(time.RFC3339Nano), run.id); err != nil {
		t.Fatal(err)
	}

	if err := store.RecoverLedger(ctx, in); err != nil {
		t.Fatalf("reclaim stale recovery lease: %v", err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs`); got != 1 {
		t.Fatalf("reclaimed run count=%d want 1", got)
	}
	var status, owner string
	if err := store.db.QueryRow(`
SELECT status, COALESCE(recovery_lease_owner, '')
  FROM ledger_reconciliation_runs WHERE id=?`, run.id).Scan(&status, &owner); err != nil {
		t.Fatal(err)
	}
	if status != "complete" || owner != "" {
		t.Fatalf("reclaimed run status=%q owner=%q want complete and released", status, owner)
	}
}

func TestRecoverLedgerDrainsExpiredForeignSourceRunsBeforeRequestedSource(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	in := seedDenseRecoveryFixture(t, reqStore, store, 1)
	in.Source = "startup_scan"
	oldest, _, err := store.acquireRecoveryRun(ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	staleLease := sqliteTimeText(time.Now().UTC().Add(-time.Minute))
	if _, err := store.db.Exec(`UPDATE ledger_reconciliation_runs SET recovery_lease_expires_at_utc=? WHERE id=?`, staleLease, oldest.id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`INSERT INTO ledger_reconciliation_runs (
    run_type, from_utc, to_utc, request_log_rows_scanned,
    missing_credit_rows_created, orphan_credit_rows_quarantined,
    buyer_equivalent_credits, provider_gross_credits, reconciliation_delta_credits,
    started_at_utc, finished_at_utc, status, error, recovery_phase,
    recovery_orphan_cursor_ts_utc, recovery_orphan_cursor_id,
    recovery_request_cursor_ts_utc, recovery_request_cursor_id,
    recovery_lease_owner, recovery_lease_expires_at_utc, created_at_utc
) VALUES ('admin_reconcile', ?, ?, 0, 0, 0, 0, 0, 0, ?, NULL, 'running', NULL,
          'orphan', ?, 0, ?, 0, 'stale-admin-owner', ?, ?)`,
		sqliteTimeText(in.ScanFrom), sqliteTimeText(in.ScanTo), staleLease,
		sqliteTimeText(in.ScanFrom), sqliteTimeText(in.ScanFrom), staleLease, staleLease); err != nil {
		t.Fatal(err)
	}

	requested := in
	requested.Source = "nightly_reconcile"
	if err := store.RecoverLedger(ctx, requested); err != nil {
		t.Fatalf("drain stale foreign-source runs: %v", err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE status='complete'`); got != 3 {
		t.Fatalf("complete recovery runs=%d want startup, admin, and requested nightly", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE status!='complete'`); got != 0 {
		t.Fatalf("incomplete recovery runs=%d want 0", got)
	}
}

func TestRecoverLedgerMovingWindowFinishesDurableResumeBeforeFreshRun(t *testing.T) {
	ctx := context.Background()
	reqStore, store := newRequestAndBillingStores(t)
	in := seedDenseRecoveryFixture(t, reqStore, store, recoverLedgerBatchRows+1)
	injected := errors.New("injected moving-window interruption")
	failedOnce := false
	recoverLedgerAfterBatchForTest = func(phase string, rows int, _ int64) error {
		if phase == "request" && rows == recoverLedgerBatchRows && !failedOnce {
			failedOnce = true
			return injected
		}
		return nil
	}
	t.Cleanup(func() { recoverLedgerAfterBatchForTest = nil })
	if err := store.RecoverLedger(ctx, in); !errors.Is(err, injected) {
		t.Fatalf("first RecoverLedger error=%v want injected interruption", err)
	}

	recoverLedgerAfterBatchForTest = nil
	moving := in
	moving.ScanTo = moving.ScanTo.Add(time.Second)
	if err := store.RecoverLedger(ctx, moving); err != nil {
		t.Fatalf("moving-window RecoverLedger: %v", err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE status='complete'`); got != 2 {
		t.Fatalf("complete recovery runs=%d want resumed old range plus fresh moving range", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE status='failed'`); got != 0 {
		t.Fatalf("failed recovery runs=%d want resumed run promoted to complete", got)
	}
}

func seedDenseRecoveryFixture(t *testing.T, reqStore *requestlog.Store, store *Store, count int) RecoverInput {
	t.Helper()
	input, row := testHotPathInput(t, store)
	stamp := time.Unix(3600, 0).UTC()
	for i := 0; i < count; i++ {
		requestID := fmt.Sprintf("dense-recovery-%04d", i)
		assignedID := fmt.Sprintf("dense-assigned-%04d", i)
		itemRow := row
		itemRow.RequestID = requestID
		itemRow.ProviderAssignedID = assignedID
		itemRow.TSUtc = stamp
		itemInput := input
		itemInput.RequestID = requestID
		itemInput.ProviderAssignedID = assignedID
		itemInput.TSUtc = stamp
		if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, itemRow, itemInput); err != nil {
			t.Fatalf("seed dense recovery row %d: %v", i, err)
		}
	}
	return RecoverInput{ScanFrom: stamp.Add(-time.Second), ScanTo: stamp.Add(time.Second), Source: "nightly_reconcile"}
}
