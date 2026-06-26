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

// Post-#92 (PR #167): header timeout must be >= the request budget so a
// slow-but-valid streaming first-event (or non-streaming completion)
// doesn't false-fail before the coordinator's own request_timeout_s
// runs out. See SPEC-002 v1.4.0 §FR-P11a + check-deploy-config.sh C2b.
func TestGatewayHeaderTimeoutDefaultCoversFullRequestBudget(t *testing.T) {
	cfg := Default()
	if cfg.Timeouts.CoordinatorHeaderTimeoutSeconds < cfg.Timeouts.CoordinatorRequestSeconds {
		t.Fatalf("CoordinatorHeaderTimeoutSeconds=%d MUST be >= CoordinatorRequestSeconds=%d (post-#92: streaming headers don't commit until first valid SSE event)",
			cfg.Timeouts.CoordinatorHeaderTimeoutSeconds, cfg.Timeouts.CoordinatorRequestSeconds)
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

func TestStickyRequiresKeyHashSecret(t *testing.T) {
	cfg := validTestConfig()
	cfg.Auth.KeyHash = "sha256"
	cfg.Auth.KeyHashSecret = ""
	cfg.Routing.StickyEnabled = true

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "auth.key_hash_secret must be set when routing.sticky_enabled is true") {
		t.Fatalf("Validate error=%v", err)
	}
}

func TestProxyTrustedCIDRValidation(t *testing.T) {
	cfg := validTestConfig()
	cfg.Proxy.TrustedCIDRs = nil
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "proxy.trusted_cidrs") {
		t.Fatalf("empty trusted CIDRs error=%v", err)
	}

	cfg = validTestConfig()
	cfg.Proxy.TrustedCIDRs = []string{"not-a-cidr"}
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "proxy.trusted_cidrs[0]") {
		t.Fatalf("invalid trusted CIDR error=%v", err)
	}

	cfg = validTestConfig()
	cfg.Proxy.TrustedCIDRs = []string{"127.0.0.1", "10.0.0.0/8", "::1/128"}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("valid trusted CIDRs error=%v", err)
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
