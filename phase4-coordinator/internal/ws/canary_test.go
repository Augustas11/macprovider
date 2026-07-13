package ws

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestBuildCanaryBodyUsesPrivateChallengeTemplates(t *testing.T) {
	challenges := []config.CanaryChallengeConfig{
		testCanaryChallenge(),
		{
			Prompt:   "Decode the NATO word for V and append -{nonce}.",
			Expected: "victor-{nonce}",
		},
	}
	body, expected, err := buildCanaryBodyFromRandom("model-a", 8, challenges, []byte{0xAB, 0xCD, 0x01, 0x02, 0x00})
	if err != nil {
		t.Fatalf("build canary body: %v", err)
	}
	if expected != "Vermont-ABCD0102" {
		t.Fatalf("expected answer = %q, want configured answer with nonce", expected)
	}
	req := decodeCanaryBody(t, body)
	if req.Model != "model-a" || req.MaxTokens != 8 || req.Stream {
		t.Fatalf("canary request = %+v", req)
	}
	// Greedy decoding must be pinned so a healthy provider echoes the nonce
	// exactly rather than sampling and hallucinating it (spurious nonce_mismatch).
	if req.Temperature == nil || *req.Temperature != 0 {
		t.Fatalf("canary request temperature = %v, want 0", req.Temperature)
	}
	if len(req.Messages) != 1 || req.Messages[0].Role != "user" {
		t.Fatalf("messages = %+v", req.Messages)
	}
	content := req.Messages[0].Content
	if strings.Contains(content, expected) || strings.Contains(content, "Vermont") {
		t.Fatalf("prompt %q leaked expected answer %q", content, expected)
	}
	if !strings.Contains(content, "ABCD0102") {
		t.Fatalf("prompt %q does not carry nonce from expected answer %q", content, expected)
	}
	for _, publicArithmeticMarker := range []string{"Compute ", "numeric result", "Solve ", "Evaluate "} {
		if strings.Contains(content, publicArithmeticMarker) {
			t.Fatalf("prompt %q used legacy arithmetic marker %q", content, publicArithmeticMarker)
		}
	}
	if !canaryAnswerMatches(strings.Join(canaryPayloadContents([]byte(`{"choices":[{"message":{"content":"`+expected+`"}}]}`)), ""), expected) {
		t.Fatal("canary payload should match exact answer in assistant output")
	}
	echo := content
	if canaryAnswerMatches(strings.Join(canaryPayloadContents([]byte(`{"choices":[{"message":{"content":"`+echo+`"}}]}`)), ""), expected) {
		t.Fatal("prompt echo must not satisfy exact canary answer")
	}
	if canaryAnswerMatches(strings.Join(canaryPayloadContents([]byte(`{"choices":[{"message":{"content":"ok-`+strings.Split(expected, "-")[1]+`"}}]}`)), ""), expected) {
		t.Fatal("nonce without arithmetic answer must not satisfy canary")
	}

	_, selectedSecond, err := buildCanaryBodyFromRandom("model-a", 8, challenges, []byte{0x10, 0x20, 0x30, 0x40, 0x01})
	if err != nil {
		t.Fatalf("build canary body for second challenge: %v", err)
	}
	if selectedSecond != "victor-10203040" {
		t.Fatalf("second challenge expected = %q", selectedSecond)
	}
}

