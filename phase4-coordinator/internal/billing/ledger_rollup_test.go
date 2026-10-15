package billing

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// ledgerReaderSnapshot is every total a reader of the ledger serves for the
// fixture provider: admin summary and provider listing, provider earnings
// (rollup-served and view-served, lifetime and ranged), and the live
// earnings buckets.
type ledgerReaderSnapshot struct {
	Summary        map[string]any
	Providers      map[string]any
	Earnings       providerEarningsFigures
	EarningsView   providerEarningsFigures
	EarningsRanged providerEarningsFigures
	Buckets        earningsBuckets
	PayableGross   int64
}

func snapshotLedgerReaders(t *testing.T, f *retentionFixture, providerID string) ledgerReaderSnapshot {
	t.Helper()
	ctx := context.Background()
	h := &handler{store: f.store}
	decode := func(path string, serve func(*httptest.ResponseRecorder)) map[string]any {
		rec := httptest.NewRecorder()
		serve(rec)
		if rec.Code != 200 {
			t.Fatalf("%s: %d %s", path, rec.Code, rec.Body.String())
		}
		var out map[string]any
		if err := json.Unmarshal(rec.Body.Bytes(), &out); err != nil {
			t.Fatal(err)
		}
		return out
	}
	var snap ledgerReaderSnapshot
	snap.Summary = decode("summary", func(rec *httptest.ResponseRecorder) {
		h.summary(rec, httptest.NewRequest("GET", "/admin/ledger/summary", nil))
	})
	delete(snap.Summary, "settlement_verdict_counters")
	snap.Providers = decode("providers", func(rec *httptest.ResponseRecorder) {
		h.providers(rec, httptest.NewRequest("GET", "/admin/ledger/providers", nil))
	})
	if items, ok := snap.Providers["providers"].([]any); ok {
		for _, item := range items {
			if m, ok := item.(map[string]any); ok {
				delete(m, "settlement_receipts")
			}
		}
	}
	now := f.store.nowUTC()
	win := earningsWindows{week: currentMondayUTC(now), today: time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, time.UTC)}
	if _, err := f.store.RefreshProviderEarningsRollup(ctx, 100000); err != nil {
		t.Fatal(err)
	}
	var err error
	if snap.Earnings, err = h.providerEarningsFigures(ctx, providerID, win); err != nil {
		t.Fatal(err)
	}
	if snap.EarningsView, err = h.providerEarningsFiguresFromView(ctx, providerID, win); err != nil {
		t.Fatal(err)
	}
	ranged := win
	ranged.hasRange = true
	ranged.from = time.Date(f.windowStart.Year(), f.windowStart.Month(), f.windowStart.Day(), 0, 0, 0, 0, time.UTC)
	ranged.to = ranged.from.AddDate(0, 0, 14)
	if snap.EarningsRanged, err = h.providerEarningsFiguresFromView(ctx, providerID, ranged); err != nil {
		t.Fatal(err)
	}
	if snap.Buckets, err = computeEarningsBuckets(ctx, f.store.reader(), providerID, "", ""); err != nil {
		t.Fatal(err)
	}
	snap.PayableGross = scalar(t, f.store.db, `SELECT COALESCE(SUM(gross_credits), 0) FROM spec022_payable_request_credits`) +
		scalar(t, f.store.db, `SELECT COALESCE(SUM(gross_credits), 0) FROM ledger_settled_rollups`)
	return snap
}

func ledgerRollupTestOptions(dir string) LedgerRollupOptions {
	return LedgerRollupOptions{Enabled: true, MinSettlementCycles: 5, CadenceDays: 7, ArchiveDir: dir, BatchSize: 2, MaxRequestsPerArchive: 100}
}

