package billing

import (
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

// retentionFixture is a billing store holding settled SPEC-022 enforce
// requests whose settlement window is two completed cycles old.
type retentionFixture struct {
	store       *Store
	base        SettlementVerifyInput
	windowStart time.Time
	windowEnd   time.Time
	journalDB   *sql.DB
	inputs      map[string]SettlementVerifyInput
}

func newRetentionFixture(t *testing.T, withJournal bool) *retentionFixture {
	t.Helper()
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	base := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	base.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	f := &retentionFixture{store: store, base: base, inputs: map[string]SettlementVerifyInput{}}
	f.windowStart, f.windowEnd = settlementWindowForInput(base)
	now := f.windowEnd.AddDate(0, 0, 40)
	store.now = func() time.Time { return now }
	if withJournal {
		path := filepath.Join(t.TempDir(), "coordinator.db.route-snapshots")
		journalDB, err := sql.Open("sqlite", sqliteutil.WithManualWALCheckpointPragmas(path))
		if err != nil {
			t.Fatal(err)
		}
		journalDB.SetMaxOpenConns(1)
		t.Cleanup(func() { _ = journalDB.Close() })
		store.SetRouteSnapshotJournalDB(journalDB)
		if err := store.InitRouteSnapshotJournal(context.Background()); err != nil {
			t.Fatal(err)
		}
		f.journalDB = journalDB
	}
	return f
}

// seed writes one enforce request with a verified receipt and a
// receipt-bound credit. Seeding order is verdict id order, so the first
// seeded request of a provider holds its earliest verified verdict.
func (f *retentionFixture) seed(t *testing.T, suffix string) SettlementVerifyInput {
	t.Helper()
	input := f.base
	input.RequestID = f.base.RequestID + "-" + suffix
	input.RouteSnapshot.RequestID = input.RequestID
	seedSettlementReceiptEvidence(t, f.store, input)
	insertSPEC022ReceiptBoundLedgerCredit(t, f.store.db, input, 0)
	markSPEC022ReceiptVerified(t, f.store.db, input)
	f.inputs[suffix] = input
	return input
}

// settle runs the weekly settlement for the fixture window and records two
// later completed windows, so the window is two completed cycles old.
func (f *retentionFixture) settle(t *testing.T) {
	t.Helper()
	if err := f.store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, f.windowStart, f.windowEnd); err != nil {
		t.Fatal(err)
	}
	f.addLaterWindows(t, 2)
}

func (f *retentionFixture) addLaterWindows(t *testing.T, n int) {
	t.Helper()
	for i := 1; i <= n; i++ {
		end := f.windowEnd.AddDate(0, 0, 7*i)
		if _, err := f.store.db.Exec(`
INSERT OR IGNORE INTO ledger_settlement_windows (window_start_utc, window_end_utc, cadence_days, completed_at_utc)
VALUES (?, ?, 7, ?)`, sqliteTimeText(end.AddDate(0, 0, -7)), sqliteTimeText(end), sqliteTimeText(end)); err != nil {
			t.Fatal(err)
		}
	}
}

func (f *retentionFixture) creditID(t *testing.T, suffix string) int64 {
	t.Helper()
	in := f.inputs[suffix]
	return scalar(t, f.store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, in.RequestID)
}

func (f *retentionFixture) hotRows(t *testing.T, suffix string) int64 {
	t.Helper()
	in := f.inputs[suffix]
	return scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_route_snapshots WHERE request_id = ?`, in.RequestID) +
		scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE request_id = ?`, in.RequestID) +
		scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_attempt_outputs WHERE request_id = ?`, in.RequestID)
}

func (f *retentionFixture) addDrainedOutbox(t *testing.T, suffix string, drained, poisoned bool) {
	t.Helper()
	in := f.inputs[suffix]
	verdictID := scalar(t, f.store.db, `SELECT id FROM settlement_receipt_verdicts WHERE request_id = ?`, in.RequestID)
	var drainedAt, poisonedAt any
	if drained {
		drainedAt = sqliteTimeText(f.windowEnd)
	}
	if poisoned {
		poisonedAt = sqliteTimeText(f.windowEnd)
	}
	if _, err := f.store.db.Exec(`