func TestRunCanaryProbeRecordsPassAndThresholdFailure(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 2
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryMaxTokens = 8
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 1)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	registerCanaryFloorPeer(registry, "model-a")
	go session.runWriter()

	passDone := make(chan struct{})
	go func() {
		s.runCanaryProbe(*provider)
		close(passDone)
	}()
	passReq := readCanaryInferenceRequest(t, providerConn)
	expected := expectedAnswerFromCanaryRequest(t, passReq)
	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: passReq.RequestID,
		Seq:       0,
		Data:      `{"choices":[{"message":{"content":"` + expected + `"}}]}`,
	}))
	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  passReq.RequestID,
		Status:     "complete",
		ChunksSent: 1,
	}))
	waitForCanary(t, passDone)
	got, ok := registry.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider not found after pass")
	}
	if got.CanaryFailCount != 0 || got.State != pool.StateReady || got.CanaryLastCheckedAt == nil {
		t.Fatalf("provider after canary pass = %+v", got)
	}

	runFailedCanaryProbe(t, s, providerConn, provider)
	got, _ = registry.Resolve("p1", "s1")
	if got.CanaryFailCount != 1 || got.State != pool.StateReady {
		t.Fatalf("provider after first failed canary = %+v", got)
	}
	runFailedCanaryProbe(t, s, providerConn, provider)
	got, _ = registry.Resolve("p1", "s1")
	if got.CanaryFailCount != 2 || got.State != pool.StateUnavailable {
		t.Fatalf("provider after threshold failed canary = %+v", got)
	}
	if !s.admission.Rejected("p1") {
		t.Fatal("provisional provider should be rejected after canary threshold")
	}
}

// TestCanaryBuyerServingAppliesTier2Gate verifies the floor's injected
// buyer-serving predicate excludes a Tier-2-excluded provider that raw
// ServingCapable would accept — the H1 residual (a non-buyer-routable peer must
// not lift the last-provider floor).
func TestCanaryBuyerServingAppliesTier2Gate(t *testing.T) {
	registry := pool.NewRegistry(nil)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	p := pool.Provider{
		ProviderID:     "p",
		AssignedID:     "s",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
		EncryptedLeg:   false,
	}
	if !s.canaryBuyerServing(p) {
		t.Fatal("baseline ready provider should be buyer-serving")
	}
	// Tier-2 now requires an encrypted leg the provider lacks → excluded.
	s.SetTier2Config(config.Tier2Config{RequireEncryptedLeg: true})
	if s.canaryBuyerServing(p) {
		t.Fatal("Tier-2-excluded provider must not be buyer-serving (would falsely lift the floor)")
	}
	// A busy provider (no free slots) is still buyer-serving capacity.
	busy := p
	busy.State = pool.StateBusy
	busy.SlotsFree = 0
	s.SetTier2Config(config.Tier2Config{})
	if !s.canaryBuyerServing(busy) {
		t.Fatal("busy provider should still be buyer-serving")
	}
}

func TestRunCanaryProbePersistsPinnedSanctionAndClearsOnPass(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "pinned-p1",
		AssignedID:     "pinned-s1",
		ModelID:        "model-a",
		Tier:           pool.TierPinned,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 1
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryMaxTokens = 8
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	store := &recordingCanarySanctionStore{}
	s := NewServer(cfg, registry, zerolog.Nop(), WithCanarySanctionStore(store))
	session := newProviderSession("pinned-p1", "pinned-s1", serverConn, 1)
	s.sessions.Store(sessionKey("pinned-p1", "pinned-s1"), session)
	registerCanaryFloorPeer(registry, "model-a")
	go session.runWriter()

	runFailedCanaryProbe(t, s, providerConn, provider)
	saved := store.savedSnapshots()
	if len(saved) != 1 || saved[0].ProviderID != "pinned-p1" || saved[0].FailCount != 1 {
		t.Fatalf("saved canary sanctions = %+v", saved)
	}
	got, ok := registry.Resolve("pinned-p1", "pinned-s1")
	if !ok {
		t.Fatal("provider not found after canary failure")
	}
	if got.State != pool.StateDegraded || got.RoutingEligible() {
		t.Fatalf("pinned provider after failed canary = %+v, want degraded and unroutable", got)
	}

	passDone := make(chan struct{})
	go func() {
		s.runCanaryProbe(*provider)
		close(passDone)
	}()
	passReq := readCanaryInferenceRequest(t, providerConn)
	expected := expectedAnswerFromCanaryRequest(t, passReq)
	s.handleInferenceChunk("pinned-p1", "pinned-s1", mustJSON(InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: passReq.RequestID,
		Seq:       0,
		Data:      `{"choices":[{"message":{"content":"` + expected + `"}}]}`,
	}))
	s.handleInferenceEnd("pinned-p1", "pinned-s1", mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  passReq.RequestID,
		Status:     "complete",
		ChunksSent: 1,
	}))
	waitForCanary(t, passDone)
	if deleted := store.deletedProviders(); len(deleted) != 1 || deleted[0] != "pinned-p1" {
		t.Fatalf("deleted canary sanctions = %+v", deleted)
	}
	got, ok = registry.Resolve("pinned-p1", "pinned-s1")
	if !ok {
		t.Fatal("provider not found after canary pass")
	}
	if got.State != pool.StateReady || !got.RoutingEligible() || got.CanaryFailCount != 0 {
		t.Fatalf("pinned provider after passing canary = %+v, want ready/routable and fail count reset", got)
	}
}