// SPEC-022 R-15.11 / SPEC-005 §7.8: settled detail rows roll up into
// per-payout aggregates and every reader serves the same totals; the payout
// still revalidates and claims; recovery never re-credits a rolled request.
func TestLedgerRollupKeepsEveryTotalAndPayout(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	for _, suffix := range []string{"first", "a", "b", "c"} {
		f.seed(t, suffix)
	}
	f.settle(t)
	providerID := f.base.ProviderID
	if _, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil)); err != nil {
		t.Fatal(err)
	}
	for _, suffix := range []string{"a", "b", "c"} {
		if f.hotRows(t, suffix) != 0 {
			t.Fatalf("%s evidence not archived", suffix)
		}
	}
	dir := t.TempDir()
	// Two completed windows after the payout window: not old enough.
	report, err := f.store.RunLedgerRollup(ctx, ledgerRollupTestOptions(dir))
	if err != nil || report.RolledRequests != 0 {
		t.Fatalf("rollup before five completed windows: %+v %v", report, err)
	}
	f.addLaterWindows(t, 6)
	before := snapshotLedgerReaders(t, f, providerID)
	payoutID := scalar(t, f.store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, providerID)
	payoutGross := scalar(t, f.store.db, `SELECT gross_credits FROM ledger_payout_ready WHERE id = ?`, payoutID)

	report, err = f.store.RunLedgerRollup(ctx, ledgerRollupTestOptions(dir))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != ledgerRollupStatusRolledUp || report.RolledRequests != 3 || report.RolledCredits != 3 || report.KeptRequests != 1 {
		t.Fatalf("rollup report=%+v", report)
	}
	for _, suffix := range []string{"a", "b", "c"} {
		in := f.inputs[suffix]
		for _, table := range []string{"ledger_request_credits", "ledger_operator_credits", "ledger_provider_identity_snapshots"} {
			if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM `+table+` WHERE request_id = ?`, in.RequestID); n != 0 {
				t.Fatalf("%s keeps %d %s rows", suffix, n, table)
			}
		}
		if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archived_credits WHERE request_id = ?`, in.RequestID); n != 0 {
			t.Fatalf("%s keeps its tombstone", suffix)
		}
		if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archived_finality WHERE request_id = ?`, in.RequestID); n == 0 {
			t.Fatalf("%s lost its frozen settlement finality", suffix)
		}
	}
	if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, f.inputs["first"].RequestID); n != 1 {
		t.Fatal("the request holding the first verified verdict was rolled up")
	}
	if got := scalar(t, f.store.db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != billingCompatContractLedgerRollup {
		t.Fatalf("floor after rollup=%d want %d", got, billingCompatContractLedgerRollup)
	}
	after := snapshotLedgerReaders(t, f, providerID)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("readers changed across the rollup:\nbefore %+v\nafter  %+v", before, after)
	}
	// The archive verifies from the file alone and holds the detail rows.
	var file string
	if err := f.store.db.QueryRow(`SELECT file_name FROM ledger_rollup_archives WHERE status = 'deleted'`).Scan(&file); err != nil {
		t.Fatal(err)
	}
	manifest, err := VerifyLedgerRollupArchiveFile(filepath.Join(dir, file))
	if err != nil || manifest.RowCounts["ledger_request_credits"] != 3 {
		t.Fatalf("rollup archive verify err=%v counts=%v", err, manifest.RowCounts)
	}
	// A second run rolls nothing up twice.
	report, err = f.store.RunLedgerRollup(ctx, ledgerRollupTestOptions(dir))
	if err != nil || report.RolledRequests != 0 {
		t.Fatalf("second rollup=%+v %v", report, err)
	}
	if again := snapshotLedgerReaders(t, f, providerID); !reflect.DeepEqual(before, again) {
		t.Fatalf("readers changed on the second run:\nbefore %+v\nafter  %+v", before, again)
	}
	// The ready payout still revalidates against its rolled-up credits.
	claimed, err := f.store.ClaimPayoutReady(ctx, payoutID, payoutGross, "ext-1", "USDC")
	if err != nil || !claimed {
		t.Fatalf("claim after rollup: claimed=%v err=%v status=%s", claimed, err, scalarText(t, f.store.db, `SELECT status FROM ledger_payout_ready WHERE id = ?`, payoutID))
	}
	if status := scalarText(t, f.store.db, `SELECT status FROM ledger_payout_ready WHERE id = ?`, payoutID); status != "consumed" {
		t.Fatalf("payout status after claim=%s", status)
	}
	// Rollup rows are permanent and only grow.
	if _, err := f.store.db.Exec(`DELETE FROM ledger_settled_rollups`); err == nil {
		t.Fatal("rollup rows were deletable")
	}
	if _, err := f.store.db.Exec(`UPDATE ledger_settled_rollups SET provider_credits = provider_credits - 1`); err == nil {
		t.Fatal("rollup rows could shrink")
	}
}

// A request whose detail rows changed after export is not rolled up.
func TestLedgerRollupKeepsRequestChangedAfterExport(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	for _, suffix := range []string{"first", "a", "b"} {
		f.seed(t, suffix)
	}
	f.settle(t)
	if _, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil)); err != nil {
		t.Fatal(err)
	}
	f.addLaterWindows(t, 6)
	dir := t.TempDir()
	opts, err := ledgerRollupTestOptions(dir).normalized()
	if err != nil {
		t.Fatal(err)
	}
	cutoff, ok, err := f.store.ledgerRollupCutoff(ctx, opts)
	if err != nil || !ok {
		t.Fatalf("cutoff %v %v", ok, err)
	}
	rec, _, err := f.store.exportLedgerRollupArchive(ctx, opts, cutoff, f.store.nowUTC().Add(time.Hour))
	if err != nil || rec == nil {
		t.Fatalf("export: %v %v", rec, err)
	}
	// After export, b's operator credit row changes: b stays hot.
	if res, err := f.store.db.Exec(`UPDATE ledger_operator_credits SET created_at_utc = '2026-01-01T00:00:00.000000000Z' WHERE request_id = ?`, f.inputs["b"].RequestID); err != nil {
		t.Fatal(err)
	} else if n, _ := res.RowsAffected(); n != 1 {
		t.Fatalf("changed %d operator credit rows", n)
	}
	report, err := f.store.RunLedgerRollup(ctx, opts)
	if err != nil {
		t.Fatal(err)
	}
	// The stale archive rolls up only a; b is held, re-checked, and rolled up
	// from a fresh archive that holds its rows as they now are.
	if report.RolledRequests != 2 || report.Archives != 2 {
		t.Fatalf("report=%+v", report)
	}
	if got := scalar(t, f.store.db, `SELECT COALESCE(SUM(credit_count), 0) FROM ledger_settled_rollups`); got != 2 {
		t.Fatalf("rollup counted %d credits, want 2 (each once)", got)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_rollup_holds`); got != 0 {
		t.Fatalf("%d holds left", got)
	}
}

