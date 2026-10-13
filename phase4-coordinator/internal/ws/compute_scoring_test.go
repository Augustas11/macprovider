package ws

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"math/rand"
	"net"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type fakeHold struct {
	computeintegrity.EarningsHold
}

type fakeHoldStore struct {
	mu    sync.Mutex
	holds    []*fakeHold
	fail     atomic.Bool
	attempts atomic.Int64
}

func (f *fakeHoldStore) OpenComputeIntegrityHold(_ context.Context, providerID, modelID string, kind computeintegrity.HoldKind, start time.Time, end *time.Time, reason string, now time.Time) (int64, error) {
	f.attempts.Add(1)
	if f.fail.Load() {
		return 0, errors.New("hold store down")
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	h := &fakeHold{computeintegrity.EarningsHold{
		ID: int64(len(f.holds) + 1), ProviderID: providerID, ModelID: modelID, Kind: kind,
		WindowStart: start, WindowEnd: end, Reason: reason, Status: computeintegrity.HoldHeld, CreatedAt: now,
	}}
	f.holds = append(f.holds, h)
	return h.ID, nil
}

func (f *fakeHoldStore) CloseComputeIntegrityRecoveryHold(_ context.Context, providerID, modelID string, end time.Time, release bool, now time.Time) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, h := range f.holds {
		if h.ProviderID == providerID && h.ModelID == modelID && h.Kind == computeintegrity.HoldKindRecovery && h.WindowEnd == nil {
			e := end
			h.WindowEnd = &e
			if release {
				h.Status = computeintegrity.HoldReleased
				h.ReleasedAt = &now
			}
		}
	}
	return nil
}

func (f *fakeHoldStore) ComputeIntegrityHolds(_ context.Context, providerID string) ([]computeintegrity.EarningsHold, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []computeintegrity.EarningsHold
	for _, h := range f.holds {
		if h.ProviderID == providerID {
			out = append(out, h.EarningsHold)
		}
	}
	return out, nil
}

func (f *fakeHoldStore) ReleaseComputeIntegrityHold(_ context.Context, holdID int64, operatorID, reason string, now time.Time) (computeintegrity.EarningsHold, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, h := range f.holds {
		if h.ID == holdID {
			h.Status = computeintegrity.HoldReleased
			h.ReleasedBy = operatorID
			h.ReleaseReason = reason
			h.ReleasedAt = &now
			return h.EarningsHold, nil
		}
	}
	return computeintegrity.EarningsHold{}, errors.New("not found")
}

func (f *fakeHoldStore) CountHeldComputeIntegrityHolds(context.Context) (int, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	n := 0
	for _, h := range f.holds {
		if h.Status == computeintegrity.HoldHeld {
			n++
		}
	}
	return n, nil
}

func (f *fakeHoldStore) snapshot() []computeintegrity.EarningsHold {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []computeintegrity.EarningsHold
	for _, h := range f.holds {
		out = append(out, h.EarningsHold)
	}
	return out
}

type scoringHarness struct {
	t          *testing.T
	server     *Server
	registry   *pool.Registry
	engine     *computeScoringEngine
	holds      *fakeHoldStore
	clock      atomic.Int64
	dispatched atomic.Int64
	cheatProbe atomic.Int64
	cheaters   map[string]bool
	conns      []net.Conn
}

const scoringModel = "model-ci"

var scoringManifest = strings.Repeat("d", 64)

func (h *scoringHarness) now() time.Time { return time.Unix(0, h.clock.Load()).UTC() }

func (h *scoringHarness) advance(d time.Duration) { h.clock.Add(int64(d)) }