INSERT INTO settlement_receipt_audit_outbox (
    settlement_receipt_verdict_id, event_type, account_scope_hash, request_id, attempt_n,
    provider_id, attempted_received_at_unix_ms, idempotency_status, created_at_utc,
    drained_at_utc, poisoned_at_utc
) VALUES (?, 'settlement_receipt_verdict', ?, ?, ?, ?, ?, 'first_terminal', ?, ?, ?)`,
		verdictID, SettlementAccountScopeHash(in.AccountScope), in.RequestID, in.AttemptN, in.ProviderID,
		in.ReceiptReceivedUnixMS, sqliteTimeText(f.windowStart), drainedAt, poisonedAt); err != nil {
		t.Fatal(err)
	}
}

type recordingVerifier struct {
	calls []string
	err   error
	hook  func()
}

func (r *recordingVerifier) verify(_ context.Context, path, sha string) error {
	r.calls = append(r.calls, filepath.Base(path)+"|"+sha)
	if r.hook != nil {
		r.hook()
	}
	return r.err
}

// holdVerifier is a configured off-host check that never confirms: the run
// exports and verifies its archive locally and deletes nothing.
func holdVerifier() EvidenceArchiveOffhostVerifier {
	return (&recordingVerifier{err: errors.New("off-host copy not present yet")}).verify
}

func retentionTestOptions(dir string, verifier EvidenceArchiveOffhostVerifier) EvidenceRetentionOptions {
	return EvidenceRetentionOptions{
		Enabled:                   true,
		ArchiveDir:                dir,
		MinSettlementCycles:       2,
		CadenceDays:               7,
		ReconcileHorizon:          8 * 24 * time.Hour,
		BatchSize:                 1,
		MaxRequestsPerRun:         100,
		MaxScanRowsPerRun:         10000,
		IncrementalVacuumPages:    16,
		IncrementalVacuumMaxSteps: 4,
		OffhostVerifier:           verifier,
	}
}

func TestEvidenceRetentionArchivesVerifiesAndDeletesSettledEvidence(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, true)
	f.seed(t, "first")
	b := f.seed(t, "b")
	f.seed(t, "c")
	f.addDrainedOutbox(t, "b", true, false)
	if n, err := f.store.MirrorPendingRouteSnapshots(ctx, 100); err != nil || n != 3 {
		t.Fatalf("mirror route journal n=%d err=%v", n, err)
	}
	f.settle(t)
	payableBefore := scalar(t, f.store.db, `SELECT SUM(provider_credits) FROM spec022_payable_request_credits`)
	payoutID := scalar(t, f.store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, b.ProviderID)
	payoutGross := scalar(t, f.store.db, `SELECT gross_credits FROM ledger_payout_ready WHERE id = ?`, payoutID)
	if payableBefore <= 0 {
		t.Fatalf("payable before retention=%d", payableBefore)
	}

	dir := t.TempDir()
	verifier := &recordingVerifier{}
	dry, err := f.store.DryRunEvidenceRetention(ctx, retentionTestOptions(dir, verifier.verify))
	if err != nil {
		t.Fatal(err)
	}
	if dry.Status != EvidenceRetentionStatusDryRun || dry.EligibleRequests != 2 {
		t.Fatalf("dry run=%+v", dry)
	}
	if dry.SkippedRequests[retentionSkipFirstVerified] != 1 {
		t.Fatalf("dry run skipped=%v want the provider's first verified request kept", dry.SkippedRequests)
	}
	for _, table := range []string{"settlement_route_snapshots", "settlement_receipt_verdicts", "settlement_attempt_outputs"} {
		if st := dry.Tables[table]; st.Rows != 2 || st.PayloadBytes <= 0 {
			t.Fatalf("dry run %s=%+v", table, st)
		}
	}
	if st := dry.Tables["settlement_receipt_audit_outbox"]; st.Rows != 1 {
		t.Fatalf("dry run outbox=%+v", st)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archives`); got != 0 {
		t.Fatalf("dry run wrote archives=%d", got)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("dry run wrote files: %v", entries)
	}

	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, verifier.verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || report.DeletedRequests != 2 {
		t.Fatalf("run report=%+v", report)
	}
	if len(verifier.calls) != 1 || verifier.calls[0] != report.ArchiveFile+"|"+report.ArchiveSHA256 {
		t.Fatalf("off-host verifier calls=%v report=%+v", verifier.calls, report)
	}
	if f.hotRows(t, "first") != 3 || f.hotRows(t, "b") != 0 || f.hotRows(t, "c") != 0 {
		t.Fatalf("hot rows first=%d b=%d c=%d", f.hotRows(t, "first"), f.hotRows(t, "b"), f.hotRows(t, "c"))
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox`); got != 0 {
		t.Fatalf("drained outbox rows=%d want 0", got)
	}
	if got := scalar(t, f.journalDB, `SELECT COUNT(*) FROM settlement_route_snapshot_journal`); got != 1 {
		t.Fatalf("route journal rows=%d want 1 (first request only)", got)
	}
	if report.RouteJournalDeletedRows != 2 {
		t.Fatalf("route journal deleted=%d want 2", report.RouteJournalDeletedRows)
	}
	// The journal copies are archived losslessly before they are deleted.
	manifest, err := readEvidenceArchiveManifest(filepath.Join(dir, report.ArchiveFile))
	if err != nil {
		t.Fatal(err)
	}
	if got := manifest.RowCounts[evidenceRetentionJournalTable]; got != 2 {
		t.Fatalf("archived journal rows=%d want 2", got)
	}
	journalColumns := scalar(t, f.journalDB, `SELECT COUNT(*) FROM pragma_table_info('settlement_route_snapshot_journal')`)
	err = streamEvidenceArchive(filepath.Join(dir, report.ArchiveFile), manifest, func(req archivedRequest) error {
		for _, row := range req.Rows[evidenceRetentionJournalTable] {
			if int64(len(row)) != journalColumns {
				t.Errorf("archived journal row has %d columns, table has %d", len(row), journalColumns)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// The money record stays hot and unchanged.
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE settled = 1`); got != 3 {
		t.Fatalf("settled credits=%d want 3", got)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_operator_credits`); got != 3 {
		t.Fatalf("operator credits=%d want 3", got)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archived_credits WHERE spec022_verified = 1`); got != 2 {
		t.Fatalf("verified tombstones=%d want 2", got)
	}
	if got := scalar(t, f.store.db, `SELECT verdict_count FROM settlement_evidence_archived_verdict_counts WHERE provider_id = ? AND settlement_outcome = 'verified' AND receipt_result = 'valid'`, b.ProviderID); got != 2 {
		t.Fatalf("archived verdict count=%d want 2", got)
	}
	if got := scalar(t, f.store.db, `SELECT SUM(provider_credits) FROM spec022_payable_request_credits`); got != payableBefore {
		t.Fatalf("payable after retention=%d want %d", got, payableBefore)
	}
	if got := scalar(t, f.store.db, `SELECT status = 'deleted' FROM settlement_evidence_archives WHERE id = ?`, report.ArchiveID); got != 1 {
		t.Fatal("archive row not marked deleted")
	}
	if _, err := os.Stat(filepath.Join(dir, report.ArchiveFile+evidenceArchiveManifestSuffix)); err != nil {
		t.Fatalf("manifest missing: %v", err)
	}
	if len(report.Vacuum) != 2 || report.Vacuum[0].AutoVacuumMode == "" {
		t.Fatalf("vacuum report=%+v", report.Vacuum)
	}
	// Payout revalidation still sees every source credit as payable.
	claimed, err := f.store.ClaimPayoutReady(ctx, payoutID, payoutGross, "external-after-retention", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if !claimed {
		t.Fatal("payout claim failed revalidation after retention")
	}
	// A second run finds nothing new and deletes nothing.
	again, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, verifier.verify))
	if err != nil {
		t.Fatal(err)
	}
	if again.Status != EvidenceRetentionStatusNothingEligible || again.DeletedRequests != 0 {
		t.Fatalf("second run=%+v", again)
	}
	if f.hotRows(t, "first") != 3 {
		t.Fatal("second run touched the first verified request")
	}
}

// With no off-host command the locally re-read, row-for-row verified archive
// is the whole precondition: the run deletes.
func TestEvidenceRetentionDeletesWithoutOffhostCommand(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || report.DeletedRequests != 1 || f.hotRows(t, "b") != 0 {
		t.Fatalf("no-command run=%+v", report)
	}
	if report.ArchiveBytes <= 0 || report.ArchiveFreeBytes <= 0 || report.ArchiveDiskBytes < report.ArchiveFreeBytes {
		t.Fatalf("archive disk accounting missing: %+v", report)
	}
	if f.hotRows(t, "first") != 3 {
		t.Fatal("run touched the first verified request")
	}
}

