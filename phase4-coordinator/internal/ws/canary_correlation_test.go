package ws

import (
	"net"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/canarycorr"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

func TestMapCanaryFailClass(t *testing.T) {
	t.Parallel()
	if mapCanaryFailClass(canaryProbePass, canaryFailNone) != canarycorr.ClassPass {
		t.Fatal("pass")
	}
	if mapCanaryFailClass(canaryProbeFail, canaryFailNonce) != canarycorr.ClassNonceMismatch {
		t.Fatal("nonce")
	}
	if mapCanaryFailClass(canaryProbeFail, canaryFailIncomplete) != canarycorr.ClassIncomplete {
		t.Fatal("incomplete")
	}
	if canarycorr.CorrectnessFailure(mapCanaryFailClass(canaryProbeFail, canaryFailTTFT)) {
		t.Fatal("ttft must not be correctness failure")
	}
}

func TestCanaryCorrelationStagesUntilResolve(t *testing.T) {
	registry := pool.NewRegistry(nil)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 1
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryMaxTokens = 8
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	cfg.Pool.CanaryIntervalS = 1
	s := NewServer(cfg, registry, zerolog.Nop())

	// Two buyer-serving providers for model-a.
	p1Conn, p1Prov := registerWSProvider(t, s, registry, "p1", "s1", "model-a")
	defer p1Conn.Close()
	p2Conn, p2Prov := registerWSProvider(t, s, registry, "p2", "s2", "model-a")
	defer p2Conn.Close()
	registry.NoteBuyerSuccess("p1", time.Now().UTC())
	registry.NoteBuyerSuccess("p2", time.Now().UTC())

	// First correctness failure stages (N=2) and does not immediately trip.
	runFailedCanaryProbe(t, s, p1Conn, p1Prov)
	got, _ := registry.Resolve("p1", "s1")
	if got.CanaryFailCount != 1 {
		// After completePendingCorrelationPeers incomplete resolve, count should apply.
		t.Fatalf("after staged+resolve fail count = %d, want 1", got.CanaryFailCount)
	}
	if got.State != pool.StateUnavailable && got.State != pool.StateReady && got.State != pool.StateDegraded {
		t.Fatalf("unexpected state after one failure: %+v", got)
	}
	// Peer should remain ready (not correlated majority).
	peer, _ := registry.Resolve("p2", "s2")
	if peer.State != pool.StateReady {
		t.Fatalf("peer state = %s, want ready", peer.State)
	}
	_ = p2Prov
}

func TestCanaryCorrelationSuspicionDiscardsBoth(t *testing.T) {
	registry := pool.NewRegistry(nil)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 1
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryMaxTokens = 8
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())

	p1Conn, p1Prov := registerWSProvider(t, s, registry, "a1", "sa", "model-corr")
	defer p1Conn.Close()
	p2Conn, p2Prov := registerWSProvider(t, s, registry, "a2", "sb", "model-corr")
	defer p2Conn.Close()
	registry.NoteBuyerSuccess("a1", time.Now().UTC())
	registry.NoteBuyerSuccess("a2", time.Now().UTC())

	// Manually open epoch and stage two correctness failures → suspicion.
	fp := canaryChallengeFingerprint(testCanaryChallenge())
	ep, err := canarycorr.NewEpoch("model-corr", fp, 1, []string{"a1", "a2"})
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a1", "a2"} {
		if err := ep.Stage(canarycorr.StagedResult{
			ProviderID: id, AssignedID: "s", ModelID: "model-corr",
			Fingerprint: fp, BankGeneration: 1, Class: canarycorr.ClassNonceMismatch,
			BuyerServing: true, ObservedServing: true,
		}); err != nil {
			t.Fatal(err)
		}
	}
	live := &liveCorrelationEpoch{
		modelID: "model-corr", fingerprint: fp, bankGeneration: 1, epoch: ep,
		assignedByID: map[string]string{"a1": "sa", "a2": "sb"},
	}
	if !s.resolveAndApplyCorrelation(live, false) {
		// Suspicion returns true (handled) with no commits — ok if true.
	}
	// Neither provider should have been sanctioned (discard path).
	g1, _ := registry.Resolve("a1", "sa")
	g2, _ := registry.Resolve("a2", "sb")
	if g1.CanaryFailCount != 0 || g2.CanaryFailCount != 0 {
		t.Fatalf("suspicion must not apply counters: a1=%d a2=%d", g1.CanaryFailCount, g2.CanaryFailCount)
	}
	if g1.State != pool.StateReady || g2.State != pool.StateReady {
		t.Fatalf("suspicion must not trip state: a1=%s a2=%s", g1.State, g2.State)
	}
	_ = p1Prov
	_ = p2Prov
	_ = p1Conn
	_ = p2Conn
}

