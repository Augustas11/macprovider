package ws

import (
	"context"
	"encoding/json"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// newFoldingScoringHarness is a scoring harness whose registry verifies a
// reported hash equal to the expected one, so a heartbeat can re-spell the
// model of provider "a" while it stays catalog-verified.
func newFoldingScoringHarness(t *testing.T) (*scoringHarness, func(spelling string)) {
	t.Helper()
	registry := pool.NewRegistry(nil)
	h := newScoringHarnessOnRegistry(t, registry, map[string]string{"a": "github:1", "b": "github:2", "c": "github:3"}, nil, nil, nil)
	pool.WithModelIdentityResolver(func(req pool.ModelIdentityRequest) pool.ModelIdentityVerdict {
		if req.ReportedHash != "" && req.ReportedHash == req.ExpectedHash {
			return pool.ModelIdentityVerdict{Status: pool.HashStatusVerified}
		}
		return pool.ModelIdentityVerdict{Status: pool.HashStatusUncatalogued}
	})(registry)
	respell := func(spelling string) {
		t.Helper()
		if _, _, ok := registry.ApplyHeartbeat("a", "as-a", pool.HeartbeatUpdate{
			Status: pool.StateReady, ModelID: spelling, MaxContextTokens: 8192, MaxConcurrency: 4, SlotsTotal: 4, SlotsFree: 4,
			ModelHash: scoringModelHash, ModelHashPresent: true, ExpectedModelHash: scoringModelHash,
			WeightsManifestSHA256: scoringManifest, At: time.Now(),
		}); !ok {
			t.Fatal("heartbeat failed")
		}
		if p, _ := registry.Resolve("a", "as-a"); p.ModelID != spelling || p.HashStatus != pool.HashStatusVerified {
			t.Fatalf("respell %q: model=%s status=%s", spelling, p.ModelID, p.HashStatus)
		}
	}
	return h, respell
}

// keysOf lists the scoring keys of one provider in the engine's state and
// schedule maps.
func (h *scoringHarness) keysOf(providerID string) map[computeScoringKey]struct{} {
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	out := map[computeScoringKey]struct{}{}
	for key := range h.engine.states {
		if key.providerID == providerID {
			out[key] = struct{}{}
		}
	}
	for key := range h.engine.nextDue {
		if key.providerID == providerID {
			out[key] = struct{}{}
		}
	}
	return out
}

// SPEC-036 FR-20: a provider re-spelling its model keeps one key and its due
// time; a new spelling is never a new key with a fresh first interval.
func TestComputeScoringModelSpellingKeepsOneKeyAndDueTime(t *testing.T) {
	h, respell := newFoldingScoringHarness(t)
	h.engine.sweep(context.Background(), h.now())
	key := computeScoringKey{"a", scoringModel}
	h.engine.mu.Lock()
	due, ok := h.engine.nextDue[key]
	h.engine.mu.Unlock()
	if !ok {
		t.Fatal("setup: key a not scheduled")
	}
	for i, spelling := range []string{"Model-CI", "MODEL-CI", "model-Ci"} {
		respell(spelling)
		h.advance(time.Minute)
		h.engine.sweep(context.Background(), h.now())
		if keys := h.keysOf("a"); len(keys) != 1 {
			t.Fatalf("spelling %d (%s): keys %v, want one", i, spelling, keys)
		}
		h.engine.mu.Lock()
		got := h.engine.nextDue[key]
		h.engine.mu.Unlock()
		if !got.Equal(due) {
			t.Fatalf("spelling %s moved the due time %v -> %v", spelling, due, got)
		}
	}
}

// SPEC-036 FR-20 output binding: a spelling change while a verification
// request is in flight is no session change; the measurement counts.
func TestComputeScoringProbeInFlightSurvivesSpellingChange(t *testing.T) {
	h, respell := newFoldingScoringHarness(t)
	spellings := []string{"MODEL-CI", "Model-ci", scoringModel}
	var probes atomic.Int64
	h.engine.deps.Dispatch = func(_ context.Context, d ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error) {
		var body map[string]any
		if err := json.Unmarshal(d.Body, &body); err != nil {
			return ComputeIntegrityProbeResponse{}, err
		}
		model, _ := body["model"].(string)
		if pool.ModelKey(model) != scoringModel {
			return ComputeIntegrityProbeResponse{}, errors.New("bad body")
		}
		if d.ProviderID == "a" {
			respell(spellings[probes.Add(1)%int64(len(spellings))])
		}
		return ComputeIntegrityProbeResponse{OutputText: "HONEST output", Complete: true}, nil
	}
	inBand := func() int {
		h.engine.mu.Lock()
		defer h.engine.mu.Unlock()
		if st := h.engine.states[computeScoringKey{"a", scoringModel}]; st != nil {
			return st.InBandTotal
		}
		return 0
	}
	for i := 0; i < 24 && inBand() == 0; i++ {
		h.round(2 * time.Hour)
	}
	if probes.Load() == 0 {
		t.Fatal("provider a was never probed")
	}
	if inBand() == 0 {
		t.Fatalf("%d probes across spelling changes, none conclusive", probes.Load())
	}
	if keys := h.keysOf("a"); len(keys) != 1 {
		t.Fatalf("keys %v, want one", keys)
	}
	if got := h.state("a"); got == computeintegrity.VerificationSuspect || got == computeintegrity.VerificationFailed {
		t.Fatalf("honest provider state = %s", got)
	}
}

// Rows stored under two spellings of one model before folding restore as
// one key: the adverse state and the earlier due time win.
func TestComputeScoringRestoreFoldsStoredSpellings(t *testing.T) {
	h, _ := newFoldingScoringHarness(t)
	ctx := context.Background()
	store := h.engine.deps.Store
	now := h.now()
	failed := computeintegrity.NewKeyState("a", "Model-CI", now)
	failed.State = computeintegrity.VerificationFailed
	failed.FailedAt = now
	healthy := computeintegrity.NewKeyState("a", "MODEL-CI", now)
	for _, st := range []*computeintegrity.KeyState{failed, healthy} {
		if err := store.UpsertKeyState(ctx, st, now); err != nil {
			t.Fatal(err)
		}
	}
	early, late := now.Add(10*time.Minute), now.Add(40*time.Minute)
	if err := store.SaveProbeSchedule(ctx, []computeintegrity.ProbeDue{
		{ProviderID: "a", ModelID: "MODEL-CI", Due: late},
		{ProviderID: "a", ModelID: "Model-CI", Due: early},
	}, now); err != nil {
		t.Fatal(err)
	}
	e := h.restartScoring()
	e.mu.Lock()
	defer e.mu.Unlock()
	key := computeScoringKey{"a", scoringModel}
	if st := e.states[key]; st == nil || st.State != computeintegrity.VerificationFailed {
		t.Fatalf("restored state = %+v, want the failed row", st)
	}
	if due := e.nextDue[key]; !due.Equal(early) {
		t.Fatalf("restored due = %v, want the earlier %v", due, early)
	}
}
