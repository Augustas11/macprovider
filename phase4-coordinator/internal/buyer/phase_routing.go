package buyer

import (
	"encoding/json"
	"math"
	mrand "math/rand"
	"net/http"
	"strings"

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
	phase       routing.Phase
	basis       routing.Basis
	inputTokens int
	candidates  int
	fresh       int
	scores      map[string]float64
	evidence    map[string]routing.PerfEvidence
}

// requestMaxOutputTokens returns the body's max_tokens, or 0 when absent or
// unusable (the phase classifier then uses its default).
func requestMaxOutputTokens(raw json.RawMessage) int {
	var body struct {
		MaxTokens *float64 `json:"max_tokens"`
	}
	if err := json.Unmarshal(raw, &body); err != nil || body.MaxTokens == nil {
		return 0
	}
	v := *body.MaxTokens
	if math.IsNaN(v) || v <= 0 {
		return 0
	}
	if v > math.MaxInt32 {
		return math.MaxInt32
	}
	return int(v)
}

// applyPhaseOrder runs the SPEC-002-R006 reorder on the objective-sorted
// candidates. Draws come from the request seed so a decision is reproducible
// within the day.
func (s *Server) applyPhaseOrder(requestID string, req chatRequest, estimatedTokens int, candidates []pool.Provider, dailyKey string) routeDecision {
	phase := routing.ClassifyPhase(estimatedTokens, requestMaxOutputTokens(req.raw), req.Stream)
	if dailyKey == "" {
		dailyKey = defaultDailyKey()
	}
	// A distinct stream from the tiebreak draw: the tiebreak uses the first
	// value of this seed, the phase step the next two.
	rng := mrand.New(mrand.NewSource(seedForRequestWithKey(requestID, dailyKey)))
	_ = rng.Float64()
	exploreDraw, bandDraw := rng.Float64(), rng.Float64()
	d := routing.PhaseOrder(candidates, req.Model, phase, s.perf, s.now(), exploreDraw, bandDraw)
	return routeDecision{phase: d.Phase, basis: d.Basis, inputTokens: estimatedTokens, candidates: d.Candidates, fresh: d.Fresh, scores: d.Scores, evidence: d.Evidence}
}

// noteRouteTrace records the SPEC-002-R007 operator line and counter for the
// first selection of a plaintext request and returns the buyer header value.
func (s *Server) noteRouteTrace(requestID string, req chatRequest, headers http.Header, provider pool.Provider, decision *routeDecision, estimatedTokens int) string {
	d := routeDecision{basis: routing.BasisFallback, inputTokens: estimatedTokens}
	if decision != nil {
		d = *decision
	}
	if d.phase == "" {
		d.phase = routing.ClassifyPhase(estimatedTokens, requestMaxOutputTokens(req.raw), req.Stream)
	}
	if hasPinnedRoute(headers) {
		d.basis = routing.BasisPinned
	}
	evidence, ok := d.evidence[provider.SortKey()]
	if !ok {
		evidence, ok = s.perf.Lookup(provider.ProviderID, req.Model)
	}
	now := s.now()
	fresh := ok && evidence.Fresh(now)
	ageS := int64(-1)
	if ok && !evidence.LastObserved.IsZero() {
		ageS = int64(now.Sub(evidence.LastObserved).Seconds())
	}
	engine := routing.EngineClass(provider)
	latency := routing.LatencyClass(d.phase, d.inputTokens, evidence, fresh)
	score, scored := d.scores[provider.SortKey()]
	event := s.log.Info().
		Str("event", "route_trace").
		Str("request_id", requestID).
		Str("provider_id", provider.ProviderID).
		Str("model", sanitizeRequestLogText(req.Model)).
		Str("phase", string(d.phase)).
		Str("basis", string(d.basis)).
		Int("candidates", d.candidates).
		Int("fresh", d.fresh).
		Int("samples", evidence.TTFTSamples).
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

// observeServedPerformance feeds one streamed, successful, coordinator-timed
// attempt into the SPEC-002-R005 store. Relay-blind attempts are skipped:
// their token counts are upper bounds.
func (b *billingRecorder) observeServedPerformance(providerAssignedID, providerID string, status int, promptTok, cachedPromptTok, completionTok *int64) {
	s := b.server
	if s == nil || s.perf == nil || b.relayBlind != nil || !b.stream || status < 200 || status >= 300 {
		return
	}
	if providerAssignedID == "" || promptTok == nil || completionTok == nil || b.model == "" || b.state == nil {
		return
	}
	timing := b.state.phaseTiming.snapshot()
	if !timing.matchesProviderAssignedID(providerAssignedID) {
		return
	}
	ttft, decode := timing.requestLogTTFTMs(), timing.requestLogDecodeMs()
	if ttft == nil {
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
	var cached int64
	if cachedPromptTok != nil {
		cached = *cachedPromptTok
	}
	var decodeMs float64
	if decode != nil {
		decodeMs = *decode
	}
	s.perf.Observe(routing.PerfObservation{
		ProviderID:         providerID,
		Model:              b.model,
		PromptTokens:       *promptTok,
		CachedPromptTokens: cached,
		CompletionTokens:   *completionTok,
		TTFTMs:             *ttft,
		DecodeMs:           decodeMs,
		At:                 s.now(),
	})
}
