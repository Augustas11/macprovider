package main

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
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

func TestParseAdminDSNFromYAML(t *testing.T) {
	got, err := parseAdminDSNFromYAML(writeCoverYAML(t, "stats:\n  partner_keys_admin_dsn: \"postgres://x/y\"\n"))
	if err != nil || got != "postgres://x/y" {
		t.Fatalf("got %q, %v", got, err)
	}
	if _, err := parseAdminDSNFromYAML(writeCoverYAML(t, "stats:\n  other: 1\n")); err == nil || !strings.Contains(err.Error(), "missing") {
		t.Fatalf("absent DSN must error, got %v", err)
	}
	if _, err := parseAdminDSNFromYAML(writeCoverYAML(t, "stats: [unterminated\n")); err == nil || !strings.Contains(err.Error(), "yaml parse") {
		t.Fatalf("malformed yaml must error, got %v", err)
	}
	if _, err := parseAdminDSNFromYAML(filepath.Join(t.TempDir(), "nope.yaml")); err == nil {
		t.Fatal("missing file must error")
	}
}

func TestParseProductionSignoffPathFromYAML(t *testing.T) {
	got, err := parseProductionSignoffPathFromYAML(writeCoverYAML(t, "stats:\n  partner_keys:\n    production_signoff_path: \"  /etc/signoff.json  \"\n"))
	if err != nil || got != "/etc/signoff.json" {
		t.Fatalf("got %q, %v", got, err)
	}
	got, err = parseProductionSignoffPathFromYAML(writeCoverYAML(t, "stats: {}\n"))
	if err != nil || got != "" {
		t.Fatalf("absent path must be empty without error, got %q, %v", got, err)
	}
	if _, err := parseProductionSignoffPathFromYAML(writeCoverYAML(t, "stats: [oops\n")); err == nil {
		t.Fatal("malformed yaml must error")
	}
	if _, err := parseProductionSignoffPathFromYAML(filepath.Join(t.TempDir(), "nope.yaml")); err == nil {
		t.Fatal("missing file must error")
	}
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
		"   ":         "   ",
		":memory:":    ":memory:",
		"/var/db.sql": "/var/db.sql.route-snapshots",
	}
	for in, want := range cases {
		if got := routeSnapshotJournalDBPath(in); got != want {
			t.Errorf("routeSnapshotJournalDBPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDefaultSettlementAttemptOutputJournalMaterializerConfigRetention(t *testing.T) {
	if got := defaultSettlementAttemptOutputJournalMaterializerConfig(0).Retention; got != 30*24*time.Hour {
		t.Fatalf("non-positive retention must default to 30 days, got %v", got)
	}
	if got := defaultSettlementAttemptOutputJournalMaterializerConfig(-5).Retention; got != 30*24*time.Hour {
		t.Fatalf("negative retention must default to 30 days, got %v", got)
	}
	cfg := defaultSettlementAttemptOutputJournalMaterializerConfig(7)
	if cfg.Retention != 7*24*time.Hour {
		t.Fatalf("retention = %v, want 7 days", cfg.Retention)
	}
	if cfg.Batch != settlementAttemptOutputJournalBatch || cfg.Interval != settlementAttemptOutputJournalInterval {
		t.Fatalf("batch/interval not taken from constants: %+v", cfg)
	}
}

func TestDefaultRouteSnapshotJournalConfigs(t *testing.T) {
	m := defaultRouteSnapshotJournalMirrorConfig()
	if m.Batch != routeSnapshotJournalMirrorBatch || m.Interval != routeSnapshotJournalMirrorInterval || m.MaxBatches != 5 {
		t.Fatalf("mirror config: %+v", m)
	}
	p := defaultRouteSnapshotJournalPrunerConfig()
	if p.Batch != 100 || p.MaxBatches != 100 || p.Interval != time.Minute || p.Timeout != 2*time.Minute {
		t.Fatalf("pruner config: %+v", p)
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

func TestPQStringArrayLiteral(t *testing.T) {
	cases := []struct {
		in   []string
		want string
	}{
		{nil, "{}"},
		{[]string{"a"}, `{"a"}`},
		{[]string{"a.com", "b:80"}, `{"a.com","b:80"}`},
		{[]string{`q"x`, `b\s`}, `{"q\"x","b\\s"}`},
	}
	for _, c := range cases {
		if got := pqStringArrayLiteral(c.in); got != c.want {
			t.Errorf("pqStringArrayLiteral(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestNullStringHelpers(t *testing.T) {
	if got := nullTimeString(sql.NullTime{}); got != "" {
		t.Fatalf("invalid time = %q", got)
	}
	loc := time.FixedZone("x", 8*3600)
	nt := sql.NullTime{Valid: true, Time: time.Date(2026, 5, 6, 8, 0, 0, 0, loc)}
	if got := nullTimeString(nt); got != "2026-05-06T00:00:00Z" {
		t.Fatalf("valid time must be UTC RFC3339, got %q", got)
	}
	if got := nullInt64String(sql.NullInt64{Int64: 5}); got != "" {
		t.Fatalf("invalid int = %q", got)
	}
	if got := nullInt64String(sql.NullInt64{Valid: true, Int64: -42}); got != "-42" {
		t.Fatalf("valid int = %q", got)
	}
}

func TestHexDecodeShim(t *testing.T) {
	b, err := hexDecode("00ff10")
	if err != nil || len(b) != 3 || b[1] != 0xff {
		t.Fatalf("got %v, %v", b, err)
	}
	if _, err := hexDecode("zz"); err == nil {
		t.Fatal("invalid hex must error")
	}
}
