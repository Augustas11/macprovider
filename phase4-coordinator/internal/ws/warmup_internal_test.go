package ws

import (
	"testing"

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