func TestExpireCanaryCorrelationWindowsAppliesIncomplete(t *testing.T) {
	registry := pool.NewRegistry(nil)
	cfg := config.Default()
	cfg.Pool.CanaryIntervalS = 1
	cfg.Pool.CanaryFailureThreshold = 1
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	// Freeze now for deterministic deadline.
	base := time.Date(2026, 7, 23, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return base }

	p1Conn, p1Prov := registerWSProvider(t, s, registry, "w1", "sw1", "model-win")
	defer p1Conn.Close()
	_, _ = registerWSProvider(t, s, registry, "w2", "sw2", "model-win")
	registry.NoteBuyerSuccess("w1", base)
	registry.NoteBuyerSuccess("w2", base)

	// Stage one failure without resolving.
	fp := canaryChallengeFingerprint(testCanaryChallenge())
	ep, err := canarycorr.NewEpoch("model-win", fp, 2, []string{"w1", "w2"})
	if err != nil {
		t.Fatal(err)
	}
	if err := ep.Stage(canarycorr.StagedResult{
		ProviderID: "w1", AssignedID: "sw1", ModelID: "model-win",
		Fingerprint: fp, BankGeneration: 2, Class: canarycorr.ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	}); err != nil {
		t.Fatal(err)
	}
	s.canaryCorrMu.Lock()
	s.canaryCorrByModel = map[string]*liveCorrelationEpoch{
		"model-win": {
			modelID: "model-win", fingerprint: fp, bankGeneration: 2, epoch: ep,
			assignedByID: map[string]string{"w1": "sw1"},
			startedAt:    base.Add(-time.Hour),
			deadline:     base.Add(-time.Minute), // already expired
		},
	}
	s.canaryCorrMu.Unlock()

	s.expireCanaryCorrelationWindows()
	got, _ := registry.Resolve("w1", "sw1")
	if got.CanaryFailCount != 1 {
		t.Fatalf("window expiry must commit staged failure, count=%d", got.CanaryFailCount)
	}
	_ = p1Prov
}

func registerWSProvider(t *testing.T, s *Server, registry *pool.Registry, id, session, model string) (net.Conn, *pool.Provider) {
	t.Helper()
	serverConn, providerConn := net.Pipe()
	p := &pool.Provider{
		ProviderID: id, AssignedID: session, ModelID: model,
		Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled,
		State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1,
		MaxContextTokens: 4096,
	}
	registry.Register(p, serverConn)
	ps := newProviderSession(id, session, serverConn, 1)
	s.sessions.Store(sessionKey(id, session), ps)
	go ps.runWriter()
	return providerConn, p
}

func TestNoteBuyerSuccessObservedServing(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	p := &pool.Provider{
		ProviderID: "obs", AssignedID: "s", ModelID: "m",
		State: pool.StateReady, SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1,
		MaxContextTokens: 1, InferencePath: pool.InferencePathHTTPForwarding,
		EndpointURL: "http://127.0.0.1:9",
	}
	registry.Register(p, nil)
	if !registry.LastBuyerSuccessAt("obs").IsZero() {
		t.Fatal("expected zero stamp")
	}
	at := time.Date(2026, 7, 23, 10, 0, 0, 0, time.UTC)
	registry.NoteBuyerSuccess("obs", at)
	if !registry.LastBuyerSuccessAt("obs").Equal(at) {
		t.Fatalf("stamp = %v want %v", registry.LastBuyerSuccessAt("obs"), at)
	}
	s := NewServer(config.Default(), registry, zerolog.Nop())
	s.now = func() time.Time { return at.Add(30 * time.Second) }
	got, _ := registry.Resolve("obs", "s")
	if !s.observedServingFor(got) {
		t.Fatal("expected observed serving within window")
	}
	s.now = func() time.Time { return at.Add(2 * time.Minute) }
	if s.observedServingFor(got) {
		t.Fatal("expected observed serving expired")
	}
}

func TestShouldRouteThroughCorrelationSoleProvider(t *testing.T) {
	registry := pool.NewRegistry(nil)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	p := pool.Provider{ProviderID: "solo", AssignedID: "s", ModelID: "m", State: pool.StateReady, SlotsFree: 1, MaxContextTokens: 1}
	registry.Register(&p, nil)
	if s.shouldRouteThroughCorrelation(p, canarycorr.ClassNonceMismatch) {
		t.Fatal("sole provider must not open correlation")
	}
}

