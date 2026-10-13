package buyer

import (
	"context"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

var phaseTestNow = time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)

var routeTraceGrammar = regexp.MustCompile(`^v=1; phase=(interactive|long_input|throughput); basis=(measured|explore|fallback|pinned); evidence=(fresh|none); engine=(general_mlx|continuous_batching|native_mtp|unknown); latency=(low|medium|high|unknown)$`)

func phaseTestServer(t *testing.T) (*Server, *pool.Registry) {
	t.Helper()
	s, registry, _ := poolIsolationServer(t)
	s.now = func() time.Time { return phaseTestNow }
	// The objective (default: fewest free slots, then throughput) ranks
	// "slow" first: same slots, higher self-reported throughput.
	slow := poolProvider("slow")
	slow.ThroughputTPSEstimate = 500
	registry.Register(&slow, nil)
	fast := poolProvider("fast")
	fast.ThroughputTPSEstimate = 10
	fast.EngineProfile = &pool.EngineProfile{Version: "engine-profile-v1", EngineFamily: "native_mtp", NativeMTPActive: true, ChipClass: "m4_max", RAMClassGB: 128}
	registry.Register(&fast, nil)
	return s, registry
}

func streamChatReq() chatRequest {
	return chatRequest{
		Model:  "model-a",
		Stream: true,
		raw:    []byte(`{"model":"model-a","stream":true,"max_tokens":256,"messages":[{"role":"user","content":"hi"}]}`),
	}
}

func warmProvider(s *Server, providerID string, ttftMs, decodeMs float64) {
	for i := 0; i < routing.PerfFreshMinSamples; i++ {
		s.perf.Observe(routing.PerfObservation{ProviderID: providerID, Model: "model-a", PromptTokens: 200, CompletionTokens: 101, TTFTMs: ttftMs, DecodeMs: decodeMs, At: phaseTestNow})
	}
}

