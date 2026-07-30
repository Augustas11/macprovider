package buyer

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestEffectiveHashStatusKeepsEmptySessionStatusUnverified(t *testing.T) {
	server := &Server{}
	provider := pool.Provider{
		ModelID:   "model-a",
		ModelHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
	}
	got := server.effectiveHashStatus(provider, config.Tier2Config{ObserveEnabled: true})
	if got != pool.HashStatusUncatalogued {
		t.Fatalf("empty session status was reconstructed from an independent authority: %q", got)
	}
}
