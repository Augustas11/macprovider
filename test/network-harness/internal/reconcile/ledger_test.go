// Tests for the per-pair drift fix (issue #226) with the R2 refinements
// required by the 3-lane codex audit on PR #229 R1:
//   - Signed-cancel CRITICAL: I1 must catch a +N overbill pair even if
//     another pair offsets it by -N. Net sum is reference-only; the
//     positive-only overbill sum is the headline signal.
//   - Coord-missing HIGH: matched gateway-ok pairs without a coord row
//     are surfaced separately (legit for fallback outcomes, suspicious
//     for ok).
//   - Unmatched gateway-ok HIGH: orphan/leaked settlement rows are
//     listed; fallback outcomes are excluded as noisy.
package reconcile

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
)

// TestComputePerPairDrift_CleanMatches: identical token counts → zero
// drift across every signal.
func TestComputePerPairDrift_CleanMatches(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "h1", HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, GatewayOutcome: "ok", CoordinatorRequestID: "c1", CoordinatorCompletionTokens: 8},
			{HarnessRequestID: "h2", HarnessCompletionTokens: 16, GatewayCompletionTokens: 16, GatewayOutcome: "ok", CoordinatorRequestID: "c2", CoordinatorCompletionTokens: 16},
		},
	}
	computePerPairDrift(r)
	if r.NetGatewayMinusHarnessTokens != 0 {
		t.Errorf("net gw-harness: want 0, got %d", r.NetGatewayMinusHarnessTokens)
	}
	if r.GatewayOverbillVsHarnessTokens != 0 {
		t.Errorf("overbill gw-harness: want 0, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if r.GatewayOverbillVsCoordinatorTokens != 0 {
		t.Errorf("overbill gw-coord: want 0, got %d", r.GatewayOverbillVsCoordinatorTokens)
	}
	if len(r.OverbilledPairs) != 0 {
		t.Errorf("OverbilledPairs: want empty, got %v", r.OverbilledPairs)
	}
	if len(r.MatchedCoordMissing) != 0 {
		t.Errorf("MatchedCoordMissing: want empty, got %v", r.MatchedCoordMissing)
	}
}

// TestComputePerPairDrift_SignedCancellation is the regression test for
// the PR #229 R1 CRITICAL: a +10 overbill matched with a -10 underbill.
// Pre-R2 NET drift hides the overbill; positive-only sum surfaces it.
func TestComputePerPairDrift_SignedCancellation(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "OVERBILLED", HarnessCompletionTokens: 100, GatewayCompletionTokens: 110, GatewayOutcome: "ok"},
			{HarnessRequestID: "UNDERBILLED", HarnessCompletionTokens: 100, GatewayCompletionTokens: 90, GatewayOutcome: "ok"},
		},
	}
	computePerPairDrift(r)
	if r.NetGatewayMinusHarnessTokens != 0 {
		t.Errorf("net should cancel to 0 (proving the headline-net-zero failure mode), got %d", r.NetGatewayMinusHarnessTokens)
	}
	if r.GatewayOverbillVsHarnessTokens != 10 {
		t.Errorf("overbill must NOT cancel: want 10, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "OVERBILLED" {
		t.Errorf("OverbilledPairs: want [OVERBILLED], got %v", r.OverbilledPairs)
	}
}

// TestComputePerPairDrift_RealOvercharge: pure overbill, no offsets.
func TestComputePerPairDrift_RealOvercharge(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "h1", HarnessCompletionTokens: 8, GatewayCompletionTokens: 12, GatewayOutcome: "ok", CoordinatorRequestID: "c1", CoordinatorCompletionTokens: 8},
			{HarnessRequestID: "h2", HarnessCompletionTokens: 8, GatewayCompletionTokens: 10, GatewayOutcome: "ok", CoordinatorRequestID: "c2", CoordinatorCompletionTokens: 8},
			{HarnessRequestID: "h3", HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, GatewayOutcome: "ok", CoordinatorRequestID: "c3", CoordinatorCompletionTokens: 8},
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 6 {
		t.Errorf("want overbill 6 (4+2), got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if r.GatewayOverbillVsCoordinatorTokens != 6 {
		t.Errorf("want overbill vs coord 6, got %d", r.GatewayOverbillVsCoordinatorTokens)
	}
	if len(r.OverbilledPairs) != 2 {
		t.Errorf("want 2 overbilled pairs, got %d (%v)", len(r.OverbilledPairs), r.OverbilledPairs)
	}
}