func TestRunCanaryProbeDoesNotDeletePersistedSanctionOnStaleTerminalPass(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "pinned-stale",
		AssignedID:     "pinned-stale-s1",
		ModelID:        "model-a",
		Tier:           pool.TierPinned,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 1
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryMaxTokens = 8
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	store := &recordingCanarySanctionStore{}
	s := NewServer(cfg, registry, zerolog.Nop(), WithCanarySanctionStore(store))
	session := newProviderSession("pinned-stale", "pinned-stale-s1", serverConn, 1)
	s.sessions.Store(sessionKey("pinned-stale", "pinned-stale-s1"), session)
	registerCanaryFloorPeer(registry, "model-a")
	go session.runWriter()

	runFailedCanaryProbe(t, s, providerConn, provider)
	if saved := store.savedSnapshots(); len(saved) != 1 {
		t.Fatalf("saved canary sanctions = %+v, want one", saved)
	}

	passDone := make(chan struct{})
	go func() {
		s.runCanaryProbe(*provider)
		close(passDone)
	}()
	passReq := readCanaryInferenceRequest(t, providerConn)
	if !registry.MarkState("pinned-stale", "pinned-stale-s1", pool.StateUnavailable) {
		t.Fatal("mark unavailable failed")
	}
	expected := expectedAnswerFromCanaryRequest(t, passReq)
	s.handleInferenceChunk("pinned-stale", "pinned-stale-s1", mustJSON(InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: passReq.RequestID,
		Seq:       0,
		Data:      `{"choices":[{"message":{"content":"` + expected + `"}}]}`,
	}))
	s.handleInferenceEnd("pinned-stale", "pinned-stale-s1", mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  passReq.RequestID,
		Status:     "complete",
		ChunksSent: 1,
	}))
	waitForCanary(t, passDone)
	if deleted := store.deletedProviders(); len(deleted) != 0 {
		t.Fatalf("deleted canary sanctions after stale terminal pass = %+v, want none", deleted)
	}
}

func TestRunCanaryProbeSkipsBackpressureWithoutFailureCount(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 2
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 1)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	relay, err := s.DispatchInference(context.Background(), *provider, "req-buyer", []byte(`{"model":"model-a"}`), false)
	if err != nil {
		t.Fatalf("dispatch active buyer request: %v", err)
	}
	_ = readInferenceRequestFrame(t, providerConn)

	done := make(chan struct{})
	go func() {
		s.runCanaryProbe(*provider)
		close(done)
	}()
	waitForCanary(t, done)
	got, ok := registry.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.CanaryFailCount != 0 || got.CanaryLastCheckedAt != nil {
		t.Fatalf("backpressure canary should be skipped without count/timestamp update: %+v", got)
	}

	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  "req-buyer",
		Status:     "complete",
		ChunksSent: 0,
	}))
	select {
	case <-relay.Done:
	case <-time.After(2 * time.Second):
		t.Fatal("buyer relay did not complete")
	}
}