// A configured off-host command is an extra check: while it fails nothing is
// deleted and the archive is resumed, never duplicated.
func TestEvidenceRetentionRefusesDeletionWhileOffhostCommandFails(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	dir := t.TempDir()

	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, holdVerifier()))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusOffhostUnverified || report.DeletedRequests != 0 {
		t.Fatalf("first failing-verifier run=%+v", report)
	}
	failing := &recordingVerifier{err: errors.New("checksum not found off host")}
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, failing.verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusOffhostUnverified || !report.ResumedArchive || report.DeletedRequests != 0 {
		t.Fatalf("failing-verifier run=%+v", report)
	}
	if f.hotRows(t, "b") != 3 {
		t.Fatal("evidence deleted without off-host confirmation")
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archives`); got != 1 {
		t.Fatalf("archives=%d want one resumed archive, never a duplicate", got)
	}
	ok := &recordingVerifier{}
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, ok.verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || report.DeletedRequests != 1 || f.hotRows(t, "b") != 0 {
		t.Fatalf("confirmed run=%+v hot=%d", report, f.hotRows(t, "b"))
	}
}

// SPEC-022 R-15.9: a retention-capable coordinator records billing contract
// 4 at open and with every deletion, so a pre-retention (contract 3)
// coordinator refuses the database instead of dropping archived credits from
// the payable view.
func TestEvidenceRetentionRaisesRollbackFloor(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	floor := func() int64 {
		return scalar(t, f.store.db, `SELECT contract FROM billing_compat_floor WHERE id = 1`)
	}
	if got := floor(); got != billingCompatContractEvidenceRetention {
		t.Fatalf("floor at open=%d want %d", got, billingCompatContractEvidenceRetention)
	}
	if billingCompatContractRelayBlind >= billingCompatContractEvidenceRetention {
		t.Fatal("a pre-retention contract would accept the retention floor")
	}
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	// Even with the row lowered by hand, the deletion commits with floor 4.
	if _, err := f.store.db.Exec(`UPDATE billing_compat_floor SET contract = ?`, billingCompatContractRelayBlind); err != nil {
		t.Fatal(err)
	}
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), (&recordingVerifier{}).verify))
	if err != nil || report.DeletedRequests != 1 {
		t.Fatalf("run=%+v err=%v", report, err)
	}
	if got := floor(); got != billingCompatContractEvidenceRetention {
		t.Fatalf("floor after deletion=%d want %d", got, billingCompatContractEvidenceRetention)
	}
	if _, err := NewStore(f.store.db); err != nil {
		t.Fatalf("retention-capable coordinator refused its own floor: %v", err)
	}
}

func TestEvidenceRetentionRefusesDeletionWhenArchiveChecksumFails(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	dir := t.TempDir()
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, holdVerifier()))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, report.ArchiveFile)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)/2] ^= 0xff
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	ok := &recordingVerifier{}
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, ok.verify))
	if !errors.Is(err, ErrEvidenceArchiveInvalid) {
		t.Fatalf("corrupt archive err=%v", err)
	}
	if report.Status != EvidenceRetentionStatusArchiveInvalid || len(ok.calls) != 0 {
		t.Fatalf("corrupt archive report=%+v verifier calls=%v", report, ok.calls)
	}
	if f.hotRows(t, "b") != 3 {
		t.Fatal("evidence deleted against a corrupt archive")
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archives WHERE status = 'failed'`); got != 1 {
		t.Fatalf("failed archives=%d want 1", got)
	}
	// The next run writes a fresh archive and deletes against it.
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, ok.verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || report.DeletedRequests != 1 {
		t.Fatalf("fresh archive run=%+v", report)
	}
}

func TestEvidenceArchiveVerificationRejectsTampering(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	dir := t.TempDir()
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, holdVerifier()))
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, report.ArchiveFile)
	manifest, err := readEvidenceArchiveManifest(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := verifyEvidenceArchive(path, manifest); err != nil {
		t.Fatalf("intact archive failed verification: %v", err)
	}
	for name, mutate := range map[string]func(m *EvidenceArchiveManifest){
		"sha256":    func(m *EvidenceArchiveManifest) { m.SHA256 = strings.Repeat("0", 64) },
		"size":      func(m *EvidenceArchiveManifest) { m.SizeBytes++ },
		"row_count": func(m *EvidenceArchiveManifest) { m.RowCounts["settlement_route_snapshots"]++ },
		"requests":  func(m *EvidenceArchiveManifest) { m.RequestCount++ },
		"format":    func(m *EvidenceArchiveManifest) { m.Format = "other" },
	} {
		t.Run(name, func(t *testing.T) {
			m := manifest
			m.RowCounts = map[string]int64{}
			for k, v := range manifest.RowCounts {
				m.RowCounts[k] = v
			}
			mutate(&m)
			if _, err := verifyEvidenceArchive(path, m); !errors.Is(err, ErrEvidenceArchiveInvalid) {
				t.Fatalf("tampered %s err=%v", name, err)
			}
		})
	}
	if err := os.WriteFile(path, append(mustReadFile(t, path), 'x'), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := verifyEvidenceArchive(path, manifest); !errors.Is(err, ErrEvidenceArchiveInvalid) {
		t.Fatalf("appended bytes err=%v", err)
	}
}

// The delete pass re-reads the archive as a stream and keeps no verified
// rows in memory, so every re-read request must match the digest of the
// verified pass: an archive rewritten after verification deletes nothing,
// even before its whole-file checksum is reached.
func TestEvidenceRetentionRefusesArchiveChangedAfterVerification(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	b := f.seed(t, "b")
	f.settle(t)
	dir := t.TempDir()
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, holdVerifier()))
	if err != nil || report.Status != EvidenceRetentionStatusOffhostUnverified {
		t.Fatalf("export run=%+v err=%v", report, err)
	}
	path := filepath.Join(dir, report.ArchiveFile)
	verifier := &recordingVerifier{hook: func() {
		in, err := os.Open(path)
		if err != nil {
			t.Error(err)
			return
		}
		zr, err := gzip.NewReader(in)
		if err != nil {
			t.Error(err)
			return
		}
		plain, err := io.ReadAll(zr)
		_ = in.Close()
		if err != nil {
			t.Error(err)
			return
		}
		changed := strings.Replace(string(plain), b.RequestID, b.RequestID+"x", -1)
		var out bytes.Buffer
		zw := gzip.NewWriter(&out)
		_, _ = zw.Write([]byte(changed))
		_ = zw.Close()
		if err := os.WriteFile(path, out.Bytes(), 0o600); err != nil {
			t.Error(err)
		}
	}}
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, verifier.verify))
	if !errors.Is(err, ErrEvidenceArchiveInvalid) || report.Status != EvidenceRetentionStatusArchiveInvalid || report.DeletedRequests != 0 {
		t.Fatalf("changed archive err=%v report=%+v", err, report)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archives WHERE status = 'failed'`); got != 1 {
		t.Fatalf("failed archives=%d want 1", got)
	}
	if f.hotRows(t, "b") != 3 {
		t.Fatal("evidence deleted against an archive changed after verification")
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archived_credits`); got != 0 {
		t.Fatalf("tombstones=%d want 0", got)
	}
}