// SPEC-002-R006: with fresh evidence for both providers, an interactive
// request goes to the low-TTFT provider even though the objective ranks the
// other first. Both are fresh, so exploration cannot fire.
func TestPhaseAwareSelectionPrefersMeasuredFastProvider(t *testing.T) {
	s, _ := phaseTestServer(t)
	warmProvider(s, "slow", 800, 2000)
	warmProvider(s, "fast", 40, 1000)
	state := &forwardState{}
	p, routeErr := s.selectProviderExcluding(context.Background(), "rid-1", streamChatReq(), http.Header{}, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "fast" {
		t.Fatalf("provider=%q err=%+v", p.ProviderID, routeErr)
	}
	if state.routeDecision == nil || state.routeDecision.basis != routing.BasisMeasured || state.routeDecision.phase != routing.PhaseInteractive || state.routeDecision.fresh != 2 {
		t.Fatalf("decision = %+v", state.routeDecision)
	}
	trace := s.noteRouteTrace("rid-1", streamChatReq(), http.Header{}, p, state.routeDecision, 10)
	if trace != "v=1; phase=interactive; basis=measured; evidence=fresh; engine=native_mtp; latency=low" {
		t.Fatalf("trace = %q", trace)
	}
}

// SPEC-002-R006 fallback: without evidence, selection is the objective order.
func TestPhaseAwareSelectionFallsBackWithoutEvidence(t *testing.T) {
	s, _ := phaseTestServer(t)
	state := &forwardState{}
	p, routeErr := s.selectProviderExcluding(context.Background(), "rid-2", streamChatReq(), http.Header{}, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "slow" {
		t.Fatalf("provider=%q err=%+v", p.ProviderID, routeErr)
	}
	if state.routeDecision == nil || state.routeDecision.basis != routing.BasisFallback {
		t.Fatalf("decision = %+v", state.routeDecision)
	}
	trace := s.noteRouteTrace("rid-2", streamChatReq(), http.Header{}, p, state.routeDecision, 10)
	if !routeTraceGrammar.MatchString(trace) || !strings.Contains(trace, "basis=fallback; evidence=none; engine=unknown; latency=unknown") {
		t.Fatalf("trace = %q", trace)
	}
	// Stale evidence is the same as none.
	warmProvider(s, "slow", 800, 2000)
	warmProvider(s, "fast", 40, 1000)
	s.now = func() time.Time { return phaseTestNow.Add(routing.PerfFreshMaxAge + time.Minute) }
	state = &forwardState{}
	p, routeErr = s.selectProviderExcluding(context.Background(), "rid-3", streamChatReq(), http.Header{}, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "slow" || state.routeDecision.basis != routing.BasisFallback {
		t.Fatalf("stale: provider=%q decision=%+v err=%+v", p.ProviderID, state.routeDecision, routeErr)
	}
}

// SPEC-002-R007: a pinned route reports basis=pinned and the header never
// names the provider; the operator counter sees the selection.
func TestRouteTracePinnedAndCounted(t *testing.T) {
	s, _ := phaseTestServer(t)
	counter := &countingRouteMetrics{}
	s.routeMetrics = counter
	headers := http.Header{}
	headers.Set("X-MacProvider-Provider", "fast")
	headers.Set(internalPrivacyModeHeader, "owned_provider")
	p := poolProvider("fast")
	trace := s.noteRouteTrace("rid-4", streamChatReq(), headers, p, nil, 10)
	if !routeTraceGrammar.MatchString(trace) || !strings.Contains(trace, "basis=pinned") || strings.Contains(trace, "fast") {
		t.Fatalf("trace = %q", trace)
	}
	if counter.calls["interactive/pinned"] != 1 {
		t.Fatalf("counter = %v", counter.calls)
	}
	if internalPrivacyMode(headers) != "owned_provider" {
		t.Fatal("privacy mode label")
	}
	headers.Set(internalPrivacyModeHeader, "anything")
	if internalPrivacyMode(headers) != "unset" {
		t.Fatal("unknown privacy mode must be unset")
	}
}

type countingRouteMetrics struct{ calls map[string]int }

func (c *countingRouteMetrics) IncRouteSelection(phase, basis string) {
	if c.calls == nil {
		c.calls = map[string]int{}
	}
	c.calls[phase+"/"+basis]++
}

// SPEC-002-R005: only streamed, successful, coordinator-timed, plaintext
// attempts feed the store.
func TestServedPerformanceObservation(t *testing.T) {
	s, _ := phaseTestServer(t)
	record := func(stream bool, status int, relayBlind bool) {
		state := &forwardState{}
		state.phaseTiming.markProviderDispatchStart(phaseTestNow, "s-fast")
		state.phaseTiming.markProviderDispatchDone(phaseTestNow)
		state.phaseTiming.markProviderFirstByte(phaseTestNow.Add(50 * time.Millisecond))
		state.phaseTiming.markProviderDone(phaseTestNow.Add(1050 * time.Millisecond))
		rec := &billingRecorder{server: s, state: state, model: "model-a", stream: stream}
		if relayBlind {
			rec.relayBlind = &relayBlindAuditFields{}
		}
		prompt, completion := int64(500), int64(101)
		_ = rec.recordRow("s-fast", "fast", "", status, &prompt, nil, &completion, "", "", 0, nil, "", nil)
	}
	record(false, http.StatusOK, false)
	record(true, http.StatusBadGateway, false)
	record(true, http.StatusOK, true)
	if s.perf.Len() != 0 {
		t.Fatalf("non-stream, failed or relay-blind attempts were recorded: %d", s.perf.Len())
	}
	record(true, http.StatusOK, false)
	e, ok := s.perf.Lookup("fast", "model-a")
	if !ok || e.TTFTMs != 50 || e.PrefillTPS != 10000 || e.DecodeTPS != 100 || e.TTFTSamples != 1 {
		t.Fatalf("evidence = %+v ok=%v", e, ok)
	}
	// A timing snapshot for another session is not this attempt's timing.
	state := &forwardState{}
	state.phaseTiming.markProviderDispatchStart(phaseTestNow, "s-other")
	state.phaseTiming.markProviderDispatchDone(phaseTestNow)
	state.phaseTiming.markProviderFirstByte(phaseTestNow.Add(time.Millisecond))
	rec := &billingRecorder{server: s, state: state, model: "model-a", stream: true}
	prompt, completion := int64(500), int64(101)
	_ = rec.recordRow("s-fast", "fast", "", http.StatusOK, &prompt, nil, &completion, "", "", 0, nil, "", nil)
	if e, _ := s.perf.Lookup("fast", "model-a"); e.TTFTSamples != 1 {
		t.Fatalf("foreign timing recorded: %+v", e)
	}
}

func TestRequestMaxOutputTokens(t *testing.T) {
	for raw, want := range map[string]int{
		`{"max_tokens":256}`:  256,
		`{}`:                  0,
		`{"max_tokens":0}`:    0,
		`{"max_tokens":-5}`:   0,
		`{"max_tokens":"x"}`:  0,
		`{"max_tokens":1e12}`: 2147483647,
		`not json`:            0,
	} {
		if got := requestMaxOutputTokens([]byte(raw)); got != want {
			t.Errorf("%s: got %d want %d", raw, got, want)
		}
	}
}