func TestRunCanarySweepSeedsJitteredDueTimesBeforeProbing(t *testing.T) {
	var requests atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"wrong"}}]}`))
	}))
	defer ts.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "http-p1",
		AssignedID:     "http-s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathHTTPForwarding,
		EndpointURL:    ts.URL,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, nil)
	cfg := config.Default()
	cfg.Pool.CanaryIntervalS = 10
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	now := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }

	s.runCanarySweep()
	if got := requests.Load(); got != 0 {
		t.Fatalf("first sweep issued %d HTTP canaries, want due-time seeding only", got)
	}
	key := "http-p1"
	rawDue, ok := s.canaryDue.Load(key)
	if !ok {
		t.Fatal("first sweep did not seed next canary due time")
	}
	due, ok := rawDue.(time.Time)
	if !ok {
		t.Fatalf("due value = %T, want time.Time", rawDue)
	}
	if due.Before(now.Add(5*time.Second)) || !due.Before(now.Add(15*time.Second)) {
		t.Fatalf("seeded due time = %s, want in [5s, 15s)", due.Sub(now))
	}

	now = now.Add(16 * time.Second)
	s.runCanarySweep()
	deadline := time.Now().Add(2 * time.Second)
	for requests.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if requests.Load() == 0 {
		t.Fatal("due sweep did not issue canary request")
	}
	deadline = time.Now().Add(2 * time.Second)
	for {
		if _, inFlight := s.canaries.Load(key); !inFlight {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("canary remained in flight")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !registry.RemoveIfSession("http-p1", "http-s1") {
		t.Fatal("provider removal failed")
	}
	s.runCanarySweep()
	if _, ok := s.canaryDue.Load(key); ok {
		t.Fatal("stale provider canary due time was not pruned")
	}
}

func TestRunCanarySweepKeepsProviderDueAcrossReconnect(t *testing.T) {
	var requests atomic.Int32
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"wrong"}}]}`))
	}))
	defer ts.Close()

	registry := pool.NewRegistry(nil)
	first := &pool.Provider{
		ProviderID:     "http-p1",
		AssignedID:     "http-s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathHTTPForwarding,
		EndpointURL:    ts.URL,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(first, nil)
	cfg := config.Default()
	cfg.Pool.CanaryIntervalS = 10
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	now := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }

	s.runCanarySweep()
	if requests.Load() != 0 {
		t.Fatal("first sweep should seed due time only")
	}
	if !registry.RemoveIfSession("http-p1", "http-s1") {
		t.Fatal("first provider removal failed")
	}
	reconnected := *first
	reconnected.AssignedID = "http-s2"
	registry.Register(&reconnected, nil)

	now = now.Add(16 * time.Second)
	s.runCanarySweep()
	deadline := time.Now().Add(2 * time.Second)
	for requests.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if requests.Load() == 0 {
		t.Fatal("provider-level due time did not survive reconnect")
	}
}

func TestRunCanarySweepKeepsDueAfterInFlightReconnect(t *testing.T) {
	serverConnA, providerConnA := net.Pipe()
	defer providerConnA.Close()
	defer serverConnA.Close()
	serverConnB, providerConnB := net.Pipe()
	defer providerConnB.Close()
	defer serverConnB.Close()

	registry := pool.NewRegistry(nil)
	providerA := &pool.Provider{
		ProviderID:     "p1",
		AssignedID:     "s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(providerA, serverConnA)
	cfg := config.Default()
	cfg.Pool.CanaryIntervalS = 10
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	sessionA := newProviderSession("p1", "s1", serverConnA, 1)
	s.sessions.Store(sessionKey("p1", "s1"), sessionA)
	go sessionA.runWriter()
	now := time.Date(2026, 6, 22, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	s.canaryDue.Store("p1", now.Add(-time.Second))

	s.runCanarySweep()
	reqA := readCanaryInferenceRequest(t, providerConnA)
	providerB := *providerA
	providerB.AssignedID = "s2"
	registry.Register(&providerB, serverConnB)
	sessionB := newProviderSession("p1", "s2", serverConnB, 1)
	s.sessions.Store(sessionKey("p1", "s2"), sessionB)
	go sessionB.runWriter()

	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  reqA.RequestID,
		Status:     "error",
		ChunksSent: 0,
	}))
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, inFlight := s.canaries.Load(sessionKey("p1", "s1")); !inFlight {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("old-session canary remained in flight")
		}
		time.Sleep(10 * time.Millisecond)
	}
	rawDue, ok := s.canaryDue.Load("p1")
	if !ok {
		t.Fatal("provider due time missing after stale in-flight failure")
	}
	due, ok := rawDue.(time.Time)
	if !ok {
		t.Fatalf("provider due value = %T, want time.Time", rawDue)
	}
	if due.After(now) {
		t.Fatalf("provider due was pushed forward after stale in-flight failure: %s", due.Sub(now))
	}

	s.runCanarySweep()
	_ = readCanaryInferenceRequest(t, providerConnB)
}

