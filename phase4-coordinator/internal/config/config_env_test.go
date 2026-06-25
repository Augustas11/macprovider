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

// TestLoadResolvesPayoutSecurityEnvFields covers the Step 4 r1 [sec:r1-4]
// MEDIUM fix: env:NAME indirection must be expanded for payout.security.*
// string fields so operators can inject RPC URLs + wallet path via env vars.
func TestLoadResolvesPayoutSecurityEnvFields(t *testing.T) {
	t.Setenv("S4R1_TEST_OP_KEY", "test-operator-key")
	t.Setenv("S4R1_PAYOUT_RPC_PRIMARY", "https://primary.rpc.example/v1")
	t.Setenv("S4R1_PAYOUT_RPC_SECONDARY", "https://secondary.rpc.example/v1")
	t.Setenv("S4R1_PAYOUT_HOT_WALLET", "0x8ba1f109551bD432803012645Ac136ddd64DBA72")
	t.Setenv("S4R1_PAYOUT_WALLET_PATH", "/var/lib/macprovider/wallet.enc")

	cfg := writeMinimalConfig(t, `
auth:
  operator_key: env:S4R1_TEST_OP_KEY
payout:
  enabled: true
  security:
    hot_wallet_address: env:S4R1_PAYOUT_HOT_WALLET
    rpc_url_primary:    env:S4R1_PAYOUT_RPC_PRIMARY
    rpc_url_secondary:  env:S4R1_PAYOUT_RPC_SECONDARY
    encrypted_wallet_path: env:S4R1_PAYOUT_WALLET_PATH
    per_payout_cap_usdc_base_units: 500000000
    per_day_cap_usdc_base_units:    5000000000
    cancel_max_tip_multiplier:      5.0
    cancel_max_gas_native_wei:      10000000000000000
    cancel_max_gas_native_wei_per_24h: 50000000000000000
    abandon_rate_per_hour:          3
    chain_recon_interval:           1h
    chain_recon_tolerance_usdc_base_units: 100000
    pause_resume_min_interval:      1s
  tuning:
    address_cooling_off_period: 24h
    run_interval:               6h
    run_now_min_interval:       60s
    confirmation_blocks:        5
    max_rows_per_run:           50
    reorg_poll_window:          24h
    low_balance_threshold:      0
    low_native_threshold:       0
`)
	// Assert all four payout.security.* env: fields resolved.
	if cfg.Payout.Security.RPCURLPrimary != "https://primary.rpc.example/v1" {
		t.Errorf("RPCURLPrimary=%q, want resolved value", cfg.Payout.Security.RPCURLPrimary)
	}
	if cfg.Payout.Security.RPCURLSecondary != "https://secondary.rpc.example/v1" {
		t.Errorf("RPCURLSecondary=%q, want resolved value", cfg.Payout.Security.RPCURLSecondary)
	}
	if cfg.Payout.Security.HotWalletAddress != "0x8ba1f109551bD432803012645Ac136ddd64DBA72" {
		t.Errorf("HotWalletAddress=%q, want resolved value", cfg.Payout.Security.HotWalletAddress)
	}
	if cfg.Payout.Security.EncryptedWalletPath != "/var/lib/macprovider/wallet.enc" {
		t.Errorf("EncryptedWalletPath=%q, want resolved value", cfg.Payout.Security.EncryptedWalletPath)
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
