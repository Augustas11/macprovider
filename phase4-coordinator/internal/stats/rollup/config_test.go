package rollup

import (
	"testing"
	"time"
)

// TestConfigDefaultsApplied — every zero-value field gets a
// non-zero default per SPEC §9.2 / §9.3 / §9.4.
func TestConfigDefaultsApplied(t *testing.T) {
	c := Config{}.DefaultsApplied()
	if c.BackfillMode != "partial" {
		t.Errorf("BackfillMode default = %q, want partial", c.BackfillMode)
	}
	if c.UsdPerMillionCredits != 1.0 {
		t.Errorf("UsdPerMillionCredits default = %v, want 1.0", c.UsdPerMillionCredits)
	}
	if c.DriftThresholdRatio != 0.005 {
		t.Errorf("DriftThresholdRatio default = %v, want 0.005", c.DriftThresholdRatio)
	}
	if c.LateEventsLookbackHours != 48 {
		t.Errorf("LateEventsLookbackHours default = %v, want 48", c.LateEventsLookbackHours)
	}
	if c.LateEventsRetentionDays != 90 {
		t.Errorf("LateEventsRetentionDays default = %v, want 90", c.LateEventsRetentionDays)
	}
	if c.OverviewInterval != 30*time.Second {
		t.Errorf("OverviewInterval default = %v, want 30s", c.OverviewInterval)
	}
	if c.LeaderboardAllInterval != 6*time.Hour {
		t.Errorf("LeaderboardAllInterval default = %v, want 6h", c.LeaderboardAllInterval)
	}
}

// TestConfigValidate — each invariant exercised.
func TestConfigValidate(t *testing.T) {
	cases := []struct {
		name    string
		mutate  func(*Config)
		wantErr bool
	}{
		{"defaults_ok", func(c *Config) {}, false},
		{"bad_mode", func(c *Config) { c.BackfillMode = "bogus" }, true},
		{"negative_usd", func(c *Config) { c.UsdPerMillionCredits = -1 }, true},
		{"low_drift", func(c *Config) { c.DriftThresholdRatio = 0.0001 }, true},
		{"high_drift", func(c *Config) { c.DriftThresholdRatio = 0.1 }, true},
		{"bad_hour_low", func(c *Config) { c.NightlyRebuildHourUTC = -1 }, true},
		{"bad_hour_high", func(c *Config) { c.NightlyRebuildHourUTC = 24 }, true},
		{"low_lookback", func(c *Config) { c.LateEventsLookbackHours = 23 }, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := Config{}.DefaultsApplied()
			tc.mutate(&c)
			err := c.Validate()
			if tc.wantErr && err == nil {
				t.Errorf("Validate should have erred")
			}
			if !tc.wantErr && err != nil {
				t.Errorf("Validate unexpected err: %v", err)
			}
		})
	}
}