func TestHTTPCanaryEndpointResetCountsAsFailure(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hijacker, ok := w.(http.Hijacker)
		if !ok {
			t.Fatal("response writer does not support hijack")
		}
		conn, _, err := hijacker.Hijack()
		if err != nil {
			t.Fatalf("hijack: %v", err)
		}
		_ = conn.Close()
	}))
	defer ts.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "http-p1",
		AssignedID:     "http-s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathHTTPForwarding,
		EndpointURL:    ts.URL,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 0,
	}
	registry.Register(provider, nil)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 2
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())

	if !s.canaryProbeEligible(*provider) {
		t.Fatal("canary should be eligible for routable provider with unlimited max concurrency")
	}
	s.runCanaryProbe(*provider)
	got, ok := registry.Resolve("http-p1", "http-s1")
	if !ok {
		t.Fatal("provider not found")
	}
	if got.CanaryFailCount != 1 || got.State != pool.StateReady {
		t.Fatalf("HTTP reset canary result = %+v, want one semantic failure and ready before threshold", got)
	}
}

type decodedCanaryBody struct {
	Model       string   `json:"model"`
	MaxTokens   int      `json:"max_tokens"`
	Stream      bool     `json:"stream"`
	Temperature *float64 `json:"temperature"`
	Messages    []struct {
		Role    string `json:"role"`
		Content string `json:"content"`
	} `json:"messages"`
}

func decodeCanaryBody(t *testing.T, body []byte) decodedCanaryBody {
	t.Helper()
	var req decodedCanaryBody
	if err := json.Unmarshal(body, &req); err != nil {
		t.Fatalf("canary body json: %v", err)
	}
	return req
}