func mustReadFile(t *testing.T, path string) []byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestEvidenceRetentionDeletesOnlyArchivedRowsInBoundedBatches(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	b := f.seed(t, "b")
	f.seed(t, "c")
	f.seed(t, "d")
	f.settle(t)
	dir := t.TempDir()
	// Between export and deletion a new evidence row appears for request b:
	// it is not in the archive, so b must stay hot in full.
	verifier := &recordingVerifier{hook: func() {
		if _, err := f.store.db.Exec(`
INSERT INTO settlement_receipt_audit_outbox (
    settlement_receipt_verdict_id, event_type, account_scope_hash, request_id, attempt_n,
    provider_id, attempted_received_at_unix_ms, idempotency_status, created_at_utc, drained_at_utc
) SELECT id, 'settlement_receipt_verdict', account_scope_hash, request_id, attempt_n, provider_id,
         received_at_unix_ms, 'first_terminal', created_at_utc, created_at_utc
    FROM settlement_receipt_verdicts WHERE request_id = ?`, b.RequestID); err != nil {
			t.Error(err)
		}
	}}
	opts := retentionTestOptions(dir, verifier.verify)
	opts.BatchSize = 2
	report, err := f.store.RunEvidenceRetention(ctx, opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.DeletedRequests != 2 || report.SkippedRequests[retentionSkipHotRowNotArchived] != 1 {
		t.Fatalf("report=%+v", report)
	}
	if f.hotRows(t, "b") != 3 || f.hotRows(t, "c") != 0 || f.hotRows(t, "d") != 0 {
		t.Fatalf("hot rows b=%d c=%d d=%d", f.hotRows(t, "b"), f.hotRows(t, "c"), f.hotRows(t, "d"))
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archived_credits WHERE request_id = ?`, b.RequestID); got != 0 {
		t.Fatalf("skipped request tombstones=%d want 0", got)
	}
	if got := report.Tables["settlement_route_snapshots"].DeletedRows; got != 2 {
		t.Fatalf("deleted route snapshots=%d want 2", got)
	}
}

// A row whose id is archived but whose content changed after export is not
// deleted: the archive would hold the earlier contents.
func TestEvidenceRetentionRefusesRowChangedAfterExport(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	b := f.seed(t, "b")
	f.seed(t, "c")
	f.settle(t)
	verifier := &recordingVerifier{hook: func() {
		if _, err := f.store.db.Exec(`UPDATE settlement_receipt_verdicts SET reason = reason || '-changed' WHERE request_id = ?`, b.RequestID); err != nil {
			t.Error(err)
		}
	}}
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), verifier.verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.DeletedRequests != 1 || report.SkippedRequests[retentionSkipHotRowChanged] != 1 {
		t.Fatalf("report=%+v", report)
	}
	if f.hotRows(t, "b") != 3 || f.hotRows(t, "c") != 0 {
		t.Fatalf("hot rows b=%d c=%d", f.hotRows(t, "b"), f.hotRows(t, "c"))
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archived_credits WHERE request_id = ?`, b.RequestID); got != 0 {
		t.Fatalf("changed request tombstones=%d want 0", got)
	}
}

func TestEvidenceArchiveRowsEqualComparesEveryColumn(t *testing.T) {
	base := archiveRow{"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": int64(3), "b": archiveBlob{Base64: "AA=="}}
	same := archiveRow{"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": int64(3), "b": archiveBlob{Base64: "AA=="}}
	if !archiveRowsEqual(base, same) {
		t.Fatal("identical rows differ")
	}
	// An integral REAL reads back from JSON as an integer.
	if !archiveRowsEqual(archiveRow{"r": float64(4)}, archiveRow{"r": int64(4)}) {
		t.Fatal("integral REAL and its JSON round trip differ")
	}
	for name, other := range map[string]archiveRow{
		"text":    {"id": int64(1), "a": "y", "n": nil, "f": float64(2.5), "i": int64(3), "b": archiveBlob{Base64: "AA=="}},
		"null":    {"id": int64(1), "a": "x", "n": "v", "f": float64(2.5), "i": int64(3), "b": archiveBlob{Base64: "AA=="}},
		"real":    {"id": int64(1), "a": "x", "n": nil, "f": float64(2.6), "i": int64(3), "b": archiveBlob{Base64: "AA=="}},
		"int":     {"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": int64(4), "b": archiveBlob{Base64: "AA=="}},
		"blob":    {"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": int64(3), "b": archiveBlob{Base64: "AQ=="}},
		"type":    {"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": "3", "b": archiveBlob{Base64: "AA=="}},
		"missing": {"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": int64(3)},
		"extra":   {"id": int64(1), "a": "x", "n": nil, "f": float64(2.5), "i": int64(3), "b": archiveBlob{Base64: "AA=="}, "z": nil},
	} {
		if archiveRowsEqual(base, other) {
			t.Fatalf("%s: changed row compared equal", name)
		}
	}
}

// Journal copies are deleted after the main transaction commits. A run that
// stops between the two leaves them hot; the next run resumes the archive,
// retries the journal step for the requests it already tombstoned, and only
// then marks the archive deleted.
func TestEvidenceRetentionRetriesInterruptedJournalCleanup(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, true)
	f.seed(t, "first")
	b := f.seed(t, "b")
	if n, err := f.store.MirrorPendingRouteSnapshots(ctx, 100); err != nil || n != 2 {
		t.Fatalf("mirror route journal n=%d err=%v", n, err)
	}
	f.settle(t)
	if _, err := f.journalDB.Exec(`CREATE TRIGGER block_journal_delete BEFORE DELETE ON settlement_route_snapshot_journal BEGIN SELECT RAISE(ABORT, 'journal unavailable'); END`); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	opts := retentionTestOptions(dir, (&recordingVerifier{}).verify)
	report, err := f.store.RunEvidenceRetention(ctx, opts)
	if err == nil || report.Status == EvidenceRetentionStatusDeleted {
		t.Fatalf("interrupted run err=%v report=%+v", err, report)
	}
	if f.hotRows(t, "b") != 0 {
		t.Fatal("main rows not deleted before the journal step")
	}
	journalRows := func() int64 {
		return scalar(t, f.journalDB, `SELECT COUNT(*) FROM settlement_route_snapshot_journal WHERE request_id = ?`, b.RequestID)
	}
	if journalRows() != 1 {
		t.Fatalf("journal rows after interruption=%d want 1", journalRows())
	}
	if got := scalar(t, f.store.db, `SELECT status = 'offhost_verified' FROM settlement_evidence_archives`); got != 1 {
		t.Fatal("interrupted archive was not left pending")
	}
	if _, err := f.journalDB.Exec(`DROP TRIGGER block_journal_delete`); err != nil {
		t.Fatal(err)
	}
	report, err = f.store.RunEvidenceRetention(ctx, opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusDeleted || !report.ResumedArchive || report.RouteJournalDeletedRows != 1 {
		t.Fatalf("resumed run=%+v", report)
	}
	if journalRows() != 0 {
		t.Fatalf("journal rows after resume=%d want 0", journalRows())
	}
	if got := scalar(t, f.store.db, `SELECT status = 'deleted' FROM settlement_evidence_archives`); got != 1 {
		t.Fatal("archive not marked deleted after the journal retry")
	}
	// The deletion count committed with the interrupted run's deletion.
	if got := scalar(t, f.store.db, `SELECT deleted_requests FROM settlement_evidence_archives`); got != 1 {
		t.Fatalf("archive deleted_requests=%d want 1", got)
	}
}

// A finality lookup reads verdicts and usage in separate statements. When
// retention deletes the request between them, the lookup returns the
// finality frozen with that deletion instead of a partial view or an error.
func TestEvidenceRetentionFinalityLookupStraddlingDeletion(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	b := f.seed(t, "b")
	f.settle(t)
	hot, found, err := f.store.RequestSettlementFinality(ctx, b.AccountScope, b.RequestID, f.store.nowUTC().UnixMilli())
	if err != nil || !found || !hot.Closed {
		t.Fatalf("hot finality=%+v found=%v err=%v", hot, found, err)
	}
	fired := false
	requestSettlementFinalityAfterVerdictsHook = func() {
		if fired {
			return
		}
		fired = true
		report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), (&recordingVerifier{}).verify))
		if err != nil || report.DeletedRequests != 1 {
			t.Errorf("interleaved retention run=%+v err=%v", report, err)
		}
	}
	t.Cleanup(func() { requestSettlementFinalityAfterVerdictsHook = nil })
	got, found, err := f.store.RequestSettlementFinality(ctx, b.AccountScope, b.RequestID, f.store.nowUTC().UnixMilli())
	if !fired {
		t.Fatal("hook did not interleave the deletion")
	}
	if f.hotRows(t, "b") != 0 {
		t.Fatal("interleaved run did not delete request b")
	}
	if err != nil || !found || got != hot {
		t.Fatalf("straddling lookup=%+v found=%v err=%v, want the frozen %+v", got, found, err, hot)
	}
}