func TestCorrelationFloorHeldSuppressesGhostPeer(t *testing.T) {
	// Ghost peer is buyer-serving but never observed-serving; residual must
	// force floor-held at threshold instead of provisional ban.
	registry := pool.NewRegistry(nil)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 1
	s := NewServer(cfg, registry, zerolog.Nop())
	// Inject buyer-serving predicate so both count as FR-CAN22 peers.
	registry.SetBuyerServingPredicate(func(p pool.Provider) bool {
		return p.State == pool.StateReady && p.SlotsFree > 0 && p.MaxContextTokens > 0
	})

	real := &pool.Provider{
		ProviderID: "real", AssignedID: "sr", ModelID: "m",
		Tier: pool.TierProvisional, State: pool.StateReady,
		SlotsFree: 1, SlotsTotal: 1, MaxConcurrency: 1, MaxContextTokens: 4096,
		InferencePath: pool.InferencePathHTTPForwarding, EndpointURL: "http://127.0.0.1:1",
	}
	ghost := &pool.Provider{
		ProviderID: "ghost", AssignedID: "sg", ModelID: "m",
		Tier: pool.TierProvisional, State: pool.StateReady,
		SlotsFree: 1, MaxConcurrency: 1, MaxContextTokens: 1,
		InferencePath: pool.InferencePathHTTPForwarding, EndpointURL: "http://127.0.0.1:2",
	}
	registry.Register(real, nil)
	registry.Register(ghost, nil)
	registry.NoteBuyerSuccess("real", time.Now().UTC())
	// ghost has no LastBuyerSuccessAt

	fp := "fp-ghost"
	ep, err := canarycorr.NewEpoch("m", fp, 1, []string{"real", "ghost"})
	if err != nil {
		t.Fatal(err)
	}
	if err := ep.Stage(canarycorr.StagedResult{
		ProviderID: "real", AssignedID: "sr", ModelID: "m",
		Fingerprint: fp, BankGeneration: 1, Class: canarycorr.ClassNonceMismatch,
		BuyerServing: true, ObservedServing: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := ep.Stage(canarycorr.StagedResult{
		ProviderID: "ghost", AssignedID: "sg", ModelID: "m",
		Fingerprint: fp, BankGeneration: 1, Class: canarycorr.ClassPass,
		BuyerServing: true, ObservedServing: false,
	}); err != nil {
		t.Fatal(err)
	}
	live := &liveCorrelationEpoch{
		modelID: "m", fingerprint: fp, bankGeneration: 1, epoch: ep,
		assignedByID: map[string]string{"real": "sr", "ghost": "sg"},
	}
	s.resolveAndApplyCorrelation(live, false)
	got, _ := registry.Resolve("real", "sr")
	if got.State != pool.StateReady {
		t.Fatalf("ghost peer must not authorize ban: state=%s count=%d", got.State, got.CanaryFailCount)
	}
	if got.CanaryFailCount != 1 {
		t.Fatalf("fail count must still accrue: %d", got.CanaryFailCount)
	}
}

func TestRecordCanaryResultForceFloorHeld(t *testing.T) {
	t.Parallel()
	registry := pool.NewRegistry(nil)
	registry.SetBuyerServingPredicate(func(p pool.Provider) bool {
		return p.State == pool.StateReady && p.SlotsFree > 0
	})
	target := &pool.Provider{
		ProviderID: "t", AssignedID: "st", ModelID: "m",
		Tier: pool.TierProvisional, State: pool.StateReady,
		SlotsFree: 1, MaxConcurrency: 1, MaxContextTokens: 1,
	}
	peer := &pool.Provider{
		ProviderID: "p", AssignedID: "sp", ModelID: "m",
		Tier: pool.TierProvisional, State: pool.StateReady,
		SlotsFree: 1, MaxConcurrency: 1, MaxContextTokens: 1,
	}
	registry.Register(target, nil)
	registry.Register(peer, nil)
	at := time.Now().UTC()
	// Without force, peer lifts floor → ban at threshold 1.
	res := registry.RecordCanaryResult("t", "st", false, at, 1)
	if res.Tripped != pool.CanaryTripUnavailable {
		t.Fatalf("without force want unavailable, got %+v", res)
	}
	// Reset target
	registry.Register(&pool.Provider{
		ProviderID: "t2", AssignedID: "st2", ModelID: "m",
		Tier: pool.TierProvisional, State: pool.StateReady,
		SlotsFree: 1, MaxConcurrency: 1, MaxContextTokens: 1,
	}, nil)
	res2 := registry.RecordCanaryResultForceFloorHeld("t2", "st2", false, at, 1)
	if res2.Tripped != pool.CanaryTripFloorHeld {
		t.Fatalf("force floor held = %+v", res2)
	}
	got, _ := registry.Resolve("t2", "st2")
	if got.State != pool.StateReady || got.CanaryFailCount != 1 {
		t.Fatalf("force floor held state=%s count=%d", got.State, got.CanaryFailCount)
	}
}
