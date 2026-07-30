package config

import (
	"os"
	"strings"
	"testing"
	"time"
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

// Post-#92 (PR #167), retargeted after #760/#784: header timeout must cover
// the admission phase so a slow first-event stream does not false-fail before
// the configured pre-header budget expires. See SPEC-002 FR-P11a C2b +
// check-deploy-config.sh C2b.
func TestGatewayHeaderTimeoutDefaultCoversAdmissionBudget(t *testing.T) {
	cfg := Default()
	if cfg.Timeouts.CoordinatorHeaderTimeoutSeconds < cfg.Timeouts.CoordinatorAdmissionSeconds {
		t.Fatalf("CoordinatorHeaderTimeoutSeconds=%d MUST be >= CoordinatorAdmissionSeconds=%d (post-#92/#760: streaming headers don't commit until first valid SSE event)",
			cfg.Timeouts.CoordinatorHeaderTimeoutSeconds, cfg.Timeouts.CoordinatorAdmissionSeconds)
	}
}

func TestStreamingIdleTimeoutDefaultTerminatesBeforeBuyerHarnessTimeout(t *testing.T) {
	cfg := Default()
	if cfg.Timeouts.StreamingIdleMS != 10000 {
		t.Fatalf("StreamingIdleMS=%d want 10000", cfg.Timeouts.StreamingIdleMS)
	}
	if got := cfg.StreamingIdleTimeout().Milliseconds(); got != int64(cfg.Timeouts.StreamingIdleMS) {
		t.Fatalf("StreamingIdleTimeout=%dms want %dms", got, cfg.Timeouts.StreamingIdleMS)
	}
}

// Validate must reject configs where CoordinatorHeaderTimeoutSeconds is below
// CoordinatorAdmissionSeconds — this is the runtime backstop for the deploy-time
// check-deploy-config.sh C2b gate. A gateway started outside the deploy gate
// (direct `gateway -config` / `gateway -check`) MUST still refuse the unsafe
// relation.
func TestValidateRejectsHeaderTimeoutBelowAdmissionBudget(t *testing.T) {
	cfg := validTestConfig()
	cfg.Timeouts.CoordinatorAdmissionSeconds = 400
	cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 60
	err := cfg.Validate()
	if err == nil {
		t.Fatal("Validate() accepted header=60 < admission=400; expected rejection per SPEC-002 FR-P11a C2b")
	}
	for _, want := range []string{"coordinator_header_timeout_seconds", "coordinator_admission_seconds", "SPEC-002 FR-P11a"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("Validate() error = %q, missing substring %q (diagnostic must name both fields + spec ref)", err.Error(), want)
		}
	}
}

func TestValidateRejectsInheritedNonStreamBudgetAboveHeader(t *testing.T) {
	cfg := validTestConfig()
	cfg.Timeouts.CoordinatorRequestSeconds = 600
	cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 300
	cfg.Timeouts.CoordinatorAdmissionSeconds = 120
	cfg.Timeouts.StreamCeilingMaxSeconds = 900
	err := cfg.Validate()
	if err == nil {
		t.Fatal("Validate() accepted header=300 < inherited non-stream wall=600; expected rejection per SPEC-002 FR-P11a C2b")
	}
	for _, want := range []string{"coordinator_header_timeout_seconds", "non_stream_request_seconds", "SPEC-002 FR-P11a"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("Validate() error = %q, missing substring %q", err.Error(), want)
		}
	}
}

func TestValidateAllowsExplicitNonStreamBudgetWithinHeader(t *testing.T) {
	cfg := validTestConfig()
	cfg.Timeouts.CoordinatorRequestSeconds = 600
	cfg.Timeouts.NonStreamRequestSeconds = 300
	cfg.Timeouts.CoordinatorHeaderTimeoutSeconds = 300
	cfg.Timeouts.CoordinatorAdmissionSeconds = 120
	cfg.Timeouts.StreamCeilingMaxSeconds = 900
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() rejected explicit non-stream=300 with header=300 and stream ceiling=900: %v", err)
	}
}

