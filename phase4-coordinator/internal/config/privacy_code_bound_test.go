package config

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestPrivacyCodeBoundDefaultOff(t *testing.T) {
	cfg := Default()
	if cfg.PrivacyClass.CodeBound.Enabled || cfg.PrivacyClass.CodeBound.TeamID != "" || cfg.PrivacyClass.CodeBound.MaxEnrollmentsPerProviderPerDay != 3 {
		t.Fatalf("code_bound defaults = %+v", cfg.PrivacyClass.CodeBound)
	}
	merged := Default()
	if err := yaml.Unmarshal([]byte("privacy_class:\n  code_bound:\n    team_id: ABCDE12345\n"), &merged); err != nil {
		t.Fatal(err)
	}
	if merged.PrivacyClass.CodeBound.Enabled || merged.PrivacyClass.CodeBound.MaxEnrollmentsPerProviderPerDay != 3 || merged.PrivacyClass.CodeBound.TeamID != "ABCDE12345" {
		t.Fatalf("partial yaml = %+v", merged.PrivacyClass.CodeBound)
	}
	// A disabled block never blocks startup, even when incomplete.
	off := validTestConfig()
	off.PrivacyClass.CodeBound = PrivacyCodeBoundConfig{TeamID: "bad", MaxEnrollmentsPerProviderPerDay: 0}
	if err := off.Validate(); err != nil {
		t.Fatalf("disabled code_bound validated: %v", err)
	}
}

func TestPrivacyCodeBoundValidation(t *testing.T) {
	ready := func(t *testing.T) Config {
		cfg := privacyReadyConfig(t)
		cfg.PrivacyClass.Enabled = true
		cfg.PrivacyClass.CodeBound = PrivacyCodeBoundConfig{Enabled: true, TeamID: "ABCDE12345", MaxEnrollmentsPerProviderPerDay: 3}
		return cfg
	}
	if err := ready(t).Validate(); err != nil {
		t.Fatal(err)
	}
	for _, bound := range []int{1, 10} {
		cfg := ready(t)
		cfg.PrivacyClass.CodeBound.MaxEnrollmentsPerProviderPerDay = bound
		if err := cfg.Validate(); err != nil {
			t.Fatalf("bound %d: %v", bound, err)
		}
	}
	cases := map[string]struct {
		mutate func(*Config)
		want   string
	}{
		"requires privacy class": {func(c *Config) { c.PrivacyClass.Enabled = false }, "requires privacy_class.enabled"},
		"missing team":           {func(c *Config) { c.PrivacyClass.CodeBound.TeamID = "" }, "code_bound.team_id"},
		"lowercase team":         {func(c *Config) { c.PrivacyClass.CodeBound.TeamID = "abcde12345" }, "code_bound.team_id"},
		"short team":             {func(c *Config) { c.PrivacyClass.CodeBound.TeamID = "ABCDE1234" }, "code_bound.team_id"},
		"zero enrollments":       {func(c *Config) { c.PrivacyClass.CodeBound.MaxEnrollmentsPerProviderPerDay = 0 }, "max_enrollments_per_provider_per_day"},
		"eleven enrollments":     {func(c *Config) { c.PrivacyClass.CodeBound.MaxEnrollmentsPerProviderPerDay = 11 }, "max_enrollments_per_provider_per_day"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := ready(t)
			tc.mutate(&cfg)
			if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate = %v, want %q", err, tc.want)
			}
		})
	}
}
