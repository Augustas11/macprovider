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

func TestAccountAdmissionDefaults(t *testing.T) {
	cfg := Default()
	if cfg.Quotas.AccountConcurrency != 4 {
		t.Fatalf("AccountConcurrency=%d want 4", cfg.Quotas.AccountConcurrency)
	}
	if cfg.Quotas.AccountRequestRatePerSecond != 30 {
		t.Fatalf("AccountRequestRatePerSecond=%d want 30", cfg.Quotas.AccountRequestRatePerSecond)
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

// Validate must reject configs where CoordinatorHeaderTimeoutSeconds is
// below CoordinatorRequestSeconds — this is the runtime backstop for the
// deploy-time check-deploy-config.sh C2b gate. A gateway started outside
// the deploy gate (direct `gateway -config` / `gateway -check`) MUST
// still refuse the unsafe relation.
func TestValidateRejectsHeaderTimeoutBelowRequestBudget(t *testing.T) {
	cfg := validTestConfig()
	cfg.Timeouts.CoordinatorRequestSeconds = 400
	cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 60
	err := cfg.Validate()
	if err == nil {
		t.Fatal("Validate() accepted header=60 < request=400; expected rejection per post-#92 SPEC-002 FR-P11a")
	}
	for _, want := range []string{"coordinator_header_timeout_seconds", "coordinator_request_seconds", "SPEC-002 FR-P11a"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("Validate() error = %q, missing substring %q (diagnostic must name both fields + spec ref)", err.Error(), want)
		}
	}
}

// Validate must accept the canonical case where the two timeouts are equal.
func TestValidateAcceptsEqualHeaderAndRequestTimeout(t *testing.T) {
	cfg := validTestConfig() // both default to 300
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() rejected default config (both timeouts = 300): %v", err)
	}
}

func TestSettlementReconcileDefaults(t *testing.T) {
	cfg := Default()
	if !cfg.Settlement.ReconcileEnabled {
		t.Fatal("Settlement.ReconcileEnabled=false want true")
	}
	if cfg.Settlement.ReconcileIntervalSeconds != 30 {
		t.Fatalf("ReconcileIntervalSeconds=%d want 30", cfg.Settlement.ReconcileIntervalSeconds)
	}
	if cfg.Settlement.ReconcileBatchLimit != 100 {
		t.Fatalf("ReconcileBatchLimit=%d want 100", cfg.Settlement.ReconcileBatchLimit)
	}
	if cfg.Settlement.ReconcileRequestTimeoutSeconds != 10 {
		t.Fatalf("ReconcileRequestTimeoutSeconds=%d want 10", cfg.Settlement.ReconcileRequestTimeoutSeconds)
	}
}

func TestSettlementReconcileConfigValidation(t *testing.T) {
	for name, tc := range map[string]struct {
		mutate func(*Config)
		want   string
	}{
		"disabled reconciler": {
			mutate: func(cfg *Config) { cfg.Settlement.ReconcileEnabled = false },
			want:   "settlement.reconcile_enabled must be true",
		},
		"zero interval": {
			mutate: func(cfg *Config) { cfg.Settlement.ReconcileIntervalSeconds = 0 },
			want:   "settlement.reconcile_interval_s must be > 0",
		},
		"zero batch": {
			mutate: func(cfg *Config) { cfg.Settlement.ReconcileBatchLimit = 0 },
			want:   "settlement.reconcile_batch_limit must be between 1 and 500",
		},
		"oversized batch": {
			mutate: func(cfg *Config) { cfg.Settlement.ReconcileBatchLimit = 501 },
			want:   "settlement.reconcile_batch_limit must be between 1 and 500",
		},
		"zero request timeout": {
			mutate: func(cfg *Config) { cfg.Settlement.ReconcileRequestTimeoutSeconds = 0 },
			want:   "settlement.reconcile_request_timeout_s must be > 0",
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

func TestAccountRequestRateConfigValidation(t *testing.T) {
	cfg := validTestConfig()
	cfg.Quotas.AccountRequestRatePerSecond = 0
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "quotas.account_request_rate_per_second must be positive") {
		t.Fatalf("Validate error=%v", err)
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
