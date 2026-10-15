package buyer

import (
	mrand "math/rand"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/routing"
)

const (
	// routeTraceHeader is the SPEC-002-R007 buyer-visible route trace.
	routeTraceHeader = "X-MacProvider-Route-Trace"
	// internalPrivacyModeHeader carries the SPEC-006-R019 effective privacy
	// mode from the gateway; it only labels the route_trace line.
	internalPrivacyModeHeader = "X-MacProvider-Internal-Privacy-Mode"
)

// RouteSelectionMetrics counts SPEC-002-R007 selections by phase and basis.
type RouteSelectionMetrics interface {
	IncRouteSelection(phase, basis string)
}

// WithRouteSelectionMetrics wires the route_trace counter.
func WithRouteSelectionMetrics(m RouteSelectionMetrics) Option {
	return func(s *Server) {
		s.routeMetrics = m
	}
}

// routeDecision is the SPEC-002-R006 outcome of one plaintext selection.
type routeDecision struct {
	phase routing.Phase
	basis routing.Basis
	// scope is where the provider came from for the operator line:
	// ranked, sticky, pinned or slot_queue.
	scope       string
	inputTokens int
	candidates  int
	fresh       int
	scores      map[string]float64
	evidence    map[string]routing.PerfEvidence
}

// applyPhaseOrder runs the SPEC-002-R006 reorder on the objective-sorted
// candidates. Draws come from the request seed so a decision is reproducible
// within the day.
func (s *Server) applyPhaseOrder(requestID string, req chatRequest, estimatedTokens int, candidates []pool.Provider, dailyKey string) routeDecision {
	phase := routing.ClassifyPhase(estimatedTokens, req.maxTokens, req.Stream)
	if dailyKey == "" {
		dailyKey = defaultDailyKey()
	}
	// A distinct stream from the tiebreak draw: the tiebreak uses the first
	// value of this seed, the phase step the next two.
	rng := mrand.New(mrand.NewSource(seedForRequestWithKey(requestID, dailyKey)))
	_ = rng.Float64()
	exploreDraw, bandDraw := rng.Float64(), rng.Float64()
	d := routing.PhaseOrder(candidates, req.Model, phase, s.perf, s.now(), exploreDraw, bandDraw)
	return routeDecision{phase: d.Phase, basis: d.Basis, scope: "ranked", inputTokens: estimatedTokens, candidates: d.Candidates, fresh: d.Fresh, scores: d.Scores, evidence: d.Evidence}
}

// stickyRouteDecision describes a SPEC-004 sticky hit: the objective order
// with the sticky provider first, no phase reorder.
func (s *Server) stickyRouteDecision(req chatRequest, estimatedTokens int, candidates []pool.Provider) routeDecision {
	return routeDecision{
		phase:       routing.ClassifyPhase(estimatedTokens, req.maxTokens, req.Stream),
		basis:       routing.BasisFallback,
		scope:       "sticky",
		inputTokens: estimatedTokens,
		candidates:  len(candidates),
	}
}

// noteRouteTrace records the SPEC-002-R007 operator line and counter for the
// first selection of a plaintext request and returns the buyer header value.
func (s *Server) noteRouteTrace(requestID string, req chatRequest, headers http.Header, provider pool.Provider, decision *routeDecision, estimatedTokens int) string {
	d := routeDecision{basis: routing.BasisFallback, scope: "ranked", inputTokens: estimatedTokens}
	if decision != nil {
		d = *decision
	}
	if d.phase == "" {
		d.phase = routing.ClassifyPhase(estimatedTokens, req.maxTokens, req.Stream)
	}
	if hasPinnedRoute(headers) {
		d.basis, d.scope, d.candidates = routing.BasisPinned, "pinned", 1
	}
	evidence, ok := d.evidence[provider.SortKey()]
	if !ok {
		evidence, ok = s.perf.Lookup(provider.ProviderID, req.Model)
	}
	now := s.now()
	fresh := ok && evidence.FreshFor(d.phase, now)
	if d.scope != "ranked" && fresh {
		d.fresh = 1
	}
	ageS := int64(-1)
	if ok && !evidence.LastObserved.IsZero() {
		ageS = int64(now.Sub(evidence.LastObserved).Seconds())
	}
	engine := routing.EngineClass(provider)
	latency := routing.LatencyClass(d.phase, d.inputTokens, evidence, now)
	score, scored := d.scores[provider.SortKey()]
	event := s.log.Info().
		Str("event", "route_trace").
		Str("request_id", requestID).
		Str("provider_id", provider.ProviderID).
		Str("model", sanitizeRequestLogText(req.Model)).
		Str("phase", string(d.phase)).
		Str("basis", string(d.basis)).
		Str("scope", d.scope).
		Int("candidates", d.candidates).
		Int("fresh", d.fresh).
		Int("samples", evidence.TTFTSamples).
		Int("prefill_samples", evidence.PrefillSamples).
		Int("decode_samples", evidence.DecodeSamples).
		Int64("evidence_age_s", ageS).
		Str("engine", engine).
		Str("latency", latency).
		Str("privacy_mode", internalPrivacyMode(headers))
	if scored {
		event = event.Float64("score", score)
	} else {
		event = event.Float64("score", -1)
	}
	event.Send()
	if s.routeMetrics != nil {
		s.routeMetrics.IncRouteSelection(string(d.phase), string(d.basis))
	}
	return routing.RouteTraceHeader(d.phase, d.basis, fresh, engine, latency)
}

