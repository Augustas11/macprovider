package routing

import (
	"math"
	"sort"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// Phase is the SPEC-002-R006 request shape.
type Phase string

const (
	PhaseInteractive Phase = "interactive"
	PhaseLongInput   Phase = "long_input"
	PhaseThroughput  Phase = "throughput"
)

// Basis names why the order was chosen (SPEC-002-R007).
type Basis string

const (
	BasisMeasured Basis = "measured"
	BasisExplore  Basis = "explore"
	BasisFallback Basis = "fallback"
	BasisPinned   Basis = "pinned"
)

const (
	PhaseDefaultMaxOut        = 512
	PhaseLongInputMinTokens   = 2048
	PhaseLongInputOutputRatio = 4
	PhaseBandFraction         = 0.85
	PhaseExplorationShare     = 0.10
)

// ClassifyPhase maps the request shape onto a phase. maxOut <= 0 means the
// buyer sent no max_tokens.
func ClassifyPhase(inputTokens, maxOut int, stream bool) Phase {
	if maxOut <= 0 {
		maxOut = PhaseDefaultMaxOut
	}
	if inputTokens >= PhaseLongInputMinTokens && inputTokens >= PhaseLongInputOutputRatio*maxOut {
		return PhaseLongInput
	}
	if stream {
		return PhaseInteractive
	}
	return PhaseThroughput
}

// PhaseDecision is the outcome of PhaseOrder. Scores and Evidence are keyed
// by pool.Provider.SortKey(); only candidates fresh for the phase appear in
// them.
type PhaseDecision struct {
	Phase      Phase
	Basis      Basis
	Candidates int
	Fresh      int
	Scores     map[string]float64
	Evidence   map[string]PerfEvidence
}

// PhaseOrder reorders the objective-sorted candidates by phase without adding
// or removing any. exploreDraw and bandDraw are per-request draws in [0,1).
func PhaseOrder(candidates []pool.Provider, model string, phase Phase, store *PerfStore, now time.Time, exploreDraw, bandDraw float64) PhaseDecision {
	decision := PhaseDecision{Phase: phase, Basis: BasisFallback, Candidates: len(candidates), Scores: map[string]float64{}, Evidence: map[string]PerfEvidence{}}
	if len(candidates) == 0 || store == nil {
		return decision
	}
	ids := make([]string, len(candidates))
	for i, p := range candidates {
		ids[i] = p.ProviderID
	}
	records := store.LookupMany(model, ids)
	var fresh, unmeasured []pool.Provider
	for _, p := range candidates {
		if e, ok := records[p.ProviderID]; ok && e.FreshFor(phase, now) {
			fresh = append(fresh, p)
			decision.Evidence[p.SortKey()] = e
			continue
		}
		unmeasured = append(unmeasured, p)
	}
	decision.Fresh = len(fresh)
	if len(fresh) == 0 {
		return decision
	}
	scorePhase(fresh, phase, decision.Evidence, decision.Scores, now)
	sort.SliceStable(fresh, func(i, j int) bool {
		return decision.Scores[fresh[i].SortKey()] > decision.Scores[fresh[j].SortKey()]
	})
	if len(unmeasured) > 0 && exploreDraw < PhaseExplorationShare {
		decision.Basis = BasisExplore
		copy(candidates, append(unmeasured, fresh...))
		return decision
	}
	if len(fresh) < 2 {
		return decision
	}
	best := decision.Scores[fresh[0].SortKey()]
	band := 1
	for band < len(fresh) && decision.Scores[fresh[band].SortKey()] >= PhaseBandFraction*best {
		band++
	}
	pick := int(bandDraw * float64(band))
	if pick >= band {
		pick = band - 1
	}
	if pick < 0 {
		pick = 0
	}
	if pick != 0 {
		chosen := fresh[pick]
		copy(fresh[1:pick+1], fresh[0:pick])
		fresh[0] = chosen
	}
	decision.Basis = BasisMeasured
	copy(candidates, append(fresh, unmeasured...))
	return decision
}

func freeShare(p pool.Provider) float64 {
	if p.SlotsTotal <= 0 {
		return 0
	}
	return clampFloat(float64(p.SlotsFree)/float64(p.SlotsTotal), 0, 1)
}

// scorePhase scores candidates that are fresh for phase. A secondary signal
// not observed within PerfFreshMaxAge contributes 0, never a favourable value.
func scorePhase(fresh []pool.Provider, phase Phase, evidence map[string]PerfEvidence, scores map[string]float64, now time.Time) {
	decode := make(map[string]float64, len(fresh))
	prefill := make(map[string]float64, len(fresh))
	var minTTFT, maxDecode, maxPrefill, maxSlotService float64
	for i, p := range fresh {
		e := evidence[p.SortKey()]
		d := e.decodeAt(now, p.ThroughputTPSEstimate)
		decode[p.SortKey()] = d
		prefill[p.SortKey()] = e.prefillAt(now)
		if i == 0 || e.TTFTMs < minTTFT {
			minTTFT = e.TTFTMs
		}
		maxDecode = math.Max(maxDecode, d)
		maxPrefill = math.Max(maxPrefill, prefill[p.SortKey()])
		maxSlotService = math.Max(maxSlotService, float64(max(p.SlotsFree, 0))*e.ServiceTPS)
	}
	ratio := func(v, best float64) float64 {
		if best <= 0 {
			return 0
		}
		return clampFloat(v/best, 0, 1)
	}
	for _, p := range fresh {
		key := p.SortKey()
		e := evidence[key]
		load := 0.5 + 0.5*freeShare(p)
		var s float64
		switch phase {
		case PhaseLongInput:
			s = (0.8*ratio(prefill[key], maxPrefill) + 0.2*ratio(decode[key], maxDecode)) * load
		case PhaseThroughput:
			s = ratio(float64(max(p.SlotsFree, 0))*e.ServiceTPS, maxSlotService)
		default:
			ttftTerm := 0.0
			if e.TTFTMs > 0 {
				ttftTerm = clampFloat(minTTFT/e.TTFTMs, 0, 1)
			}
			s = (0.5*ttftTerm + 0.5*ratio(decode[key], maxDecode)) * load
		}
		scores[key] = s
	}
}

// LatencyClass buckets the expected time to first token (SPEC-002-R007):
// input over the prefill average for long_input when prefill is fresh, else
// the TTFT average when TTFT is fresh, else unknown. Decode-only evidence
// says nothing about the first token.
func LatencyClass(phase Phase, inputTokens int, e PerfEvidence, now time.Time) string {
	var ms float64
	switch {
	case phase == PhaseLongInput && e.PrefillFresh(now) && e.PrefillTPS > 0:
		ms = float64(inputTokens) / e.PrefillTPS * 1000
	case e.TTFTFresh(now):
		ms = e.TTFTMs
	default:
		return "unknown"
	}
	switch {
	case ms < 500:
		return "low"
	case ms < 2000:
		return "medium"
	default:
		return "high"
	}
}

// EngineClass returns the buyer-visible engine family of a provider.
func EngineClass(p pool.Provider) string {
	if p.EngineProfile == nil {
		return "unknown"
	}
	switch p.EngineProfile.EngineFamily {
	case "general_mlx", "continuous_batching", "native_mtp":
		return p.EngineProfile.EngineFamily
	default:
		return "unknown"
	}
}

// RouteTraceHeader renders the SPEC-002-R007 buyer-visible trace.
func RouteTraceHeader(phase Phase, basis Basis, fresh bool, engine, latency string) string {
	evidence := "none"
	if fresh {
		evidence = "fresh"
	}
	return "v=1; phase=" + string(phase) + "; basis=" + string(basis) + "; evidence=" + evidence + "; engine=" + engine + "; latency=" + latency
}
