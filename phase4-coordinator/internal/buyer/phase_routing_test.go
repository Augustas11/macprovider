package buyer

import (
	"context"
	"math"
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

// SPEC-002-R005/R006 on a non-stream-heavy network: end-to-end evidence
// alone ranks a non-streamed (throughput) request, and the same evidence is
// no evidence for a streamed (interactive) one, whose first-token latency it
// cannot describe.
func TestPhaseAwareSelectionUsesNonStreamEvidence(t *testing.T) {
	s, _ := phaseTestServer(t)
	for _, w := range []struct {
		id     string
		tokens int64
	}{{"slow", 40}, {"fast", 160}} {
		for i := 0; i < routing.PerfFreshMinSamples; i++ {
			s.perf.Observe(routing.PerfObservation{ProviderID: w.id, Model: "model-a", EndToEnd: true, RequestTokens: 20, PromptTokens: 20, CompletionTokens: w.tokens, ServiceMs: 2000, At: phaseTestNow})
		}
	}
	req := streamChatReq()
	req.Stream = false
	req.raw = []byte(`{"model":"model-a","max_tokens":256,"messages":[{"role":"user","content":"hi"}]}`)
	state := &forwardState{}
	p, routeErr := s.selectProviderExcluding(context.Background(), "rid-ns", req, http.Header{}, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "fast" {
		t.Fatalf("provider=%q err=%+v", p.ProviderID, routeErr)
	}
	if state.routeDecision == nil || state.routeDecision.phase != routing.PhaseThroughput || state.routeDecision.basis != routing.BasisMeasured || state.routeDecision.fresh != 2 {
		t.Fatalf("decision = %+v", state.routeDecision)
	}
	trace := s.noteRouteTrace("rid-ns", req, http.Header{}, p, state.routeDecision, 10)
	if !strings.Contains(trace, "phase=throughput; basis=measured; evidence=fresh;") || !strings.HasSuffix(trace, "latency=unknown") {
		t.Fatalf("trace = %q", trace)
	}
	state = &forwardState{}
	p, routeErr = s.selectProviderExcluding(context.Background(), "rid-st", streamChatReq(), http.Header{}, nil, "2026-10-13", state)
	if routeErr != nil || p.ProviderID != "slow" || state.routeDecision.basis != routing.BasisFallback || state.routeDecision.fresh != 0 {
		t.Fatalf("interactive: provider=%q decision=%+v err=%+v", p.ProviderID, state.routeDecision, routeErr)
	}
	trace = s.noteRouteTrace("rid-st", streamChatReq(), http.Header{}, p, state.routeDecision, 10)
	if !strings.Contains(trace, "basis=fallback; evidence=none;") || !strings.HasSuffix(trace, "latency=unknown") {
		t.Fatalf("interactive trace = %q", trace)
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

// SPEC-002-R005: only cleanly completed plaintext attempts feed the store,
// and every rate is the coordinator's own. A streamed attempt with a
// first-token time gives TTFT, prefill and decode; a non-streamed one is
// end-to-end and gives no TTFT.
func TestServedPerformanceObservation(t *testing.T) {
	s, _ := phaseTestServer(t)
	type attempt struct {
		model                       string
		stream, relayBlind          bool
		firstToken                  bool
		status                      int
		errMsg, errCode, fault      string
		estimate                    int
		contentBytes                int
		reported, cached            int64
		dispatchAccepted, serviceMs int
		foreignTiming               bool
	}
	record := func(a attempt) {
		state := &forwardState{estimatedTokens: a.estimate, routingEstimatedTokens: a.estimate}
		session := "s-fast"
		if a.foreignTiming {
			session = "s-other"
		}
		state.phaseTiming.markProviderDispatchStart(phaseTestNow, session)
		state.phaseTiming.markProviderDispatchDone(phaseTestNow.Add(time.Duration(a.dispatchAccepted) * time.Millisecond))
		// A role-only opening chunk is a first byte, not a first token.
		state.phaseTiming.markProviderFirstByte(phaseTestNow.Add(time.Millisecond))
		if a.firstToken {
			state.phaseTiming.markProviderFirstToken(phaseTestNow.Add(50 * time.Millisecond))
		}
		state.phaseTiming.markProviderDone(phaseTestNow.Add(time.Duration(a.serviceMs) * time.Millisecond))
		rec := &billingRecorder{server: s, state: state, model: a.model, stream: a.stream}
		if a.relayBlind {
			rec.relayBlind = &relayBlindAuditFields{}
		}
		prompt, reported, delivered := int64(1_000_000), a.reported, int64(1_000_000)
		cached := a.cached
		output := settlementOutputForContent(strings.Repeat("x", a.contentBytes), nil, nil, "normal_done")
		_ = rec.recordRow("s-fast", "fast", "", a.status, &prompt, &cached, &reported, a.errMsg, a.errCode, 0, &delivered, a.fault, output)
	}
	// 404 generated bytes are 101 output tokens.
	streamed := attempt{model: "stream", stream: true, firstToken: true, status: http.StatusOK, fault: "none", estimate: 4000, contentBytes: 404, reported: 101, serviceMs: 1050}
	for name, a := range map[string]attempt{
		"failed":         {stream: true, firstToken: true, status: http.StatusBadGateway},
		"relay-blind":    {stream: true, firstToken: true, status: http.StatusOK, relayBlind: true},
		"partial stream": {stream: true, firstToken: true, status: http.StatusOK, errMsg: "Provider disconnected during streaming"},
		"error code":     {stream: true, firstToken: true, status: http.StatusOK, errCode: "malformed_tool_call"},
		"breaker fault":  {stream: true, firstToken: true, status: http.StatusOK, fault: "breaker_qualifying"},
		"foreign timing": {stream: true, firstToken: true, status: http.StatusOK, foreignTiming: true},
	} {
		base := streamed
		base.stream, base.firstToken, base.status, base.relayBlind = a.stream, a.firstToken, a.status, a.relayBlind
		base.errMsg, base.errCode, base.fault, base.foreignTiming = a.errMsg, a.errCode, a.fault, a.foreignTiming
		record(base)
		if s.perf.Len() != 0 {
			t.Fatalf("%s attempt was recorded", name)
		}
	}
	record(streamed)
	e, found := s.perf.Lookup("fast", "stream")
	// Prefill: 4000 estimated input tokens over the 1050 ms service time.
	// Decode: 100 tokens after the first over the 1 s after it.
	if !found || e.TTFTMs != 50 || math.Abs(e.PrefillTPS-4000/1.05) > 1e-9 || e.DecodeTPS != 100 || e.TTFTSamples != 1 {
		t.Fatalf("evidence = %+v found=%v", e, found)
	}
	// A reported cached prefix, or a reported completion far above the
	// generated output, withholds the prefill sample only; inflated usage
	// never raises a rate.
	cachedAttempt := streamed
	cachedAttempt.cached = 400
	record(cachedAttempt)
	inflated := streamed
	inflated.reported = 1_000_000
	record(inflated)
	if e, _ := s.perf.Lookup("fast", "stream"); e.TTFTSamples != 3 || e.PrefillSamples != 1 || e.DecodeSamples != 3 || e.DecodeTPS != 100 {
		t.Fatalf("withheld prefill: %+v", e)
	}

	// Non-streamed: the provider accepted the dispatch only after 3 s, as an
	// HTTP provider that sends its headers when done would; the service time
	// still runs from dispatch start. 800 bytes are 200 tokens over 4 s.
	nonStream := attempt{model: "non-stream", status: http.StatusOK, estimate: 300, contentBytes: 800, reported: 200, dispatchAccepted: 3000, serviceMs: 4000}
	record(nonStream)
	e, found = s.perf.Lookup("fast", "non-stream")
	if !found || e.DecodeTPS != 50 || e.DecodeSamples != 1 || e.TTFTSamples != 0 || e.TTFTMs != 0 || e.PrefillSamples != 0 {
		t.Fatalf("non-stream evidence = %+v found=%v", e, found)
	}
	// A streamed attempt without a first-token time (buffered) is end-to-end.
	buffered := nonStream
	buffered.stream = true
	record(buffered)
	if e, _ := s.perf.Lookup("fast", "non-stream"); e.DecodeSamples != 2 || e.TTFTSamples != 0 {
		t.Fatalf("buffered stream: %+v", e)
	}
	// Hidden generation (reported completion well above the generated output)
	// withholds the end-to-end sample entirely.
	hidden := nonStream
	hidden.reported = 2*200 + routing.PerfMinDecodeTokens + 1
	record(hidden)
	if e, _ := s.perf.Lookup("fast", "non-stream"); e.DecodeSamples != 2 {
		t.Fatalf("hidden generation recorded: %+v", e)
	}
	// A prompt-heavy non-streamed attempt is neither a decode nor a prefill
	// measurement and creates no record.
	heavy := nonStream
	heavy.model, heavy.estimate = "heavy", 4*200+1
	record(heavy)
	if _, ok := s.perf.Lookup("fast", "heavy"); ok {
		t.Fatal("prompt-heavy non-stream attempt was recorded")
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
