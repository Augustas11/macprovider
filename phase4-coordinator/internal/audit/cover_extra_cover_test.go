package audit

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/verifiedarchive"
)

func TestEmitReceiptRotationRejectsIncompleteEvents(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	at := time.Date(2026, 6, 23, 12, 0, 0, 0, time.UTC)
	key := []byte("k")
	cases := map[string]struct {
		provider string
		old, new []byte
		at       time.Time
	}{
		"no provider": {"", key, key, at},
		"no old key":  {"p", nil, key, at},
		"no new key":  {"p", key, nil, at},
		"zero time":   {"p", key, key, time.Time{}},
	}
	for name, c := range cases {
		err := store.EmitReceiptRotation(context.Background(), receiptRotationEventForTest(c.provider, c.old, c.new, c.at))
		if err == nil || !strings.Contains(err.Error(), "invalid receipt_rotation_detected") {
			t.Fatalf("%s: err = %v", name, err)
		}
	}
	if n := countAuditRows(t, store); n != 0 {
		t.Fatalf("rows written for invalid events: %d", n)
	}
}

func TestRotationOptionsNormalizedValidatesAndDefaults(t *testing.T) {
	abs := t.TempDir()
	bad := map[string]RotationOptions{
		"empty dir":     {HotDays: 1, RetentionDays: 1},
		"relative dir":  {ArchiveDir: "rel/dir", HotDays: 1, RetentionDays: 1},
		"zero hot days": {ArchiveDir: abs, HotDays: 0, RetentionDays: 5},
		"retention<hot": {ArchiveDir: abs, HotDays: 7, RetentionDays: 6},
		"blank dir":     {ArchiveDir: "   ", HotDays: 1, RetentionDays: 1},
	}
	for name, o := range bad {
		if _, err := o.normalized(); err == nil {
			t.Fatalf("%s: expected error", name)
		}
	}
	got, err := RotationOptions{ArchiveDir: abs, HotDays: 7, RetentionDays: 7}.normalized()
	if err != nil {
		t.Fatal(err)
	}
	if got.MaxRowsPerArchive != 200000 || got.BatchSize != pruneBatchSize || got.RunBudget != 15*time.Minute {
		t.Fatalf("defaults = %+v", got)
	}
	kept, err := RotationOptions{ArchiveDir: abs, HotDays: 1, RetentionDays: 1, MaxRowsPerArchive: 5, BatchSize: 2, RunBudget: time.Second}.normalized()
	if err != nil || kept.MaxRowsPerArchive != 5 || kept.BatchSize != 2 || kept.RunBudget != time.Second {
		t.Fatalf("explicit values overwritten: %+v %v", kept, err)
	}
}

func TestRotateClosedPeriodsGuards(t *testing.T) {
	ctx := context.Background()
	now := time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC)
	var nilStore *Store
	if _, err := nilStore.RotateClosedPeriods(ctx, RotationOptions{}, now); !errors.Is(err, errStoreClosed) {
		t.Fatalf("nil store err = %v", err)
	}
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	if _, err := store.RotateClosedPeriods(ctx, RotationOptions{ArchiveDir: "rel", HotDays: 1, RetentionDays: 1}, now); err == nil {
		t.Fatal("relative archive dir accepted")
	}
	store.rotation.mu.Lock()
	_, err := store.RotateClosedPeriods(ctx, rotationTestOptions(t.TempDir()), now)
	store.rotation.mu.Unlock()
	if !errors.Is(err, ErrRotationBusy) {
		t.Fatalf("concurrent run err = %v", err)
	}
	cctx, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := store.RotateClosedPeriods(cctx, rotationTestOptions(t.TempDir()), now); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled err = %v", err)
	}
}

func TestRotateClosedPeriodsNothingDueReportsCutoffAndMode(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	now := time.Date(2026, 10, 20, 2, 0, 0, 0, time.UTC)
	seedAuditDays(t, store, []time.Time{time.Date(2026, 10, 19, 0, 0, 0, 0, time.UTC)}, 2)
	report, err := store.RotateClosedPeriods(context.Background(), rotationTestOptions(t.TempDir()), now)
	if err != nil {
		t.Fatal(err)
	}
	if report.Status != RotationStatusNothingDue || report.CutoffDayUTC != "2026-10-13" || report.Archives != 0 {
		t.Fatalf("report = %+v", report)
	}
	if auditRowCount(t, store, "1=1") != 2 {
		t.Fatal("hot rows were touched")
	}
	if report.AutoVacuumMode != "none" {
		t.Fatalf("auto vacuum mode = %q", report.AutoVacuumMode)
	}
}

