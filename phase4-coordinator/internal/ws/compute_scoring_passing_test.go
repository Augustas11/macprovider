package ws

import (
	"context"
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// SPEC-022 R-16.2a: the scoring loop publishes a key's passing verification
// to the pool on its transition and again from the persisted state at start;
// a key that leaves passing clears it.
func TestComputeScoringPublishesPassingVerification(t *testing.T) {
	h := newScoringHarness(t, map[string]string{"a": "github:1", "b": "github:2"}, nil)
	if p, _ := h.registry.Resolve("a", "as-a"); p.ComputeIntegrityPassing {
		t.Fatal("an unverified key is passing")
	}
	for i := 0; i < 20 && h.state("a") != computeintegrity.VerificationPassing; i++ {
		h.round(2 * time.Hour)
	}
	if h.state("a") != computeintegrity.VerificationPassing {
		t.Fatal("setup: expected passing")
	}
	if p, _ := h.registry.Resolve("a", "as-a"); !p.ComputeIntegrityPassing {
		t.Fatal("a passing key is not published to the pool")
	}

	// A fresh registry and engine over the same store restore it.
	registry := pool.NewRegistry(nil)
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	registry.Register(&pool.Provider{ProviderID: "a", AssignedID: "as-2", ModelID: scoringModel, WeightsManifestSHA256: scoringManifest, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, HashStatus: pool.HashStatusVerified}, server)
	s2 := NewServer(config.Default(), registry, zerolog.Nop(), WithNow(h.now))
	if _, err := s2.newComputeScoringEngine(context.Background(), ComputeScoringDeps{
		Config: h.engine.deps.Config, Store: h.engine.deps.Store, Dispatch: h.engine.deps.Dispatch,
		OperatorKey: h.engine.deps.OperatorKey, Holds: h.holds,
	}); err != nil {
		t.Fatal(err)
	}
	if p, _ := registry.Resolve("a", "as-2"); !p.ComputeIntegrityPassing {
		t.Fatal("a persisted passing key is not published after restart")
	}

	// With scoring off no key is passing: the provider-wide hold applies.
	off := h.engine.deps.Config
	off.Enabled = false
	registryOff := pool.NewRegistry(nil)
	registryOff.Register(&pool.Provider{ProviderID: "a", AssignedID: "as-3", ModelID: scoringModel, WeightsManifestSHA256: scoringManifest, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, HashStatus: pool.HashStatusVerified}, server)
	s3 := NewServer(config.Default(), registryOff, zerolog.Nop(), WithNow(h.now))
	if _, err := s3.newComputeScoringEngine(context.Background(), ComputeScoringDeps{
		Config: off, Store: h.engine.deps.Store, Dispatch: h.engine.deps.Dispatch,
		OperatorKey: h.engine.deps.OperatorKey, Holds: h.holds,
	}); err != nil {
		t.Fatal(err)
	}
	if p, _ := registryOff.Resolve("a", "as-3"); p.ComputeIntegrityPassing {
		t.Fatal("a persisted passing key is published with scoring off")
	}

	// Leaving passing clears it.
	h.engine.mu.Lock()
	st := h.engine.stateLocked(computeScoringKey{"a", scoringModel}, h.now())
	tr := st.Apply(computeintegrity.Outcome{OutOfBand: true, OutReason: computeintegrity.OutOfBandTop1, At: h.now()})
	committed := tr != nil && h.engine.applyTransitionLocked(context.Background(), st, tr, h.now())
	h.engine.mu.Unlock()
	if !committed {
		t.Fatal("setup: suspect transition not committed")
	}
	if p, _ := h.registry.Resolve("a", "as-a"); p.ComputeIntegrityPassing {
		t.Fatal("a suspect key is still passing")
	}
}