// TestComputePerPairDrift_ScenarioSevenShape: 40 pairs of matching tokens
// (the 2026-06-29 production shape that tripped I1). Per-pair drift
// must be 0 even though aggregate gateway-ok tokens vs harness-ok
// tokens differ.
func TestComputePerPairDrift_ScenarioSevenShape(t *testing.T) {
	pairs := make([]MatchedPair, 40)
	tokenCounts := []int64{8, 8, 8, 8, 8, 6, 6, 6, 6, 6, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8,
		6, 6, 6, 6, 6, 4, 4, 4, 4, 4, 8, 8, 8, 8, 8, 6, 6, 6, 6, 6}
	for i, n := range tokenCounts {
		// 5/40 land as outcome="ok", 35/40 as fallback — exactly the
		// production-trip shape on 2026-06-29.
		outcome := "stream_output_exceeded"
		if i < 5 {
			outcome = "ok"
		}
		pairs[i] = MatchedPair{
			HarnessRequestID:        "h",
			HarnessCompletionTokens: n,
			GatewayCompletionTokens: n,
			GatewayOutcome:          outcome,
			CoordinatorRequestID:    "c",
			CoordinatorCompletionTokens: n,
		}
	}
	r := &Result{MatchedSuccesses: pairs}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 0 {
		t.Errorf("scenario-7 shape: want 0 overbill, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if r.NetGatewayMinusHarnessTokens != 0 {
		t.Errorf("scenario-7 shape: want 0 net, got %d", r.NetGatewayMinusHarnessTokens)
	}
}

// TestComputePerPairDrift_CoordMissing_OkVsFallback: gateway-ok pair
// without a coord row → suspicious, flagged in MatchedCoordMissing.
// Gateway-fallback pair without a coord row → expected (provider died
// mid-stream), NOT flagged.
func TestComputePerPairDrift_CoordMissing_OkVsFallback(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "SUSPICIOUS", HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, GatewayOutcome: "ok", CoordinatorRequestID: ""},
			{HarnessRequestID: "expected", HarnessCompletionTokens: 8, GatewayCompletionTokens: 8, GatewayOutcome: "stream_truncated", CoordinatorRequestID: ""},
		},
	}
	computePerPairDrift(r)
	if len(r.MatchedCoordMissing) != 1 || r.MatchedCoordMissing[0] != "SUSPICIOUS" {
		t.Errorf("only gateway-ok-no-coord should flag: got %v", r.MatchedCoordMissing)
	}
}

// TestComputePerPairDrift_UnderbillNotFlagged: gateway billed less
// than harness observed — allowed for streaming (gateway-side rounding).
// Per-pair drift records it in NetGatewayMinusHarnessTokens but
// OverbilledPairs stays empty.
func TestComputePerPairDrift_UnderbillNotFlagged(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "h1", HarnessCompletionTokens: 10, GatewayCompletionTokens: 8, GatewayOutcome: "ok"},
			{HarnessRequestID: "h2", HarnessCompletionTokens: 10, GatewayCompletionTokens: 7, GatewayOutcome: "ok"},
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 0 {
		t.Errorf("underbill: want 0 overbill, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if r.NetGatewayMinusHarnessTokens != -5 {
		t.Errorf("net underbill: want -5, got %d", r.NetGatewayMinusHarnessTokens)
	}
	if len(r.OverbilledPairs) != 0 {
		t.Errorf("underbills are not overbills: %v", r.OverbilledPairs)
	}
}