// TestValidateRejectsWhitespaceEquivalentServiceToken pins the audit-r2
// whitespace-bypass fix: the coordinator's BearerTokenMatchesHeader trims
// both sides before matching, so "X" and "X " collapse on the wire.
// Validate must reject the collision instead of a strict == that misses it.
func TestValidateRejectsWhitespaceEquivalentServiceToken(t *testing.T) {
	for _, tc := range []struct {
		name    string
		op, svc string
	}{
		{"trailing space", "operator-key", "operator-key "},
		{"leading space", "operator-key", " operator-key"},
		{"trailing newline", "operator-key", "operator-key\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.Coordinator.OperatorKey = tc.op
			cfg.Coordinator.ServiceToken = tc.svc
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), "must differ from coordinator.operator_key") {
				t.Fatalf("Validate err=%v want distinctness rejection", err)
			}
		})
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

// TestSettlementJournalDefaults pins the #763 defaults, and with them the
// BACK-COMPAT contract: Validate REQUIRES journal_enabled and journal_fsync,
// so both must default to true or every pre-#763 gateway.yaml (which sets no
// journal keys at all) would refuse to boot.
func TestSettlementJournalDefaults(t *testing.T) {
	cfg := Default()
	if !cfg.Settlement.JournalEnabled {
		t.Fatal("Settlement.JournalEnabled=false want true — a false default would break every existing config")
	}
	if !cfg.Settlement.JournalFsync {
		t.Fatal("Settlement.JournalFsync=false want true")
	}
	if cfg.Settlement.JournalSegmentMaxBytes != 16<<20 {
		t.Fatalf("JournalSegmentMaxBytes=%d want 16MiB", cfg.Settlement.JournalSegmentMaxBytes)
	}
	if cfg.Settlement.JournalMaxTotalBytes != 512<<20 {
		t.Fatalf("JournalMaxTotalBytes=%d want 512MiB", cfg.Settlement.JournalMaxTotalBytes)
	}
	if cfg.Settlement.JournalRetentionHours != 168 {
		t.Fatalf("JournalRetentionHours=%d want 168", cfg.Settlement.JournalRetentionHours)
	}
	if cfg.Settlement.JournalRecoveryIntervalSeconds != 30 {
		t.Fatalf("JournalRecoveryIntervalSeconds=%d want 30", cfg.Settlement.JournalRecoveryIntervalSeconds)
	}
	if cfg.Settlement.JournalRecoveryBatchLimit != 100 {
		t.Fatalf("JournalRecoveryBatchLimit=%d want 100", cfg.Settlement.JournalRecoveryBatchLimit)
	}
	if cfg.Settlement.JournalRecoveryGraceSeconds != 60 {
		t.Fatalf("JournalRecoveryGraceSeconds=%d want 60", cfg.Settlement.JournalRecoveryGraceSeconds)
	}
	// A zero-value journal_dir derives a sibling of the sqlite file, so the
	// journal always lands on the same volume as the DB it protects.
	cfg.Storage.DBPath = "/var/lib/macprovider/gateway.db"
	if got := cfg.SettlementJournalDir(); got != "/var/lib/macprovider/settlement-journal" {
		t.Fatalf("SettlementJournalDir()=%q want the sqlite sibling", got)
	}
	cfg.Settlement.JournalDir = "/mnt/journal"
	if got := cfg.SettlementJournalDir(); got != "/mnt/journal" {
		t.Fatalf("SettlementJournalDir()=%q want the explicit override", got)
	}
}

