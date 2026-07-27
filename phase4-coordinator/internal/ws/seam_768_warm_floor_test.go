package ws

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

const warmFloorModelID = "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"

func warmFloorServer(t *testing.T, floors map[string]string) *Server {
	t.Helper()
	cfg := config.Default()
	cfg.CoordinatorAdvertisedVersion.PerModelRequiredBinaryVersion = floors
	return NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop())
}

func warmFloorProvider(providerID, binaryVersion string) pool.Provider {
	now := time.Now().UTC()
	return pool.Provider{
		ProviderID:       providerID,
		AssignedID:       "s-" + providerID,
		ModelID:          warmFloorModelID,
		BinaryVersion:    binaryVersion,
		State:            pool.StateReady,
		Tier:             pool.TierPinned,
		MaxContextTokens: 50000,
		MaxConcurrency:   1,
		SlotsTotal:       1,
		SlotsFree:        1,
		EndpointURL:      "https://" + providerID + ".example",
		InferencePath:    pool.InferencePathHTTPForwarding,
		LastHeartbeatAt:  now,
		ConnectedAt:      now,
	}
}

// TestWarmPoolGateSharesModelVersionFloor is the "we never warm a box we won't
// route to" half of #768: the warm-pool candidate gates read the same map and
// the same versionfloor.Check the buyer-side routing gates read.
func TestWarmPoolGateSharesModelVersionFloor(t *testing.T) {
	s := warmFloorServer(t, map[string]string{warmFloorModelID: "1.8.60"})

	old := warmFloorProvider("old", "1.8.59")
	if s.canaryBuyerServing(old) {
		t.Fatal("canaryBuyerServing admitted a below-floor provider as a serving peer")
	}
	if s.runWarmupGateAttempt(old, 1) {
		t.Fatal("runWarmupGateAttempt warmed a below-floor provider")
	}

	fresh := warmFloorProvider("new", "1.8.65")
	if !s.canaryBuyerServing(fresh) {
		t.Fatal("canaryBuyerServing rejected an above-floor provider")
	}

	// Malformed version fails SAFE at the warm gates too.
	garbled := warmFloorProvider("garbled", "1.8.65-dev")
	if s.canaryBuyerServing(garbled) {
		t.Fatal("canaryBuyerServing admitted a provider with an unparseable binary_version while a floor is in force")
	}
}

// TestWarmPoolGateUnconfiguredIsByteIdentical pins the default posture at the
// warm gates: unset floors never exclude, not even an unparseable version.
func TestWarmPoolGateUnconfiguredIsByteIdentical(t *testing.T) {
	s := warmFloorServer(t, nil)
	for _, version := range []string{"0.1.0", "not-a-version", ""} {
		p := warmFloorProvider("p", version)
		if s.belowModelVersionFloor(p, "test") {
			t.Fatalf("belowModelVersionFloor(%q) = true with no floors configured", version)
		}
		if !s.canaryBuyerServing(p) {
			t.Fatalf("canaryBuyerServing(%q) = false with no floors configured", version)
		}
	}
}
