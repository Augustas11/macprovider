package audit

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

func rotationTestOptions(dir string) RotationOptions {
	return RotationOptions{ArchiveDir: dir, HotDays: 7, RetentionDays: 90, BatchSize: 3, MaxRowsPerArchive: 1000}
}

// seedAuditDays writes perDay audit rows on each of the given days.
func seedAuditDays(t *testing.T, store *Store, days []time.Time, perDay int) {
	t.Helper()
	ctx := context.Background()
	outbox := int64(1)
	for _, day := range days {
		for i := 0; i < perDay; i++ {
			ts := day.Add(time.Duration(i) * time.Minute)
			payload := fmt.Sprintf(`{"request_id":"req-%d","attempt_n":0}`, outbox)
			if _, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "provider-a", payload, outbox); err != nil {
				t.Fatal(err)
			}
			outbox++
		}
	}
}

func auditRowCount(t *testing.T, store *Store, where string, args ...any) int {
	t.Helper()
	var n int
	if err := store.DB().QueryRowContext(context.Background(), `SELECT COUNT(*) FROM audit_log WHERE `+where, args...).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestRotateClosedPeriodsArchivesVerifiesAndDeletesClosedDays(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 10, 20, 2, 30, 0, 0, time.UTC)
	old1 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	old2 := time.Date(2026, 10, 12, 23, 0, 0, 0, time.UTC)
	hot := time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC)
	seedAuditDays(t, store, []time.Time{old1, old2, hot}, 4)
	before := map[int64]string{}
	rows, err := store.DB().QueryContext(ctx, `SELECT id, payload_json FROM audit_log WHERE ts_utc < '2026-10-13'`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id int64
		var payload string
		if err := rows.Scan(&id, &payload); err != nil {
			t.Fatal(err)
		}
		before[id] = payload
	}
	rows.Close()

	dir := t.TempDir()
	report, err := store.RotateClosedPeriods(ctx, rotationTestOptions(dir), now)
	if err != nil {
		t.Fatalf("rotate: %v", err)
	}
	if report.Status != RotationStatusRotated || report.Archives != 1 || report.ArchivedRows != 8 || report.DeletedRows != 8 || report.CutoffDayUTC != "2026-10-13" {
		t.Fatalf("report = %+v", report)
	}
	if n := auditRowCount(t, store, `1=1`); n != 4 {
		t.Fatalf("hot rows = %d, want the 4 rows of the hot day", n)
	}
	if n := auditRowCount(t, store, `ts_utc < '2026-10-13'`); n != 0 {
		t.Fatalf("closed-day rows left hot: %d", n)
	}
	// The archive verifies on its own and holds every archived row intact.
	path := filepath.Join(dir, report.LastArchiveFile)
	manifest, err := verifiedarchive.ReadManifest(path)
	if err != nil {
		t.Fatal(err)
	}
	if manifest.SHA256 != report.LastArchiveSHA || manifest.RowCounts[auditArchiveTable] != 8 {
		t.Fatalf("manifest = %+v", manifest)
	}
	got := map[int64]string{}
	if err := verifiedarchive.Stream(path, manifest, auditArchiveKnownTable, func(g verifiedarchive.Group) error {
		for _, row := range g.Rows[auditArchiveTable] {
			got[row["id"].(int64)] = row["payload_json"].(string)
		}
		return nil
	}); err != nil {
		t.Fatalf("archive does not verify: %v", err)
	}
	if len(got) != len(before) {
		t.Fatalf("archived %d rows, want %d", len(got), len(before))
	}
	for id, payload := range before {
		if got[id] != payload {
			t.Fatalf("row %d archived as %q want %q", id, got[id], payload)
		}
	}
	var status, firstDay, lastDay string
	var deleted int64
	if err := store.DB().QueryRowContext(ctx, `SELECT status, first_day_utc, last_day_utc, deleted_rows FROM audit_log_archives`).Scan(&status, &firstDay, &lastDay, &deleted); err != nil {
		t.Fatal(err)
	}
	if status != auditArchiveStatusDeleted || firstDay != "2026-10-01" || lastDay != "2026-10-12" || deleted != 8 {
		t.Fatalf("archive record = %s %s %s %d", status, firstDay, lastDay, deleted)
	}
	// A second run finds nothing due.
	report, err = store.RotateClosedPeriods(ctx, rotationTestOptions(dir), now)
	if err != nil || report.Status != RotationStatusNothingDue || report.Archives != 0 {
		t.Fatalf("second run = %+v, %v", report, err)
	}
}

