package billing

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestRecoverLedgerChunkedMatchesSingleWindowAcrossBoundary(t *testing.T) {
	ctx := context.Background()
	reqChunked, chunked := newRequestAndBillingStores(t)
	in := seedRecoveryChunkEquivalenceFixture(t, reqChunked, chunked)

	reqSingle, single := newRequestAndBillingStores(t)
	seedRecoveryChunkEquivalenceFixture(t, reqSingle, single)

	if err := chunked.RecoverLedger(ctx, in); err != nil {
		t.Fatalf("chunked RecoverLedger: %v", err)
	}
	poolAttested, err := single.recoveryPoolAttestedRoutes(ctx, in)
	if err != nil {
		t.Fatalf("single-window pool attestation pre-read: %v", err)
	}
	singleStats, err := single.recoverLedgerChunk(ctx, in, poolAttested)
	if err != nil {
		t.Fatalf("single-window recover chunk: %v", err)
	}

	if got, want := recoveryLedgerSnapshot(t, chunked.db), recoveryLedgerSnapshot(t, single.db); got != want {
		t.Fatalf("chunked ledger state differs from single-window helper\ngot:\n%s\nwant:\n%s", got, want)
	}
	run := lastRecoveryRunStats(t, chunked.db)
	if run != singleStats {
		t.Fatalf("chunked run totals=%+v want single-window stats=%+v", run, singleStats)
	}
	if got := scalar(t, chunked.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE status='complete' AND run_type='nightly_reconcile'`); got != 1 {
		t.Fatalf("complete recovery rows=%d want 1", got)
	}
	if got := scalar(t, chunked.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE status='failed' AND run_type='nightly_reconcile'`); got != 0 {
		t.Fatalf("failed recovery rows=%d want 0", got)
	}
}

func seedRecoveryChunkEquivalenceFixture(t *testing.T, reqStore *requestlog.Store, store *Store) RecoverInput {
	t.Helper()
	boundary := time.Unix(3600, 0).UTC()
	scanFrom := boundary.Add(-time.Hour)
	scanTo := boundary.Add(time.Hour)

	input, row := testHotPathInput(t, store)
	row.RequestID = "chunk-straddle"
	input.RequestID = row.RequestID
	row.TSUtc = boundary.Add(-time.Second)
	input.TSUtc = row.TSUtc
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row, input); err != nil {
		t.Fatal(err)
	}

	row2 := row
	input2 := input
	row2.TSUtc = boundary.Add(time.Second)
	input2.TSUtc = row2.TSUtc
	row2.ProviderAssignedID = "assigned-b"
	input2.ProviderAssignedID = row2.ProviderAssignedID
	input2.ProviderID = "provider-b"
	input2.AttemptN = 1
	row2.Retried = 1
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, row2, input2); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE request_log SET attempt_n = NULL WHERE request_id = ?`, row.RequestID); err != nil {
		t.Fatal(err)
	}

	missingInput := input
	missingRow := row
	missingRow.RequestID = "chunk-missing-credit"
	missingInput.RequestID = missingRow.RequestID
	missingRow.TSUtc = boundary.Add(10 * time.Minute)
	missingInput.TSUtc = missingRow.TSUtc
	missingRow.ProviderAssignedID = "assigned-missing"
	missingInput.ProviderAssignedID = missingRow.ProviderAssignedID
	missingInput.ProviderID = "provider-missing"
	if err := store.WriteRequestLogWithIdentity(context.Background(), reqStore, missingRow, missingInput); err != nil {
		t.Fatal(err)
	}

	insertCreditWithRequest(t, store.db, "chunk-orphan", "provider-orphan", boundary.Add(20*time.Minute), 500)
	return RecoverInput{ScanFrom: scanFrom, ScanTo: scanTo, Source: "nightly_reconcile"}
}

func recoveryLedgerSnapshot(t *testing.T, db *sql.DB) string {
	t.Helper()
	rows, err := db.Query(`
SELECT request_id, attempt_n, provider_id, COALESCE(provider_assigned_id, ''),
       gross_credits, provider_credits, quarantined, COALESCE(quarantine_reason, ''), recovery_source
  FROM ledger_request_credits
 ORDER BY request_id, attempt_n, provider_id`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var requestID, providerID, assignedID, reason, source string
		var attemptN int
		var gross, provider int64
		var quarantined int
		if err := rows.Scan(&requestID, &attemptN, &providerID, &assignedID, &gross, &provider, &quarantined, &reason, &source); err != nil {
			t.Fatal(err)
		}
		out = append(out, fmt.Sprintf("%s|%d|%s|%s|%d|%d|%d|%s|%s", requestID, attemptN, providerID, assignedID, gross, provider, quarantined, reason, source))
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return strings.Join(out, "\n")
}

func lastRecoveryRunStats(t *testing.T, db *sql.DB) recoveryStats {
	t.Helper()
	var stats recoveryStats
	if err := db.QueryRow(`
SELECT request_log_rows_scanned, missing_credit_rows_created, orphan_credit_rows_quarantined,
       buyer_equivalent_credits, provider_gross_credits
  FROM ledger_reconciliation_runs
 WHERE run_type='nightly_reconcile' AND status='complete'
 ORDER BY id DESC LIMIT 1`).Scan(&stats.scanned, &stats.created, &stats.quarantined, &stats.buyerEquivalent, &stats.providerGross); err != nil {
		t.Fatal(err)
	}
	return stats
}
