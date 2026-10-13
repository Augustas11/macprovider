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
		Model:     "model-a",
		Stream:    true,
		maxTokens: 256,
		raw:       []byte(`{"model":"model-a","stream":true,"max_tokens":256,"messages":[{"role":"user","content":"hi"}]}`),
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

// SPEC-002-R005: only streamed, cleanly completed, plaintext attempts with a
// coordinator-timed first token feed the store, and every quantity is the
// coordinator's own.
func TestServedPerformanceObservation(t *testing.T) {
	s, _ := phaseTestServer(t)
	type attempt struct {
		stream, relayBlind, firstToken bool
		status                         int
		errMsg, errCode, fault         string
		cached                         int64
	}
	record := func(a attempt) {
		state := &forwardState{estimatedTokens: 500}
		state.phaseTiming.markProviderDispatchStart(phaseTestNow, "s-fast")
		state.phaseTiming.markProviderDispatchDone(phaseTestNow)
		// A role-only opening chunk is a first byte, not a first token.
		state.phaseTiming.markProviderFirstByte(phaseTestNow.Add(time.Millisecond))
		if a.firstToken {
			state.phaseTiming.markProviderFirstToken(phaseTestNow.Add(50 * time.Millisecond))
		}
		state.phaseTiming.markProviderDone(phaseTestNow.Add(1050 * time.Millisecond))
		rec := &billingRecorder{server: s, state: state, model: "model-a", stream: a.stream}
		if a.relayBlind {
			rec.relayBlind = &relayBlindAuditFields{}
		}
		// Inflated provider usage must not matter.
		prompt, completion, delivered := int64(1_000_000), int64(1_000_000), int64(101)
		cached := a.cached
		_ = rec.recordRow("s-fast", "fast", "", a.status, &prompt, &cached, &completion, a.errMsg, a.errCode, 0, &delivered, a.fault, nil)
	}
	ok := attempt{stream: true, firstToken: true, status: http.StatusOK, fault: "none"}
	for name, a := range map[string]attempt{
		"non-stream":     {stream: false, firstToken: true, status: http.StatusOK},
		"failed":         {stream: true, firstToken: true, status: http.StatusBadGateway},
		"relay-blind":    {stream: true, firstToken: true, status: http.StatusOK, relayBlind: true},
		"no first token": {stream: true, status: http.StatusOK},
		"partial stream": {stream: true, firstToken: true, status: http.StatusOK, errMsg: "Provider disconnected during streaming"},
		"error code":     {stream: true, firstToken: true, status: http.StatusOK, errCode: "malformed_tool_call"},
		"breaker fault":  {stream: true, firstToken: true, status: http.StatusOK, fault: "breaker_qualifying"},
	} {
		record(a)
		if s.perf.Len() != 0 {
			t.Fatalf("%s attempt was recorded", name)
		}
	}
	record(ok)
	e, found := s.perf.Lookup("fast", "model-a")
	if !found || e.TTFTMs != 50 || e.PrefillTPS != 10000 || e.DecodeTPS != 100 || e.TTFTSamples != 1 {
		t.Fatalf("evidence = %+v found=%v", e, found)
	}
	// A reported cached prefix withholds the prefill sample only.
	cachedAttempt := ok
	cachedAttempt.cached = 400
	record(cachedAttempt)
	if e, _ := s.perf.Lookup("fast", "model-a"); e.TTFTSamples != 2 || e.PrefillSamples != 1 || e.DecodeSamples != 2 {
		t.Fatalf("cached prefix: %+v", e)
	}
	// A timing snapshot for another session is not this attempt's timing.
	state := &forwardState{estimatedTokens: 500}
	state.phaseTiming.markProviderDispatchStart(phaseTestNow, "s-other")
	state.phaseTiming.markProviderDispatchDone(phaseTestNow)
	state.phaseTiming.markProviderFirstToken(phaseTestNow.Add(time.Millisecond))
	rec := &billingRecorder{server: s, state: state, model: "model-a", stream: true}
	delivered := int64(101)
	_ = rec.recordRow("s-fast", "fast", "", http.StatusOK, nil, nil, nil, "", "", 0, &delivered, "", nil)
	if e, _ := s.perf.Lookup("fast", "model-a"); e.TTFTSamples != 2 {
		t.Fatalf("foreign timing recorded: %+v", e)
	}
}

// The first-token mark fires on the first delivered event that carries
// generated content, not on a role-only opening event.
func TestFirstTokenMarkedOnFirstContent(t *testing.T) {
	s, _ := phaseTestServer(t)
	state := &forwardState{}
	state.phaseTiming.markProviderDispatchStart(phaseTestNow, "s-fast")
	acct := newDeliveredSSEAccounting()
	s.markFirstTokenOnContent(acct, state)
	acct.written([]byte("data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n"))
	if !state.phaseTiming.snapshot().providerFirstToken.IsZero() {
		t.Fatal("role-only event marked a first token")
	}
	acct.written([]byte("data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\n"))
	if state.phaseTiming.snapshot().providerFirstToken.IsZero() {
		t.Fatal("content event did not mark a first token")
	}
}

func TestValidateChatRequestCapturesMaxTokens(t *testing.T) {
	req, status, _, _, _ := validateChatRequestDetailed([]byte(`{"model":"m","max_tokens":256,"messages":[{"role":"user","content":"hi"}]}`))
	if status != 0 || req.maxTokens != 256 {
		t.Fatalf("status=%d maxTokens=%d", status, req.maxTokens)
	}
	req, status, _, _, _ = validateChatRequestDetailed([]byte(`{"model":"m","messages":[{"role":"user","content":"hi"}]}`))
	if status != 0 || req.maxTokens != 0 {
		t.Fatalf("absent: status=%d maxTokens=%d", status, req.maxTokens)
	}
}

// SPEC-004 sticky affinity is judged against the objective order: a sticky
// hit keeps its provider even when phase evidence prefers another.
func TestStickyHitSkipsPhaseReorder(t *testing.T) {
	s, _ := phaseTestServer(t)
	s.stickyEnabled = true
	warmProvider(s, "slow", 800, 2000)
	warmProvider(s, "fast", 40, 1000)
	headers := http.Header{}
	headers.Set("Authorization", "Bearer gateway-secret")
	headers.Set("X-MacProvider-Account", "acct-1")
	headers.Set("X-MacProvider-Internal-Conv", "conv:phase-sticky")
	s.stickyMap.Update("conv:phase-sticky", "acct-1", "slow", "model-a")
	state := &forwardState{}
	p, routeErr := s.selectProviderExcluding(context.Background(), "rid-s", streamChatReq(), headers, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "slow" {
		t.Fatalf("provider=%q err=%+v", p.ProviderID, routeErr)
	}
	if state.stickyResult != "hit" || state.routeDecision == nil || state.routeDecision.scope != "sticky" || state.routeDecision.basis != routing.BasisFallback {
		t.Fatalf("sticky=%q decision=%+v", state.stickyResult, state.routeDecision)
	}
}