// A request skipped for a reason that can clear is held and rolled up by a
// later run once it clears; the cursor moving past its payout never strands
// it. A request whose request_log rows remain is one such reason.
func TestLedgerRollupRetriesHeldRequests(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	for _, suffix := range []string{"first", "a", "b"} {
		f.seed(t, suffix)
	}
	f.settle(t)
	if _, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil)); err != nil {
		t.Fatal(err)
	}
	f.addLaterWindows(t, 6)
	in := f.inputs["b"]
	prompt, completion := int64(10), int64(20)
	if err := f.reqStore.Insert(ctx, requestlog.Row{TSUtc: f.windowStart.Add(time.Hour), RequestID: in.RequestID, AccountID: "acct", Model: "m", Status: 200,
		ProviderAssignedID: "pa", PromptTokens: &prompt, CompletionTokens: &completion, BuyerIP: "127.0.0.1"}); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	report, err := f.store.RunLedgerRollup(ctx, ledgerRollupTestOptions(dir))
	if err != nil || report.RolledRequests != 1 {
		t.Fatalf("first run=%+v err=%v", report, err)
	}
	if reason := scalarText(t, f.store.db, `SELECT reason FROM ledger_rollup_holds WHERE request_id = ?`, in.RequestID); reason != "request_log_present" {
		t.Fatalf("hold reason=%q", reason)
	}
	if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, in.RequestID); n != 1 {
		t.Fatal("a request with request_log rows was rolled up")
	}
	// The first verified request is kept hot for good: no hold.
	if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_rollup_holds WHERE request_id = ?`, f.inputs["first"].RequestID); n != 0 {
		t.Fatal("a request kept hot for good was held")
	}
	// Its request_log rows leave through the fold; the next run, with the
	// cursor already past the payout, rolls it up from the holds table.
	if _, err := f.store.FoldWholesaleRequestLog(ctx, f.store.nowUTC()); err != nil {
		t.Fatal(err)
	}
	report, err = f.store.RunLedgerRollup(ctx, ledgerRollupTestOptions(dir))
	if err != nil || report.RolledRequests != 1 {
		t.Fatalf("second run=%+v err=%v", report, err)
	}
	if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, in.RequestID); n != 0 {
		t.Fatal("held request not rolled up after it cleared")
	}
	if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_rollup_holds`); n != 0 {
		t.Fatalf("%d holds left", n)
	}
}