func TestRotateClosedPeriodsRefusesTamperedArchive(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 10, 20, 2, 30, 0, 0, time.UTC)
	seedAuditDays(t, store, []time.Time{time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}, 5)
	dir := t.TempDir()
	opts, err := rotationTestOptions(dir).normalized()
	if err != nil {
		t.Fatal(err)
	}
	rec, err := store.exportAuditArchive(ctx, opts, "2026-10-13", now, &auditExportKey{})
	if err != nil || rec == nil {
		t.Fatalf("export: %v %v", rec, err)
	}
	path := filepath.Join(dir, rec.manifest.ArchiveFile)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)/2] ^= 0xff
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	report, err := store.RotateClosedPeriods(ctx, opts, now)
	if !errors.Is(err, verifiedarchive.ErrInvalid) || report.Status != RotationStatusInvalid || report.DeletedRows != 0 {
		t.Fatalf("tampered archive: report=%+v err=%v", report, err)
	}
	if n := auditRowCount(t, store, `1=1`); n != 5 {
		t.Fatalf("rows deleted against a tampered archive: %d left", n)
	}
	var status string
	if err := store.DB().QueryRowContext(ctx, `SELECT status FROM audit_log_archives WHERE id = ?`, rec.id).Scan(&status); err != nil || status != auditArchiveStatusFailed {
		t.Fatalf("archive status = %q, %v", status, err)
	}
	// The next run archives the still-hot rows again into a new file.
	report, err = store.RotateClosedPeriods(ctx, opts, now)
	if err != nil || report.DeletedRows != 5 {
		t.Fatalf("re-archive: %+v %v", report, err)
	}
}

