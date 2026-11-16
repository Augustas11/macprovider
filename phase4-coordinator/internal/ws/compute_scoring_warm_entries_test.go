package ws

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-036 FR-20/FR-25 per entry: a multi-model session whose further member
// serves the scored model is verified for that member; a member serving
// substituted computation fails and leaves routing while the primary entry
// and the session stay routable.
func TestComputeScoringVerifiesFurtherWarmMember(t *testing.T) {
	registry := pool.NewRegistry(nil)
	providers := map[string]string{"multi": "github:1", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarnessOnRegistry(t, registry, providers, map[string]bool{"multi": true}, nil, nil)
	// The member's identity verdict: its hash against its expected hash.
	pool.WithModelIdentityResolver(func(req pool.ModelIdentityRequest) pool.ModelIdentityVerdict {
		if req.ReportedHash != "" && req.ReportedHash == req.ExpectedHash {
			return pool.ModelIdentityVerdict{Status: pool.HashStatusVerified}
		}
		return pool.ModelIdentityVerdict{Status: pool.HashStatusUncatalogued}
	})(registry)

	// The session's primary serves another model; the scored model is a
	// further member with its own verified identity.
	member := pool.WarmModel{
		ModelID: scoringModel, State: pool.WarmModelWarm, SlotsTotal: 2, SlotsFree: 2, MaxContextTokens: 8192,
		ModelHash: scoringModelHash, ExpectedModelHash: scoringModelHash, WeightsManifestSHA256: scoringManifest,
	}
	primary := pool.WarmModel{ModelID: "model-primary", State: pool.WarmModelWarm, Primary: true, SlotsTotal: 4, SlotsFree: 4, MaxContextTokens: 8192}
	// The primary's identity verifies too (two verified warm members make the
	// session multi-model); without a manifest it is never itself scored.
	primaryHash := strings.Repeat("f", 64)
	if _, _, ok := registry.ApplyHeartbeat("multi", "as-multi", pool.HeartbeatUpdate{
		Status: pool.StateReady, ModelID: "model-primary", MaxContextTokens: 8192, MaxConcurrency: 4, SlotsTotal: 4, SlotsFree: 4,
		ModelHash: primaryHash, ExpectedModelHash: primaryHash, ModelHashPresent: true,
		WarmModels: []pool.WarmModel{primary, member}, At: time.Now(),
	}); !ok {
		t.Fatal("heartbeat failed")
	}
	if entry, ok := registry.ResolveEntry("multi", "as-multi", scoringModel); !ok || entry.HashStatus != pool.HashStatusVerified || !entry.RoutingEligible() {
		t.Fatalf("setup: member entry = %+v", entry)
	}

	for i := 0; i < 16 && h.state("multi") != computeintegrity.VerificationFailed; i++ {
		h.round(2 * time.Hour)
		for j := 0; j < 8 && h.state("multi") == computeintegrity.VerificationSuspect; j++ {
			h.round(20 * time.Minute)
		}
	}
	if got := h.state("multi"); got != computeintegrity.VerificationFailed {
		t.Fatalf("substituting member state = %s, want failed (never probed?)", got)
	}
	entry, ok := registry.ResolveEntry("multi", "as-multi", scoringModel)
	if !ok || !entry.ComputeIntegritySuspended || entry.RoutingEligible() {
		t.Fatalf("failed member must leave routing: suspended=%v eligible=%v", entry.ComputeIntegritySuspended, entry.RoutingEligible())
	}
	if primaryEntry, _ := registry.ResolveEntry("multi", "as-multi", "model-primary"); primaryEntry.ComputeIntegritySuspended || !primaryEntry.RoutingEligible() {
		t.Fatal("member failure closed the primary entry")
	}
	if session, _ := registry.Resolve("multi", "as-multi"); session.ComputeIntegritySuspended {
		t.Fatal("member failure reached the session")
	}
}
