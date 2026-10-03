package billing

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"
)

func TestJournalSettlementAttemptOutputConnIdempotentReplayAndConflict(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	attempt := testJournalSettlementAttempt("req-journal-idempotent")
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
		t.Fatal(err)
	}
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
		t.Fatalf("identical journal replay failed: %v", err)
	}
	var rows int64
	if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM settlement_attempt_output_journal WHERE request_id = ?`, attempt.RequestID).Scan(&rows); err != nil {
		t.Fatal(err)
	}
	if rows != 1 {
		t.Fatalf("journal rows=%d want 1", rows)
	}

	conflict := attempt
	conflict.Usage.BillableOutputTokens++
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, conflict); err == nil {
		t.Fatal("conflicting journal replay succeeded")
	}
	var poisoned sql.NullString
	if err := conn.QueryRowContext(ctx, `
SELECT poisoned_at_utc
  FROM settlement_attempt_output_journal
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		attempt.AccountScope, attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
	).Scan(&poisoned); err != nil {
		t.Fatal(err)
	}
	if !poisoned.Valid || poisoned.String == "" {
		t.Fatal("conflicting journal replay did not mark poison metadata")
	}
}

func TestWriteHotPathCommitsCreditAndAttemptOutputJournalAtomically(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	attempt := testJournalSettlementAttempt(input.RequestID)
	attempt.ProviderID = input.ProviderID
	input.SettlementAttemptOutput = &attempt

	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}
	for table, want := range map[string]int64{
		"request_log":                       1,
		"ledger_request_credits":            1,
		"settlement_attempt_output_journal": 1,
		"settlement_attempt_outputs":        0,
	} {
		if got := scalar(t, store.db, `SELECT COUNT(*) FROM `+table); got != want {
			t.Fatalf("%s rows=%d want %d", table, got, want)
		}
	}
	var journalSchema string
	if err := store.db.QueryRow(`SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'settlement_attempt_output_journal'`).Scan(&journalSchema); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(journalSchema, "settlement_output_canonical_json") {
		t.Fatal("compact attempt-output journal schema permits raw provider output")
	}
}

func TestWriteHotPathRollsBackCreditWhenAttemptOutputJournalRejects(t *testing.T) {
	reqStore, store := newRequestAndBillingStores(t)
	input, row := testHotPathInput(t, store)
	attempt := testJournalSettlementAttempt(input.RequestID)
	attempt.ProviderID = input.ProviderID
	attempt.TerminalStateTSUnixMS = 0
	input.SettlementAttemptOutput = &attempt

	if err := store.WriteHotPath(context.Background(), reqStore, row, input); err == nil {
		t.Fatal("hot path succeeded with invalid settlement attempt output")
	}
	for _, table := range []string{
		"request_log",
		"ledger_request_credits",
		"ledger_operator_credits",
		"ledger_provider_identity_snapshots",
		"settlement_attempt_output_journal",
	} {
		if got := scalar(t, store.db, `SELECT COUNT(*) FROM `+table); got != 0 {
			t.Fatalf("%s rows=%d want 0 after atomic rollback", table, got)
		}
	}
}

