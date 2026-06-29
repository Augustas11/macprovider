// Tests for the per-pair drift fix (issue #226). The aggregate-sum
// approach in the pre-fix reconciler false-failed I1 whenever the
// gateway settled most successful streams as SPEC-006 §17.7 fallback
// outcomes — the gateway "ok"-only completion-tokens total covered
// only a small subset of rows while the harness "ok" total covered
// every success. Per-pair drift uses the matched-pair token deltas
// exclusively, so the population-mismatch can't bias the answer.
package reconcile

import (
	"testing"
)

// TestComputePerPairDrift_CleanMatches verifies that matched pairs with
// identical token counts yield zero drift. This is the happy path:
// every harness success matches a gateway row with the exact same token
// count, every gateway row has a coord counterpart with the same count.
func TestComputePerPairDrift_CleanMatches(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, CoordinatorRequestID: "c1", CoordinatorCompletionTokens: 8},
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, CoordinatorRequestID: "c2", CoordinatorCompletionTokens: 8},
			{HarnessCompletionTokens: 16, GatewayCompletionTokens: 16, CoordinatorRequestID: "c3", CoordinatorCompletionTokens: 16},
		},
	}
	computePerPairDrift(r)
	if r.GatewayMinusHarnessTokens != 0 {
		t.Errorf("clean matches: want gateway-harness drift 0, got %d", r.GatewayMinusHarnessTokens)
	}
	if r.GatewayMinusCoordinatorTokens != 0 {
		t.Errorf("clean matches: want gateway-coord drift 0, got %d", r.GatewayMinusCoordinatorTokens)
	}
}

// TestComputePerPairDrift_RealOvercharge verifies that an actual
// money-path overcharge (gateway billed more than harness saw) is
// surfaced as positive drift. This is the signal I1 needs to keep
// firing on — the bug fix must preserve it.
func TestComputePerPairDrift_RealOvercharge(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 12, CoordinatorRequestID: "c1", CoordinatorCompletionTokens: 8},  // +4 overcharge
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 10, CoordinatorRequestID: "c2", CoordinatorCompletionTokens: 8},  // +2 overcharge
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, CoordinatorRequestID: "c3", CoordinatorCompletionTokens: 8},   // clean
		},
	}
	computePerPairDrift(r)
	// Two pairs over-billed by 4 + 2 = 6
	if r.GatewayMinusHarnessTokens != 6 {
		t.Errorf("overcharge: want drift +6, got %d", r.GatewayMinusHarnessTokens)
	}
	// Gateway-coord: gateway also exceeds coord by 6
	if r.GatewayMinusCoordinatorTokens != 6 {
		t.Errorf("overcharge vs coord: want drift +6, got %d", r.GatewayMinusCoordinatorTokens)
	}
}

// TestComputePerPairDrift_ScenarioSevenFromProduction is the production
// trip from the 2026-06-29 e2e run: 40 harness successes, 5 match to
// gateway rows with outcome="ok", 35 match to gateway rows with
// fallback outcomes (stream_output_exceeded etc.). Pre-fix this yielded
// a phantom "drift=32" because aggregate sums compared 5 gateway-ok
// rows' tokens against 40 harness-ok tokens.
//
// Post-fix: per-pair drift over the matched pairs should be 0 because
// each individual pair has matching token counts — the false drift was
// a population-mismatch artifact, NOT real overcharging.
func TestComputePerPairDrift_ScenarioSevenFromProduction(t *testing.T) {
	// Mirror the 2026-06-29 reality: harness sees N=40 successes with
	// avg ~5.8 tokens (233 total / 40 = 5.825). Some land at 8 tokens
	// (max_tokens limit), others at 4-6 (natural stop). Build 40 pairs
	// where each pair's gateway tokens == harness tokens.
	pairs := make([]MatchedPair, 0, 40)
	tokenCounts := []int64{8, 8, 8, 8, 8, 6, 6, 6, 6, 6, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8,
		6, 6, 6, 6, 6, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8, 6, 6, 6, 6, 6}
	for i, n := range tokenCounts {
		hasCoord := i%2 == 0 // half match to coord, half don't (matching the windowing reality)
		mp := MatchedPair{
			HarnessCompletionTokens: n,
			GatewayCompletionTokens: n,
		}
		if hasCoord {
			mp.CoordinatorRequestID = "c"
			mp.CoordinatorCompletionTokens = n
		}
		pairs = append(pairs, mp)
	}
	r := &Result{MatchedSuccesses: pairs}
	computePerPairDrift(r)
	if r.GatewayMinusHarnessTokens != 0 {
		t.Errorf("production-shape clean pairs: want drift 0 (pre-fix would report 32), got %d", r.GatewayMinusHarnessTokens)
	}
	if r.GatewayMinusCoordinatorTokens != 0 {
		t.Errorf("production-shape clean pairs vs coord: want drift 0, got %d", r.GatewayMinusCoordinatorTokens)
	}
}

// TestComputePerPairDrift_NoCoordMatch verifies the "coord row missing"
// branch: pairs without a coord match contribute to gateway-vs-harness
// drift but NOT to gateway-vs-coord drift. The latter is a different
// signal (gateway vs coord disagreement) and shouldn't double-count
// pairs that simply lack a coord-side row.
func TestComputePerPairDrift_NoCoordMatch(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 12, CoordinatorRequestID: ""},   // no coord match
			{HarnessCompletionTokens: 8, GatewayCompletionTokens: 10, CoordinatorRequestID: "c2", CoordinatorCompletionTokens: 8},
		},
	}
	computePerPairDrift(r)
	if r.GatewayMinusHarnessTokens != 6 {
		t.Errorf("want gateway-harness drift +6, got %d", r.GatewayMinusHarnessTokens)
	}
	// Only the second pair (with coord match) contributes to gw-coord drift: 10-8 = 2
	if r.GatewayMinusCoordinatorTokens != 2 {
		t.Errorf("want gateway-coord drift +2 (one pair with coord match), got %d", r.GatewayMinusCoordinatorTokens)
	}
}

// TestComputePerPairDrift_GatewayUnderbilled is the inverse of the
// overcharge case: the gateway billed FEWER tokens than the harness
// observed. I1's check treats this as "allowed" (legitimate gateway-
// side rounding on streaming) — the drift sum can be negative. This
// test pins the sign convention so I1 stays consistent.
func TestComputePerPairDrift_GatewayUnderbilled(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessCompletionTokens: 10, GatewayCompletionTokens: 8},
			{HarnessCompletionTokens: 10, GatewayCompletionTokens: 7},
		},
	}
	computePerPairDrift(r)
	if r.GatewayMinusHarnessTokens != -5 {
		t.Errorf("underbill: want drift -5, got %d", r.GatewayMinusHarnessTokens)
	}
}

// TestComputePerPairDrift_EmptyMatches handles the case where the run
// reconciles but every harness success was unmatched (gateway empty or
// SQL window mis-targeted). Drift should stay 0 here — unmatched ids
// are a separate signal, not a token-count drift.
func TestComputePerPairDrift_EmptyMatches(t *testing.T) {
	r := &Result{MatchedSuccesses: nil}
	computePerPairDrift(r)
	if r.GatewayMinusHarnessTokens != 0 {
		t.Errorf("empty matches: want drift 0, got %d", r.GatewayMinusHarnessTokens)
	}
	if r.GatewayMinusCoordinatorTokens != 0 {
		t.Errorf("empty matches: want gw-coord drift 0, got %d", r.GatewayMinusCoordinatorTokens)
	}
}