func TestRunCanaryProbeUsesAutotuneAdmissionKeyForModelClassProbe(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:          "p1",
		AssignedID:          "s1",
		ModelID:             "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
		MaxAdmittedModelKey: "qwen3-coder-30b-a3b-instruct",
		Tier:                pool.TierPinned,
		InferencePath:       pool.InferencePathWSTunneled,
		State:               pool.StateReady,
		SlotsFree:           1,
		SlotsTotal:          1,
		MaxConcurrency:      1,
	}
	registry.Register(provider, serverConn)
	cfg := config.Default()
	cfg.Pool.CanaryTimeoutS = 1
	cfg.Pool.CanaryMaxTokens = 8
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{{
		Prompt:   "global {nonce}",
		Expected: "{nonce}",
	}}
	cfg.Pool.ModelClassChallenges = map[string][]config.CanaryChallengeConfig{
		"qwen3-coder-30b-a3b-instruct": {testCanaryChallenge()},
	}
	s := NewServer(cfg, registry, zerolog.Nop())
	session := newProviderSession("p1", "s1", serverConn, 1)
	s.sessions.Store(sessionKey("p1", "s1"), session)
	go session.runWriter()

	done := make(chan struct{})
	go func() {
		s.runCanaryProbe(*provider)
		close(done)
	}()
	req := readCanaryInferenceRequest(t, providerConn)
	body := decodeCanaryBody(t, []byte(req.Body))
	if body.Model != "qwen3-coder-30b-a3b-instruct" {
		t.Fatalf("canary body model = %q, want admitted key", body.Model)
	}
	if len(body.Messages) != 1 || !strings.Contains(body.Messages[0].Content, "Which US state") {
		t.Fatalf("canary prompt = %+v, want model-class challenge", body.Messages)
	}
	expected := expectedAnswerFromCanaryRequest(t, req)
	s.handleInferenceChunk("p1", "s1", mustJSON(InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: req.RequestID,
		Seq:       0,
		Data:      `{"choices":[{"message":{"content":"` + expected + `"}}]}`,
	}))
	s.handleInferenceEnd("p1", "s1", mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  req.RequestID,
		Status:     "complete",
		ChunksSent: 1,
	}))
	waitForCanary(t, done)
	got, ok := registry.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider not found after canary")
	}
	if got.ModelClassOPoIPass == nil || !*got.ModelClassOPoIPass {
		t.Fatalf("ModelClassOPoIPass = %v, want true", got.ModelClassOPoIPass)
	}
}

func readCanaryInferenceRequest(t *testing.T, conn net.Conn) InferenceRequest {
	t.Helper()
	return readInferenceRequestFrame(t, conn)
}

func readInferenceRequestFrame(t *testing.T, conn net.Conn) InferenceRequest {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	defer conn.SetReadDeadline(time.Time{})
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read canary inference request: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var req InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("inference request json: %v", err)
	}
	if req.Type != "inference_request" {
		t.Fatalf("request = %+v", req)
	}
	return req
}

func expectedAnswerFromCanaryRequest(t *testing.T, req InferenceRequest) string {
	t.Helper()
	var body struct {
		Messages []struct {
			Content string `json:"content"`
		} `json:"messages"`
	}
	if err := json.Unmarshal([]byte(req.Body), &body); err != nil {
		t.Fatalf("request body json: %v", err)
	}
	if len(body.Messages) != 1 {
		t.Fatalf("messages = %+v", body.Messages)
	}
	return "Vermont-" + nonceFromTestCanaryPrompt(t, body.Messages[0].Content)
}

func nonceFromTestCanaryPrompt(t *testing.T, content string) string {
	t.Helper()
	const marker = "Append -"
	start := strings.LastIndex(content, marker)
	if start < 0 {
		t.Fatalf("canary prompt missing nonce marker: %q", content)
	}
	nonce := strings.TrimSuffix(content[start+len(marker):], ".")
	if len(nonce) != 8 {
		t.Fatalf("nonce = %q, want 8 hex chars", nonce)
	}
	return nonce
}

func testCanaryChallenge() config.CanaryChallengeConfig {
	return config.CanaryChallengeConfig{
		Prompt:   "Which US state uses postal abbreviation VT? Append -{nonce}.",
		Expected: "Vermont-{nonce}",
	}
}

// registerCanaryFloorPeer registers a second routing-eligible provider for
// modelID so the FR-CAN22 last-provider floor does not spare the provider under
// test — letting canary tests still exercise the normal trip path. The peer has
// no session/conn; it exists only as an eligible registry entry and is never
// probed.
func registerCanaryFloorPeer(registry *pool.Registry, modelID string) {
	registry.Register(&pool.Provider{
		ProviderID:     "canary-floor-peer",
		AssignedID:     "canary-floor-peer-session",
		ModelID:        modelID,
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathWSTunneled,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}, nil)
}