func TestEvidenceRetentionRespectsSettlementCycleFinality(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	if err := f.store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, f.windowStart, f.windowEnd); err != nil {
		t.Fatal(err)
	}
	f.addLaterWindows(t, 1)
	dry, err := f.store.DryRunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil))
	if err != nil {
		t.Fatal(err)
	}
	if dry.EligibleRequests != 0 || dry.SkippedRequests[retentionSkipWindowTooRecent] == 0 {
		t.Fatalf("one completed cycle: %+v", dry)
	}
	f.addLaterWindows(t, 2)
	dry, err = f.store.DryRunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), nil))
	if err != nil {
		t.Fatal(err)
	}
	if dry.EligibleRequests != 1 {
		t.Fatalf("two completed cycles: %+v", dry)
	}
	opts := retentionTestOptions(t.TempDir(), nil)
	opts.ReconcileHorizon = 365 * 24 * time.Hour
	dry, err = f.store.DryRunEvidenceRetention(ctx, opts)
	if err != nil {
		t.Fatal(err)
	}
	if dry.EligibleRequests != 0 {
		t.Fatalf("inside reconcile horizon: %+v", dry)
	}
}

func TestEvidenceRetentionRederivesSettledCreditFromArchive(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	dir := t.TempDir()
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, (&recordingVerifier{}).verify))
	if err != nil || report.DeletedRequests != 1 {
		t.Fatalf("run=%+v err=%v", report, err)
	}
	creditID := f.creditID(t, "b")
	got, err := RederiveArchivedCredit(filepath.Join(dir, report.ArchiveFile), creditID)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Matches || got.Basis != "receipt_bound_usage" || got.RederivedGrossCredits <= 0 {
		t.Fatalf("rederivation=%+v", got)
	}
	if want := scalar(t, f.store.db, `SELECT gross_credits FROM ledger_request_credits WHERE id = ?`, creditID); got.RederivedGrossCredits != want {
		t.Fatalf("rederived gross=%d hot ledger=%d", got.RederivedGrossCredits, want)
	}
	if _, err := RederiveArchivedCredit(filepath.Join(dir, report.ArchiveFile), creditID+1000); err == nil {
		t.Fatal("rederived a credit that is not in the archive")
	}
}

func TestEvidenceRetentionReadersTolerateArchivedRequests(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	b := f.seed(t, "b")
	f.settle(t)
	hotFinality, found, err := f.store.RequestSettlementFinality(ctx, b.AccountScope, b.RequestID, f.store.nowUTC().UnixMilli())
	if err != nil || !found || !hotFinality.Closed || hotFinality.Outcome != SettlementOutcomeVerified {
		t.Fatalf("hot finality=%+v found=%v err=%v", hotFinality, found, err)
	}
	if _, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), (&recordingVerifier{}).verify)); err != nil {
		t.Fatal(err)
	}
	if f.hotRows(t, "b") != 0 {
		t.Fatal("request b was not archived")
	}
	verdictsBefore := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts`)

	// A buyer reservation still held at the gateway settles after retention:
	// the lookup returns the finality frozen at deletion, never a
	// missing-evidence refund, and writes nothing. The account-scoped lookup
	// the gateway reconciler uses returns it too.
	archivedFinality, found, err := f.store.RequestSettlementFinality(ctx, b.AccountScope, b.RequestID, f.store.nowUTC().UnixMilli())
	if err != nil || !found {
		t.Fatalf("archived finality found=%v err=%v", found, err)
	}
	if archivedFinality != hotFinality {
		t.Fatalf("archived finality=%+v want the hot finality %+v", archivedFinality, hotFinality)
	}
	if _, found, err := f.store.RequestSettlementFinality(ctx, "other-scope", b.RequestID, f.store.nowUTC().UnixMilli()); err != nil || found {
		t.Fatalf("another account scope saw the archived finality: found=%v err=%v", found, err)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts`); got != verdictsBefore {
		t.Fatalf("finality lookup wrote verdicts: %d -> %d", verdictsBefore, got)
	}

	// Ledger reconciliation of the settled, archived credit with different
	// request-log usage is not a settled-credit mismatch.
	prompt, completion := int64(1), int64(999999)
	tx, err := f.store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback()
	input := HotPathInput{
		RequestID: b.RequestID, AttemptN: int(b.AttemptN), ProviderID: b.ProviderID,
		PromptTokens: &prompt, CompletionTokens: &completion,
		RateEntry:     RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000},
		MultiplierPPM: 1000000, ProviderShareBps: 10000,
	}
	expected := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, input.RateEntry, 1000000, 10000)
	gross, expectedGross, exists, mismatch, err := reconcileExistingCreditTx(ctx, tx, input, expected, sqliteTimeText(f.store.nowUTC()))
	if err != nil || !exists || mismatch || gross != expectedGross {
		t.Fatalf("reconcile archived settled credit gross=%d expected=%d exists=%v mismatch=%v err=%v", gross, expectedGross, exists, mismatch, err)
	}
	_ = tx.Rollback()

	// Unranged receipt summaries still count the archived verdict.
	h := &handler{store: f.store}
	summaries, err := h.settlementReceiptSummariesForProviders(ctx, []string{b.ProviderID}, time.Time{}, time.Time{}, false, 0)
	if err != nil {
		t.Fatal(err)
	}
	if got := summaries[b.ProviderID].VerifiedCount; got != 2 {
		t.Fatalf("unranged verified count=%d want 2 (1 hot + 1 archived)", got)
	}
}