// TestSettlementJournalConfigBackCompat drives the real Load() path over a
// config that predates #763: it must boot, with the journal on.
func TestSettlementJournalConfigBackCompat(t *testing.T) {
	yaml := `
listen:
  bind_address: 127.0.0.1
  port: 9443
public:
  base_url: https://api.streamvc.live
  account_path: /account
coordinator:
  buyer_url: http://127.0.0.1:8443
  operator_url: http://127.0.0.1:8444
  operator_key: operator-key
  service_token: service-token
  poolz_poll_interval_s: 10
storage:
  driver: sqlite
  db_path: /var/lib/macprovider/gateway.db
auth:
  key_hash_secret: secret
  github_oauth_enabled: false
  demo:
    signing_secret: demo-secret
settlement:
  reconcile_enabled: true
  reconcile_interval_s: 30
  reconcile_batch_limit: 100
  reconcile_request_timeout_s: 10
`
	path := t.TempDir() + "/gateway.yaml"
	if err := os.WriteFile(path, []byte(yaml), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("a pre-#763 config must still load: %v", err)
	}
	if !cfg.Settlement.JournalEnabled || !cfg.Settlement.JournalFsync {
		t.Fatalf("journal defaults lost on a partial settlement block: %+v", cfg.Settlement)
	}
	if cfg.Settlement.ReconcileIntervalSeconds != 30 {
		t.Fatalf("explicit reconcile keys were clobbered: %+v", cfg.Settlement)
	}
	if got := cfg.SettlementJournalDir(); got != "/var/lib/macprovider/settlement-journal" {
		t.Fatalf("derived journal dir=%q", got)
	}
}

func TestSettlementJournalConfigValidation(t *testing.T) {
	for name, tc := range map[string]struct {
		mutate func(*Config)
		want   string
	}{
		"disabled journal": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalEnabled = false },
			want:   "settlement.journal_enabled must be true",
		},
		"fsync off": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalFsync = false },
			want:   "settlement.journal_fsync must be true",
		},
		"zero segment cap": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalSegmentMaxBytes = 0 },
			want:   "settlement.journal_segment_max_bytes must be > 0",
		},
		"total cap below segment cap": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalMaxTotalBytes = 1 << 10 },
			want:   "settlement.journal_max_total_bytes",
		},
		"zero retention": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalRetentionHours = 0 },
			want:   "settlement.journal_retention_hours must be > 0",
		},
		"zero recovery interval": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalRecoveryIntervalSeconds = 0 },
			want:   "settlement.journal_recovery_interval_s must be > 0",
		},
		"oversized recovery batch": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalRecoveryBatchLimit = 501 },
			want:   "settlement.journal_recovery_batch_limit must be between 1 and 500",
		},
		"negative grace": {
			mutate: func(cfg *Config) { cfg.Settlement.JournalRecoveryGraceSeconds = -1 },
			want:   "settlement.journal_recovery_grace_s must be >= 0",
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
	// Post-PR #87 item 3: service_token is required for /internal/*
	// upstream calls; Validate() now rejects empty.
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Auth.KeyHashSecret = "key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "demo-secret"
	cfg.Auth.OAuth.GitHub.ClientID = "client-id"
	cfg.Auth.OAuth.GitHub.ClientSecret = "client-secret"
	return cfg
}

// ---- issue #760: per-phase deadline config --------------------------------