// TestCollectUnmatchedGatewayOK takes a leftover gateway pool (what
// matchByFuzzy did NOT consume) and surfaces only the "ok"-outcome
// rows. Fallback outcomes and not-ok are noise on a live network.
func TestCollectUnmatchedGatewayOK(t *testing.T) {
	now := time.Now()
	leftoverGw := []gwRow{
		{RequestID: "ORPHAN_OK", Outcome: "ok", CreatedAt: now},
		{RequestID: "fallback_left", Outcome: "stream_truncated", CreatedAt: now}, // EXCLUDED (noisy)
		{RequestID: "notok_left", Outcome: "upstream_error", CreatedAt: now},      // EXCLUDED (not ok)
	}
	r := &Result{}
	collectUnmatchedGatewayOK(r, leftoverGw)
	if len(r.UnmatchedGatewayOKRows) != 1 || r.UnmatchedGatewayOKRows[0] != "ORPHAN_OK" {
		t.Errorf("want [ORPHAN_OK], got %v", r.UnmatchedGatewayOKRows)
	}
}

// TestCollectUnmatchedGatewayOK_NoLeftovers: empty leftover pool →
// no orphans listed.
func TestCollectUnmatchedGatewayOK_NoLeftovers(t *testing.T) {
	r := &Result{}
	collectUnmatchedGatewayOK(r, nil)
	if len(r.UnmatchedGatewayOKRows) != 0 {
		t.Errorf("want empty, got %v", r.UnmatchedGatewayOKRows)
	}
}

// TestComputePerPairDrift_FallbackPairsDontCountAsOverbill_R5HIGH:
// the production scenario 07 shape has gateway settle most successful
// streams as stream_output_exceeded with gateway tokens >> harness
// tokens (F-8 SSE undercount). Pre-R5 this counted as gateway overbill
// and false-failed I1 on exactly the shape #226 was filed to fix.
// Post-R5, only OK-outcome overbill counts.
func TestComputePerPairDrift_FallbackPairsDontCountAsOverbill_R5HIGH(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			// Fallback pair: gateway recorded 64 bytes' worth of tokens
			// before the upstream error, harness's SSE parser only saw 8.
			// Pre-R5: GatewayOverbillVsHarnessTokens += 56. R5: excluded.
			{HarnessRequestID: "fallback_undercount", HarnessCompletionTokens: 8, GatewayCompletionTokens: 64,
				GatewayOutcome: "stream_output_exceeded"},
			// OK pair: clean billing.
			{HarnessRequestID: "ok_clean", HarnessCompletionTokens: 32, GatewayCompletionTokens: 32, GatewayOutcome: "ok"},
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 0 {
		t.Errorf("fallback pair must not count as gateway overbill, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 0 {
		t.Errorf("fallback pair must not appear in OverbilledPairs: %v", r.OverbilledPairs)
	}
}

// TestCollectUnmatchedCoord2xx_R5HIGH: a coord 2xx row that no harness
// success matched must surface as orphan/leaked traffic. Pre-R5 the
// leftover coord pool was discarded entirely, so the signal disappeared.
func TestCollectUnmatchedCoord2xx_R5HIGH(t *testing.T) {
	now := time.Now()
	leftoverCoord := []coordRow{
		{RequestID: "ORPHAN_COORD", Status: 200, CompletionTokens: 8, TsUTC: now},
		{RequestID: "coord_5xx", Status: 500, TsUTC: now},  // EXCLUDED (not 2xx)
		{RequestID: "coord_4xx", Status: 404, TsUTC: now},  // EXCLUDED (not 2xx)
	}
	r := &Result{}
	collectUnmatchedCoord2xx(r, leftoverCoord)
	if len(r.UnmatchedCoordinator2xxRows) != 1 || r.UnmatchedCoordinator2xxRows[0] != "ORPHAN_COORD" {
		t.Errorf("want [ORPHAN_COORD], got %v", r.UnmatchedCoordinator2xxRows)
	}
}

// TestMatchByFuzzy_FallbackDoesntStealCoord_R4HIGH is the regression
// for the R4 audit finding: a fallback gateway row paired with a
// harness success could consume a nearby coord row that a later "ok"
// pair needed, producing a false MatchedCoordMissing on the ok pair.
// The fix: only call pickClosestCoord when the gateway outcome is "ok".
func TestMatchByFuzzy_FallbackDoesntStealCoord_R4HIGH(t *testing.T) {
	now := time.Now()
	// 2 harness successes, both with 8 tokens. Gateway has one fallback
	// row (stream_truncated, 8 tokens, earlier) and one ok row (8 tokens,
	// later). Coord has 1 row (8 tokens) — should match the ok pair, not
	// the fallback pair.
	gwRows := []gwRow{
		{RequestID: "gw_fallback", Outcome: "stream_truncated", CompletionTokens: 8, CreatedAt: now},
		{RequestID: "gw_ok", Outcome: "ok", CompletionTokens: 8, CreatedAt: now.Add(time.Millisecond)},
	}
	coordRows := []coordRow{
		{RequestID: "c1", Status: 200, CompletionTokens: 8, TsUTC: now.Add(time.Millisecond)},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: now, StartUTC: now, RequestID: "h_fallback"},
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: now.Add(time.Millisecond), StartUTC: now.Add(time.Millisecond), RequestID: "h_ok"},
	}
	r := &Result{}
	matchByFuzzy(r, results, gwRows, coordRows)
	if len(r.MatchedSuccesses) != 2 {
		t.Fatalf("want 2 pairs, got %d", len(r.MatchedSuccesses))
	}
	// Find the ok pair and verify it has the coord row.
	var okPair *MatchedPair
	for i := range r.MatchedSuccesses {
		if r.MatchedSuccesses[i].GatewayOutcome == "ok" {
			okPair = &r.MatchedSuccesses[i]
		}
	}
	if okPair == nil {
		t.Fatal("ok pair missing from matches")
	}
	if okPair.CoordinatorRequestID == "" {
		t.Errorf("fallback pair stole the coord row — ok pair should have c1, got empty")
	}
	// And verify the fallback pair did NOT get the coord row.
	for _, p := range r.MatchedSuccesses {
		if p.GatewayOutcome == "stream_truncated" && p.CoordinatorRequestID != "" {
			t.Errorf("fallback pair must not consume coord row, got %s", p.CoordinatorRequestID)
		}
	}
}

