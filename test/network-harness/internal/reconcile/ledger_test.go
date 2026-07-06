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
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/scenario"

	_ "modernc.org/sqlite"
)

// TestSnapshotWindow_NoBackwardPad is the regression test for the
// "false-positive orphan when scenarios run back-to-back" bug. The
// snapshot window MUST start exactly at the harness's startUTC,
// never earlier — backward padding pulls tail rows from a prior
// scenario into the next scenario's query, surfacing already-matched
// rows as orphans in the second scenario's leftover pool.
//
// The forward pad (endUTC + 30s) stays, because gateway settlement
// can legitimately lag the harness's observation of the response.
func TestSnapshotWindow_NoBackwardPad(t *testing.T) {
	start := time.Date(2026, 6, 29, 13, 7, 47, 0, time.UTC)
	end := time.Date(2026, 6, 29, 13, 8, 35, 0, time.UTC)
	winStart, winEnd := snapshotWindow(start, end)
	if !winStart.Equal(start) {
		t.Errorf("winStart must equal startUTC (no backward pad), got %v vs %v", winStart, start)
	}
	if !winEnd.After(end) {
		t.Errorf("winEnd must extend past endUTC (forward pad), got %v vs %v", winEnd, end)
	}
	if got := winEnd.Sub(end); got != 90*time.Second {
		t.Errorf("forward pad must be 90s, got %v", got)
	}
}

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
			HarnessRequestID:            "h",
			HarnessCompletionTokens:     n,
			GatewayCompletionTokens:     n,
			GatewayOutcome:              outcome,
			CoordinatorRequestID:        "c",
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
// matchPairs did NOT consume) and surfaces complete settlement rows,
// including fallback settlements.
func TestCollectUnmatchedGatewayOK(t *testing.T) {
	now := time.Now()
	leftoverGw := []gwRow{
		{RequestID: "ORPHAN_OK", Outcome: "ok", CreatedAt: now},
		{RequestID: "fallback_left", Outcome: "stream_truncated", CreatedAt: now},
		{RequestID: "notok_left", Outcome: "upstream_error", CreatedAt: now}, // EXCLUDED (not ok)
	}
	r := &Result{}
	collectUnmatchedGatewayOK(r, leftoverGw)
	if len(r.UnmatchedGatewayOKRows) != 3 ||
		r.UnmatchedGatewayOKRows[0] != "ORPHAN_OK" ||
		r.UnmatchedGatewayOKRows[1] != "fallback_left" ||
		r.UnmatchedGatewayOKRows[2] != "notok_left" {
		t.Errorf("want all complete settlement leftovers, got %v", r.UnmatchedGatewayOKRows)
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

func TestComputePerPairDrift_FallbackPairsCountBuyerVisibleOverbill(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "fallback_undercount", HarnessCompletionTokens: 8, GatewayCompletionTokens: 64,
				GatewayOutcome: "stream_output_exceeded", HarnessSawSSEErrorEvent: true, HarnessSSEErrorCode: "stream_output_exceeded"},
			// OK pair: clean billing.
			{HarnessRequestID: "ok_clean", HarnessCompletionTokens: 32, GatewayCompletionTokens: 32, GatewayOutcome: "ok"},
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 56 {
		t.Errorf("fallback pair must count buyer-visible overbill 56, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "fallback_undercount" {
		t.Errorf("fallback pair must appear in OverbilledPairs: %v", r.OverbilledPairs)
	}
}

// TestComputePerPairDrift_FallbackOverbillFlagged_WhenNoSSEErrorEvent_232:
// the trust-gap scenario #232 was filed about. A gateway labels the
// pair as a SPEC-006 §17.7 fallback outcome (claiming truncation) with
// a large overbill (gateway=999, harness=8). But the buyer never
// received the gateway's terminal SSE error envelope. Without #232
// corroboration the overbill would be silently suppressed; with it,
// the overbill is fed into I1 and the pair surfaces in OverbilledPairs.
func TestComputePerPairDrift_FallbackOverbillFlagged_WhenNoSSEErrorEvent_232(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			// Buggy / malicious gateway shape: claims fallback but never
			// emitted the terminal error envelope the buyer would have
			// received on a real truncation.
			{HarnessRequestID: "trust_gap", HarnessCompletionTokens: 8, GatewayCompletionTokens: 999,
				GatewayOutcome: "stream_truncated", HarnessSawSSEErrorEvent: false,
				CoordinatorRequestID: "coord_trust_gap", CoordinatorCompletionTokens: 8},
		},
	}
	computePerPairDrift(r)

	// Gateway-vs-harness axis: overbill of 991 must be flagged.
	if r.GatewayOverbillVsHarnessTokens != 991 {
		t.Errorf("trust-gap pair must flag harness-axis overbill 991, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "trust_gap" {
		t.Errorf("trust-gap pair must appear in OverbilledPairs, got %v", r.OverbilledPairs)
	}

	// Gateway-vs-coordinator axis: overbill of 991 must also surface.
	if r.GatewayOverbillVsCoordinatorTokens != 991 {
		t.Errorf("trust-gap pair must flag coord-axis overbill 991, got %d", r.GatewayOverbillVsCoordinatorTokens)
	}
	if r.AbsGatewayCoordinatorMismatchTokens != 991 {
		t.Errorf("trust-gap pair must contribute |delta|=991 to coord mismatch, got %d", r.AbsGatewayCoordinatorMismatchTokens)
	}
	if len(r.GatewayCoordMismatchedPairs) != 1 || r.GatewayCoordMismatchedPairs[0] != "trust_gap" {
		t.Errorf("trust-gap pair must appear in GatewayCoordMismatchedPairs, got %v", r.GatewayCoordMismatchedPairs)
	}
}

// TestComputePerPairDrift_FallbackUnlistedCodeMismatch_232_R6_HIGH:
// SEC R6 + ARCH R6 convergent HIGH — buyer-visible error.code differs
// from gateway outcome WITHOUT a named SPEC-006 mapping exception
// (e.g. code=provider_timeout while outcome=stream_truncated). The
// mapping clause says unlisted mismatches MUST be treated as
// uncorroborated overbill candidates. fallbackOverbillSuppressed must
// refuse to suppress.
func TestComputePerPairDrift_FallbackUnlistedCodeMismatch_232_R6_HIGH(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "code_mismatch", HarnessCompletionTokens: 8, GatewayCompletionTokens: 500,
				GatewayOutcome:          "stream_truncated",
				HarnessSawSSEErrorEvent: true,
				HarnessSSEErrorCode:     "provider_timeout"}, // unlisted mismatch
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 492 {
		t.Errorf("unlisted code/outcome mismatch must NOT suppress overbill, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "code_mismatch" {
		t.Errorf("unlisted code/outcome mismatch must surface pair in OverbilledPairs, got %v", r.OverbilledPairs)
	}
}

// TestComputePerPairDrift_FallbackNamedMappingException_232_R6:
// the SPEC-006 §17.7.1 named-mapping exception path. Buyer-visible
// `error.code=provider_disconnected` while gateway outcome is
// `stream_truncated` is an EXPLICITLY allowed divergence (matches
// gateway writeProviderDisconnectedSSE behavior). The mapping may suppress
// coord-mismatch noise, but it must not suppress buyer-visible overbill.
func TestComputePerPairDrift_FallbackNamedMappingException_232_R6(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "named_exception", HarnessCompletionTokens: 8, GatewayCompletionTokens: 64,
				GatewayOutcome:          "stream_truncated",
				HarnessSawSSEErrorEvent: true,
				HarnessSSEErrorCode:     "provider_disconnected"},
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 56 {
		t.Errorf("provider_disconnected↔stream_truncated named mapping must still count overbill 56, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "named_exception" {
		t.Errorf("named-mapping exception must surface buyer-visible overbill, got %v", r.OverbilledPairs)
	}
}

// TestSseErrorCorroboratesOutcome_232_R6: unit cases for the
// SPEC-006 §17.7.1 mapping helper.
func TestSseErrorCorroboratesOutcome_232_R6(t *testing.T) {
	cases := []struct {
		name    string
		code    string
		outcome string
		want    bool
	}{
		{"default same code", "stream_truncated", "stream_truncated", true},
		{"default same code stream_malformed", "stream_malformed", "stream_malformed", true},
		{"default same code provider_timeout", "provider_timeout", "provider_timeout", true},
		{"named exception provider_disconnected", "provider_disconnected", "stream_truncated", true},
		{"unlisted mismatch", "provider_timeout", "stream_truncated", false},
		{"unlisted mismatch other dir", "stream_truncated", "stream_malformed", false},
		{"empty code", "", "stream_truncated", false},
		{"unicode injected code", "🚫", "stream_truncated", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := sseErrorCorroboratesOutcome(tc.code, tc.outcome)
			if got != tc.want {
				t.Errorf("sseErrorCorroboratesOutcome(%q, %q) = %v, want %v", tc.code, tc.outcome, got, tc.want)
			}
		})
	}
}