// LedgerRollupOptionsFromConfig keeps a payout hot while request_log may
// still hold its window.
func TestLedgerRollupCutoffRespectsRequestLogRetention(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.settle(t)
	f.addLaterWindows(t, 6)
	opts := ledgerRollupTestOptions(t.TempDir())
	opts.RequestLogRetention = 365 * 24 * time.Hour
	cutoff, ok, err := f.store.ledgerRollupCutoff(ctx, opts)
	if err != nil || !ok || !cutoff.Before(f.windowStart) {
		t.Fatalf("cutoff=%s ok=%v err=%v; want before the settled window", cutoff, ok, err)
	}
}

// The whole money lifecycle across slices 7 and 8: two identical ledgers,
// one kept hot and one whose evidence is archived before settlement and
// whose detail rows are rolled up after it, settle into the same payouts,
// serve the same totals, and claim the same payout.
func TestSettlementLifecycleAcrossEarlyArchiveAndRollupMatchesHotLedger(t *testing.T) {
	ctx := context.Background()
	type outcome struct {
		Payouts []string
		Readers ledgerReaderSnapshot
		Claimed bool
	}
	run := func(footprint bool) outcome {
		f := newRetentionFixture(t, false)
		for _, suffix := range []string{"first", "a", "b", "c", "d"} {
			f.seed(t, suffix)
		}
		if footprint {
			report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil))
			if err != nil || report.DeletedRequests != 4 {
				t.Fatalf("early archive: %+v %v", report, err)
			}
		}
		f.settle(t)
		f.addLaterWindows(t, 6)
		if footprint {
			report, err := f.store.RunLedgerRollup(ctx, ledgerRollupTestOptions(t.TempDir()))
			if err != nil || report.RolledRequests != 4 {
				t.Fatalf("rollup: %+v %v", report, err)
			}
			if n := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_request_credits`); n != 1 {
				t.Fatalf("%d ledger credits left hot, want 1", n)
			}
		}
		var out outcome
		out.Payouts = snapshotSettlement(t, f.store.db).Payouts
		out.Readers = snapshotLedgerReaders(t, f, f.base.ProviderID)
		payoutID := scalar(t, f.store.db, `SELECT id FROM ledger_payout_ready`)
		gross := scalar(t, f.store.db, `SELECT gross_credits FROM ledger_payout_ready WHERE id = ?`, payoutID)
		claimed, err := f.store.ClaimPayoutReady(ctx, payoutID, gross, "ext", "USDC")
		if err != nil {
			t.Fatal(err)
		}
		out.Claimed = claimed
		return out
	}
	hot, slim := run(false), run(true)
	if !hot.Claimed || !reflect.DeepEqual(hot, slim) {
		t.Fatalf("lifecycle differs:\nhot  %+v\nslim %+v", hot, slim)
	}
}

// A payout larger than one archive is rolled up across archives through the
// partial-payout cursor, each request exactly once.
func TestLedgerRollupSplitsALargePayoutAcrossArchives(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	for _, suffix := range []string{"first", "a", "b", "c"} {
		f.seed(t, suffix)
	}
	f.settle(t)
	if _, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil)); err != nil {
		t.Fatal(err)
	}
	f.addLaterWindows(t, 6)
	before := snapshotLedgerReaders(t, f, f.base.ProviderID)
	opts := ledgerRollupTestOptions(t.TempDir())
	opts.MaxRequestsPerArchive = 1
	report, err := f.store.RunLedgerRollup(ctx, opts)
	if err != nil || report.RolledRequests != 3 || report.Archives < 3 {
		t.Fatalf("rollup report=%+v err=%v", report, err)
	}
	if got := scalar(t, f.store.db, `SELECT COALESCE(SUM(credit_count), 0) FROM ledger_settled_rollups`); got != 3 {
		t.Fatalf("rolled credits=%d want 3", got)
	}
	if after := snapshotLedgerReaders(t, f, f.base.ProviderID); !reflect.DeepEqual(before, after) {
		t.Fatalf("readers changed:\nbefore %+v\nafter  %+v", before, after)
	}
}