func runFailedCanaryProbe(t *testing.T, s *Server, providerConn net.Conn, provider *pool.Provider) {
	t.Helper()
	done := make(chan struct{})
	go func() {
		s.runCanaryProbe(*provider)
		close(done)
	}()
	req := readCanaryInferenceRequest(t, providerConn)
	s.handleInferenceChunk(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseChunk{
		Type:      "inference_response_chunk",
		RequestID: req.RequestID,
		Seq:       0,
		Data:      `{"choices":[{"message":{"content":"canned response"}}]}`,
	}))
	s.handleInferenceEnd(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseEnd{
		Type:       "inference_response_end",
		RequestID:  req.RequestID,
		Status:     "complete",
		ChunksSent: 1,
	}))
	waitForCanary(t, done)
}

func waitForCanary(t *testing.T, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("canary probe timeout")
	}
}

func TestOperatorDeleteRejectClearsAdmissionAndCanarySanctions(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	registry := pool.NewRegistry(nil)
	registry.LoadCanarySanctions([]pool.CanarySanctionSnapshot{{
		ProviderID: "provider-a",
		FailCount:  3,
	}})
	store := &recordingCanarySanctionStore{}
	s := NewServer(cfg, registry, zerolog.Nop(), WithCanarySanctionStore(store))
	s.admission.Reject("provider-a", "false-positive canary")
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	req, err := http.NewRequest(http.MethodDelete, ts.URL+"/admin/reject/provider-a", nil)
	if err != nil {
		t.Fatalf("recovery request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("recover provider: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("recovery status = %d, want 200", resp.StatusCode)
	}
	if s.admission.Rejected("provider-a") {
		t.Fatal("admission rejection survived operator recovery")
	}
	if sanctions := registry.CanarySanctions(); len(sanctions) != 0 {
		t.Fatalf("runtime canary sanctions = %+v, want none", sanctions)
	}
	if deleted := store.deletedProviders(); len(deleted) != 1 || deleted[0] != "provider-a" {
		t.Fatalf("persisted sanction deletions = %v, want provider-a", deleted)
	}
}

func TestOperatorDeleteRejectFailsClosedWhenCanaryPersistenceFails(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	registry := pool.NewRegistry(nil)
	registry.LoadCanarySanctions([]pool.CanarySanctionSnapshot{{
		ProviderID: "provider-a",
		FailCount:  3,
	}})
	store := &recordingCanarySanctionStore{deleteErr: errors.New("sqlite unavailable")}
	s := NewServer(cfg, registry, zerolog.Nop(), WithCanarySanctionStore(store))
	s.admission.Reject("provider-a", "false-positive canary")
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	req, err := http.NewRequest(http.MethodDelete, ts.URL+"/admin/reject/provider-a", nil)
	if err != nil {
		t.Fatalf("recovery request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("recover provider: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("recovery status = %d, want 500", resp.StatusCode)
	}
	if !s.admission.Rejected("provider-a") {
		t.Fatal("failed durable recovery removed admission rejection")
	}
	if sanctions := registry.CanarySanctions(); len(sanctions) != 1 {
		t.Fatalf("runtime canary sanctions = %+v, want retained sanction", sanctions)
	}
}

func TestOperatorDeleteRejectFailsClosedWhenAdmissionPersistenceFails(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	registry := pool.NewRegistry(nil)
	registry.LoadCanarySanctions([]pool.CanarySanctionSnapshot{{
		ProviderID: "provider-a",
		FailCount:  3,
	}})
	store := &recordingCanarySanctionStore{}
	s := NewServer(cfg, registry, zerolog.Nop(), WithCanarySanctionStore(store))
	s.admission.Reject("provider-a", "false-positive canary")
	s.admission.SetPersistence(failingAdmissionStateStore{err: errors.New("sqlite unavailable")}, nil)
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	req, err := http.NewRequest(http.MethodDelete, ts.URL+"/admin/reject/provider-a", nil)
	if err != nil {
		t.Fatalf("recovery request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("recover provider: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("recovery status = %d, want 500", resp.StatusCode)
	}
	if !s.admission.Rejected("provider-a") {
		t.Fatal("failed durable recovery removed admission rejection")
	}
	if sanctions := registry.CanarySanctions(); len(sanctions) != 1 {
		t.Fatalf("runtime canary sanctions = %+v, want retained sanction", sanctions)
	}
}

func TestOperatorDeleteRejectRequiresAuthAndCanonicalProviderID(t *testing.T) {
	cfg := config.Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	s := NewServer(cfg, pool.NewRegistry(nil), zerolog.Nop())
	ts := httptest.NewServer(s.Handler())
	defer ts.Close()

	unauthorized, err := http.NewRequest(http.MethodDelete, ts.URL+"/admin/reject/provider-a", nil)
	if err != nil {
		t.Fatalf("unauthorized request: %v", err)
	}
	resp, err := http.DefaultClient.Do(unauthorized)
	if err != nil {
		t.Fatalf("unauthorized recovery: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("unauthorized status = %d, want 401", resp.StatusCode)
	}

	invalid, err := http.NewRequest(http.MethodDelete, ts.URL+"/admin/reject/provider%2Fchild", nil)
	if err != nil {
		t.Fatalf("invalid provider request: %v", err)
	}
	invalid.Header.Set("Authorization", "Bearer test-operator-key")
	resp, err = http.DefaultClient.Do(invalid)
	if err != nil {
		t.Fatalf("invalid provider recovery: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("invalid provider status = %d, want 400", resp.StatusCode)
	}
}

func TestOperatorRecoveryFencesInflightCanaryResult(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-release
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"content":"wrong"}}]}`))
	}))
	defer ts.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:     "http-p1",
		AssignedID:     "http-s1",
		ModelID:        "model-a",
		Tier:           pool.TierProvisional,
		InferencePath:  pool.InferencePathHTTPForwarding,
		EndpointURL:    ts.URL,
		State:          pool.StateReady,
		SlotsFree:      1,
		SlotsTotal:     1,
		MaxConcurrency: 1,
	}
	registry.Register(provider, nil)
	cfg := config.Default()
	cfg.Pool.CanaryFailureThreshold = 1
	cfg.Pool.CanaryTimeoutS = 2
	cfg.Pool.CanaryChallenges = []config.CanaryChallengeConfig{testCanaryChallenge()}
	s := NewServer(cfg, registry, zerolog.Nop())
	epoch := s.canaryEpoch(provider.ProviderID).Load()
	done := make(chan struct{})
	go func() {
		s.runCanaryProbeAtEpoch(*provider, epoch)
		close(done)
	}()

	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("canary request did not start")
	}
	if _, _, err := s.recoverProvider(provider.ProviderID); err != nil {
		t.Fatalf("operator recovery: %v", err)
	}
	close(release)
	waitForCanary(t, done)

	got, ok := registry.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider not found")
	}
	if got.CanaryFailCount != 0 || got.State != pool.StateReady || s.admission.Rejected(provider.ProviderID) {
		t.Fatalf("stale canary result survived recovery fence: %+v", got)
	}
}

type recordingCanarySanctionStore struct {
	mu        sync.Mutex
	saved     []pool.CanarySanctionSnapshot
	deleted   []string
	deleteErr error
}

func (s *recordingCanarySanctionStore) LoadCanarySanctions(context.Context) ([]pool.CanarySanctionSnapshot, error) {
	return nil, nil
}

func (s *recordingCanarySanctionStore) UpsertCanarySanction(_ context.Context, snapshot pool.CanarySanctionSnapshot) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.saved = append(s.saved, snapshot)
	return nil
}

func (s *recordingCanarySanctionStore) DeleteCanarySanction(_ context.Context, providerID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.deleteErr != nil {
		return s.deleteErr
	}
	s.deleted = append(s.deleted, providerID)
	return nil
}

func (s *recordingCanarySanctionStore) savedSnapshots() []pool.CanarySanctionSnapshot {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]pool.CanarySanctionSnapshot(nil), s.saved...)
}

func (s *recordingCanarySanctionStore) deletedProviders() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.deleted...)
}