func newScoringHarness(t *testing.T, providers map[string]string, cheaters map[string]bool) *scoringHarness {
	t.Helper()
	h := &scoringHarness{t: t, registry: pool.NewRegistry(nil), holds: &fakeHoldStore{}, cheaters: cheaters}
	h.clock.Store(time.Date(2026, 10, 13, 0, 0, 0, 0, time.UTC).UnixNano())
	cfg := config.Default()
	h.server = NewServer(cfg, h.registry, zerolog.Nop(), WithNow(h.now))
	for id := range providers {
		p := &pool.Provider{
			ProviderID: id, AssignedID: "as-" + id, ModelID: scoringModel,
			WeightsManifestSHA256: scoringManifest, State: pool.StateReady,
			SlotsFree: 4, SlotsTotal: 4, MaxContextTokens: 8192, ComputeScoreV1: true,
		}
		client, server := net.Pipe()
		h.conns = append(h.conns, client, server)
		h.registry.Register(p, server)
		session := newProviderSession(p.ProviderID, p.AssignedID, server, 16, time.Second)
		h.server.sessions.Store(sessionKey(p.ProviderID, p.AssignedID), session)
		go session.runWriter()
		go h.fakeScorer(p.ProviderID, p.AssignedID, client)
	}
	t.Cleanup(func() {
		for _, c := range h.conns {
			_ = c.Close()
		}
	})
	db, err := sql.Open("sqlite", filepath.Join(t.TempDir(), "ci.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	store, err := computeintegrity.NewScoringStore(context.Background(), db)
	if err != nil {
		t.Fatal(err)
	}
	scfg := config.DefaultComputeIntegrityConfig().Scoring
	scfg.BaseIntervalMinutes = 60
	scfg.EscalationIntervalMinutes = 10
	scfg.MaxInFlight = 16
	scfg.ScoreDeadlineSeconds = 5
	h.engine, err = h.server.newComputeScoringEngine(context.Background(), ComputeScoringDeps{
		Config: scfg,
		Store:  store,
		Dispatch: func(_ context.Context, d ComputeIntegrityProbeDispatch) (ComputeIntegrityProbeResponse, error) {
			h.dispatched.Add(1)
			var body map[string]any
			if err := json.Unmarshal(d.Body, &body); err != nil || body["model"] != scoringModel {
				return ComputeIntegrityProbeResponse{}, errors.New("bad body")
			}
			if h.cheaters[d.ProviderID] {
				h.cheatProbe.Add(1)
				return ComputeIntegrityProbeResponse{OutputText: "CHEAP output", Complete: true}, nil
			}
			return ComputeIntegrityProbeResponse{OutputText: "HONEST output", Complete: true}, nil
		},
		OperatorKey: func(_ context.Context, providerID string) (string, error) { return providers[providerID], nil },
		Holds:       h.holds,
		Rand:        rand.New(rand.NewSource(1644)),
	})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

// fakeScorer answers every scoring job: an honest output scores near the
// generating model, a substituted one far below.
func (h *scoringHarness) fakeScorer(providerID, assignedID string, conn net.Conn) {
	for {
		raw, err := wsutil.ReadServerText(conn)
		if err != nil {
			return
		}
		var req ComputeScoreRequest
		if json.Unmarshal(raw, &req) != nil || req.Type != computeScoreRequestType {
			continue
		}
		result := ComputeScoreResult{
			Type: computeScoreResultType, Version: 1, ScoreID: req.ScoreID,
			ProviderID: req.ProviderID, AssignedID: req.AssignedID, ModelID: req.ModelID,
			WeightsManifestSHA256: req.WeightsManifestSHA256, Status: "ok",
			PromptTokens: 40, ScoredTokens: 100, Top1Matches: 98, SumLogprob: -18,
		}
		if strings.Contains(req.OutputText, "CHEAP") {
			result.Top1Matches = 55
			result.SumLogprob = -160
		}
		payload, _ := json.Marshal(result)
		h.server.handleComputeScoreResult(providerID, assignedID, payload)
	}
}

func (h *scoringHarness) round(step time.Duration) {
	h.t.Helper()
	h.advance(step)
	h.engine.sweep(context.Background(), h.now())
	deadline := time.Now().Add(10 * time.Second)
	for {
		h.engine.mu.Lock()
		n := h.engine.inFlightCount
		h.engine.mu.Unlock()
		if n == 0 {
			return
		}
		if time.Now().After(deadline) {
			h.t.Fatal("probes did not finish")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (h *scoringHarness) state(providerID string) computeintegrity.VerificationState {
	h.engine.mu.Lock()
	defer h.engine.mu.Unlock()
	st := h.engine.states[computeScoringKey{providerID, scoringModel}]
	if st == nil {
		return ""
	}
	return st.State
}

func TestComputeScoringHonestProvidersPassAndCheaterFailsWithHold(t *testing.T) {
	providers := map[string]string{
		"honest": "github:1", "cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4",
	}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 12 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(2 * time.Hour)
		if h.state("cheat") == computeintegrity.VerificationSuspect {
			// Escalation cadence.
			for j := 0; j < 8 && h.state("cheat") == computeintegrity.VerificationSuspect; j++ {
				h.round(20 * time.Minute)
			}
		}
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("cheater state = %s, want failed", got)
	}
	cheat, ok := h.registry.Resolve("cheat", "as-cheat")
	if !ok || !cheat.ComputeIntegritySuspended || cheat.RoutingEligible() {
		t.Fatalf("failed provider must leave routing: suspended=%v eligible=%v", cheat.ComputeIntegritySuspended, cheat.RoutingEligible())
	}
	honest, _ := h.registry.Resolve("honest", "as-honest")
	if honest.ComputeIntegritySuspended || !honest.RoutingEligible() {
		t.Fatal("honest provider must stay routable")
	}
	holds := h.holds.snapshot()
	if len(holds) != 1 || holds[0].ProviderID != "cheat" || holds[0].Kind != computeintegrity.HoldKindFailure ||
		holds[0].Status != computeintegrity.HoldHeld || holds[0].WindowEnd == nil || !holds[0].WindowStart.Before(*holds[0].WindowEnd) {
		t.Fatalf("expected one held failure hold for the cheater, got %+v", holds)
	}

	// A failed key is not probed while suspended; the others still are.
	cheatBefore, allBefore := h.cheatProbe.Load(), h.dispatched.Load()
	for i := 0; i < 4; i++ {
		h.round(2 * time.Hour)
	}
	if h.cheatProbe.Load() != cheatBefore {
		t.Fatal("a failed key must not be probed during its cooldown")
	}
	if h.dispatched.Load() == allBefore {
		t.Fatal("other providers must keep being probed")
	}
	for i := 0; i < 8; i++ {
		h.round(2 * time.Hour)
	}
	for _, id := range []string{"honest", "scorer-a", "scorer-b"} {
		if got := h.state(id); got != computeintegrity.VerificationPassing {
			t.Fatalf("%s state = %s, want passing", id, got)
		}
	}

	// After the cooldown the cheater recovers onto probation with an open
	// recovery hold, keeps cheating, and fails again; the recovery hold
	// closes and stays held.
	h.round(25 * time.Hour)
	if got := h.state("cheat"); got != computeintegrity.VerificationRecovering && got != computeintegrity.VerificationFailed {
		t.Fatalf("after cooldown state = %s", got)
	}
	for j := 0; j < 12 && h.state("cheat") == computeintegrity.VerificationRecovering; j++ {
		h.round(20 * time.Minute)
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("persistent cheater must fail again, got %s", got)
	}
	holds = h.holds.snapshot()
	if len(holds) != 2 || holds[1].Kind != computeintegrity.HoldKindRecovery || holds[1].WindowEnd == nil || holds[1].Status != computeintegrity.HoldHeld {
		t.Fatalf("recovery hold must close and stay held: %+v", holds)
	}
}

func TestComputeScoringHoldWriteFailureDefersFailure(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	h.holds.fail.Store(true)
	for i := 0; i < 120 && h.holds.attempts.Load() < 2; i++ {
		h.round(20 * time.Minute)
	}
	if h.holds.attempts.Load() < 2 {
		t.Fatal("setup: the failure transition was never attempted")
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationSuspect {
		t.Fatalf("a failure must not apply while its hold cannot be written, state %s", got)
	}
	if p, _ := h.registry.Resolve("cheat", "as-cheat"); p.ComputeIntegritySuspended {
		t.Fatal("no suspension without the hold")
	}
	h.holds.fail.Store(false)
	for i := 0; i < 10 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	if got := h.state("cheat"); got != computeintegrity.VerificationFailed {
		t.Fatalf("failure must apply once the hold store recovers, got %s", got)
	}
}

func TestComputeScoringNeedsScorerOfAnotherOperator(t *testing.T) {
	// Every connected provider belongs to one operator: nobody may score.
	providers := map[string]string{"a": "github:1", "b": "github:1"}
	h := newScoringHarness(t, providers, nil)
	for i := 0; i < 4; i++ {
		h.round(2 * time.Hour)
	}
	if n := h.dispatched.Load(); n != 0 {
		t.Fatalf("no verification request may be dispatched without an independent scorer, got %d", n)
	}
}

func TestComputeScoringPersistedFailureSuspendsOnStart(t *testing.T) {
	providers := map[string]string{"cheat": "github:2", "scorer-a": "github:3", "scorer-b": "github:4"}
	h := newScoringHarness(t, providers, map[string]bool{"cheat": true})
	for i := 0; i < 120 && h.state("cheat") != computeintegrity.VerificationFailed; i++ {
		h.round(20 * time.Minute)
	}
	if h.state("cheat") != computeintegrity.VerificationFailed {
		t.Fatal("setup: expected failure")
	}
	// A fresh registry and engine over the same store re-apply the suspension.
	registry := pool.NewRegistry(nil)
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	registry.Register(&pool.Provider{ProviderID: "cheat", AssignedID: "as-2", ModelID: scoringModel, WeightsManifestSHA256: scoringManifest, State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1}, server)
	s2 := NewServer(config.Default(), registry, zerolog.Nop(), WithNow(h.now))
	if _, err := s2.newComputeScoringEngine(context.Background(), ComputeScoringDeps{
		Config: h.engine.deps.Config, Store: h.engine.deps.Store, Dispatch: h.engine.deps.Dispatch,
		OperatorKey: h.engine.deps.OperatorKey, Holds: h.holds,
	}); err != nil {
		t.Fatal(err)
	}
	if p, _ := registry.Resolve("cheat", "as-2"); !p.ComputeIntegritySuspended || p.RoutingEligible() {
		t.Fatal("a persisted failure must suspend routing after restart")
	}
}

func TestParseComputeScoreResultIsStrict(t *testing.T) {
	good := ComputeScoreResult{
		Type: computeScoreResultType, Version: 1, ScoreID: "s", ProviderID: "p", AssignedID: "a", ModelID: "m",
		WeightsManifestSHA256: scoringManifest, Status: "ok", ScoredTokens: 20, Top1Matches: 19, SumLogprob: -3,
	}
	raw, _ := json.Marshal(good)
	if _, _, err := ParseComputeScoreResult(raw); err != nil {
		t.Fatalf("valid result rejected: %v", err)
	}
	for name, mutate := range map[string]func(map[string]any){
		"unknown field":   func(m map[string]any) { m["prompt"] = "x" },
		"bad status":      func(m map[string]any) { m["status"] = "great" },
		"matches>scored":  func(m map[string]any) { m["top1_matches"] = 21 },
		"bad manifest":    func(m map[string]any) { m["weights_manifest_sha256"] = "AB" },
		"wrong type":      func(m map[string]any) { m["type"] = "compute_score_request_v1" },
		"control in id":   func(m map[string]any) { m["score_id"] = "a\nb" },
		"negative counts": func(m map[string]any) { m["scored_tokens"] = -1 },
	} {
		var m map[string]any
		_ = json.Unmarshal(raw, &m)
		mutate(m)
		bad, _ := json.Marshal(m)
		if _, _, err := ParseComputeScoreResult(bad); err == nil {
			t.Errorf("%s: expected rejection", name)
		}
	}
}

func TestComputeScoreResultFromWrongSessionIsIgnored(t *testing.T) {
	providers := map[string]string{"x": "github:1"}
	h := newScoringHarness(t, providers, nil)
	ch := make(chan ComputeScoreResult, 1)
	h.engine.mu.Lock()
	h.engine.pending["score-1"] = &pendingComputeScore{scorerID: "x", assignedID: "as-x", modelID: scoringModel, manifest: scoringManifest, ch: ch}
	h.engine.mu.Unlock()
	result := ComputeScoreResult{
		Type: computeScoreResultType, Version: 1, ScoreID: "score-1", ProviderID: "x", AssignedID: "as-other", ModelID: scoringModel,
		WeightsManifestSHA256: scoringManifest, Status: "ok", ScoredTokens: 20, Top1Matches: 20,
	}
	raw, _ := json.Marshal(result)
	h.server.handleComputeScoreResult("x", "as-other", raw)
	select {
	case <-ch:
		t.Fatal("a result from another session must not be delivered")
	default:
	}
	result.AssignedID = "as-x"
	raw, _ = json.Marshal(result)
	h.server.handleComputeScoreResult("x", "as-x", raw)
	select {
	case got := <-ch:
		if got.ScoreID != "score-1" {
			t.Fatalf("unexpected result %+v", got)
		}
	default:
		t.Fatal("matching result must be delivered")
	}
}
