package config

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// TestLoadResolvesEnvOperatorKey verifies env:NAME indirection on
// auth.operator_key resolves at Load time against the process
// environment (M3-2 / DEVE-7).
func TestLoadResolvesEnvOperatorKey(t *testing.T) {
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "0123456789abcdefABCDEFghijklmnop")

	cfg := writeMinimalConfig(t, `
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
`)
	if cfg.Auth.OperatorKey != "0123456789abcdefABCDEFghijklmnop" {
		t.Fatalf("OperatorKey=%q want %q", cfg.Auth.OperatorKey, "0123456789abcdefABCDEFghijklmnop")
	}
}

// TestLoadFailsClosedOnEmptyEnv verifies that env:NAME pointing at an
// unset variable returns a config-load error rather than silently
// resolving to "". Silent fall-through would let the coordinator boot
// with an empty bearer credential on the internal-bearer path.
func TestLoadFailsClosedOnEmptyEnv(t *testing.T) {
	os.Unsetenv("M3_2_TEST_MISSING")

	_, err := loadConfigFromYAML(t, `
auth:
  operator_key: env:M3_2_TEST_MISSING
`)
	if err == nil || !strings.Contains(err.Error(), "M3_2_TEST_MISSING") {
		t.Fatalf("expected env-missing error, got %v", err)
	}
	if !strings.Contains(err.Error(), "unset or empty") {
		t.Fatalf("error should mention unset/empty, got %v", err)
	}
}

// TestLoadResolvesEnvGatewayServiceToken covers the new
// gateway_service_token field on the same env:NAME pathway.
func TestLoadResolvesEnvGatewayServiceToken(t *testing.T) {
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "0123456789abcdefABCDEFghijklmnop")
	t.Setenv("M3_2_TEST_GATEWAY_TOKEN", "gateway-secret")

	cfg := writeMinimalConfig(t, `
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
  gateway_service_token: env:M3_2_TEST_GATEWAY_TOKEN
`)
	if cfg.Auth.OperatorKey != "0123456789abcdefABCDEFghijklmnop" {
		t.Fatalf("OperatorKey=%q", cfg.Auth.OperatorKey)
	}
	if cfg.Auth.GatewayServiceToken != "gateway-secret" {
		t.Fatalf("GatewayServiceToken=%q", cfg.Auth.GatewayServiceToken)
	}
}

// TestLoadResolvesEnvStatsDSNs locks the SPEC-017 deployment path:
// stats runtime DSNs may be env-indirected and resolve before
// stats.enabled validation runs.
func TestLoadResolvesEnvStatsDSNs(t *testing.T) {
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "0123456789abcdefABCDEFghijklmnop")
	t.Setenv("TEST_STATS_READER_DSN", "postgres://reader@localhost/macprovider")
	t.Setenv("TEST_STATS_ROLLUP_DSN", "postgres://rollup@localhost/macprovider")

	cfg := writeMinimalConfig(t, `
listen:
  bind_address: "127.0.0.1"
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
stats:
  enabled: true
  reader_dsn: env:TEST_STATS_READER_DSN
  rollup_dsn: env:TEST_STATS_ROLLUP_DSN
  rollup:
    backfill_mode: "full"
`)
	if cfg.Stats.ReaderDSN != "postgres://reader@localhost/macprovider" {
		t.Fatalf("Stats.ReaderDSN=%q", cfg.Stats.ReaderDSN)
	}
	if cfg.Stats.RollupDSN != "postgres://rollup@localhost/macprovider" {
		t.Fatalf("Stats.RollupDSN=%q", cfg.Stats.RollupDSN)
	}
}

// TestLoadFailsClosedOnMissingStatsEnvDSN ensures stats cutovers fail
// before boot when a required env-indirected DSN is absent.
func TestLoadFailsClosedOnMissingStatsEnvDSN(t *testing.T) {
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "0123456789abcdefABCDEFghijklmnop")
	os.Unsetenv("TEST_STATS_MISSING_READER_DSN")

	_, err := loadConfigFromYAML(t, `
listen:
  bind_address: "127.0.0.1"
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
stats:
  enabled: true
  reader_dsn: env:TEST_STATS_MISSING_READER_DSN
  rollup_dsn: postgres://rollup@localhost/macprovider
`)
	if err == nil {
		t.Fatal("expected missing stats env DSN error")
	}
	if !strings.Contains(err.Error(), "stats.reader_dsn") || !strings.Contains(err.Error(), "TEST_STATS_MISSING_READER_DSN") {
		t.Fatalf("error should name stats.reader_dsn and env var, got %v", err)
	}
	if !strings.Contains(err.Error(), "unset or empty") {
		t.Fatalf("error should mention unset/empty, got %v", err)
	}
}