// internalPrivacyMode returns the gateway's SPEC-006-R019 effective mode, or
// "unset" for any other value. It never changes routing.
func internalPrivacyMode(headers http.Header) string {
	values := headers.Values(internalPrivacyModeHeader)
	if len(values) != 1 {
		return "unset"
	}
	switch v := strings.TrimSpace(values[0]); v {
	case "pool", "relay_blind_required", "owned_provider":
		return v
	default:
		return "unset"
	}
}

// markFirstTokenOnContent marks the SPEC-002-R005 first-token time when the
// first delivered event carries generated content or a tool call.
func (s *Server) markFirstTokenOnContent(acct *deliveredSSEAccounting, state *forwardState) {
	if acct == nil || state == nil {
		return
	}
	acct.onFirstContent = func() {
		state.phaseTiming.markProviderFirstToken(phaseTimingNow(s))
	}
}

// observeServedPerformance feeds one cleanly completed plaintext attempt into
// the SPEC-002-R005 store. Every rate is the coordinator's own: its clock, its
// token estimate of the request body for prefill, and its estimate of the
// generated output for decode. An attempt with a coordinator first-token time
// gives TTFT, prefill and decode samples; any other attempt (non-streamed or
// buffered) is end-to-end and gives only prefill and decode samples. Provider
// usage only withholds samples: a reported cached prefix withholds prefill,
// and a reported completion well above the generated output (hidden
// reasoning) withholds every rate that spans the whole service time.
func (b *billingRecorder) observeServedPerformance(providerAssignedID, providerID string, status int, cachedPromptTok, reportedCompTok *int64, output *billing.SettlementOutput, errMsg, errCode, faultFlag string) {
	s := b.server
	if s == nil || s.perf == nil || b.relayBlind != nil || status < 200 || status >= 300 {
		return
	}
	if errMsg != "" || errCode != "" || (faultFlag != "" && faultFlag != billing.FaultNone) {
		return
	}
	if providerAssignedID == "" || b.model == "" || b.state == nil {
		return
	}
	timing := b.state.phaseTiming.snapshot()
	if !timing.matchesProviderAssignedID(providerAssignedID) {
		return
	}
	if providerID == "" && s.pool != nil {
		for _, p := range s.pool.Snapshot() {
			if p.AssignedID == providerAssignedID {
				providerID = p.ProviderID
				break
			}
		}
	}
	generated := generatedOutputTokens(output)
	hidden := reportedCompTok != nil && *reportedCompTok > perfHiddenOutputFactor*generated+routing.PerfMinDecodeTokens
	prompt := int64(b.state.routingEstimatedTokens)
	if (cachedPromptTok != nil && *cachedPromptTok > 0) || hidden {
		prompt = 0
	}
	obs := routing.PerfObservation{
		ProviderID:       providerID,
		Model:            b.model,
		PromptTokens:     prompt,
		CompletionTokens: generated,
		At:               s.now(),
	}
	if ttft := timing.routingTTFTMs(); ttft != nil {
		obs.TTFTMs = *ttft
		if decode := timing.routingDecodeMs(); decode != nil {
			obs.DecodeMs = *decode
		}
		if service := timing.routingServiceMs(); service != nil {
			obs.ServiceMs = *service
		}
	} else {
		if hidden {
			return
		}
		service := timing.routingEndToEndServiceMs()
		if service == nil {
			return
		}
		obs.EndToEnd = true
		obs.ServiceMs = *service
		obs.RequestTokens = int64(b.state.routingEstimatedTokens)
	}
	s.perf.Observe(obs)
}

// perfHiddenOutputFactor: a reported completion above this many times the
// generated-output estimate (plus PerfMinDecodeTokens) means generation the
// coordinator did not see, such as reasoning.
const perfHiddenOutputFactor = 2

// perfOutputBytesPerToken converts generated bytes into the SPEC-002-R005
// output token estimate.
const perfOutputBytesPerToken = 4

// generatedOutputTokens estimates the tokens of the content and tool calls the
// coordinator delivered for an attempt, from its own settlement output: the
// same quantity for streamed and non-streamed responses.
func generatedOutputTokens(output *billing.SettlementOutput) int64 {
	if output == nil || output.RelayBlindResponseSHA256 != "" {
		return 0
	}
	n := int64(len(output.Content))
	for _, call := range output.ToolCalls {
		n += int64(len(call.Name) + len(call.Arguments))
	}
	return (n + perfOutputBytesPerToken - 1) / perfOutputBytesPerToken
}