func TestPhaseDeadlineDefaults(t *testing.T) {
	cfg := Default()
	for _, tc := range []struct {
		name string
		got  int
		want int
	}{
		{"coordinator_connect_seconds", cfg.Timeouts.CoordinatorConnectSeconds, 60},
		{"coordinator_admission_seconds", cfg.Timeouts.CoordinatorAdmissionSeconds, 120},
		{"first_token_seconds", cfg.Timeouts.FirstTokenSeconds, 0},
		{"stream_ceiling_floor_seconds", cfg.Timeouts.StreamCeilingFloorSeconds, 60},
		{"stream_ceiling_per_token_ms", cfg.Timeouts.StreamCeilingPerTokenMS, 250},
		{"stream_ceiling_max_seconds", cfg.Timeouts.StreamCeilingMaxSeconds, 900},
		{"non_stream_request_seconds", cfg.Timeouts.NonStreamRequestSeconds, 0},
	} {
		if tc.got != tc.want {
			t.Errorf("%s=%d want %d", tc.name, tc.got, tc.want)
		}
	}
	// The non-streaming wall must stay at the legacy flat wall so #760 is a
	// no-op on that path.
	if cfg.NonStreamRequestTimeout() != cfg.CoordinatorTimeout() {
		t.Errorf("NonStreamRequestTimeout=%s must equal the legacy CoordinatorTimeout=%s (no behavior change on the non-streaming path)",
			cfg.NonStreamRequestTimeout(), cfg.CoordinatorTimeout())
	}
	// Unset non_stream_request_seconds must INHERIT an operator-raised legacy
	// wall, not silently regress it to the compiled default (#760 audit,
	// architect lane: a pre-#760 config setting only
	// coordinator_request_seconds: 600 must keep 600s non-streaming).
	inherited := cfg
	inherited.Timeouts.CoordinatorRequestSeconds = 600
	if got := inherited.NonStreamRequestTimeout(); got != 600*time.Second {
		t.Errorf("NonStreamRequestTimeout with only coordinator_request_seconds raised = %s, want 600s (inherit)", got)
	}
	explicit := cfg
	explicit.Timeouts.CoordinatorRequestSeconds = 600
	explicit.Timeouts.NonStreamRequestSeconds = 300
	if got := explicit.NonStreamRequestTimeout(); got != 300*time.Second {
		t.Errorf("explicit non_stream_request_seconds must win over inheritance, got %s want 300s", got)
	}
	// Unset first_token_seconds derives min(120s, header timeout) so a
	// short-header config gets a coherent accessor value. Validate separately
	// rejects values below the admission phase budget.
	if got := cfg.FirstTokenTimeout(); got != 120*time.Second {
		t.Errorf("derived FirstTokenTimeout=%s want 120s under the default header timeout", got)
	}
	shortHeader := cfg
	shortHeader.Timeouts.CoordinatorHeaderTimeoutSeconds = 60
	if got := shortHeader.FirstTokenTimeout(); got != 60*time.Second {
		t.Errorf("derived FirstTokenTimeout=%s want 60s clamped to the header timeout", got)
	}
	explicitFT := cfg
	explicitFT.Timeouts.FirstTokenSeconds = 30
	if got := explicitFT.FirstTokenTimeout(); got != 30*time.Second {
		t.Errorf("explicit first_token_seconds must win over derivation, got %s want 30s", got)
	}
	if err := validTestConfig().Validate(); err != nil {
		t.Fatalf("default phase budgets must satisfy Validate(): %v", err)
	}
}

func TestValidateRejectsInconsistentPhaseDeadlines(t *testing.T) {
	for _, tc := range []struct {
		name    string
		mutate  func(*Config)
		wantSub string
	}{
		{
			name:    "admission below connect",
			mutate:  func(c *Config) { c.Timeouts.CoordinatorAdmissionSeconds = 30 },
			wantSub: "coordinator_admission_seconds",
		},
		{
			name:    "first token above header timeout",
			mutate:  func(c *Config) { c.Timeouts.FirstTokenSeconds = 600 },
			wantSub: "first_token_seconds",
		},
		{
			name:    "ceiling max below floor",
			mutate:  func(c *Config) { c.Timeouts.StreamCeilingFloorSeconds = 950 },
			wantSub: "stream_ceiling_floor_seconds",
		},
		{
			// Monotonicity invariant: an operator must not be able to make the
			// derived streaming ceiling SHORTER than the flat wall it replaced.
			name:    "ceiling max below legacy wall",
			mutate:  func(c *Config) { c.Timeouts.StreamCeilingMaxSeconds = 120 },
			wantSub: "stream_ceiling_max_seconds",
		},
		{
			name:    "non-stream wall below connect budget",
			mutate:  func(c *Config) { c.Timeouts.NonStreamRequestSeconds = 5 },
			wantSub: "non_stream_request_seconds",
		},
		{
			name:    "negative first token budget",
			mutate:  func(c *Config) { c.Timeouts.FirstTokenSeconds = -1 },
			wantSub: "phase budgets must be positive",
		},
		{
			name:    "zero phase budget",
			mutate:  func(c *Config) { c.Timeouts.CoordinatorConnectSeconds = 0 },
			wantSub: "phase budgets must be positive",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			tc.mutate(&cfg)
			err := cfg.Validate()
			if err == nil {
				t.Fatalf("Validate() accepted %s", tc.name)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("Validate() error = %q, want substring %q", err.Error(), tc.wantSub)
			}
		})
	}
}
