package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/audit"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

func writeCoverYAML(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "c.yaml")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestParseRFC3339Strict(t *testing.T) {
	ts, err := parseRFC3339Strict("2026-01-02T03:04:05Z")
	if err != nil || !ts.Equal(time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)) {
		t.Fatalf("got %v, %v", ts, err)
	}
	for _, bad := range []string{"", "2026-01-02", "2026-01-02 03:04:05"} {
		if _, err := parseRFC3339Strict(bad); err == nil {
			t.Fatalf("%q must be rejected", bad)
		}
	}
}

func TestRouteSnapshotJournalDBPath(t *testing.T) {
	cases := map[string]string{
		"":            "",
		":memory:":    ":memory:",
		"/var/db.sql": "/var/db.sql.route-snapshots",
	}
	for in, want := range cases {
		if got := routeSnapshotJournalDBPath(in); got != want {
			t.Errorf("routeSnapshotJournalDBPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAuditLogRotationOptions(t *testing.T) {
	var cfg config.Config
	cfg.Storage.AuditLogArchiveDir = "/explicit/archive"
	cfg.Storage.AuditLogHotDays = 14
	cfg.Storage.AuditLogRetentionDays = 400
	cfg.Billing.Retention.BatchPauseMS = 250
	cfg.Billing.Retention.RunBudgetMinutes = 3
	cfg.Billing.Retention.ArchiveMinFreeBytes = 1 << 20
	cfg.Billing.Retention.IncrementalVacuumPages = 9
	opts := auditLogRotationOptions(cfg)
	if opts.ArchiveDir != "/explicit/archive" || opts.HotDays != 14 || opts.RetentionDays != 400 {
		t.Fatalf("explicit options wrong: %+v", opts)
	}
	if opts.BatchPause != 250*time.Millisecond || opts.RunBudget != 3*time.Minute ||
		opts.MinFreeBytes != 1<<20 || opts.IncrementalVacuumPages != 9 {
		t.Fatalf("retention mapping wrong: %+v", opts)
	}

	dir := t.TempDir()
	cfg.Storage.AuditLogArchiveDir = ""
	cfg.Storage.DBPath = filepath.Join(dir, "coord.db")
	opts = auditLogRotationOptions(cfg)
	if want := filepath.Join(dir, audit.AuditArchiveDirName); opts.ArchiveDir != want {
		t.Fatalf("default archive dir = %q, want %q", opts.ArchiveDir, want)
	}
}