// TestMatchByFuzzy_DuplicateRequestID_R3HIGH is the regression for the
// R3 security HIGH: gateway PK is (account_id, request_id), so the
// same request_id can legitimately appear twice across accounts. The
// pre-R3 collectUnmatchedGatewayOK used request_id matching against
// MatchedSuccesses, which would mark BOTH rows consumed when only one
// was actually paired. R3 changed matchByFuzzy to return the leftover
// pool directly, so identity is per-slice-element, not per-request_id.
func TestMatchByFuzzy_DuplicateRequestID_R3HIGH(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "X", Outcome: "ok", CompletionTokens: 10, CreatedAt: now},
		{RequestID: "X", Outcome: "ok", CompletionTokens: 10, CreatedAt: now}, // duplicate (different account in prod)
	}
	// Only one harness success — should match one row, leave the other.
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 10, EndUTC: now, RequestID: "h1"},
	}
	r := &Result{}
	leftover, _ := matchByFuzzy(r, results, gwRows, nil)
	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if len(leftover) != 1 {
		t.Fatalf("want 1 leftover gateway row, got %d", len(leftover))
	}
	collectUnmatchedGatewayOK(r, leftover)
	if len(r.UnmatchedGatewayOKRows) != 1 {
		t.Errorf("duplicate-request_id: orphan must be detected via leftover pool, got %v", r.UnmatchedGatewayOKRows)
	}
}