// TestComputePerPairDrift_FallbackPairSuppressedWithSSEErrorEvent_232:
// the legitimate fallback case: gateway labeled the pair as a fallback AND
// the buyer received the matching terminal SSE error envelope. This can
// suppress coord mismatch noise, but not buyer-visible overbill.
func TestComputePerPairDrift_FallbackPairCountsHarnessOverbillWithSSEErrorEvent_232(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "legit_truncation", HarnessCompletionTokens: 8, GatewayCompletionTokens: 64,
				GatewayOutcome: "stream_output_exceeded", HarnessSawSSEErrorEvent: true, HarnessSSEErrorCode: "stream_output_exceeded",
				CoordinatorRequestID: "coord_legit", CoordinatorCompletionTokens: 80},
		},
	}
	computePerPairDrift(r)

	if r.GatewayOverbillVsHarnessTokens != 56 {
		t.Errorf("legit truncation must count harness-axis overbill 56, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if r.GatewayOverbillVsCoordinatorTokens != 0 {
		t.Errorf("legit truncation must keep coord-axis suppression, got %d", r.GatewayOverbillVsCoordinatorTokens)
	}
	if r.AbsGatewayCoordinatorMismatchTokens != 0 {
		t.Errorf("legit truncation must keep coord-mismatch suppression, got %d", r.AbsGatewayCoordinatorMismatchTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "legit_truncation" || len(r.GatewayCoordMismatchedPairs) != 0 {
		t.Errorf("legit truncation must surface overbill only, got %v / %v",
			r.OverbilledPairs, r.GatewayCoordMismatchedPairs)
	}
}

// TestComputePerPairDrift_FallbackOverbillFlagged_BenignNoDoneCase_232:
// SEC R1 HIGH-1 edge: a gateway delivers a buyer-visible 200 stream
// with no `[DONE]` terminator AND no error envelope, then labels the
// usage_events row as `stream_truncated` with a large gateway-token
// count. Earlier draft used SawTerminator as the anchor, which would
// have suppressed this case (SawTerminator=false matched the "harness
// corroborates" branch). The SSE-error-event anchor catches it: no
// error envelope means no corroboration, drift goes into I1.
func TestComputePerPairDrift_FallbackOverbillFlagged_BenignNoDoneCase_232(t *testing.T) {
	r := &Result{
		MatchedSuccesses: []MatchedPair{
			{HarnessRequestID: "benign_no_done", HarnessCompletionTokens: 8, GatewayCompletionTokens: 500,
				GatewayOutcome: "stream_truncated", HarnessSawSSEErrorEvent: false},
		},
	}
	computePerPairDrift(r)
	if r.GatewayOverbillVsHarnessTokens != 492 {
		t.Errorf("benign-no-DONE trust-gap must flag overbill 492, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "benign_no_done" {
		t.Errorf("benign-no-DONE pair must surface in OverbilledPairs, got %v", r.OverbilledPairs)
	}
}

// TestCollectUnmatchedCoord2xx_R5HIGH: a coord 2xx row that no harness
// success matched must surface as orphan/leaked traffic. Pre-R5 the
// leftover coord pool was discarded entirely, so the signal disappeared.
func TestCollectUnmatchedCoord2xx_R5HIGH(t *testing.T) {
	now := time.Now()
	leftoverCoord := []coordRow{
		{RequestID: "ORPHAN_COORD", Status: 200, CompletionTokens: 8, TsUTC: now},
		{RequestID: "coord_5xx", Status: 500, TsUTC: now}, // EXCLUDED (not 2xx)
		{RequestID: "coord_4xx", Status: 404, TsUTC: now}, // EXCLUDED (not 2xx)
	}
	r := &Result{}
	collectUnmatchedCoord2xx(r, leftoverCoord)
	if len(r.UnmatchedCoordinator2xxRows) != 1 || r.UnmatchedCoordinator2xxRows[0] != "ORPHAN_COORD" {
		t.Errorf("want [ORPHAN_COORD], got %v", r.UnmatchedCoordinator2xxRows)
	}
}

// TestMatchPairs_FallbackDoesntStealCoord_R4HIGH is the regression
// for the R4 audit finding: a fallback gateway row paired with a
// harness success could consume a nearby coord row that a later "ok"
// pair needed, producing a false MatchedCoordMissing on the ok pair.
// The fix: only call pickClosestCoord when the gateway outcome is "ok".
func TestMatchPairs_FallbackDoesntStealCoord_R4HIGH(t *testing.T) {
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
	matchPairs(r, results, gwRows, coordRows)
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

// TestMatchPairs_DuplicateRequestID_R3HIGH is the regression for the
// R3 security HIGH: gateway PK is (account_id, request_id), so the
// same request_id can legitimately appear twice across accounts. The
// pre-R3 collectUnmatchedGatewayOK used request_id matching against
// MatchedSuccesses, which would mark BOTH rows consumed when only one
// was actually paired. R3 changed matchPairs to return the leftover
// pool directly, so identity is per-slice-element, not per-request_id.
func TestMatchPairs_DuplicateRequestID_R3HIGH(t *testing.T) {
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
	leftover, _ := matchPairs(r, results, gwRows, nil)
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

// TestMatchPairs_ExactIDWinsOverFuzzy is the regression for the v0.3
// scenario-07 finding: harness SSE parser undercounted 2 of 39 requests
// to 0 tokens, and pickClosestGw's tokenDiff*100_000 + dt scoring
// snapped the harness 0-token rows onto a different gateway row that
// happened to have low tokens, leaving the gateway-OK rows to drift
// 55+s onto wrong harness requests. Cross-check showed pair 1's matched
// gateway_request_id literally equaled pair 3's harness_request_id. The
// fix prefers exact request_id (gateway echoes it via X-Request-Id
// response header, loadgen.go:199) before falling back to token+ts
// fuzzy.
func TestMatchPairs_ExactIDWinsOverFuzzy(t *testing.T) {
	now := time.Now()
	// Harness h_A undercounted to 0 tokens (SSE parser missed deltas).
	// Gateway row for h_A is "gw_A" with 36 tokens. Another gateway row
	// "gw_B" with 0 tokens exists for a different harness request h_B.
	// Pre-fix: pickClosestGw would snap h_A onto gw_B (exact 0=0 match);
	// post-fix: exact request_id match snaps h_A onto gw_A.
	gwRows := []gwRow{
		{RequestID: "gw_A", Outcome: "ok", CompletionTokens: 36, CreatedAt: now},
		{RequestID: "gw_B", Outcome: "ok", CompletionTokens: 0, CreatedAt: now.Add(time.Millisecond)},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 0, EndUTC: now, StartUTC: now, RequestID: "gw_A"},
		{Outcome: "ok", CompletionTokensReceived: 0, EndUTC: now.Add(time.Millisecond), StartUTC: now.Add(time.Millisecond), RequestID: "gw_B"},
	}
	r := &Result{}
	matchPairs(r, results, gwRows, nil)
	if len(r.MatchedSuccesses) != 2 {
		t.Fatalf("want 2 pairs, got %d", len(r.MatchedSuccesses))
	}
	for _, p := range r.MatchedSuccesses {
		if p.HarnessRequestID != p.GatewayRequestID {
			t.Errorf("exact-id match failed: harness=%s gateway=%s", p.HarnessRequestID, p.GatewayRequestID)
		}
	}
}

// TestMatchPairs_ExactIDPrefersOverFallback: when a harness request's
// exact gateway counterpart is a fallback row (e.g. stream_truncated),
// the matcher must still prefer the exact-id row over fuzzing onto a
// different OK row that happens to have a closer token count. Without
// this, the production #226 shape causes phantom OK pairs.
func TestMatchPairs_ExactIDPrefersOverFallback(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "h1", Outcome: "stream_truncated", CompletionTokens: 64, CreatedAt: now},
		{RequestID: "h2", Outcome: "ok", CompletionTokens: 0, CreatedAt: now.Add(time.Millisecond)},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 0, EndUTC: now, StartUTC: now, RequestID: "h1"},
	}
	r := &Result{}
	matchPairs(r, results, gwRows, nil)
	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 pair, got %d", len(r.MatchedSuccesses))
	}
	p := r.MatchedSuccesses[0]
	if p.GatewayRequestID != "h1" {
		t.Errorf("want exact-id match h1 (fallback) over fuzz to h2 (ok), got gw=%s outcome=%s", p.GatewayRequestID, p.GatewayOutcome)
	}
	if p.GatewayOutcome != "stream_truncated" {
		t.Errorf("want fallback outcome preserved, got %s", p.GatewayOutcome)
	}
}

