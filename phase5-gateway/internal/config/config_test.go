package config

import (
	"strings"
	"testing"
)

func TestQuotaReaperDefaults(t *testing.T) {
	cfg := Default()
	if cfg.Quotas.ReaperIntervalHours != 1 {
		t.Fatalf("ReaperIntervalHours=%d want 1", cfg.Quotas.ReaperIntervalHours)
	}
	if cfg.Quotas.ReservationMaxAgeHours != 24 {
		t.Fatalf("ReservationMaxAgeHours=%d want 24", cfg.Quotas.ReservationMaxAgeHours)
	}
}

func TestQuotaReaperConfigValidation(t *testing.T) {
	for name, tc := range map[string]struct {
		mutate func(*Config)
		want   string
	}{
		"zero reaper interval": {
			mutate: func(cfg *Config) { cfg.Quotas.ReaperIntervalHours = 0 },
			want:   "quotas.reaper_interval_hours must be >= 1",
		},
		"short reservation max age": {
			mutate: func(cfg *Config) { cfg.Quotas.ReservationMaxAgeHours = 1 },
			want:   "quotas.reservation_max_age_hours must be >= 2",
		},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := validTestConfig()
			tc.mutate(&cfg)
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate error=%v want containing %q", err, tc.want)
			}
		})
	}
}

func validTestConfig() Config {
	cfg := Default()
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Auth.KeyHashSecret = "key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "demo-secret"
	cfg.Auth.OAuth.GitHub.ClientID = "client-id"
	cfg.Auth.OAuth.GitHub.ClientSecret = "client-secret"
	return cfg
}