// TestComputePerPairDrift_EmptyMatches: no matched pairs → all signals 0.
func TestComputePerPairDrift_EmptyMatches(t *testing.T) {
	r := &Result{}
	computePerPairDrift(r)
	if r.NetGatewayMinusHarnessTokens != 0 || r.GatewayOverbillVsHarnessTokens != 0 {
		t.Errorf("empty: want zeros, got net=%d overbill=%d", r.NetGatewayMinusHarnessTokens, r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 0 || len(r.MatchedCoordMissing) != 0 {
		t.Errorf("empty: want no offending lists, got overbill=%v missing=%v", r.OverbilledPairs, r.MatchedCoordMissing)
	}
}

// TestComputePerPairDrift_CoordinatorUndercharge_R2HIGH is the
// regression for the R2 audit finding: when coord billed MORE tokens
// than gateway (harness=100, gateway=100, coord=110), I1 must fail.
// Pre-R2 this slipped through because we only checked positive overbill.
// Coord and gateway are both settlement systems — any directional
// disagreement is a money-path bug.
func TestComputePerPairDrift_CoordinatorUndercharge_R2HIGH(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "COORD_OVERBILLED", HarnessCompletionTokens: 100, GatewayCompletionTokens: 100, GatewayOutcome: "ok",
				CoordinatorRequestID: "c1", CoordinatorCompletionTokens: 110},
		},
	}
	computePerPairDrift(r)
	// Gateway didn't overbill vs harness (both 100). Net gw-coord is -10.
	// But abs mismatch must surface it.
	if r.GatewayOverbillVsHarnessTokens != 0 {
		t.Errorf("no gw-harness overbill: want 0, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if r.NetGatewayMinusCoordinatorTokens != -10 {
		t.Errorf("net gw-coord: want -10, got %d", r.NetGatewayMinusCoordinatorTokens)
	}
	if r.AbsGatewayCoordinatorMismatchTokens != 10 {
		t.Errorf("abs gw-coord mismatch: want 10, got %d", r.AbsGatewayCoordinatorMismatchTokens)
	}
	if len(r.GatewayCoordMismatchedPairs) != 1 || r.GatewayCoordMismatchedPairs[0] != "COORD_OVERBILLED" {
		t.Errorf("GatewayCoordMismatchedPairs: want [COORD_OVERBILLED], got %v", r.GatewayCoordMismatchedPairs)
	}
}

// TestComputePerPairDrift_CoordMismatchSignedCancel: bidirectional
// gateway-coord deltas must NOT cancel. +10 in one pair + -10 in another
// is still 20 tokens of ledger disagreement across pairs.
func TestComputePerPairDrift_CoordMismatchSignedCancel(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "p1", GatewayCompletionTokens: 110, GatewayOutcome: "ok", CoordinatorRequestID: "c1", CoordinatorCompletionTokens: 100},
			{HarnessRequestID: "p2", GatewayCompletionTokens: 100, GatewayOutcome: "ok", CoordinatorRequestID: "c2", CoordinatorCompletionTokens: 110},
		},
	}
	computePerPairDrift(r)
	if r.AbsGatewayCoordinatorMismatchTokens != 20 {
		t.Errorf("abs mismatch must NOT cancel: want 20 (=10+10), got %d", r.AbsGatewayCoordinatorMismatchTokens)
	}
	if len(r.GatewayCoordMismatchedPairs) != 2 {
		t.Errorf("want 2 mismatched pairs, got %d", len(r.GatewayCoordMismatchedPairs))
	}
}

// TestComputePerPairDrift_NetVsOverbillRelationship: the headline
// overbill signal MUST equal the sum of positive per-pair deltas, NOT
// the net sum. This pins the relationship so a future refactor doesn't
// accidentally re-conflate them.
func TestComputePerPairDrift_NetVsOverbillRelationship(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessCompletionTokens: 10, GatewayCompletionTokens: 15, GatewayOutcome: "ok"}, // +5
			{HarnessCompletionTokens: 10, GatewayCompletionTokens: 8, GatewayOutcome: "ok"},  // -2
			{HarnessCompletionTokens: 10, GatewayCompletionTokens: 10, GatewayOutcome: "ok"}, // 0
			{HarnessCompletionTokens: 10, GatewayCompletionTokens: 12, GatewayOutcome: "ok"}, // +2
		},
	}
	computePerPairDrift(r)
	// Net: +5 -2 +0 +2 = +5
	if r.NetGatewayMinusHarnessTokens != 5 {
		t.Errorf("net: want 5, got %d", r.NetGatewayMinusHarnessTokens)
	}
	// Overbill: +5 + +2 = 7  (positive-only sum)
	if r.GatewayOverbillVsHarnessTokens != 7 {
		t.Errorf("overbill: want 7, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 2 {
		t.Errorf("want 2 overbilled pairs, got %d", len(r.OverbilledPairs))
	}
}
