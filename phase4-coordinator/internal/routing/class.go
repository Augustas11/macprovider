package routing

import "github.com/augstar/macprovider-coordinator/internal/pool"

// BalancedScores computes the SPEC-004 FR-SR-8 'balanced' objective
// score for each candidate in the eligible set, returning a slice
// of length len(candidates) (score for candidates[i] at out[i]).
// The formula is normative in SPEC-004 v0.2 §FR-SR-8:
//
//	score(p) = 0.4 * norm(throughput_tps_estimate)
//	         + 0.3 * norm(model_params_b)
//	         + 0.2 * norm(max_context_tokens)
//	         + 0.1 * norm(slots_free / max(1, slots_total))
//
// norm(x) is min-max normalization across the eligible candidate
// set for the SAME request; when every candidate has the same
// component value, that component's normalized value is 1.0 for
// every candidate (per SPEC §FR-SR-8 last paragraph). Weights are
// normative in v0.2 and MAY be made operator-tunable only in a
// future minor revision (NOT here).
//
// The function returns indexed scores rather than a keyed map so
// the caller decides the key shape (buyer.routeKey, peer_id, etc.)
// without forcing routing/ to know buyer-internal key derivation.
//
// Per SPEC FR-SR-8 last paragraph the coordinator MUST log the
// individual component values (norm(tps) / norm(params) /
// norm(ctx) / norm(slots)) alongside the final score. Phase D
// step 1 + 2 land the canonical log surface (routing.Decision /
// LogRoutingDecision) and the score formula here; surfacing the
// individual component values into the routing-decision log is a
// follow-up extraction tracked under Phase D's "objective.go +
// per-component logging" deferred work (see commit c2d7e73). A
// future BalancedScoreComponents helper would return the four
// norm values per candidate; not exposed in this PR.
func BalancedScores(candidates []pool.Provider) []float64 {
	scores := make([]float64, len(candidates))
	if len(candidates) == 0 {
		return scores
	}
	tps := make([]float64, len(candidates))
	params := make([]float64, len(candidates))
	ctx := make([]float64, len(candidates))
	slots := make([]float64, len(candidates))
	for i, p := range candidates {
		tps[i] = p.ThroughputTPSEstimate
		params[i] = p.ModelParamsB
		ctx[i] = float64(p.MaxContextTokens)
		if p.SlotsTotal > 0 {
			slots[i] = float64(p.SlotsFree) / float64(p.SlotsTotal)
		}
	}
	for i := range candidates {
		scores[i] = 0.4*minMaxNorm(tps, i) +
			0.3*minMaxNorm(params, i) +
			0.2*minMaxNorm(ctx, i) +
			0.1*minMaxNorm(slots, i)
	}
	return scores
}

// minMaxNorm normalizes values[idx] across the candidate set per
// SPEC-004 FR-SR-8: returns 1.0 when every value is identical
// (no spread); otherwise (values[idx] - min) / (max - min).
// Empty input returns 1.0 (defensive; no candidate ever passes a
// 0-length slice in practice).
func minMaxNorm(values []float64, idx int) float64 {
	if len(values) == 0 {
		return 1
	}
	minV, maxV := values[0], values[0]
	for _, v := range values[1:] {
		if v < minV {
			minV = v
		}
		if v > maxV {
			maxV = v
		}
	}
	if maxV == minV {
		return 1
	}
	return (values[idx] - minV) / (maxV - minV)
}
