package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestLoadResolvesEnvOperatorKey verifies env:NAME indirection on
// auth.operator_key resolves at Load time against the process
// environment (M3-2 / DEVE-7).
func TestLoadResolvesEnvOperatorKey(t *testing.T) {
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "resolved-secret")

	cfg := writeMinimalConfig(t, `
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
`)
	if cfg.Auth.OperatorKey != "resolved-secret" {
		t.Fatalf("OperatorKey=%q want %q", cfg.Auth.OperatorKey, "resolved-secret")
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
	t.Setenv("M3_2_TEST_OPERATOR_KEY", "operator-secret")
	t.Setenv("M3_2_TEST_GATEWAY_TOKEN", "gateway-secret")

	cfg := writeMinimalConfig(t, `
auth:
  operator_key: env:M3_2_TEST_OPERATOR_KEY
  gateway_service_token: env:M3_2_TEST_GATEWAY_TOKEN
`)
	if cfg.Auth.OperatorKey != "operator-secret" {
		t.Fatalf("OperatorKey=%q", cfg.Auth.OperatorKey)
	}
	if cfg.Auth.GatewayServiceToken != "gateway-secret" {
		t.Fatalf("GatewayServiceToken=%q", cfg.Auth.GatewayServiceToken)
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
