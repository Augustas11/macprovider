package ws

import (
	"testing"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestProviderProbeModelIDUsesAutotuneAdmissionKey(t *testing.T) {
	provider := pool.Provider{
		ModelID:             "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
		MaxAdmittedModelKey: " qwen3-coder-30b-a3b-instruct ",
	}
	if got := providerProbeModelID(provider); got != "qwen3-coder-30b-a3b-instruct" {
		t.Fatalf("providerProbeModelID() = %q, want admitted model key", got)
	}
}

func TestProviderProbeModelIDFallsBackToProviderModelID(t *testing.T) {
	provider := pool.Provider{ModelID: "mlx-community/Qwen2.5-7B-Instruct-4bit"}
	if got := providerProbeModelID(provider); got != provider.ModelID {
		t.Fatalf("providerProbeModelID() = %q, want provider model id %q", got, provider.ModelID)
	}
}

func TestWarmupGateSkipsAdmissionCeilingExcludedProvider(t *testing.T) {
	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop())
	provider := pool.Provider{
		ProviderID:               "provider-a",
		AssignedID:               "assigned-a",
		ModelID:                  "large-model",
		State:                    pool.StateDegraded,
		AdmissionCeilingExcluded: true,
		MaxAdmittedModelKey:      "small",
	}
	if s.runWarmupGateAttempt(provider, 1) {
		t.Fatal("warmup gate attempted an admission-ceiling-excluded provider")
	}
}

func TestWarmupGateSkipsStaleAdmissionEvidenceProvider(t *testing.T) {
	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop())
	provider := pool.Provider{
		ProviderID:             "provider-a",
		AssignedID:             "assigned-a",
		ModelID:                "small-model",
		State:                  pool.StateDegraded,
		AdmissionEvidenceStale: true,
		MaxAdmittedModelKey:    "small",
	}
	if s.runWarmupGateAttempt(provider, 1) {
		t.Fatal("warmup gate attempted a stale-admission-evidence provider")
	}
}
