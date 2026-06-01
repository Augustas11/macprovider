package config

import (
	"strings"
	"testing"
)

func TestAC01_ExplorerDefaults(t *testing.T) {
	cfg := Default()
	ex := cfg.Explorer

	if ex.Enabled {
		t.Fatalf("explorer.enabled default = true, want false")
	}
	if ex.BindPath != "/admin/explorer/" {
		t.Fatalf("explorer.bind_path=%q", ex.BindPath)
	}
	if ex.GatewayTimeoutMs != 1500 || ex.QueryTimeoutMs != 3000 {
		t.Fatalf("unexpected explorer timeouts: %+v", ex)
	}
	if ex.PollMinIntervalSeconds != 5 || ex.RequestsPerMinuteCap != 60 {
		t.Fatalf("unexpected explorer polling defaults: %+v", ex)
	}
	if ex.ActivityMaxWindowDays != 7 || ex.ActivityDefaultWindowHours != 24 ||
		ex.BuyersMaxWindowDays != 31 || ex.BuyersDefaultWindowHours != 168 ||
		ex.LedgerMaxWindowDays != 31 || ex.LedgerDefaultWindowHours != 168 ||
		ex.SessionsMaxWindowDays != 7 || ex.SessionsDefaultWindowHours != 24 ||
		ex.SettlementsMaxWindowDays != 180 || ex.SettlementsDefaultWindowHours != 720 {
		t.Fatalf("unexpected explorer window defaults: %+v", ex)
	}
}

func TestAC02_ExplorerValidation(t *testing.T) {
	for name, tc := range map[string]struct {
		mutate func(*Config)
		want   string
	}{
		"bad bind prefix": {
			mutate: func(cfg *Config) { cfg.Explorer.BindPath = "/operator/explorer/" },
			want:   "explorer.bind_path",
		},
		"bad bind suffix": {
			mutate: func(cfg *Config) { cfg.Explorer.BindPath = "/admin/explorer" },
			want:   "explorer.bind_path",
		},
		"activity max low": {
			mutate: func(cfg *Config) { cfg.Explorer.ActivityMaxWindowDays = 0 },
			want:   "explorer.activity_max_window_days",
		},
		"settlements max low": {
			mutate: func(cfg *Config) { cfg.Explorer.SettlementsMaxWindowDays = 30 },
			want:   "explorer.settlements_max_window_days",
		},
		"default exceeds max": {
			mutate: func(cfg *Config) { cfg.Explorer.SessionsDefaultWindowHours = 169 },
			want:   "explorer.sessions_default_window_hours",
		},
		"gateway timeout low": {
			mutate: func(cfg *Config) { cfg.Explorer.GatewayTimeoutMs = 99 },
			want:   "explorer.gateway_timeout_ms",
		},
		"query timeout high": {
			mutate: func(cfg *Config) { cfg.Explorer.QueryTimeoutMs = 30001 },
			want:   "explorer.query_timeout_ms",
		},
		"poll interval high": {
			mutate: func(cfg *Config) { cfg.Explorer.PollMinIntervalSeconds = 61 },
			want:   "explorer.poll_min_interval_seconds",
		},
		"rpm cap high": {
			mutate: func(cfg *Config) { cfg.Explorer.RequestsPerMinuteCap = 601 },
			want:   "explorer.requests_per_minute_cap",
		},
		"bad gateway url": {
			mutate: func(cfg *Config) {
				cfg.Explorer.Enabled = true
				cfg.Explorer.GatewayBaseURL = "ftp://gateway"
			},
			want: "explorer.gateway_base_url",
		},
	} {
		t.Run(name, func(t *testing.T) {
			cfg := Default()
			cfg.Auth.OperatorKey = "operator-key"
			tc.mutate(&cfg)
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Validate error=%v want containing %q", err, tc.want)
			}
		})
	}
}

func TestAC03_ExplorerAllowsEmptyGatewayBaseURLWhenEnabled(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "operator-key"
	cfg.Explorer.Enabled = true
	cfg.Explorer.GatewayBaseURL = ""

	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() with empty explorer.gateway_base_url: %v", err)
	}
}