func TestEvidenceRetentionEligibilityNeverTouchClasses(t *testing.T) {
	now := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	cut := evidenceRetentionCutoffs{windowEnd: now.AddDate(0, 0, -14), windowEndSet: true, creditBefore: now.AddDate(0, 0, -9)}
	settlementID := int64(7)
	eligible := func() requestEvidenceBundle {
		return requestEvidenceBundle{
			requestID: "req",
			credits: []retentionCredit{{
				id: 1, settled: true, settlementID: &settlementID, payable: true,
				tsUTC: now.AddDate(0, 0, -30), providerID: "p", scopeHash: SettlementAccountScopeHash("s"),
			}},
			payouts: map[int64]archiveRow{7: {"id": int64(7), "status": "ready", "window_end_utc": sqliteTimeText(now.AddDate(0, 0, -21))}},
			evidence: map[string][]archiveRow{
				"settlement_route_snapshots":      {{"id": int64(3), "account_scope": "s", "request_id": "req", "attempt_n": int64(0), "provider_id": "p", "route_snapshot_digest": "d"}},
				"settlement_receipt_verdicts":     {{"id": int64(10), "provider_id": "p", "account_scope_hash": SettlementAccountScopeHash("s"), "closed": int64(1), "settlement_outcome": "verified", "receipt_result": "valid"}},
				"settlement_receipt_audit_outbox": {{"id": int64(20), "drained_at_utc": "2026-01-01T00:00:00Z", "poisoned_at_utc": nil}},
			},
			outputJournal: []archiveRow{{"id": int64(30), "materialized_at_utc": "2026-01-01T00:00:00Z", "poisoned_at_utc": nil}},
			routeJournal:  []archiveRow{{"account_scope": "s", "request_id": "req", "attempt_n": int64(0), "provider_id": "p", "route_snapshot_digest": "d", "mirrored_at_utc": "2026-01-01T00:00:00Z"}},
		}
	}
	firstVerified := map[string]int64{"p": 9}
	if ok, reason := evaluateRetentionEligibility(eligible(), cut, firstVerified, true); !ok {
		t.Fatalf("baseline not eligible: %s", reason)
	}
	cases := []struct {
		name   string
		want   string
		mutate func(b *requestEvidenceBundle, first map[string]int64, cut *evidenceRetentionCutoffs)
	}{
		{"no credit", retentionSkipNoCredit, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) { b.credits = nil }},
		{"unsettled", retentionSkipUnsettled, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].settled = false
		}},
		{"no settlement id", retentionSkipUnsettled, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].settlementID = nil
		}},
		{"quarantined", retentionSkipQuarantined, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].quarantined = true
		}},
		{"held or force-resolved", retentionSkipResolution, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].resolutions = 1
		}},
		{"not payable", retentionSkipNotPayable, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].payable = false
		}},
		{"inside reconcile horizon", retentionSkipInsideReconcile, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].tsUTC = now.AddDate(0, 0, -2)
		}},
		{"payout missing", retentionSkipPayoutMissing, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.payouts = map[int64]archiveRow{}
		}},
		{"payout voided", retentionSkipPayoutVoided, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.payouts[7]["status"] = "voided"
		}},
		{"window too recent", retentionSkipWindowTooRecent, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.payouts[7]["window_end_utc"] = sqliteTimeText(now.AddDate(0, 0, -7))
		}},
		{"fewer completed cycles than required", retentionSkipWindowTooRecent, func(_ *requestEvidenceBundle, _ map[string]int64, c *evidenceRetentionCutoffs) {
			c.windowEndSet = false
		}},
		{"verdict open", retentionSkipVerdictOpen, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_verdicts"][0]["closed"] = int64(0)
		}},
		{"verdict pending", retentionSkipVerdictOpen, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_verdicts"][0]["settlement_outcome"] = "pending"
		}},
		{"verdict quarantined", retentionSkipVerdictQuarantined, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_verdicts"][0]["settlement_outcome"] = "quarantined"
		}},
		{"provider first verified verdict", retentionSkipFirstVerified, func(_ *requestEvidenceBundle, first map[string]int64, _ *evidenceRetentionCutoffs) {
			first["p"] = 10
		}},
		{"outbox undelivered", retentionSkipOutboxUndelivered, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_audit_outbox"][0]["drained_at_utc"] = nil
		}},
		{"outbox poisoned", retentionSkipOutboxPoisoned, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_audit_outbox"][0]["drained_at_utc"] = nil
			b.evidence["settlement_receipt_audit_outbox"][0]["poisoned_at_utc"] = "2026-01-01T00:00:00Z"
		}},
		{"output journal pending", retentionSkipOutputJournal, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.outputJournal[0]["materialized_at_utc"] = nil
		}},
		{"output journal poisoned", retentionSkipOutputJournal, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.outputJournal[0]["poisoned_at_utc"] = "2026-01-01T00:00:00Z"
		}},
		{"relay-blind entrypoint", retentionSkipRelayBlind, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_route_snapshots"][0]["paid_entrypoint"] = PaidEntrypointRelayBlindChat
		}},
		{"relay-blind prompt basis", retentionSkipRelayBlind, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_route_snapshots"][0]["prompt_hash_basis"] = PromptHashBasisRelayBlindEnvelopeV1
		}},
		{"relay-blind settled verdict", retentionSkipRelayBlind, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_verdicts"][0]["settlement_outcome"] = SettlementOutcomeRelayBlindSettled
		}},
		{"credit scope without snapshot", retentionSkipScopeUnresolved, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.credits[0].scopeHash = SettlementAccountScopeHash("other")
		}},
		{"verdict scope without snapshot", retentionSkipScopeUnresolved, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.evidence["settlement_receipt_verdicts"][0]["account_scope_hash"] = SettlementAccountScopeHash("other")
		}},
		{"route journal unmirrored", retentionSkipRouteJournal, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.routeJournal[0]["mirrored_at_utc"] = nil
		}},
		{"route journal digest differs", retentionSkipRouteJournal, func(b *requestEvidenceBundle, _ map[string]int64, _ *evidenceRetentionCutoffs) {
			b.routeJournal[0]["route_snapshot_digest"] = "other"
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b := eligible()
			first := map[string]int64{"p": 9}
			c := cut
			tc.mutate(&b, first, &c)
			ok, reason := evaluateRetentionEligibility(b, c, first, true)
			if ok || reason != tc.want {
				t.Fatalf("eligible=%v reason=%q want %q", ok, reason, tc.want)
			}
		})
	}
}

