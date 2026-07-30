package config_test

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
)

func seamValidatableConfig() config.Config {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Auth.GatewayServiceToken = "test-gateway-service-token"
	return cfg
}

// The ceiling default must be a real number, not the Go zero value — a 0
// default would ship the clamp disabled and silently reproduce issue #764.
func TestDefaultMaxConcurrencyCeilingIsSet(t *testing.T) {
	if got := config.Default().Pool.MaxConcurrencyCeiling; got != 8 {
		t.Fatalf("Default().Pool.MaxConcurrencyCeiling = %d, want 8", got)
	}
}

func TestValidateMaxConcurrencyCeiling(t *testing.T) {
	cfg := seamValidatableConfig()
	cfg.Pool.MaxConcurrencyCeiling = -1
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "pool.max_concurrency_ceiling") {
		t.Fatalf("Validate() = %v, want a max_concurrency_ceiling error", err)
	}

	// 0 is the documented escape hatch back to pre-#764 behavior.
	cfg.Pool.MaxConcurrencyCeiling = 0
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() with ceiling 0 = %v, want nil (0 disables the clamp)", err)
	}

	cfg.Pool.MaxConcurrencyCeiling = 16
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() with ceiling 16 = %v, want nil", err)
	}
}

// Issue #765 dormancy: the quarantine must be off by default and must not be
// configurable without the drift evaluator that produces its verdict.
func TestQuarantineMissingBenchmarkDefaultsOffAndRequiresDriftEnabled(t *testing.T) {
	if config.Default().ProofOfWeights.TelemetryDrift.QuarantineMissingBenchmark {
		t.Fatal("telemetry_drift.quarantine_missing_benchmark must default to false")
	}
	if config.Default().ProofOfWeights.TelemetryDrift.Enabled {
		t.Fatal("telemetry_drift.enabled must default to false")
	}

	cfg := seamValidatableConfig()
	cfg.ProofOfWeights.TelemetryDrift.QuarantineMissingBenchmark = true
	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "quarantine_missing_benchmark requires telemetry_drift.enabled") {
		t.Fatalf("Validate() = %v, want the quarantine/enabled coupling error", err)
	}
}
