package ws

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// withdrawalHarness is a scoring harness with an honest multi-model session
// "multi" whose further member serves the scored model, beside two
// single-model scorers. beat applies a heartbeat of "multi" with or without
// the member.
func withdrawalHarness(t *testing.T) (*scoringHarness, func(withMember bool)) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	h := newScoringHarnessOnRegistry(t, registry, map[string]string{"multi": "github:1", "scorer-a": "github:3", "scorer-b": "github:4"}, nil, nil, nil)
	pool.WithModelIdentityResolver(func(req pool.ModelIdentityRequest) pool.ModelIdentityVerdict {
		if req.ReportedHash != "" && req.ReportedHash == req.ExpectedHash {
			return pool.ModelIdentityVerdict{Status: pool.HashStatusVerified}
		}
		return pool.ModelIdentityVerdict{Status: pool.HashStatusUncatalogued}
	})(registry)
	primaryHash := strings.Repeat("f", 64)
	beat := func(withMember bool) {
		t.Helper()
		members := []pool.WarmModel{{ModelID: "model-primary", State: pool.WarmModelWarm, Primary: true, SlotsTotal: 4, SlotsFree: 4, MaxContextTokens: 8192}}
		if withMember {
			members = append(members, pool.WarmModel{
				ModelID: scoringModel, State: pool.WarmModelWarm, SlotsTotal: 2, SlotsFree: 2, MaxContextTokens: 8192,
				ModelHash: scoringModelHash, ExpectedModelHash: scoringModelHash, WeightsManifestSHA256: scoringManifest,
			})
		}
		if _, _, ok := registry.ApplyHeartbeat("multi", "as-multi", pool.HeartbeatUpdate{
			Status: pool.StateReady, ModelID: "model-primary", MaxContextTokens: 8192, MaxConcurrency: 4, SlotsTotal: 4, SlotsFree: 4,
			ModelHash: primaryHash, ExpectedModelHash: primaryHash, ModelHashPresent: true,
			WarmModels: members, At: time.Now(),
		}); !ok {
			t.Fatal("heartbeat failed")
		}
	}
	beat(true)
	return h, beat
}

func (h *scoringHarness) due(providerID string) (time.Time, bool) {
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	due, ok := h.engine.nextDue[computeScoringKey{providerID, scoringModel}]
	return due, ok
}

// SPEC-036 FR-23: a provider that withdraws a further member from its warm
// set while the member's verification request is in flight leaves the key
// due (probed again at the next sweep the entry is routable), and every
// three such withdrawals in a row are one out-of-band outcome.
func TestComputeScoringMemberWithdrawnMidProbeStaysDueAndCounts(t *testing.T) {
	h, beat := withdrawalHarness(t)
	honest := h.engine.deps.Dispatch
	var withdrawn atomic.Int64
	h.engine.deps.Dispatch = func(ctx context.Context, d ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error) {
		resp, err := honest(ctx, d)
		if d.ProviderID == "multi" {
			beat(false)
			withdrawn.Add(1)
		}
		return resp, err
	}
	for i := 0; i < 24 && withdrawn.Load() == 0; i++ {
		h.round(2 * time.Hour)
		beat(true)
	}
	if withdrawn.Load() != 1 {
		t.Fatalf("setup: withdrawals = %d, want 1", withdrawn.Load())
	}
	if due, ok := h.due("multi"); !ok || due.After(h.now()) {
		t.Fatalf("withdrawn key not due: due=%v now=%v", due, h.now())
	}
	if got := h.state("multi"); got != computeintegrity.VerificationUnverified {
		t.Fatalf("one withdrawal changed the state to %s", got)
	}
	// The next sweep with the member back probes it again at once.
	h.round(time.Minute)
	beat(true)
	if withdrawn.Load() != 2 {
		t.Fatalf("withdrawals after the next sweep = %d, want 2", withdrawn.Load())
	}
	h.round(time.Minute)
	beat(true)
	if withdrawn.Load() != 3 {
		t.Fatalf("withdrawals = %d, want 3", withdrawn.Load())
	}
	h.engine.mu.Lock()
	st := h.engine.states[computeScoringKey{"multi", scoringModel}]
	h.engine.mu.Unlock()
	if st == nil || st.State != computeintegrity.VerificationSuspect || st.Reason != computeintegrity.ReasonEntryWithdrawn {
		t.Fatalf("three withdrawals in a row: state=%+v, want suspect (entry_withdrawn)", st)
	}
	// Withdrawals keep counting while escalating: the key fails as a
	// provider measured out of band does.
	for i := 0; i < 40 && h.state("multi") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
		beat(true)
	}
	if got := h.state("multi"); got != computeintegrity.VerificationFailed {
		t.Fatalf("repeated withdrawals: state=%s after %d withdrawals, want failed", got, withdrawn.Load())
	}
}

// An honest answer between withdrawals restarts the count.
func TestComputeScoringMemberWithdrawalCountResetsOnAnswer(t *testing.T) {
	h, beat := withdrawalHarness(t)
	honest := h.engine.deps.Dispatch
	var probes atomic.Int64
	h.engine.deps.Dispatch = func(ctx context.Context, d ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error) {
		resp, err := honest(ctx, d)
		if d.ProviderID == "multi" && probes.Add(1)%3 != 0 {
			beat(false)
		}
		return resp, err
	}
	for i := 0; i < 60 && probes.Load() < 9; i++ {
		h.round(20 * time.Minute)
		beat(true)
	}
	if probes.Load() < 9 {
		t.Fatalf("setup: probes = %d", probes.Load())
	}
	if got := h.state("multi"); got == computeintegrity.VerificationSuspect || got == computeintegrity.VerificationFailed {
		t.Fatalf("withdrawals interleaved with answers: state=%s", got)
	}
}

// The primary keeps its behaviour: a model swap by heartbeat while its
// verification request is in flight is one inconclusive result, the key's
// next due time is drawn as for any finished request, and nothing counts.
func TestComputeScoringPrimarySwapMidProbeUnchanged(t *testing.T) {
	h, respell := newFoldingScoringHarness(t)
	honest := h.engine.deps.Dispatch
	var swaps atomic.Int64
	h.engine.deps.Dispatch = func(ctx context.Context, d ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error) {
		resp, err := honest(ctx, d)
		if d.ProviderID == "a" {
			respell("model-other")
			swaps.Add(1)
		}
		return resp, err
	}
	for i := 0; i < 48 && swaps.Load() < 4; i++ {
		before := swaps.Load()
		h.round(2 * time.Hour)
		respell(scoringModel)
		if swaps.Load() > before {
			if due, ok := h.due("a"); !ok || !due.After(h.now()) {
				t.Fatalf("swap %d left the primary key due: due=%v now=%v", swaps.Load(), due, h.now())
			}
		}
	}
	if swaps.Load() < 4 {
		t.Fatalf("setup: swaps = %d", swaps.Load())
	}
	if got := h.state("a"); got != computeintegrity.VerificationUnverified {
		t.Fatalf("primary swaps changed the state to %s", got)
	}
}
