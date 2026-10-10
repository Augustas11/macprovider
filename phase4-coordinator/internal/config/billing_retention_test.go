package config

import (
	"strings"
	"testing"
)

func TestBillingRetentionDefaultsAreOnAndValid(t *testing.T) {
	cfg := Default()
	r := cfg.Billing.Retention
	if !r.Enabled || r.MinSettlementCycles != 2 || len(r.OffhostVerifyCommand) != 0 || r.ArchiveDir != "" {
		t.Fatalf("retention defaults=%+v", r)
	}
	if r.ArchiveMinFreeBytes != 20<<30 || r.ArchiveMinFreePercent != 10 {
		t.Fatalf("archive free-space floor defaults=%+v", r)
	}
	if err := cfg.validateBillingRetention(); err != nil {
		t.Fatalf("default retention invalid: %v", err)
	}
}

func TestBillingRetentionValidation(t *testing.T) {
	cases := map[string]struct {
		mutate func(r *BillingRetentionConfig)
		want   string
	}{
		"one cycle":             {func(r *BillingRetentionConfig) { r.MinSettlementCycles = 1 }, "min_settlement_cycles"},
		"zero batch":            {func(r *BillingRetentionConfig) { r.BatchSize = 0 }, "batch_size"},
		"relative dir":          {func(r *BillingRetentionConfig) { r.ArchiveDir = "archive" }, "archive_dir"},
		"negative free bytes":   {func(r *BillingRetentionConfig) { r.ArchiveMinFreeBytes = -1 }, "archive_min_free_bytes"},
		"free percent too high": {func(r *BillingRetentionConfig) { r.ArchiveMinFreePercent = 91 }, "archive_min_free_percent"},
		"relative verify cmd":   {func(r *BillingRetentionConfig) { r.OffhostVerifyCommand = []string{"verify.sh"} }, "offhost_verify_command[0]"},
		"empty verify argument": {func(r *BillingRetentionConfig) { r.OffhostVerifyCommand = []string{"/usr/bin/true", " "} }, "empty arguments"},
		"zero verify timeout":   {func(r *BillingRetentionConfig) { r.OffhostVerifyTimeoutSeconds = 0 }, "offhost_verify_timeout_seconds"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := Default()
			tc.mutate(&cfg.Billing.Retention)
			err := cfg.validateBillingRetention()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err=%v want %q", err, tc.want)
			}
		})
	}
	cfg := Default()
	cfg.Billing.Retention.ArchiveDir = "/var/lib/macprovider/evidence-archive"
	cfg.Billing.Retention.OffhostVerifyCommand = []string{"/usr/local/bin/verify-archive"}
	if err := cfg.validateBillingRetention(); err != nil {
		t.Fatalf("enabled retention invalid: %v", err)
	}
}