func TestMaterializeSettlementAttemptOutputFor(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	attempt := testJournalSettlementAttempt("req-journal-materialize")
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
		t.Fatal(err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	materialized, err := store.MaterializeSettlementAttemptOutputFor(ctx, SettlementReceiptIdentity{
		AccountScope: attempt.AccountScope,
		RequestID:    attempt.RequestID,
		AttemptN:     attempt.AttemptN,
		ProviderID:   attempt.ProviderID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !materialized {
		t.Fatal("first materialization reported false")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_attempt_outputs WHERE request_id = ?`, attempt.RequestID); got != 1 {
		t.Fatalf("materialized rows=%d want 1", got)
	}
	var materializedAt sql.NullString
	var attempts int
	if err := store.db.QueryRow(`
SELECT materialized_at_utc, materialize_attempts
  FROM settlement_attempt_output_journal
 WHERE request_id = ?`, attempt.RequestID).Scan(&materializedAt, &attempts); err != nil {
		t.Fatal(err)
	}
	if !materializedAt.Valid || materializedAt.String == "" || attempts != 1 {
		t.Fatalf("journal materialized_at=%v attempts=%d, want set/1", materializedAt, attempts)
	}
	materialized, err = store.MaterializeSettlementAttemptOutputFor(ctx, SettlementReceiptIdentity{
		AccountScope: attempt.AccountScope,
		RequestID:    attempt.RequestID,
		AttemptN:     attempt.AttemptN,
		ProviderID:   attempt.ProviderID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if materialized {
		t.Fatal("second materialization reported true")
	}
}

func TestSettlementAttemptOutputEvidenceExistsDistinguishesMissingAndMaterialized(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	attempt := testJournalSettlementAttempt("req-journal-evidence-state")
	id := SettlementReceiptIdentity{AccountScope: attempt.AccountScope, RequestID: attempt.RequestID, AttemptN: attempt.AttemptN, ProviderID: attempt.ProviderID}
	if exists, err := store.SettlementAttemptOutputEvidenceExists(ctx, id); err != nil || exists {
		t.Fatalf("missing evidence exists=%v err=%v, want false/nil", exists, err)
	}
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	_ = conn.Close()
	if exists, err := store.SettlementAttemptOutputEvidenceExists(ctx, id); err != nil || !exists {
		t.Fatalf("journal evidence exists=%v err=%v, want true/nil", exists, err)
	}
	if _, err := store.MaterializeSettlementAttemptOutputFor(ctx, id); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`DELETE FROM settlement_attempt_output_journal WHERE request_id = ?`, attempt.RequestID); err != nil {
		t.Fatal(err)
	}
	if exists, err := store.SettlementAttemptOutputEvidenceExists(ctx, id); err != nil || !exists {
		t.Fatalf("projected evidence exists=%v err=%v, want true/nil", exists, err)
	}
}

func TestPruneSettlementAttemptOutputJournalIsBoundedAndPreservesPending(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	old := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC)
	store.now = func() time.Time { return old }
	for _, requestID := range []string{"req-prune-old-a", "req-prune-old-b"} {
		attempt := testJournalSettlementAttempt(requestID)
		conn, err := store.db.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
			_ = conn.Close()
			t.Fatal(err)
		}
		_ = conn.Close()
		id := SettlementReceiptIdentity{AccountScope: attempt.AccountScope, RequestID: attempt.RequestID, AttemptN: attempt.AttemptN, ProviderID: attempt.ProviderID}
		if _, err := store.MaterializeSettlementAttemptOutputFor(ctx, id); err != nil {
			t.Fatal(err)
		}
	}
	pending := testJournalSettlementAttempt("req-prune-pending")
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, pending); err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	_ = conn.Close()
	poisoned := testJournalSettlementAttempt("req-prune-old-a")
	poisoned.Usage.BillableOutputTokens++
	conn, err = store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, poisoned); err == nil {
		_ = conn.Close()
		t.Fatal("conflicting replay unexpectedly succeeded")
	}
	_ = conn.Close()

	pruned, err := store.PruneSettlementAttemptOutputJournal(ctx, old.Add(time.Hour), 1)
	if err != nil || pruned != 1 {
		t.Fatalf("first prune rows=%d err=%v want 1/nil", pruned, err)
	}
	pruned, err = store.PruneSettlementAttemptOutputJournal(ctx, old.Add(time.Hour), 10)
	if err != nil || pruned != 0 {
		t.Fatalf("second prune rows=%d err=%v want 0/nil", pruned, err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_attempt_output_journal WHERE materialized_at_utc IS NULL`); got != 1 {
		t.Fatalf("pending journal rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_attempt_output_journal WHERE poisoned_at_utc IS NOT NULL`); got != 1 {
		t.Fatalf("retained materialized poison rows=%d want 1", got)
	}
}

func TestMaterializeSettlementAttemptOutputConflictPoisonsJournal(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	attempt := testJournalSettlementAttempt("req-journal-materialize-conflict")
	if _, err := store.InsertSettlementAttemptOutput(ctx, attempt); err != nil {
		t.Fatal(err)
	}
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conflict := attempt
	conflict.Usage.BillableInputTokens++
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, conflict); err != nil {
		t.Fatal(err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	materialized, err := store.MaterializeSettlementAttemptOutputFor(ctx, SettlementReceiptIdentity{
		AccountScope: attempt.AccountScope,
		RequestID:    attempt.RequestID,
		AttemptN:     attempt.AttemptN,
		ProviderID:   attempt.ProviderID,
	})
	if err == nil {
		t.Fatal("conflicting materialization succeeded")
	}
	if materialized {
		t.Fatal("conflicting materialization reported true")
	}
	var poisoned sql.NullString
	var attempts int
	if err := store.db.QueryRow(`
SELECT poisoned_at_utc, materialize_attempts
  FROM settlement_attempt_output_journal
 WHERE request_id = ?`, attempt.RequestID).Scan(&poisoned, &attempts); err != nil {
		t.Fatal(err)
	}
	if !poisoned.Valid || poisoned.String == "" || attempts != 1 {
		t.Fatalf("poisoned_at=%v attempts=%d, want set/1", poisoned, attempts)
	}
}

func TestMaterializeSettlementAttemptOutputTransientFailureRemainsPending(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	attempt := testJournalSettlementAttempt("req-journal-transient")
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
		_ = conn.Close()
		t.Fatal(err)
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}

	canceled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := store.MaterializeSettlementAttemptOutputFor(canceled, SettlementReceiptIdentity{
		AccountScope: attempt.AccountScope,
		RequestID:    attempt.RequestID,
		AttemptN:     attempt.AttemptN,
		ProviderID:   attempt.ProviderID,
	}); err == nil {
		t.Fatal("materialization unexpectedly succeeded with canceled context")
	}
	var poisoned sql.NullString
	if err := store.db.QueryRow(`
SELECT poisoned_at_utc
  FROM settlement_attempt_output_journal
 WHERE request_id = ?`, attempt.RequestID).Scan(&poisoned); err != nil {
		t.Fatal(err)
	}
	if poisoned.Valid {
		t.Fatalf("transient failure poisoned durable journal row at %s", poisoned.String)
	}
	stats, err := store.SettlementAttemptOutputJournalStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if stats.PendingRows != 1 || stats.PoisonedRows != 0 {
		t.Fatalf("stats=%+v, want one pending and no poison", stats)
	}
}

func TestPendingSettlementAttemptOutputMaterializationStatsAndIndexPlan(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	baseNow := time.Date(2026, 10, 3, 1, 2, 3, 0, time.UTC)
	store.now = func() time.Time { return baseNow }
	conn, err := store.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	for i, requestID := range []string{"req-journal-pending-a", "req-journal-pending-b", "req-journal-pending-c"} {
		attempt := testJournalSettlementAttempt(requestID)
		attempt.AttemptN = int64(i)
		if err := store.JournalSettlementAttemptOutputConn(ctx, conn, attempt); err != nil {
			t.Fatal(err)
		}
	}
	if err := conn.Close(); err != nil {
		t.Fatal(err)
	}
	store.now = func() time.Time { return baseNow.Add(2 * time.Minute) }
	stats, err := store.SettlementAttemptOutputJournalStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if stats.PendingRows != 3 || !stats.HasOldestPendingCreated || stats.OldestPendingAge != 2*time.Minute {
		t.Fatalf("stats=%+v, want 3 pending and 2m oldest age", stats)
	}
	if !indexExists(t, store.db, "settlement_attempt_output_journal", "idx_saoj_pending") {
		t.Fatal("missing settlement attempt output journal pending index")
	}
	if !indexExists(t, store.db, "settlement_attempt_output_journal", "idx_saoj_materialized_retention") {
		t.Fatal("missing settlement attempt output journal retention index")
	}
	if plan := explainQueryPlan(t, store.db, `
SELECT account_scope, request_id, attempt_n, provider_id
  FROM settlement_attempt_output_journal
 WHERE materialized_at_utc IS NULL
   AND poisoned_at_utc IS NULL
 ORDER BY id
 LIMIT 2`); !strings.Contains(plan, "idx_saoj_pending") {
		t.Fatalf("pending materialization query plan=%q, want idx_saoj_pending", plan)
	}
	result, err := store.MaterializePendingSettlementAttemptOutputs(ctx, 2)
	if err != nil {
		t.Fatal(err)
	}
	if result.SelectedRows != 2 || result.MaterializedRows != 2 || result.PoisonedRows != 0 {
		t.Fatalf("materialize result=%+v, want selected/materialized 2 and poison 0", result)
	}
	stats, err = store.SettlementAttemptOutputJournalStats(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if stats.PendingRows != 1 {
		t.Fatalf("pending rows after bounded materialization=%d want 1", stats.PendingRows)
	}
}

func testJournalSettlementAttempt(requestID string) SettlementAttemptOutput {
	return SettlementAttemptOutput{
		AccountScope:          "acct-a",
		RequestID:             requestID,
		AttemptN:              0,
		ProviderID:            "provider-a",
		Output:                testSettlementOutput(),
		OutputAvailable:       true,
		Usage:                 testSettlementUsage(),
		UsageSource:           UsageSourceByteEstimated,
		TerminalStateTSUnixMS: 1716768000000,
	}
}