func TestRemoveExpiredAuditArchivesSkipsPathTraversalNames(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	dir := t.TempDir()
	outside := filepath.Join(filepath.Dir(dir), filepath.Base(dir)+"-victim")
	if err := os.WriteFile(outside, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	name := "../" + filepath.Base(outside)
	if _, err := store.DB().ExecContext(ctx, `
INSERT INTO audit_log_archives (file_name, sha256, size_bytes, group_count, row_count, first_day_utc, last_day_utc, status, created_at_utc, updated_at_utc)
VALUES (?, ?, 1, 1, 1, '2026-01-01', '2026-01-02', 'deleted', 'x', 'x')`, name, strings.Repeat("a", 64)); err != nil {
		t.Fatal(err)
	}
	opts := rotationTestOptions(dir)
	removed, err := store.removeExpiredAuditArchives(ctx, opts, time.Date(2026, 10, 20, 0, 0, 0, 0, time.UTC))
	if err != nil || removed != 0 {
		t.Fatalf("removed=%d err=%v", removed, err)
	}
	if _, err := os.Stat(outside); err != nil {
		t.Fatalf("file outside archive dir was deleted: %v", err)
	}
}

func TestIncrementalVacuumReportsModeAndReclaimsPages(t *testing.T) {
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	ctx := context.Background()
	opts := RotationOptions{IncrementalVacuumPages: 10, IncrementalVacuumMaxSteps: 50}
	if got := store.incrementalVacuum(ctx, opts); got != "none" {
		t.Fatalf("mode = %q, want none", got)
	}
	// Switch to INCREMENTAL, rebuild the file, then create and free pages.
	if _, err := store.DB().ExecContext(ctx, `PRAGMA auto_vacuum=INCREMENTAL`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().ExecContext(ctx, `VACUUM`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().ExecContext(ctx, `CREATE TABLE junk(b BLOB)`); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 40; i++ {
		if _, err := store.DB().ExecContext(ctx, `INSERT INTO junk VALUES (zeroblob(8000))`); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := store.DB().ExecContext(ctx, `DROP TABLE junk`); err != nil {
		t.Fatal(err)
	}
	var before int64
	if err := store.DB().QueryRowContext(ctx, `PRAGMA freelist_count`).Scan(&before); err != nil || before == 0 {
		t.Fatalf("freelist before = %d err=%v", before, err)
	}
	if got := store.incrementalVacuum(ctx, opts); got != "incremental" {
		t.Fatalf("mode = %q, want incremental", got)
	}
	var after int64
	if err := store.DB().QueryRowContext(ctx, `PRAGMA freelist_count`).Scan(&after); err != nil {
		t.Fatal(err)
	}
	if after >= before {
		t.Fatalf("freelist %d -> %d, expected reclaim", before, after)
	}
	// Zero pages configured: mode reported, nothing reclaimed.
	if got := store.incrementalVacuum(ctx, RotationOptions{}); got != "incremental" {
		t.Fatalf("mode = %q", got)
	}
}

func TestVerifyArchiveFileRejectsMissingAndWrongFormat(t *testing.T) {
	dir := t.TempDir()
	if _, err := VerifyArchiveFile(filepath.Join(dir, "missing.tar")); err == nil {
		t.Fatal("missing archive verified")
	}
	write := func(format string) string {
		t.Helper()
		w, err := verifiedarchive.NewWriter(dir, "test", format, time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC), "2026-01-01")
		if err != nil {
			t.Fatal(err)
		}
		_, path, err := w.Finish()
		if err != nil {
			t.Fatal(err)
		}
		return path
	}
	good := write(auditArchiveFormat)
	if m, err := VerifyArchiveFile(good); err != nil || m.Format != auditArchiveFormat {
		t.Fatalf("valid archive: manifest=%+v err=%v", m, err)
	}
	// Structurally valid archive whose only defect is the format label.
	other := write("other-format")
	_, err := VerifyArchiveFile(other)
	if err == nil {
		t.Fatal("wrong-format archive verified")
	}
	if !errors.Is(err, verifiedarchive.ErrInvalid) || !strings.Contains(err.Error(), "manifest format") {
		t.Fatalf("err = %v", err)
	}
}

func TestSettlementReceiptOutboxConflictErrorIdentifiesPoisonRow(t *testing.T) {
	err := error(SettlementReceiptOutboxConflictError{OutboxID: 42})
	if !strings.Contains(err.Error(), "42") {
		t.Fatalf("message = %q", err.Error())
	}
	var m interface{ SettlementReceiptAuditOutboxConflict() bool }
	if !errors.As(err, &m) || !m.SettlementReceiptAuditOutboxConflict() {
		t.Fatal("conflict marker missing")
	}
}

func TestStoreNilAndClosedBehaviour(t *testing.T) {
	var nilStore *Store
	if nilStore.DB() != nil || nilStore.Close() != nil {
		t.Fatal("nil store DB/Close should be no-ops")
	}
	ctx := context.Background()
	now := time.Now()
	if err := nilStore.Insert(ctx, now, "e", "p", "{}"); !errors.Is(err, errStoreClosed) {
		t.Fatalf("Insert err = %v", err)
	}
	if _, err := nilStore.InsertSettlementReceiptOutbox(ctx, now, "e", "p", "{}", 1); !errors.Is(err, errStoreClosed) {
		t.Fatalf("outbox err = %v", err)
	}
	if _, err := nilStore.PruneBefore(ctx, now); !errors.Is(err, errStoreClosed) {
		t.Fatalf("prune err = %v", err)
	}
	store := openSettlementReceiptTestStore(t)
	defer store.Close()
	if _, err := store.InsertSettlementReceiptOutbox(ctx, now, "e", "p", "{}", 0); err == nil {
		t.Fatal("outbox id 0 accepted")
	}
	if _, err := OpenStore(""); err == nil {
		t.Fatal("empty db path accepted")
	}
}

func TestPruneBeforeFailsOnCanceledContext(t *testing.T) {
	store := openTestStore(t)
	defer store.Close()
	ctx, cancel := context.WithCancel(context.Background())
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	for i := 0; i < pruneBatchSize+1; i++ {
		if err := store.Insert(context.Background(), base.Add(time.Duration(i)*time.Second), "e", "p", "{}"); err != nil {
			t.Fatal(err)
		}
	}
	cancel()
	n, err := store.PruneBefore(ctx, base.Add(24*time.Hour))
	if err == nil {
		t.Fatalf("expected context error, deleted %d", n)
	}
}