// TestDeployCoordinatorYAMLLoadsWithStatsEnv is the production-config
// regression for the Malibu stats rollout. It proves dist/coordinator.yaml
// can pass config load with stats enabled when Pearl's env file provides
// the required values, and that Malibu's browser origin is allowlisted.
func TestDeployCoordinatorYAMLLoadsWithStatsEnv(t *testing.T) {
	t.Setenv("OPERATOR_KEY", "0123456789abcdefABCDEFghijklmnop")
	t.Setenv("GATEWAY_SERVICE_TOKEN", "gateway-secret")
	t.Setenv("OPERATOR_AUTH_POLICY_A", "0123456789abcdefABCDEFghijklmnop")
	t.Setenv("OPERATOR_AUTH_POLICY_B", "fedcba9876543210PONMLKJIHGFEDCBA")
	t.Setenv("STATS_READER_DSN", "postgres://reader@localhost/macprovider")
	t.Setenv("STATS_ROLLUP_DSN", "postgres://rollup@localhost/macprovider")
	t.Setenv("ONBOARDING_POSTGRES_DSN", "postgres://onboarding@localhost/macprovider")
	t.Setenv("ONBOARDING_AUTH_POLICY_REQUEST_DSN", "postgres://requester@localhost/macprovider")
	t.Setenv("ONBOARDING_AUTH_POLICY_APPROVE_DSN", "postgres://approver@localhost/macprovider")
	t.Setenv("ONBOARDING_AUTH_POLICY_CUTOVER_DSN", "postgres://cutover@localhost/macprovider")
	t.Setenv("ONBOARDING_HARDWARE_TRUST_REQUEST_DSN", "postgres://hwtrust_requester@localhost/macprovider")
	t.Setenv("ONBOARDING_HARDWARE_TRUST_APPROVE_DSN", "postgres://hwtrust_approver@localhost/macprovider")
	t.Setenv("APPLE_TEAM_ID", "TEAMID1234")
	t.Setenv("MODEL_HASH_LEGACY_UNTIL", "2099-07-19T00:00:00Z")

	cfg, err := Load(filepath.Join("..", "..", "dist", "coordinator.yaml"))
	if err != nil {
		t.Fatalf("Load dist/coordinator.yaml: %v", err)
	}
	if !cfg.Stats.Enabled {
		t.Fatal("Stats.Enabled=false, want true")
	}
	if cfg.Stats.ReaderDSN != "postgres://reader@localhost/macprovider" {
		t.Fatalf("Stats.ReaderDSN=%q", cfg.Stats.ReaderDSN)
	}
	if cfg.Stats.RollupDSN != "postgres://rollup@localhost/macprovider" {
		t.Fatalf("Stats.RollupDSN=%q", cfg.Stats.RollupDSN)
	}
	if cfg.Tier2.ModelHashLegacyUntil != "" {
		t.Fatalf(
			"production config unexpectedly activated the model-hash legacy bridge from ambient env: %q",
			cfg.Tier2.ModelHashLegacyUntil,
		)
	}
	if !cfg.Tier2.RequireHashVerified {
		t.Fatal("production config Tier2.RequireHashVerified=false, want true")
	}
	if !slices.Contains(cfg.Stats.CORS.PartnerOriginAllowlist, "https://www.malibu.tech") {
		t.Fatalf("Malibu origin missing from stats CORS allowlist: %#v", cfg.Stats.CORS.PartnerOriginAllowlist)
	}
	if got, want := cfg.Stats.PartnerKeys.ProductionSignoffPath, "/opt/macprovider/spec017-signoff.txt"; got != want {
		t.Fatalf("ProductionSignoffPath=%q want %q", got, want)
	}
	nemotron, ok := cfg.Rewards.RateCard["nemotron-3-nano-30b-a3b"]
	if !ok {
		t.Fatal("nemotron rate-card row missing")
	}
	if nemotron.PromptCreditsPerMtok != 80000 ||
		nemotron.EffectivePromptCacheHitCreditsPerMtok() != 20000 ||
		nemotron.CompletionCreditsPerMtok != 160000 {
		t.Fatalf("unexpected nemotron rate-card row: %+v", nemotron)
	}
}

func TestLoadRejectsWeakEnvNamedOperatorKey(t *testing.T) {
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "0123456789abcdefABCDEFghijklmnop")
	t.Setenv("M3_2_TEST_WEAK_OPERATOR_A", "changeme")
	t.Setenv("M3_2_TEST_STRONG_OPERATOR_B", "fedcba9876543210PONMLKJIHGFEDCBA")

	_, err := loadConfigFromYAML(t, `
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
  operator_keys:
    alice: env:M3_2_TEST_WEAK_OPERATOR_A
    bob: env:M3_2_TEST_STRONG_OPERATOR_B
`)
	if err == nil {
		t.Fatal("Load accepted weak env-indirected named operator key")
	}
	if !strings.Contains(err.Error(), "auth.operator_keys.alice") || !strings.Contains(err.Error(), "placeholder_denied") {
		t.Fatalf("error should name weak env-indirected operator key, got %v", err)
	}
}

// writeMinimalConfig writes a YAML fragment that already satisfies
// Validate() (defaults + a non-empty operator_key) and Loads it.
// Fails the test on any error so callers can check the post-condition.
func writeMinimalConfig(t *testing.T, fragment string) Config {
	t.Helper()
	cfg, err := loadConfigFromYAML(t, fragment)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	return cfg
}

func loadConfigFromYAML(t *testing.T, fragment string) (Config, error) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "coordinator.yaml")
	if err := os.WriteFile(path, []byte(fragment), 0o600); err != nil {
		t.Fatalf("write tmp yaml: %v", err)
	}
	return Load(path)
}