func TestRotateClosedPeriodsKeepsRowChangedAfterExportAndResumes(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	now := time.Date(2026, 10, 20, 2, 30, 0, 0, time.UTC)
	seedAuditDays(t, store, []time.Time{time.Date(2026, 10, 2, 0, 0, 0, 0, time.UTC)}, 6)
	dir := t.TempDir()
	opts, err := rotationTestOptions(dir).normalized()
	if err != nil {
		t.Fatal(err)
	}
	rec, err := store.exportAuditArchive(ctx, opts, "2026-10-13", now, &auditExportKey{})
	if err != nil || rec == nil {
		t.Fatalf("export: %v %v", rec, err)
	}
	var changedID, goneID int64
	if err := store.DB().QueryRowContext(ctx, `SELECT MIN(id), MAX(id) FROM audit_log`).Scan(&changedID, &goneID); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().ExecContext(ctx, `UPDATE audit_log SET payload_json = '{"changed":true}' WHERE id = ?`, changedID); err != nil {
		t.Fatal(err)
	}
	// A row already gone is the state an interrupted deletion leaves.
	if _, err := store.DB().ExecContext(ctx, `DELETE FROM audit_log WHERE id = ?`, goneID); err != nil {
		t.Fatal(err)
	}
	report, err := store.RotateClosedPeriods(ctx, opts, now)
	if err != nil {
		t.Fatal(err)
	}
	// The pending archive deletes the 4 unchanged rows and keeps the changed
	// one; the run then archives the changed row again as it now is.
	if report.DeletedRows != 5 || report.KeptRows != 1 || report.Archives != 2 || report.ArchivedRows != 1 {
		t.Fatalf("report = %+v", report)
	}
	path := filepath.Join(dir, report.LastArchiveFile)
	manifest, err := verifiedarchive.ReadManifest(path)
	if err != nil {
		t.Fatal(err)
	}
	var archived string
	if err := verifiedarchive.Stream(path, manifest, auditArchiveKnownTable, func(g verifiedarchive.Group) error {
		for _, row := range g.Rows[auditArchiveTable] {
			if row["id"].(int64) == changedID {
				archived = row["payload_json"].(string)
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if archived != `{"changed":true}` {
		t.Fatalf("changed row archived as %q", archived)
	}
}

func TestRotateClosedPeriodsRemovesArchivesPastRetention(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	seedAuditDays(t, store, []time.Time{time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)}, 2)
	dir := t.TempDir()
	first := time.Date(2026, 6, 20, 2, 30, 0, 0, time.UTC)
	report, err := store.RotateClosedPeriods(ctx, rotationTestOptions(dir), first)
	if err != nil || report.Archives != 1 {
		t.Fatalf("rotate: %+v %v", report, err)
	}
	path := filepath.Join(dir, report.LastArchiveFile)
	// Inside the 90-day window the archive stays.
	report, err = store.RotateClosedPeriods(ctx, rotationTestOptions(dir), time.Date(2026, 8, 29, 2, 30, 0, 0, time.UTC))
	if err != nil || report.RemovedArchives != 0 {
		t.Fatalf("inside retention: %+v %v", report, err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("archive removed inside retention: %v", err)
	}
	report, err = store.RotateClosedPeriods(ctx, rotationTestOptions(dir), time.Date(2026, 9, 1, 2, 30, 0, 0, time.UTC))
	if err != nil || report.RemovedArchives != 1 {
		t.Fatalf("past retention: %+v %v", report, err)
	}
	for _, p := range []string{path, path + verifiedarchive.ManifestSuffix} {
		if _, err := os.Stat(p); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("%s still present: %v", p, err)
		}
	}
}

func TestRotateClosedPeriodsRefusesBelowDiskFloor(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	seedAuditDays(t, store, []time.Time{time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}, 2)
	opts := rotationTestOptions(t.TempDir())
	opts.MinFreeBytes = 1 << 62
	report, err := store.RotateClosedPeriods(ctx, opts, time.Date(2026, 10, 20, 2, 30, 0, 0, time.UTC))
	if err != nil || report.Status != RotationStatusDiskLow || report.Archives != 0 {
		t.Fatalf("report = %+v err = %v", report, err)
	}
	if n := auditRowCount(t, store, `1=1`); n != 2 {
		t.Fatalf("rows deleted below the disk floor: %d left", n)
	}
}

func TestRotateClosedPeriodsRunsOnTheAuditDatabaseOnly(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	if _, err := store.RotateClosedPeriods(context.Background(), rotationTestOptions(t.TempDir()), time.Now()); err == nil {
		t.Fatal("rotation ran on the money-database audit store")
	}
}

func TestInsertSettlementReceiptOutboxAcceptsLegacyFormRedelivery(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	ts := time.Date(2026, 10, 14, 1, 2, 3, 0, time.UTC)
	legacy := `{"account_scope_hash":"h","attempt_id":"r:0:p","attempt_n":0,"provider_id":"p","request_id":"r","received_at_unix_ms":5,"settlement_outcome":"verified","settlement_receipt_audit_outbox_id":7,"verifier_checks":{"signature_verified":true}}`
	if _, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "p", legacy, 7); err != nil {
		t.Fatal(err)
	}
	slim := `{"account_scope_hash":"h","attempt_n":0,"provider_id":"p","request_id":"r","received_at_unix_ms":5,"settlement_outcome":"verified","settlement_receipt_audit_outbox_id":7}`
	if inserted, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "p", slim, 7); err != nil || inserted {
		t.Fatalf("slim redelivery of a legacy row: inserted=%v err=%v", inserted, err)
	}
	// A slim payload that disagrees with the legacy row is still a conflict.
	other := `{"account_scope_hash":"h","attempt_n":0,"provider_id":"p","request_id":"r","received_at_unix_ms":5,"settlement_outcome":"quarantined","settlement_receipt_audit_outbox_id":7}`
	var conflict SettlementReceiptOutboxConflictError
	if _, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "p", other, 7); !errors.As(err, &conflict) {
		t.Fatalf("disagreeing payload err = %v, want conflict", err)
	}
	// A slim row is never matched loosely against another slim payload.
	if _, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "p", slim, 8); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertSettlementReceiptOutbox(ctx, ts, "settlement_receipt_verdict", "p", other, 8); !errors.As(err, &conflict) {
		t.Fatalf("slim/slim mismatch err = %v, want conflict", err)
	}
}

func TestVerifyArchiveFile(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	seedAuditDays(t, store, []time.Time{time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)}, 3)
	dir := t.TempDir()
	report, err := store.RotateClosedPeriods(context.Background(), rotationTestOptions(dir), time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC))
	if err != nil || report.Archives != 1 {
		t.Fatalf("rotate: %+v %v", report, err)
	}
	manifest, err := VerifyArchiveFile(filepath.Join(dir, report.LastArchiveFile))
	if err != nil || manifest.RowCounts[auditArchiveTable] != 3 {
		t.Fatalf("verify: %+v %v", manifest, err)
	}
}
