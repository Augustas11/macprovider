package ws

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func routingGateProvider(t *testing.T, registry *pool.Registry) pool.Provider {
	t.Helper()
	now := time.Now().UTC()
	if _, ok := registry.Register(&pool.Provider{
		ProviderID:       "gated",
		AssignedID:       "g1",
		ModelID:          "model-a",
		Hostname:         "gated.local",
		Tier:             pool.TierPinned,
		InferencePath:    pool.InferencePathHTTPForwarding,
		State:            pool.StateReady,
		SlotsFree:        1,
		SlotsTotal:       1,
		MaxConcurrency:   1,
		MaxContextTokens: 4096,
		EndpointURL:      "https://gated.example",
		LastHeartbeatAt:  now,
		ConnectedAt:      now,
	}, nil); !ok {
		t.Fatal("register provider failed")
	}
	p, ok := registry.Resolve("gated", "g1")
	if !ok {
		t.Fatal("lookup provider failed")
	}
	return p
}

// SPEC-022-R002 R-2.7 (#1689): /poolz.routing_eligible applies the buyer
// router's enforce-mode catalog-material verdict, and only there — the
// FR-CAN22 last-provider floor (canaryBuyerServing) is unchanged.
func TestPublicRoutingEligibleAppliesCatalogMaterialGate(t *testing.T) {
	for _, tc := range []struct {
		name     string
		wire     bool
		excluded bool
		want     bool
	}{
		{name: "no gate wired", wire: false, want: true},
		{name: "enforce and material missing", wire: true, excluded: true, want: false},
		{name: "observe mode or material present", wire: true, excluded: false, want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			registry := pool.NewRegistry(nil)
			s := NewServer(config.Default(), registry, zerolog.Nop())
			p := routingGateProvider(t, registry)
			var seen []string
			if tc.wire {
				s.SetCatalogMaterialRoutingGate(func(got pool.Provider) bool {
					seen = append(seen, got.ProviderID)
					return tc.excluded
				})
			}
			if got := s.publicRoutingEligible(p); got != tc.want {
				t.Fatalf("publicRoutingEligible = %v, want %v", got, tc.want)
			}
			if tc.wire && (len(seen) != 1 || seen[0] != "gated") {
				t.Fatalf("gate saw %v, want the evaluated provider once", seen)
			}
			if !s.canaryBuyerServing(p) {
				t.Fatal("canaryBuyerServing must not apply the catalog-material gate")
			}
			if n := registry.BuyerServingCountForModel("model-a"); n != 1 {
				t.Fatalf("BuyerServingCountForModel = %d, want 1", n)
			}
		})
	}
}
