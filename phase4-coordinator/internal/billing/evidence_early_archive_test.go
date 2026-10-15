package billing

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"reflect"
	"testing"
)

// payoutSnapshot is everything weekly settlement decides, without the wall
// clock stamps it writes.
type payoutSnapshot struct {
	Payouts []string
	Credits []string
	Payable string
}

func snapshotSettlement(t *testing.T, db *sql.DB) payoutSnapshot {
	t.Helper()
	var out payoutSnapshot
	rows, err := db.Query(`
SELECT provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
       gross_credits, provider_credits, operator_credits, status, idempotency_key
  FROM ledger_payout_ready ORDER BY id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var provider, start, end, status, key string
		var cadence, count, gross, providerCredits, operator int64
		if err := rows.Scan(&provider, &start, &end, &cadence, &count, &gross, &providerCredits, &operator, &status, &key); err != nil {
			t.Fatal(err)
		}
		out.Payouts = append(out.Payouts, fmt.Sprintf("%s|%s|%s|%d|%d|%d|%d|%d|%s|%s", provider, start, end, cadence, count, gross, providerCredits, operator, status, key))
	}
	rows.Close()
	rows, err = db.Query(`
SELECT lrc.id, lrc.request_id, lrc.settled, COALESCE(p.idempotency_key, ''), lrc.quarantined,
       lrc.gross_credits, lrc.provider_credits
  FROM ledger_request_credits lrc
  LEFT JOIN ledger_payout_ready p ON p.id = lrc.settlement_id
 ORDER BY lrc.id`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id, settled, quarantined, gross, providerCredits int64
		var request, payout string
		if err := rows.Scan(&id, &request, &settled, &payout, &quarantined, &gross, &providerCredits); err != nil {
			t.Fatal(err)
		}
		out.Credits = append(out.Credits, fmt.Sprintf("%d|%s|%d|%s|%d|%d|%d", id, request, settled, payout, quarantined, gross, providerCredits))
	}
	rows.Close()
	var n, gross, providerCredits int64
	if err := db.QueryRow(`SELECT COUNT(*), COALESCE(SUM(gross_credits), 0), COALESCE(SUM(provider_credits), 0) FROM spec022_payable_request_credits`).Scan(&n, &gross, &providerCredits); err != nil {
		t.Fatal(err)
	}
	out.Payable = fmt.Sprintf("%d|%d|%d", n, gross, providerCredits)
	return out
}

// SPEC-022 v0.4.5 R-15.6: evidence archived before settlement never changes
// a payout. Two identical ledgers settle the same window; in one, retention
// first archives the evidence of every unsettled, payable request at its
// finality point. Payouts, the settlement link of every credit, and the
// payable sums are bit-identical.
func TestEarlyArchivedEvidenceSettlesIntoIdenticalPayouts(t *testing.T) {
	ctx := context.Background()
	archiveDir := t.TempDir()
	build := func(archive bool) (*retentionFixture, payoutSnapshot, payoutSnapshot) {
		f := newRetentionFixture(t, false)
		for _, suffix := range []string{"first", "a", "b", "c", "d"} {
			f.seed(t, suffix)
		}
		before := snapshotSettlement(t, f.store.db)
		if archive {
			report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(archiveDir, nil))
			if err != nil {
				t.Fatal(err)
			}
			if report.DeletedRequests != 4 {
				t.Fatalf("early archive deleted %d requests, want 4: %+v", report.DeletedRequests, report)
			}
			for _, suffix := range []string{"a", "b", "c", "d"} {
				if f.hotRows(t, suffix) != 0 {
					t.Fatalf("%s kept its evidence", suffix)
				}
			}
			if scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 1`) != 0 {
				t.Fatal("retention settled a credit")
			}
		}
		if err := f.store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, f.windowStart, f.windowEnd); err != nil {
			t.Fatal(err)
		}
		return f, before, snapshotSettlement(t, f.store.db)
	}
	_, hotBefore, hot := build(false)
	archived, archivedBefore, early := build(true)
	if !reflect.DeepEqual(hotBefore, archivedBefore) {
		t.Fatalf("the two ledgers differ before settlement:\n%+v\n%+v", hotBefore, archivedBefore)
	}
	if len(hot.Payouts) == 0 {
		t.Fatal("the window produced no payout")
	}
	if !reflect.DeepEqual(hot, early) {
		t.Fatalf("settlement after early archive differs:\nhot   %+v\nearly %+v", hot, early)
	}
	if hot.Payable != hotBefore.Payable {
		t.Fatalf("settlement changed the payable sums: %s -> %s", hotBefore.Payable, hot.Payable)
	}

	// Each archived credit rederives from its archive alone (R-15.7), and
	// still equals the settled ledger row.
	for _, suffix := range []string{"a", "d"} {
		id := archived.creditID(t, suffix)
		var archiveFile string
		if err := archived.store.db.QueryRow(`
SELECT a.file_name FROM settlement_evidence_archives a
  JOIN settlement_evidence_archived_credits c ON c.archive_id = a.id
 WHERE c.request_credit_id = ?`, id).Scan(&archiveFile); err != nil {
			t.Fatal(err)
		}
		result, err := RederiveArchivedCredit(filepath.Join(archiveDir, archiveFile), id)
		if err != nil || !result.Matches {
			t.Fatalf("rederive %s: %+v %v", suffix, result, err)
		}
		if result.ArchivedGrossCredits != scalar(t, archived.store.db, `SELECT gross_credits FROM ledger_request_credits WHERE id = ?`, id) {
			t.Fatalf("archived gross of %s differs from the settled ledger row", suffix)
		}
	}

	// Nightly reconcile of an unsettled, archived enforce credit against
	// request-log usage that no longer matches the receipt-bound price is
	// not a mismatch and does not quarantine it.
	f2 := newRetentionFixture(t, false)
	for _, suffix := range []string{"first", "b"} {
		f2.seed(t, suffix)
	}
	in := f2.inputs["b"]
	if _, err := f2.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil)); err != nil {
		t.Fatal(err)
	}
	if f2.hotRows(t, "b") != 0 || scalar(t, f2.store.db, `SELECT settled FROM ledger_request_credits WHERE request_id = ?`, in.RequestID) != 0 {
		t.Fatal("b was not archived unsettled")
	}
	prompt, completion := int64(1), int64(999999)
	input := HotPathInput{
		RequestID: in.RequestID, AttemptN: int(in.AttemptN), ProviderID: in.ProviderID,
		PromptTokens: &prompt, CompletionTokens: &completion,
		RateEntry:     RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000},
		MultiplierPPM: 1000000, ProviderShareBps: 10000,
	}
	expected := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, input.RateEntry, 1000000, 10000)
	tx, err := f2.store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	gross, expectedGross, exists, mismatch, err := reconcileExistingCreditTx(ctx, tx, input, expected, sqliteTimeText(f2.store.nowUTC()))
	if err != nil || !exists || mismatch || gross != expectedGross {
		_ = tx.Rollback()
		t.Fatalf("reconcile archived unsettled credit gross=%d expected=%d exists=%v mismatch=%v err=%v", gross, expectedGross, exists, mismatch, err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	if scalar(t, f2.store.db, `SELECT quarantined FROM ledger_request_credits WHERE request_id = ?`, in.RequestID) != 0 {
		t.Fatal("reconcile quarantined an archived unsettled credit")
	}
}