// TestMatchPairs_FallsBackToFuzzyWhenNoExact: legacy gateways that
// don't echo X-Request-Id (or rows missing from the snapshot window)
// must still match via the token+ts heuristic.
func TestMatchPairs_FallsBackToFuzzyWhenNoExact(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "legacy_gw_uuid", Outcome: "ok", CompletionTokens: 10, CreatedAt: now},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 10, EndUTC: now, StartUTC: now, RequestID: "harness_native_id"},
	}
	r := &Result{}
	matchPairs(r, results, gwRows, nil)
	if len(r.MatchedSuccesses) != 1 || r.MatchedSuccesses[0].GatewayRequestID != "legacy_gw_uuid" {
		t.Errorf("fuzzy fallback should still match when no exact id, got %+v", r.MatchedSuccesses)
	}
}

// TestPickExactGwByRequestID_SkipsIncompleteSettlement: in-flight row
// (no outcome) must not match by exact-id.
func TestPickExactGwByRequestID_SkipsIncompleteSettlement(t *testing.T) {
	now := time.Now()
	pool := []gwRow{
		{RequestID: "x", Outcome: "", CompletionTokens: 0, CreatedAt: now},
		{RequestID: "x", Outcome: "ok", CompletionTokens: 8, CreatedAt: now},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "", false)
	if status != exactPickFound || idx != 1 {
		t.Errorf("want (1, found), got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_EmptyIDReturnsNone: defensive — empty
// harness id → exactPickNone (caller falls back to fuzzy).
func TestPickExactGwByRequestID_EmptyIDReturnsNone(t *testing.T) {
	now := time.Now()
	pool := []gwRow{{RequestID: "", Outcome: "ok", CompletionTokens: 0, CreatedAt: now}}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "", EndUTC: now}, "", false)
	if status != exactPickNone || idx != -1 {
		t.Errorf("want (-1, none), got (%d, %v)", idx, status)
	}
}

// TestPickExactCoordByRequestID_SkipsNon2xx + joins on external_request_id.
func TestPickExactCoordByRequestID_SkipsNon2xx(t *testing.T) {
	now := time.Now()
	pool := []coordRow{
		{RequestID: "coord-internal-1", ExternalRequestID: "x", Status: 503, CompletionTokens: 0, TsUTC: now},
		{RequestID: "coord-internal-2", ExternalRequestID: "x", Status: 200, CompletionTokens: 8, TsUTC: now},
	}
	idx, status := pickExactCoordByRequestID(&pool, buyer.Result{RequestID: "x", StartUTC: now}, "", false)
	if status != exactPickFound || idx != 1 {
		t.Errorf("want (1, found), got (%d, %v)", idx, status)
	}
}

// TestPickExactCoordByRequestID_JoinsOnExternalIDNotInternalID is the
// regression for the R1 code-lane HIGH: coord.request_id is internal
// and NEVER equals the inbound X-Request-ID. Cross-service join key is
// external_request_id (phase4-coordinator/internal/requestlog/store.go:34-46).
func TestPickExactCoordByRequestID_JoinsOnExternalIDNotInternalID(t *testing.T) {
	now := time.Now()
	pool := []coordRow{
		{RequestID: "harness-id", ExternalRequestID: "different-external", Status: 200, CompletionTokens: 8, TsUTC: now},
		{RequestID: "coord-internal", ExternalRequestID: "harness-id", Status: 200, CompletionTokens: 16, TsUTC: now},
	}
	idx, status := pickExactCoordByRequestID(&pool, buyer.Result{RequestID: "harness-id", StartUTC: now}, "", false)
	if status != exactPickFound || idx != 1 {
		t.Errorf("must join on ExternalRequestID — want (1, found), got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_RejectsAmbiguity is the regression for the
// R1 security HIGH: gateway PK is (account_id, request_id); ambiguity
// must surface as a distinct status (exactPickAmbiguous), NOT silently
// fall back to fuzzy which would let an unrelated row consume the
// match (R2 audit HIGH).
func TestPickExactGwByRequestID_RejectsAmbiguity(t *testing.T) {
	now := time.Now()
	pool := []gwRow{
		{RequestID: "x", Outcome: "ok", CompletionTokens: 10, CreatedAt: now},
		{RequestID: "x", Outcome: "ok", CompletionTokens: 999, CreatedAt: now},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "", false)
	if status != exactPickAmbiguous || idx != -1 {
		t.Errorf("want (-1, ambiguous), got (%d, %v)", idx, status)
	}
}

// TestPickExactCoordByRequestID_RejectsAmbiguity: same on coord side.
func TestPickExactCoordByRequestID_RejectsAmbiguity(t *testing.T) {
	now := time.Now()
	pool := []coordRow{
		{RequestID: "c1", ExternalRequestID: "x", Status: 200, CompletionTokens: 8, TsUTC: now},
		{RequestID: "c2", ExternalRequestID: "x", Status: 200, CompletionTokens: 999, TsUTC: now},
	}
	idx, status := pickExactCoordByRequestID(&pool, buyer.Result{RequestID: "x", StartUTC: now}, "", false)
	if status != exactPickAmbiguous || idx != -1 {
		t.Errorf("want (-1, ambiguous), got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_EnforcesTimeWindow — stale row rejected.
func TestPickExactGwByRequestID_EnforcesTimeWindow(t *testing.T) {
	now := time.Now()
	stale := now.Add(-2 * time.Minute)
	pool := []gwRow{
		{RequestID: "x", Outcome: "ok", CompletionTokens: 10, CreatedAt: stale},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "", false)
	if status != exactPickNone || idx != -1 {
		t.Errorf("stale row must be rejected — want (-1, none), got (%d, %v)", idx, status)
	}
}

// TestPickExactCoordByRequestID_EnforcesTimeWindow: same on coord.
func TestPickExactCoordByRequestID_EnforcesTimeWindow(t *testing.T) {
	now := time.Now()
	stale := now.Add(-2 * time.Minute)
	pool := []coordRow{
		{RequestID: "c1", ExternalRequestID: "x", Status: 200, CompletionTokens: 8, TsUTC: stale},
	}
	idx, status := pickExactCoordByRequestID(&pool, buyer.Result{RequestID: "x", StartUTC: now}, "", false)
	if status != exactPickNone || idx != -1 {
		t.Errorf("stale coord row must be rejected — want (-1, none), got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_EnforcesAccountConsensus is the regression
// for the R2 code/security HIGH: the gateway PK is composite
// `(account_id, request_id)`. On a shared gateway, a row from a
// foreign account can carry the same request_id; the matcher must
// reject it when a consensus account_id is established.
func TestPickExactGwByRequestID_EnforcesAccountConsensus(t *testing.T) {
	now := time.Now()
	pool := []gwRow{
		{RequestID: "x", Outcome: "ok", AccountID: "other_account", CompletionTokens: 10, CreatedAt: now},
		{RequestID: "x", Outcome: "ok", AccountID: "harness_account", CompletionTokens: 20, CreatedAt: now},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "harness_account", true)
	if status != exactPickFound || idx != 1 {
		t.Errorf("want (1, found) for harness_account, got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_LegacyNoColumnIsNoop: a pre-migration
// snapshot (schemaHasAccountID=false) → constraint is a global noop,
// even with consensus set. Row's empty AccountID is meaningless
// because the column isn't real on this snapshot. Verifies the
// rollout-safety leg of rowAccountIDMatches (R4).
func TestPickExactGwByRequestID_LegacyNoColumnIsNoop(t *testing.T) {
	now := time.Now()
	pool := []gwRow{
		{RequestID: "x", Outcome: "ok", AccountID: "", CompletionTokens: 10, CreatedAt: now},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "harness_account", false /* legacy snapshot */)
	if status != exactPickFound || idx != 0 {
		t.Errorf("legacy snapshot (no account_id column) → constraint noop — want (0, found), got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_ModernEmptyAccountRejectedAtBootstrap is
// the R4 audit security/architect HIGH regression: even before
// consensus is pinned (requireAccountID == ""), a modern-schema
// blank-account row MUST be rejected. R4 had the empty-consensus
// shortcut first, so the bootstrap row could be a phantom-account
// match that then pinned the wrong consensus for the rest of the run.
func TestPickExactGwByRequestID_ModernEmptyAccountRejectedAtBootstrap(t *testing.T) {
	now := time.Now()
	pool := []gwRow{
		{RequestID: "x", Outcome: "ok", AccountID: "", CompletionTokens: 10, CreatedAt: now},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "" /* bootstrap — no consensus yet */, true /* modern */)
	if status != exactPickNone || idx != -1 {
		t.Errorf("modern schema + blank account row at bootstrap → must be rejected — want (-1, none), got (%d, %v)", idx, status)
	}
}

// TestPickExactGwByRequestID_ModernSchemaEmptyAccountIsRejected is the
// R3 audit security HIGH regression: when the schema HAS the
// account_id column but the row's value is empty (real NULL/blank),
// the matcher cannot prove same buyer → MUST skip the row. Earlier
// (R3) wrongly treated this as a noop.
func TestPickExactGwByRequestID_ModernSchemaEmptyAccountIsRejected(t *testing.T) {
	now := time.Now()
	pool := []gwRow{
		{RequestID: "x", Outcome: "ok", AccountID: "", CompletionTokens: 10, CreatedAt: now},
	}
	idx, status := pickExactGwByRequestID(&pool, buyer.Result{RequestID: "x", EndUTC: now}, "harness_account", true /* modern snapshot */)
	if status != exactPickNone || idx != -1 {
		t.Errorf("modern snapshot + empty row account_id → must skip — want (-1, none), got (%d, %v)", idx, status)
	}
}

// TestPickExactCoordByRequestID_EnforcesAccountConsensus: same on coord.
func TestPickExactCoordByRequestID_EnforcesAccountConsensus(t *testing.T) {
	now := time.Now()
	pool := []coordRow{
		{ExternalRequestID: "x", AccountID: "other", Status: 200, CompletionTokens: 10, TsUTC: now},
		{ExternalRequestID: "x", AccountID: "harness_account", Status: 200, CompletionTokens: 20, TsUTC: now},
	}
	idx, status := pickExactCoordByRequestID(&pool, buyer.Result{RequestID: "x", StartUTC: now}, "harness_account", true)
	if status != exactPickFound || idx != 1 {
		t.Errorf("want (1, found) for harness_account, got (%d, %v)", idx, status)
	}
}

// TestMatchPairs_AmbiguityDoesNotConsumeViaFuzzy is the R2-HIGH
// regression: when exact-id is ambiguous (≥2 candidates), the matcher
// must NOT fall through to unrestricted fuzzy where an unrelated row
// could consume the match. The harness row stays unmatched, the
// ambiguity surfaces as a hard signal, and the candidate rows stay
// in the leftover pool.
func TestMatchPairs_AmbiguityDoesNotConsumeViaFuzzy(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		// Two same-id candidates (cross-account collision on a shared gw).
		{RequestID: "h1", Outcome: "ok", AccountID: "A", CompletionTokens: 8, CreatedAt: now},
		{RequestID: "h1", Outcome: "ok", AccountID: "B", CompletionTokens: 999, CreatedAt: now},
		// An unrelated row whose token count would be a "good" fuzzy
		// hit for the harness row. Pre-fix, fuzzy fallback would have
		// consumed THIS row after the ambiguous exact-id reject.
		{RequestID: "unrelated", Outcome: "ok", AccountID: "C", CompletionTokens: 8, CreatedAt: now},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: now, StartUTC: now, RequestID: "h1"},
	}
	r := &Result{}
	leftover, _ := matchPairs(r, results, gwRows, nil)
	if len(r.AmbiguousExactGatewayIDs) != 1 || r.AmbiguousExactGatewayIDs[0] != "h1" {
		t.Errorf("want ambiguous id surfaced, got %v", r.AmbiguousExactGatewayIDs)
	}
	if len(r.UnmatchedSuccesses) != 1 {
		t.Errorf("ambiguous harness row must stay unmatched, got %v", r.UnmatchedSuccesses)
	}
	if len(r.MatchedSuccesses) != 0 {
		t.Errorf("no pairs should match, got %d", len(r.MatchedSuccesses))
	}
	if len(leftover) != 3 {
		t.Errorf("all 3 gateway rows must stay in leftover, got %d", len(leftover))
	}
}

// TestMatchPairs_AccountConsensusPinnedFromFirstExactID: the first
// exact-id gateway hit pins r.HarnessAccountID; subsequent matches
// reject foreign-account rows even when they have a matching id.
func TestMatchPairs_AccountConsensusPinnedFromFirstExactID(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		// First harness request pins consensus to "acct_harness".
		{RequestID: "h1", Outcome: "ok", AccountID: "acct_harness", CompletionTokens: 10, CreatedAt: now},
		// Second harness id matches a foreign-account row only.
		{RequestID: "h2", Outcome: "ok", AccountID: "acct_other", CompletionTokens: 10, CreatedAt: now.Add(time.Millisecond)},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 10, EndUTC: now, StartUTC: now, RequestID: "h1"},
		{Outcome: "ok", CompletionTokensReceived: 10, EndUTC: now.Add(time.Millisecond), StartUTC: now.Add(time.Millisecond), RequestID: "h2"},
	}
	r := &Result{GatewayHasAccountID: true}
	matchPairs(r, results, gwRows, nil)
	if r.HarnessAccountID != "acct_harness" {
		t.Errorf("want consensus pinned to acct_harness, got %q", r.HarnessAccountID)
	}
	if len(r.MatchedSuccesses) != 1 || r.MatchedSuccesses[0].HarnessRequestID != "h1" {
		t.Errorf("only h1 should match (h2's only candidate is foreign-account), got %d pairs", len(r.MatchedSuccesses))
	}
	if len(r.UnmatchedSuccesses) != 1 || r.UnmatchedSuccesses[0] != "h2" {
		t.Errorf("h2 must be unmatched, got %v", r.UnmatchedSuccesses)
	}
}

// TestMatchPairs_FuzzyRefusedOnModernSchemaWithoutConsensus is the
// R5-HIGH regression: with the two-pass matcher (R6), fuzzy fallback
// must NEVER run on a modern (account_id-aware) snapshot when
// consensus is empty. Pre-R6, the first harness row with no exact
// gateway counterpart could fuzzy-match a foreign-account row by
// token-proximity and pin consensus to the wrong account.
//
// Setup: harness has a single result with a harness-prefix RequestID
// the gateway didn't echo. The gateway has ONE row from a foreign
// account with a matching token count. On modern schema, fuzzy must
// refuse — the harness row stays unmatched, consensus stays empty.
func TestMatchPairs_FuzzyRefusedOnModernSchemaWithoutConsensus(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "foreign_uuid", Outcome: "ok", AccountID: "acct_attacker", CompletionTokens: 8, CreatedAt: now},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: now, StartUTC: now, RequestID: "harness-prefix-id"},
	}
	r := &Result{GatewayHasAccountID: true}
	leftover, _ := matchPairs(r, results, gwRows, nil)
	if r.HarnessAccountID != "" {
		t.Errorf("consensus must remain empty (no exact-id hit pinned it), got %q", r.HarnessAccountID)
	}
	if len(r.MatchedSuccesses) != 0 {
		t.Errorf("no fuzzy match should occur — got %d pairs", len(r.MatchedSuccesses))
	}
	if len(r.UnmatchedSuccesses) != 1 || r.UnmatchedSuccesses[0] != "harness-prefix-id" {
		t.Errorf("harness row must be unmatched, got %v", r.UnmatchedSuccesses)
	}
	if len(leftover) != 1 {
		t.Errorf("foreign-account row stays in leftover (orphan signal), got %d", len(leftover))
	}
}

// TestMatchPairs_TwoPassOrderRescuesEarlyDeferral verifies the
// two-pass shape rescues an early harness row whose exact-id failed:
// pass 1 defers it; a later harness row's exact-id pins consensus;
// pass 2 then fuzzy-matches the deferred row.
//
// Without the second pass, harness rows would be processed in
// arrival order with no chance to rescue early items once consensus
// is later established.
func TestMatchPairs_TwoPassOrderRescuesEarlyDeferral(t *testing.T) {
	t0 := time.Now()
	t1 := t0.Add(10 * time.Millisecond)
	gwRows := []gwRow{
		// Will be fuzzy-matched to h_early — same account, same tokens, close ts.
		{RequestID: "gw_unrelated_uuid", Outcome: "ok", AccountID: "acct_harness", CompletionTokens: 8, CreatedAt: t0},
		// Exact match for h_late — pins consensus.
		{RequestID: "h_late", Outcome: "ok", AccountID: "acct_harness", CompletionTokens: 16, CreatedAt: t1},
	}
	results := []buyer.Result{
		// h_early ordered first by EndUTC. Pass 1: no exact-id candidate
		// (gateway row's request_id is different) → deferred.
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: t0, StartUTC: t0, RequestID: "harness-prefix-early"},
		// h_late comes second. Pass 1: exact-id match → consensus pinned.
		{Outcome: "ok", CompletionTokensReceived: 16, EndUTC: t1, StartUTC: t1, RequestID: "h_late"},
	}
	r := &Result{GatewayHasAccountID: true}
	matchPairs(r, results, gwRows, nil)
	if r.HarnessAccountID != "acct_harness" {
		t.Errorf("want consensus acct_harness, got %q", r.HarnessAccountID)
	}
	if len(r.MatchedSuccesses) != 2 {
		t.Fatalf("want both pairs matched (early via pass-2 fuzzy, late via pass-1 exact), got %d", len(r.MatchedSuccesses))
	}
	methods := map[string]string{}
	for _, p := range r.MatchedSuccesses {
		methods[p.HarnessRequestID] = p.GatewayMatchMethod
	}
	if methods["h_late"] != methodExactID {
		t.Errorf("h_late should be exact_id, got %q", methods["h_late"])
	}
	if methods["harness-prefix-early"] != methodFuzzy {
		t.Errorf("harness-prefix-early should be rescued via fuzzy pass 2, got %q", methods["harness-prefix-early"])
	}
}

// TestMatchPairs_RecordsMatchMethod: every matched pair records which
// strategy resolved each side. Architect-lane R1 LOW.
func TestMatchPairs_RecordsMatchMethod(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "h_exact", Outcome: "ok", CompletionTokens: 10, CreatedAt: now},
		{RequestID: "different_id", Outcome: "ok", CompletionTokens: 8, CreatedAt: now.Add(time.Millisecond)},
	}
	coordRows := []coordRow{
		{RequestID: "c1", ExternalRequestID: "h_exact", Status: 200, CompletionTokens: 10, TsUTC: now},
	}
	results := []buyer.Result{
		// First resolves to gateway via exact id, coord via exact id.
		{Outcome: "ok", CompletionTokensReceived: 10, EndUTC: now, StartUTC: now, RequestID: "h_exact"},
		// Second has no exact-id counterpart on gateway → fuzzy. No coord
		// counterpart either → coord method stays empty.
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: now.Add(time.Millisecond), StartUTC: now.Add(time.Millisecond), RequestID: "h_fuzzy"},
	}
	r := &Result{}
	matchPairs(r, results, gwRows, coordRows)
	if len(r.MatchedSuccesses) != 2 {
		t.Fatalf("want 2 pairs, got %d", len(r.MatchedSuccesses))
	}
	for _, p := range r.MatchedSuccesses {
		switch p.HarnessRequestID {
		case "h_exact":
			if p.GatewayMatchMethod != "exact_id" {
				t.Errorf("h_exact gateway method: want exact_id, got %q", p.GatewayMatchMethod)
			}
			if p.CoordinatorMatchMethod != "exact_id" {
				t.Errorf("h_exact coord method: want exact_id, got %q", p.CoordinatorMatchMethod)
			}
		case "h_fuzzy":
			if p.GatewayMatchMethod != "fuzzy_token_ts" {
				t.Errorf("h_fuzzy gateway method: want fuzzy_token_ts, got %q", p.GatewayMatchMethod)
			}
			// No coord candidate at all → method empty (no attempt path).
			if p.CoordinatorMatchMethod != "" {
				t.Errorf("h_fuzzy no-coord-candidate: want empty, got %q", p.CoordinatorMatchMethod)
			}
		}
	}
}

// TestMatchPairs_MixedExactAndFuzzyPool integrates both strategies in a
// single pool: one harness request consumes via exact-id, the next via
// fuzzy fallback from the remaining rows. Architect-lane R1 LOW.
func TestMatchPairs_MixedExactAndFuzzyPool(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "h_exact", Outcome: "ok", CompletionTokens: 5, CreatedAt: now},
		// fuzzy candidate for h2 (no matching id, but token=7 matches harness)
		{RequestID: "different_id", Outcome: "ok", CompletionTokens: 7, CreatedAt: now.Add(time.Millisecond)},
	}
	results := []buyer.Result{
		{Outcome: "ok", CompletionTokensReceived: 5, EndUTC: now, StartUTC: now, RequestID: "h_exact"},
		{Outcome: "ok", CompletionTokensReceived: 7, EndUTC: now.Add(time.Millisecond), StartUTC: now.Add(time.Millisecond), RequestID: "h2"},
	}
	r := &Result{}
	leftover, _ := matchPairs(r, results, gwRows, nil)
	if len(r.MatchedSuccesses) != 2 {
		t.Fatalf("want 2 pairs, got %d", len(r.MatchedSuccesses))
	}
	if len(leftover) != 0 {
		t.Errorf("both rows should be consumed, got leftover %d", len(leftover))
	}
	for _, p := range r.MatchedSuccesses {
		if p.HarnessRequestID == "h_exact" && p.GatewayMatchMethod != "exact_id" {
			t.Errorf("h_exact: want exact_id, got %q", p.GatewayMatchMethod)
		}
		if p.HarnessRequestID == "h2" && p.GatewayMatchMethod != "fuzzy_token_ts" {
			t.Errorf("h2: want fuzzy_token_ts, got %q", p.GatewayMatchMethod)
		}
	}
}

// TestMatchPairs_FallbackExactMatchEndToEnd is the R1 code-lane LOW:
// a harness OK whose exact gateway match is a fallback outcome must
// (a) match by exact id, (b) count buyer-visible gateway overbill,
// (c) NOT trigger MatchedCoordMissing, (d) NOT leak into
// UnmatchedGatewayOKRows.
func TestMatchPairs_FallbackExactMatchEndToEnd(t *testing.T) {
	now := time.Now()
	gwRows := []gwRow{
		{RequestID: "h1", Outcome: "stream_truncated", CompletionTokens: 64, CreatedAt: now},
	}
	results := []buyer.Result{
		// SawSSEErrorEvent=true matches production happy path: gateway's
		// writeSSEError emits the OpenAI-style error envelope before
		// `data: [DONE]` on every fallback path. #232 corroborates the
		// fallback outcome via that envelope; the code must match the
		// gateway's outcome per SPEC-006 §17.7.1 mapping (#232 R6).
		{Outcome: "ok", CompletionTokensReceived: 8, EndUTC: now, StartUTC: now, RequestID: "h1",
			SawSSEErrorEvent: true, SSEErrorCode: "stream_truncated"},
	}
	r := &Result{}
	leftoverGw, _ := matchPairs(r, results, gwRows, nil)
	computePerPairDrift(r)
	collectUnmatchedGatewayOK(r, leftoverGw)
	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if r.MatchedSuccesses[0].GatewayMatchMethod != "exact_id" {
		t.Errorf("want exact_id match on fallback row, got %q", r.MatchedSuccesses[0].GatewayMatchMethod)
	}
	if r.GatewayOverbillVsHarnessTokens != 56 {
		t.Errorf("fallback exact-match must count buyer-visible overbill 56, got %d", r.GatewayOverbillVsHarnessTokens)
	}
	if len(r.OverbilledPairs) != 1 || r.OverbilledPairs[0] != "h1" {
		t.Errorf("fallback exact-match must surface in OverbilledPairs, got %v", r.OverbilledPairs)
	}
	if len(r.MatchedCoordMissing) != 0 {
		t.Errorf("fallback pair must not trigger coord-missing, got %v", r.MatchedCoordMissing)
	}
	if len(r.UnmatchedGatewayOKRows) != 0 {
		t.Errorf("fallback row consumed → no orphan, got %v", r.UnmatchedGatewayOKRows)
	}
}

// TestAttachCoord_PairsFallbackOutcomeWithCoord2xx is the F-3
// reproduction for issue #285: stream_truncated via
// finish_reason=length can still have a clean coord 2xx row. The coord
// row must attach by exact external_request_id instead of leaking into
// UnmatchedCoordinator2xxRows.
func TestAttachCoord_PairsFallbackOutcomeWithCoord2xx(t *testing.T) {
	now := time.Now()
	results := []buyer.Result{
		// SawSSEErrorEvent=true: gateway's writeSSEError envelope (#232).
		// SSEErrorCode must match the gateway's outcome per SPEC-006
		// §17.7.1 mapping (#232 R6).
		{RequestID: "h_trunc_1", Outcome: "ok", CompletionTokensReceived: 0, StartUTC: now, EndUTC: now,
			SawSSEErrorEvent: true, SSEErrorCode: "stream_truncated"},
	}
	gwRows := []gwRow{
		{RequestID: "h_trunc_1", Outcome: "stream_truncated", CompletionTokens: 64, CreatedAt: now},
	}
	coordRows := []coordRow{
		{RequestID: "h_trunc_1", ExternalRequestID: "h_trunc_1", Status: 200, CompletionTokens: 64, TsUTC: now},
	}

	r := &Result{}
	_, leftoverCoord := matchPairs(r, results, gwRows, coordRows)
	computePerPairDrift(r)
	collectUnmatchedCoord2xx(r, leftoverCoord)

	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if got := r.MatchedSuccesses[0].CoordinatorRequestID; got != "h_trunc_1" {
		t.Errorf("fallback exact coord row should attach, got coord request_id %q", got)
	}
	if len(r.UnmatchedCoordinator2xxRows) != 0 {
		t.Errorf("attached fallback coord row must not leak as unmatched, got %v", r.UnmatchedCoordinator2xxRows)
	}
	if r.GatewayOverbillVsCoordinatorTokens != 0 {
		t.Errorf("fallback gw-coord overbill must be guarded, got %d", r.GatewayOverbillVsCoordinatorTokens)
	}
	if r.AbsGatewayCoordinatorMismatchTokens != 0 {
		t.Errorf("fallback gw-coord mismatch must be guarded, got %d", r.AbsGatewayCoordinatorMismatchTokens)
	}
	if len(r.GatewayCoordMismatchedPairs) != 0 {
		t.Errorf("fallback pair must not appear in gw-coord mismatch list, got %v", r.GatewayCoordMismatchedPairs)
	}
}

// TestAttachCoord_FallbackWithoutCoord_NotFlaggedAsMissing covers the
// provider-died-mid-stream shape: fallback gateway settlement may have
// no coord trail and must not be reported as MatchedCoordMissing.
func TestAttachCoord_FallbackWithoutCoord_NotFlaggedAsMissing(t *testing.T) {
	now := time.Now()
	results := []buyer.Result{
		{RequestID: "h_upstream_error", Outcome: "ok", CompletionTokensReceived: 8, StartUTC: now, EndUTC: now},
	}
	gwRows := []gwRow{
		{RequestID: "h_upstream_error", Outcome: "upstream_error", CompletionTokens: 8, CreatedAt: now},
	}

	r := &Result{}
	matchPairs(r, results, gwRows, nil)
	computePerPairDrift(r)

	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if len(r.MatchedCoordMissing) != 0 {
		t.Errorf("fallback pair without coord must not be flagged missing, got %v", r.MatchedCoordMissing)
	}
}

// TestAttachCoord_OKOutcomeWithoutCoord_FlaggedAsMissing preserves the
// existing I1 signal: gateway "ok" with no coord row remains suspicious.
func TestAttachCoord_OKOutcomeWithoutCoord_FlaggedAsMissing(t *testing.T) {
	now := time.Now()
	results := []buyer.Result{
		{RequestID: "h_ok_missing_coord", Outcome: "ok", CompletionTokensReceived: 8, StartUTC: now, EndUTC: now},
	}
	gwRows := []gwRow{
		{RequestID: "h_ok_missing_coord", Outcome: "ok", CompletionTokens: 8, CreatedAt: now},
	}

	r := &Result{}
	matchPairs(r, results, gwRows, nil)
	computePerPairDrift(r)

	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if len(r.MatchedCoordMissing) != 1 || r.MatchedCoordMissing[0] != "h_ok_missing_coord" {
		t.Errorf("ok pair without coord must be flagged missing, got %v", r.MatchedCoordMissing)
	}
}

// TestAttachCoord_OKOutcomeOverbillStillCounted proves the fallback
// guard does not mask real gateway-vs-coord drift on clean OK pairs.
func TestAttachCoord_OKOutcomeOverbillStillCounted(t *testing.T) {
	now := time.Now()
	results := []buyer.Result{
		{RequestID: "h_ok_overbill", Outcome: "ok", CompletionTokensReceived: 64, StartUTC: now, EndUTC: now},
	}
	gwRows := []gwRow{
		{RequestID: "h_ok_overbill", Outcome: "ok", CompletionTokens: 64, CreatedAt: now},
	}
	coordRows := []coordRow{
		{RequestID: "coord_ok_overbill", ExternalRequestID: "h_ok_overbill", Status: 200, CompletionTokens: 59, TsUTC: now},
	}

	r := &Result{}
	matchPairs(r, results, gwRows, coordRows)
	computePerPairDrift(r)

	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if r.GatewayOverbillVsCoordinatorTokens != 5 {
		t.Errorf("ok pair overbill must count: want 5, got %d", r.GatewayOverbillVsCoordinatorTokens)
	}
	if r.AbsGatewayCoordinatorMismatchTokens != 5 {
		t.Errorf("ok pair mismatch must count: want 5, got %d", r.AbsGatewayCoordinatorMismatchTokens)
	}
	if len(r.GatewayCoordMismatchedPairs) != 1 || r.GatewayCoordMismatchedPairs[0] != "h_ok_overbill" {
		t.Errorf("ok pair mismatch list: want [h_ok_overbill], got %v", r.GatewayCoordMismatchedPairs)
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

// --- DB fixtures for the snapshot-window integration tests ----------

// newTestGatewayDB creates an empty usage_events table in a fresh
// temp SQLite file and returns its path. Schema is the read-side
// projection of the production phase5-gateway DDL — only columns the
// reconciler actually SELECTs.
func newTestGatewayDB(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gateway.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE usage_events (
		request_id        TEXT NOT NULL,
		account_id        TEXT NOT NULL DEFAULT '',
		completion_tokens INTEGER NOT NULL DEFAULT 0,
		outcome           TEXT NOT NULL,
		created_at        TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("create usage_events: %v", err)
	}
	return path
}

func insertGwRow(t *testing.T, path, requestID, accountID string, completionTokens int64, outcome string, createdAt time.Time) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open gateway db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(
		`INSERT INTO usage_events(request_id, account_id, completion_tokens, outcome, created_at) VALUES (?, ?, ?, ?, ?)`,
		requestID, accountID, completionTokens, outcome, createdAt.UTC().Format(time.RFC3339Nano),
	); err != nil {
		t.Fatalf("insert gw row: %v", err)
	}
}

func TestQueryGatewayCarriesTokenSourceWhenPresent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gateway.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open gateway db: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE usage_events (
		request_id        TEXT NOT NULL,
		account_id        TEXT NOT NULL DEFAULT '',
		completion_tokens INTEGER NOT NULL DEFAULT 0,
		token_source      TEXT NOT NULL,
		outcome           TEXT NOT NULL,
		created_at        TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("create usage_events: %v", err)
	}
	at := time.Date(2026, 7, 1, 12, 0, 0, 0, time.UTC)
	if _, err := db.Exec(
		`INSERT INTO usage_events(request_id, account_id, completion_tokens, token_source, outcome, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
		"req_token_source", "acct", 12, "provider_reported", "ok", at.Format(time.RFC3339Nano),
	); err != nil {
		t.Fatalf("insert gw row: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close db: %v", err)
	}

	rows, hasAccountID, err := queryGateway(path, at.Add(-time.Second), at.Add(time.Second))
	if err != nil {
		t.Fatalf("queryGateway err: %v", err)
	}
	if !hasAccountID {
		t.Fatal("hasAccountID=false, want true")
	}
	if len(rows) != 1 {
		t.Fatalf("rows=%d want 1", len(rows))
	}
	if rows[0].TokenSource != "provider_reported" {
		t.Fatalf("TokenSource=%q want provider_reported", rows[0].TokenSource)
	}

	byIDRows, err := queryGatewayByIDs(path, []string{"req_token_source"})
	if err != nil {
		t.Fatalf("queryGatewayByIDs err: %v", err)
	}
	if len(byIDRows) != 1 {
		t.Fatalf("byIDRows=%d want 1", len(byIDRows))
	}
	if byIDRows[0].TokenSource != "provider_reported" {
		t.Fatalf("byIDRows[0].TokenSource=%q want provider_reported", byIDRows[0].TokenSource)
	}
}

// newTestCoordDB creates an empty request_log table in a fresh temp
// SQLite file and returns its path. Same read-side projection rule
// as newTestGatewayDB.
func newTestCoordDB(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "coord.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`CREATE TABLE request_log (
		request_id          TEXT NOT NULL,
		external_request_id TEXT NULL,
		account_id          TEXT NULL,
		model               TEXT NOT NULL DEFAULT '',
		completion_tokens   INTEGER NULL,
		status              INTEGER NOT NULL,
		ts_utc              TEXT NOT NULL
	)`); err != nil {
		t.Fatalf("create request_log: %v", err)
	}
	return path
}

func insertCoordRow(t *testing.T, path, requestID, externalRequestID, accountID, model string, completionTokens int64, status int, ts time.Time) {
	t.Helper()
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open coord db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(
		`INSERT INTO request_log(request_id, external_request_id, account_id, model, completion_tokens, status, ts_utc) VALUES (?, ?, ?, ?, ?, ?, ?)`,
		requestID, externalRequestID, accountID, model, completionTokens, status, ts.UTC().Format(time.RFC3339Nano),
	); err != nil {
		t.Fatalf("insert coord row: %v", err)
	}
}

func TestQueryCoordinatorUsesLedgerChargedPromptTokens(t *testing.T) {
	path := filepath.Join(t.TempDir(), "coord-ledger.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open coord db: %v", err)
	}
	now := time.Date(2026, 7, 4, 5, 30, 0, 0, time.UTC)
	if _, err := db.Exec(`CREATE TABLE request_log (
		request_id          TEXT NOT NULL,
		external_request_id TEXT NULL,
		account_id          TEXT NULL,
		attempt_n           INTEGER NULL
	)`); err != nil {
		t.Fatalf("create request_log: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (
		request_id                      TEXT NOT NULL,
		attempt_n                       INTEGER NOT NULL,
		provider_id                     TEXT NOT NULL,
		ts_utc                          TEXT NOT NULL,
		model                           TEXT NOT NULL,
		status                          INTEGER NOT NULL,
		prompt_tokens                   INTEGER NULL,
		charged_prompt_tokens           INTEGER NULL,
		provider_reported_prompt_tokens INTEGER NULL,
		completion_tokens               INTEGER NULL
	)`); err != nil {
		t.Fatalf("create ledger_request_credits: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO request_log(request_id, external_request_id, account_id, attempt_n) VALUES ('coord-internal', 'gw-request', 'acct-A', 0)`); err != nil {
		t.Fatalf("insert request_log: %v", err)
	}
	if _, err := db.Exec(`INSERT INTO ledger_request_credits(
		request_id, attempt_n, provider_id, ts_utc, model, status,
		prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens, completion_tokens
	) VALUES ('coord-internal', 0, 'provider-A', ?, 'test-model', 200, 100, 8, 100, 7)`, now.Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("insert ledger_request_credits: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close coord db: %v", err)
	}

	rows, hasAccountID, err := queryCoordinator(path, now.Add(-time.Second), now.Add(time.Second))
	if err != nil {
		t.Fatalf("queryCoordinator: %v", err)
	}
	if !hasAccountID {
		t.Fatal("queryCoordinator should report account_id metadata from joined request_log")
	}
	if len(rows) != 1 {
		t.Fatalf("rows=%d want 1: %+v", len(rows), rows)
	}
	got := rows[0]
	if got.ExternalRequestID != "gw-request" || got.AccountID != "acct-A" {
		t.Fatalf("joined metadata = external %q account %q, want gw-request/acct-A", got.ExternalRequestID, got.AccountID)
	}
	if got.PromptTokens != 8 || got.CompletionTokens != 7 || got.TotalTokens != 15 {
		t.Fatalf("tokens = prompt %d completion %d total %d, want charged prompt 8 + completion 7 = 15", got.PromptTokens, got.CompletionTokens, got.TotalTokens)
	}
}

func makeScenario(coordPath, gwPath string) *scenario.Scenario {
	return &scenario.Scenario{
		Target: scenario.Target{
			CoordinatorDBPath: coordPath,
			GatewayDBPath:     gwPath,
		},
	}
}

// TestRun_IDRecoveryRescuesClockSkewedRows asserts the HIGH-1 fix
// from the 3-lane codex audit on #243: when a gateway row's
// `created_at` lands just before `startUTC` (clock-skew or scheduling
// jitter), the by-ID recovery pass MUST still pull the row in so the
// matcher pairs it with the harness result and it does NOT show up
// as unmatched.
//
// Without the by-ID recovery, the row is dropped by the SQL
// `created_at >= startUTC` predicate and the harness sees a false-
// negative "harness success unmatched" billing-gap signal.
func TestRun_IDRecoveryRescuesClockSkewedRows(t *testing.T) {
	gwPath := newTestGatewayDB(t)
	coordPath := newTestCoordDB(t)

	startUTC := time.Date(2026, 6, 29, 14, 0, 0, 0, time.UTC)
	endUTC := startUTC.Add(10 * time.Second)

	// Gateway row stamped 5s BEFORE the harness's startUTC (simulates
	// gateway clock trailing harness). Without by-ID recovery this row
	// is invisible to the snapshot-window query.
	insertGwRow(t, gwPath, "req-skewed-1", "acct-A", 12, "ok", startUTC.Add(-5*time.Second))

	// Coord row also stamped just before startUTC, joined back to the
	// harness id via external_request_id.
	insertCoordRow(t, coordPath, "coord-internal-1", "req-skewed-1", "acct-A", "test-model", 12, 200, startUTC.Add(-4*time.Second))

	results := []buyer.Result{{
		RequestID:                "req-skewed-1",
		Model:                    "test-model",
		Outcome:                  "ok",
		CompletionTokensReceived: 12,
		StartUTC:                 startUTC.Add(time.Second),
		EndUTC:                   startUTC.Add(2 * time.Second),
	}}

	sc := makeScenario(coordPath, gwPath)
	r, err := Run(sc, results, startUTC, endUTC)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(r.UnmatchedSuccesses) != 0 {
		t.Errorf("clock-skewed harness-owned row must NOT appear as unmatched, got %v", r.UnmatchedSuccesses)
	}
	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d (matched=%v)", len(r.MatchedSuccesses), r.MatchedSuccesses)
	}
	if got := r.MatchedSuccesses[0].GatewayCompletionTokens; got != 12 {
		t.Errorf("matched gateway tokens: want 12, got %d", got)
	}
	if got := r.MatchedSuccesses[0].CoordinatorCompletionTokens; got != 12 {
		t.Errorf("matched coord tokens: want 12, got %d", got)
	}
	if len(r.UnmatchedGatewayOKRows) != 0 {
		t.Errorf("by-ID-recovered row must not appear as gateway orphan, got %v", r.UnmatchedGatewayOKRows)
	}
}

// TestRun_NoDoubleCountingAcrossAdjacentScenarios asserts the #243
// no-double-counting contract: a gateway row stamped inside scenario
// N's window MUST NOT surface as an orphan in scenario N+1's
// reconcile, even when N+1 starts immediately after N ends. This is
// the end-to-end behavioral test the R1 code-lane MEDIUM finding
// asked for — the existing TestSnapshotWindow_NoBackwardPad only
// asserts the helper's arithmetic.
func TestRun_NoDoubleCountingAcrossAdjacentScenarios(t *testing.T) {
	gwPath := newTestGatewayDB(t)
	coordPath := newTestCoordDB(t)

	scn1Start := time.Date(2026, 6, 29, 14, 0, 0, 0, time.UTC)
	scn1End := scn1Start.Add(10 * time.Second)
	scn2Start := scn1End // back-to-back, like 02→03 in the v0.3 baseline run
	scn2End := scn2Start.Add(10 * time.Second)

	// Scenario 1's row, stamped 8s in (well inside scenario 1's window).
	insertGwRow(t, gwPath, "req-scn1", "acct-A", 7, "ok", scn1Start.Add(8*time.Second))
	insertCoordRow(t, coordPath, "coord-scn1", "req-scn1", "acct-A", "test-model", 7, 200, scn1Start.Add(8*time.Second))

	// Scenario 1 has the harness result for req-scn1. Run it: should
	// reconcile cleanly with one matched pair.
	scn1Results := []buyer.Result{{
		RequestID:                "req-scn1",
		Model:                    "test-model",
		Outcome:                  "ok",
		CompletionTokensReceived: 7,
		StartUTC:                 scn1Start.Add(7 * time.Second),
		EndUTC:                   scn1Start.Add(9 * time.Second),
	}}
	sc := makeScenario(coordPath, gwPath)
	r1, err := Run(sc, scn1Results, scn1Start, scn1End)
	if err != nil {
		t.Fatalf("scenario 1 Run: %v", err)
	}
	if len(r1.MatchedSuccesses) != 1 {
		t.Fatalf("scn1 want 1 matched pair, got %d", len(r1.MatchedSuccesses))
	}
	if len(r1.UnmatchedGatewayOKRows) != 0 {
		t.Errorf("scn1 unexpected gateway orphans: %v", r1.UnmatchedGatewayOKRows)
	}

	// Scenario 2: no harness result for req-scn1 (different scenario).
	// Pre-fix, the backward pad pulled scn1's tail row into scn2's
	// window and surfaced req-scn1 as a false-positive orphan in scn2.
	// Post-fix, scn2's window starts at scn2Start = scn1End, so the
	// scn1 row at scn1Start+8s is outside scn2's pull AND not in scn2's
	// harness IDs → must not appear.
	scn2Results := []buyer.Result{} // empty: simulates a scenario where no harness fires against this row
	r2, err := Run(sc, scn2Results, scn2Start, scn2End)
	if err != nil {
		t.Fatalf("scenario 2 Run: %v", err)
	}
	if len(r2.UnmatchedGatewayOKRows) != 0 {
		t.Errorf("scenario 2 must not see scenario 1's gateway row as orphan, got %v", r2.UnmatchedGatewayOKRows)
	}
	if len(r2.UnmatchedCoordinator2xxRows) != 0 {
		t.Errorf("scenario 2 must not see scenario 1's coord row as orphan, got %v", r2.UnmatchedCoordinator2xxRows)
	}
}

// TestSnapshotWindow_BoundaryNanoseconds locks the inclusive nature
// of the snapshot window bounds in SQL: a row stamped exactly at
// startUTC is included; a row stamped 1ns before is excluded; a row
// at endUTC+30s is included; a row 1ns past the pad is excluded.
// LOW finding from the R1 security lane: the test should anchor the
// `>=` / `<=` semantics so future "tighten the bound" edits cannot
// silently flip exact-boundary behavior.
//
// Sub-second component is 9-significant-digits so time.RFC3339Nano
// emits a uniform 9-digit fraction across all boundary timestamps;
// SQL string comparison of variable-length trimmed fractions is a
// separate pre-existing harness quirk, out of scope for #243.
func TestSnapshotWindow_BoundaryNanoseconds(t *testing.T) {
	gwPath := newTestGatewayDB(t)
	coordPath := newTestCoordDB(t)
	startUTC := time.Date(2026, 6, 29, 14, 0, 0, 123_456_789, time.UTC)
	endUTC := startUTC.Add(10 * time.Second)

	// Four rows: one each at start-1ns (excl), start (incl), end+90s
	// (incl), end+90s+1ns (excl). No harness results → none get
	// id-rescued. Orphans tell us which rows the snapshot query saw.
	insertGwRow(t, gwPath, "before-window", "acct-A", 1, "ok", startUTC.Add(-time.Nanosecond))
	insertGwRow(t, gwPath, "at-start", "acct-A", 1, "ok", startUTC)
	insertGwRow(t, gwPath, "at-end-pad", "acct-A", 1, "ok", endUTC.Add(90*time.Second))
	insertGwRow(t, gwPath, "past-end-pad", "acct-A", 1, "ok", endUTC.Add(90*time.Second).Add(time.Nanosecond))

	sc := makeScenario(coordPath, gwPath)
	r, err := Run(sc, nil, startUTC, endUTC)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	got := map[string]bool{}
	for _, id := range r.UnmatchedGatewayOKRows {
		got[id] = true
	}
	if got["before-window"] {
		t.Errorf("row 1ns before startUTC must be excluded, got it as orphan")
	}
	if !got["at-start"] {
		t.Errorf("row at startUTC must be included (inclusive lower bound)")
	}
	if !got["at-end-pad"] {
		t.Errorf("row at endUTC+30s must be included (inclusive upper bound)")
	}
	if got["past-end-pad"] {
		t.Errorf("row 1ns past endUTC+30s must be excluded")
	}
}

// TestRun_LateSettlement_ExactIDMatchesPastFuzzyWindow asserts the
// #243 R3 fix: a gateway row whose `created_at` is 76s after the
// harness's `EndUTC` (within live v0.3 baseline lag) MUST still
// match by exact request_id, because the snapshot pad + quiesce
// were widened to 90s but the FUZZY matchWindow stayed at 60s as a
// defensive guard against accidental token+timestamp false-positives.
// Without the exactMatchSettleWindow split, this row would be in the
// snapshot pool but rejected by the matcher, surfacing as a false-
// positive UnmatchedSuccesses + orphan gateway row.
//
// 3-of-3 R3 codex audit lanes converged on this finding before the
// fix landed. The test pins the contract so future "tighten the
// match window" edits cannot silently re-open the bug.
func TestRun_LateSettlement_ExactIDMatchesPastFuzzyWindow(t *testing.T) {
	gwPath := newTestGatewayDB(t)
	coordPath := newTestCoordDB(t)

	startUTC := time.Date(2026, 6, 29, 14, 0, 0, 0, time.UTC)
	harnessEnd := startUTC.Add(2 * time.Second)
	endUTC := startUTC.Add(10 * time.Second)

	// Gateway settles 76s after the harness's observed end (live
	// v0.3 max lag). Inside the 90s snapshot pad, OUTSIDE the 60s
	// fuzzy matchWindow.
	gwCreated := harnessEnd.Add(76 * time.Second)
	insertGwRow(t, gwPath, "req-late-76s", "acct-A", 18, "ok", gwCreated)
	// Coord settles at a similar lag from harness start.
	insertCoordRow(t, coordPath, "coord-late-1", "req-late-76s", "acct-A", "test-model", 18, 200, startUTC.Add(75*time.Second))

	results := []buyer.Result{{
		RequestID:                "req-late-76s",
		Model:                    "test-model",
		Outcome:                  "ok",
		CompletionTokensReceived: 18,
		StartUTC:                 startUTC.Add(time.Second),
		EndUTC:                   harnessEnd,
	}}

	sc := makeScenario(coordPath, gwPath)
	r, err := Run(sc, results, startUTC, endUTC)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if len(r.UnmatchedSuccesses) != 0 {
		t.Errorf("76s-late harness-owned row must match by exact id, got unmatched=%v", r.UnmatchedSuccesses)
	}
	if len(r.MatchedSuccesses) != 1 {
		t.Fatalf("want 1 matched pair, got %d", len(r.MatchedSuccesses))
	}
	if got := r.MatchedSuccesses[0].GatewayCompletionTokens; got != 18 {
		t.Errorf("matched gateway tokens: want 18, got %d", got)
	}
	if got := r.MatchedSuccesses[0].CoordinatorCompletionTokens; got != 18 {
		t.Errorf("matched coord tokens: want 18, got %d", got)
	}
	if len(r.UnmatchedGatewayOKRows) != 0 {
		t.Errorf("late settle row must not appear as gateway orphan, got %v", r.UnmatchedGatewayOKRows)
	}
}

// TestHarnessRequestIDs_DedupAndFilter pins the helper that feeds the
// by-ID recovery pass: empty strings are filtered, duplicates are
// collapsed, original order is preserved. Cheap unit test.
func TestHarnessRequestIDs_DedupAndFilter(t *testing.T) {
	results := []buyer.Result{
		{RequestID: "a"},
		{RequestID: ""},
		{RequestID: "b"},
		{RequestID: "a"}, // duplicate
		{RequestID: "c"},
	}
	got := harnessRequestIDs(results)
	want := []string{"a", "b", "c"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("want %v, got %v", want, got)
	}
	if harnessRequestIDs(nil) != nil {
		t.Errorf("nil input must return nil")
	}
}