func TestEvidenceRetentionKeepsUnsettledAndQuarantinedRequestsHot(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "settled")
	f.seed(t, "undrained")
	f.addDrainedOutbox(t, "undrained", false, false)
	f.settle(t)
	// Seeded after settlement: unsettled.
	f.seed(t, "unsettled")
	// Quarantined after settlement: the settled-link trigger allows it.
	if _, err := f.store.db.Exec(`UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'operator' WHERE request_id = ?`, f.inputs["settled"].RequestID); err != nil {
		t.Fatal(err)
	}
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(t.TempDir(), (&recordingVerifier{}).verify))
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusNothingEligible {
		t.Fatalf("report=%+v", report)
	}
	for _, suffix := range []string{"first", "settled", "undrained", "unsettled"} {
		if f.hotRows(t, suffix) != 3 {
			t.Fatalf("%s lost hot evidence", suffix)
		}
	}
	for _, reason := range []string{retentionSkipFirstVerified, retentionSkipQuarantined, retentionSkipOutboxUndelivered} {
		if report.SkippedRequests[reason] != 1 {
			t.Fatalf("skipped=%v missing %s", report.SkippedRequests, reason)
		}
	}
}

func TestEvidenceRetentionIncrementalVacuumIsBounded(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "incremental.db")
	db, err := sql.Open("sqlite", "file:"+path)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	defer db.Close()
	if _, err := db.Exec(`PRAGMA auto_vacuum = INCREMENTAL; CREATE TABLE t (v TEXT);`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 200; i++ {
		if _, err := db.Exec(`INSERT INTO t (v) VALUES (?)`, strings.Repeat("x", 4000)); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := db.Exec(`DELETE FROM t`); err != nil {
		t.Fatal(err)
	}
	r := incrementalVacuum(ctx, db, "test", EvidenceRetentionOptions{IncrementalVacuumPages: 10, IncrementalVacuumMaxSteps: 3})
	if r.AutoVacuumMode != "incremental" || r.Steps != 3 || r.FreelistBefore-r.FreelistAfter != 30 {
		t.Fatalf("bounded vacuum=%+v", r)
	}
	plain, err := sql.Open("sqlite", "file:"+filepath.Join(t.TempDir(), "plain.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer plain.Close()
	if _, err := plain.Exec(`CREATE TABLE t (v TEXT)`); err != nil {
		t.Fatal(err)
	}
	r = incrementalVacuum(ctx, plain, "plain", EvidenceRetentionOptions{IncrementalVacuumPages: 10, IncrementalVacuumMaxSteps: 3})
	if r.AutoVacuumMode != "none" || !r.ConversionNeeds || r.Steps != 0 {
		t.Fatalf("non-incremental vacuum=%+v", r)
	}
}

func TestEvidenceRetentionRunCapResumesAtNextCandidate(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.seed(t, "c")
	f.settle(t)
	opts := retentionTestOptions(t.TempDir(), (&recordingVerifier{}).verify)
	opts.MaxRequestsPerRun = 1
	for run, want := range []string{"b", "c"} {
		report, err := f.store.RunEvidenceRetention(ctx, opts)
		if err != nil {
			t.Fatal(err)
		}
		if report.DeletedRequests != 1 || f.hotRows(t, want) != 0 {
			t.Fatalf("run %d report=%+v hot(%s)=%d", run, report, want, f.hotRows(t, want))
		}
	}
	if f.hotRows(t, "first") != 3 {
		t.Fatal("cap resume touched the first verified request")
	}
}

func TestEvidenceRetentionStopsDeletingWhenDisabledMidRun(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	dir := t.TempDir()
	opts := retentionTestOptions(dir, nil)
	f.store.SetEvidenceRetentionOptions(opts)
	disabled := opts
	disabled.Enabled = false
	verifier := &recordingVerifier{hook: func() { f.store.SetEvidenceRetentionOptions(disabled) }}
	opts.OffhostVerifier = verifier.verify
	report, err := f.store.RunEvidenceRetention(ctx, opts)
	if !errors.Is(err, ErrEvidenceRetentionDisabled) || report.DeletedRequests != 0 || f.hotRows(t, "b") != 3 {
		t.Fatalf("disabled mid-run err=%v report=%+v hot=%d", err, report, f.hotRows(t, "b"))
	}
	f.store.SetEvidenceRetentionOptions(opts)
	report, err = f.store.RunEvidenceRetention(ctx, opts)
	if err != nil || !report.ResumedArchive || report.DeletedRequests != 1 {
		t.Fatalf("re-enabled run err=%v report=%+v", err, report)
	}
}

// The first run on a large backlog is chunked: it archives at most
// max_requests_per_run requests and deletes them batch_size requests per short
// transaction; the rest waits for later runs. The shipped defaults keep that
// bound.
func TestEvidenceRetentionFirstRunIsChunked(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	backlog := []string{"b", "c", "d", "e", "g"}
	for _, id := range backlog {
		f.seed(t, id)
	}
	f.settle(t)
	opts := retentionTestOptions(t.TempDir(), nil)
	opts.MaxRequestsPerRun = 3
	opts.BatchSize = 2
	report, err := f.store.RunEvidenceRetention(ctx, opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.EligibleRequests != 3 || report.DeletedRequests != 3 || report.DeleteBatches != 2 {
		t.Fatalf("first run=%+v want 3 requests in 2 delete batches", report)
	}
	hot := 0
	for _, id := range backlog {
		if f.hotRows(t, id) != 0 {
			hot++
		}
	}
	if hot != 2 {
		t.Fatalf("hot backlog after first run=%d want 2", hot)
	}
	report, err = f.store.RunEvidenceRetention(ctx, opts)
	if err != nil || report.DeletedRequests != 2 || report.DeleteBatches != 1 {
		t.Fatalf("second run=%+v err=%v", report, err)
	}

	def := config.Default()
	d := EvidenceRetentionOptionsFromConfig(def.Billing.Retention, def.Settlement)
	if !d.Enabled || d.BatchSize != 50 || d.BatchPause != 200*time.Millisecond || d.MaxRequestsPerRun != 20000 || d.MaxScanRowsPerRun != 500000 {
		t.Fatalf("default bounds=%+v", d)
	}
	if d.ArchiveDir != "" || d.OffhostVerifier != nil {
		t.Fatalf("default archive dir=%q offhost=%v", d.ArchiveDir, d.OffhostVerifier != nil)
	}
	var dbFile string
	if err := f.store.db.QueryRow(`SELECT file FROM pragma_database_list WHERE name = 'main'`).Scan(&dbFile); err != nil {
		t.Fatal(err)
	}
	dir, err := f.store.defaultEvidenceArchiveDir(ctx)
	if err != nil || dir != filepath.Join(filepath.Dir(dbFile), "retention-archive") {
		t.Fatalf("default archive dir=%q err=%v db=%q", dir, err, dbFile)
	}
	if d.ArchiveMinFreeBytes != 20<<30 || d.ArchiveMinFreePercent != 10 {
		t.Fatalf("default disk floor=%+v", d)
	}
}

// A run that would write a new archive refuses while the archive filesystem
// is below its free-space floor, and touches nothing.
func TestEvidenceRetentionRefusesBelowArchiveDiskFloor(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	f.seed(t, "b")
	f.settle(t)
	dir := filepath.Join(t.TempDir(), "archive")
	opts := retentionTestOptions(dir, nil)
	opts.ArchiveMinFreeBytes = 1 << 62
	report, err := f.store.RunEvidenceRetention(ctx, opts)
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != EvidenceRetentionStatusArchiveDiskLow || report.ArchiveFreeBytes <= 0 || report.EligibleRequests != 0 {
		t.Fatalf("disk-low run=%+v", report)
	}
	if f.hotRows(t, "b") != 3 || scalar(t, f.store.db, `SELECT COUNT(*) FROM settlement_evidence_archives`) != 0 {
		t.Fatal("disk-low run exported or deleted")
	}
	opts.ArchiveMinFreeBytes = 0
	report, err = f.store.RunEvidenceRetention(ctx, opts)
	if err != nil || report.Status != EvidenceRetentionStatusDeleted {
		t.Fatalf("run above floor=%+v err=%v", report, err)
	}

	for _, tc := range []struct {
		free, total, bytes int64
		pct                int
		low                bool
	}{
		{free: 25 << 30, total: 100 << 30, bytes: 20 << 30, pct: 10},
		{free: 19 << 30, total: 100 << 30, bytes: 20 << 30, pct: 10, low: true},
		{free: 30 << 30, total: 400 << 30, bytes: 20 << 30, pct: 10, low: true},
		{free: 1, total: 100, bytes: 0, pct: 0},
	} {
		got := archiveDiskBelowFloor(tc.free, tc.total, EvidenceRetentionOptions{ArchiveMinFreeBytes: tc.bytes, ArchiveMinFreePercent: tc.pct})
		if (got != "") != tc.low {
			t.Errorf("free=%d total=%d floor=%d/%d%% got %q", tc.free, tc.total, tc.bytes, tc.pct, got)
		}
	}
}

// SPEC-047-R012 compatibility: a pool-scoped attempt stays hot until the
// pool-proven rollup holds its final state, so archiving never shrinks the
// pool-proven aggregate. Without the rollup table (an aggregate that recounts
// hot evidence) pool-scoped requests are never archived.
func TestEvidenceRetentionKeepsPoolScopedAttemptsUntilPoolProvenRollupIsFinal(t *testing.T) {
	ctx := context.Background()
	f := newRetentionFixture(t, false)
	f.seed(t, "first")
	pool := f.seed(t, "pool")
	f.seed(t, "plain")
	f.settle(t)
	if _, err := f.store.db.Exec(`DROP TRIGGER trg_srs_immutable`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.store.db.Exec(`UPDATE settlement_route_snapshots SET pool_id = 'pool-a' WHERE request_id = ?`, pool.RequestID); err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	report, err := f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, nil))
	if err != nil {
		t.Fatal(err)
	}
	if report.DeletedRequests != 1 || f.hotRows(t, "plain") != 0 || f.hotRows(t, "pool") != 3 ||
		report.SkippedRequests[retentionSkipPoolProvenUnrolled] != 1 {
		t.Fatalf("no rollup table: report=%+v hot(pool)=%d", report, f.hotRows(t, "pool"))
	}
	snapshotID := scalar(t, f.store.db, `SELECT id FROM settlement_route_snapshots WHERE request_id = ?`, pool.RequestID)
	if _, err := f.store.db.Exec(`
CREATE TABLE pool_proven_rollup_attempts (route_snapshot_id INTEGER PRIMARY KEY, counted INTEGER NOT NULL DEFAULT 0, finality_at_utc TEXT NULL);
INSERT INTO pool_proven_rollup_attempts (route_snapshot_id, counted, finality_at_utc) VALUES (?, 1, NULL);
UPDATE settlement_evidence_retention_state SET scan_cursor_credit_id = 0;`, snapshotID); err != nil {
		t.Fatal(err)
	}
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, nil))
	if err != nil || report.DeletedRequests != 0 || f.hotRows(t, "pool") != 3 || report.SkippedRequests[retentionSkipPoolProvenUnrolled] != 1 {
		t.Fatalf("rollup row without finality: report=%+v err=%v", report, err)
	}
	if _, err := f.store.db.Exec(`
UPDATE pool_proven_rollup_attempts SET finality_at_utc = '2026-07-01T00:00:00.000000000Z';
UPDATE settlement_evidence_retention_state SET scan_cursor_credit_id = 0;`); err != nil {
		t.Fatal(err)
	}
	report, err = f.store.RunEvidenceRetention(ctx, retentionTestOptions(dir, nil))
	if err != nil || report.DeletedRequests != 1 || f.hotRows(t, "pool") != 0 {
		t.Fatalf("final rollup row: report=%+v err=%v", report, err)
	}
}
