// Package invariants holds the 4 hard pass/fail checks the harness
// enforces in phase A, before any routing-contract addendum exists:
//
//	I1  ledger reconciliation drift == 0
//	I2  no 5xx response without billing settlement (orphan check)
//	I3  no charged-tokens > delivered-tokens
//	I4  no silent hang (stream stayed open past threshold with no bytes
//	    and no terminating error)
//
// Each check produces a structured verdict with the evidence it relied
// on, so triage can re-examine the artifact bundle and judge whether a
// failure is a real bug or a test-side artifact.
package invariants

import (
	"fmt"
	"strings"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/metrics"
	"github.com/augstar/macprovider-network-harness/internal/reconcile"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

type Result struct {
	Checks []Check `json:"checks"`
}

type Check struct {
	ID            string   `json:"id"`
	Title         string   `json:"title"`
	Passed        bool     `json:"passed"`
	Skipped       bool     `json:"skipped"`
	Detail        string   `json:"detail"`
	OffendingIDs  []string `json:"offending_request_ids,omitempty"`
	EvidenceCount int      `json:"evidence_count,omitempty"`
}

func (r *Result) AnyFailed() bool {
	for _, c := range r.Checks {
		if !c.Passed && !c.Skipped {
			return true
		}
	}
	return false
}

// Evaluate runs all 4 invariants. summary is optional reference data;
// ledger is nil when reconciliation was skipped (no DB paths configured).
func Evaluate(sc *scenario.Scenario, results []buyer.Result, summary *metrics.Summary, ledger *reconcile.Result) *Result {
	return &Result{
		Checks: []Check{
			checkI1(sc, ledger),
			checkI2(results, ledger),
			checkI3(sc, ledger),
			checkI4(sc, results),
		},
	}
}

// I1 — ledger reconciliation drift must be zero. Verified live
// 2026-06-27: gateway and coordinator use SEPARATE request_id spaces
// (a gateway UUID and a coord UUID never overlap), so we correlate by
// (model, completion_tokens, ts ± window).
//
// Since #226 + #229 R4, drift is computed PER MATCHED PAIR (not as
// aggregate population sums — which false-fired when most gateway
// settlements landed as SPEC-006 §17.7 fallback outcomes). The
// reconciler stamps drift_basis="per_matched_pair_v2" so artifact
// consumers know what algorithm produced the numbers.
//
// Drift here means ANY of:
//   - harness success unmatched on gateway (UnmatchedSuccesses) —
//     billing-bypass risk
//   - gateway "ok"-outcome row unmatched on any harness success
//     (UnmatchedGatewayOKRows) — orphan/leaked settlement or
//     concurrent buyer traffic
//   - gateway "ok" matched pair with no coord row (MatchedCoordMissing)
//     — fallback outcomes legitimately lack coord rows and are NOT
//     flagged here
//   - gateway over-billed vs harness across matched pairs
//     (GatewayOverbillVsHarnessTokens > 0, positive-only sum so a
//     +N overbill is not hidden by a -N underbill). Underbill alone
//     is allowed — gateway-side streaming rounding is legitimate.
//   - gateway and coord disagree on per-pair tokens in EITHER direction
//     (AbsGatewayCoordinatorMismatchTokens > 0) — both are settlement
//     systems and must agree on per-request token counts.
func checkI1(sc *scenario.Scenario, ledger *reconcile.Result) Check {
	c := Check{ID: "I1", Title: "billing-ledger reconciliation drift == 0"}
	if ledger == nil {
		c.Skipped = true
		c.Detail = "reconciliation skipped: target.coordinator_db_path / _ssh not configured"
		return c
	}
	// Fail-closed: reconcile.Run errored. Even if every drift signal
	// below would be zero, the audit pipeline must NOT silently pass
	// when reconciliation didn't actually run. R3 audit code HIGH.
	if ledger.ReconcileError != "" {
		c.Passed = false
		c.EvidenceCount = 1
		c.Detail = "reconcile errored: " + ledger.ReconcileError
		return c
	}

	// I1 reads matched-pair drift produced by the reconciler under
	// drift_basis="per_matched_pair_v2" (#226 + #229 R2). Five signals:
	//   - harness successes unmatched on gateway (missing settlement)
	//   - gateway-ok rows unmatched on the harness side (orphan settlement)
	//   - matched gateway-ok pairs with no coord row (suspicious; fallback
	//     outcomes legitimately lack coord rows and are excluded upstream)
	//   - gateway-vs-harness positive overbill across pairs (signed-safe;
	//     underbill alone is allowed per streaming rounding semantics)
	//   - gateway-vs-coord absolute mismatch (any direction; both are
	//     settlement systems and MUST agree on per-pair token counts;
	//     same #232 corroboration gate applies)
	gwOverbillVsHarness := ledger.GatewayOverbillVsHarnessTokens
	absGwCoordMismatch := ledger.AbsGatewayCoordinatorMismatchTokens
	tolerance := int64(0)
	if sc != nil {
		tolerance = sc.ChargedDeliveredToleranceTokens
	}
	unmatched := len(ledger.UnmatchedSuccesses)
	unmatchedGwOK := len(ledger.UnmatchedGatewayOKRows)
	unmatchedCoord2xx := len(ledger.UnmatchedCoordinator2xxRows)
	coordMissingOK := len(ledger.MatchedCoordMissing)
	// Ambiguity — ≥2 exact-id candidates within window+account after
	// the matcher's filters. Hard I1 signal (PK collision evidence
	// across accounts, or duplicate settlements within one account).
	ambiguousGw := len(ledger.AmbiguousExactGatewayIDs)
	ambiguousCoord := len(ledger.AmbiguousExactCoordIDs)

	driftSignals := 0
	if unmatched > 0 {
		driftSignals++
	}
	if unmatchedGwOK > 0 {
		driftSignals++
	}
	if unmatchedCoord2xx > 0 {
		driftSignals++
	}
	if coordMissingOK > 0 {
		driftSignals++
	}
	if gwOverbillVsHarness > tolerance {
		driftSignals++
	}
	if absGwCoordMismatch > 0 {
		driftSignals++
	}
	if ambiguousGw > 0 {
		driftSignals++
	}
	if ambiguousCoord > 0 {
		driftSignals++
	}

	if driftSignals == 0 {
		c.Passed = true
		c.Detail = fmt.Sprintf("reconciled cleanly: harness=%d ok, gw=%d ok, coord=%d 2xx; %d matched pairs, no overbills (per_matched_pair_v2 basis)",
			ledger.HarnessSuccessful, ledger.GatewayRowsOK, ledger.CoordinatorRows2xx, len(ledger.MatchedSuccesses))
		return c
	}

	c.Passed = false
	c.EvidenceCount = driftSignals
	var parts []string
	if unmatched > 0 {
		parts = append(parts, fmt.Sprintf("%d harness successes unmatched on gateway", unmatched))
	}
	if unmatchedGwOK > 0 {
		parts = append(parts, fmt.Sprintf("%d gateway-ok rows unmatched by any harness success", unmatchedGwOK))
	}
	if unmatchedCoord2xx > 0 {
		parts = append(parts, fmt.Sprintf("%d coord 2xx rows unmatched by any harness success", unmatchedCoord2xx))
	}
	if coordMissingOK > 0 {
		parts = append(parts, fmt.Sprintf("%d gateway-ok matched pairs with no coord row", coordMissingOK))
	}
	if gwOverbillVsHarness > tolerance {
		parts = append(parts, fmt.Sprintf("gateway over-billed by %d vs harness above tolerance %d across %d pair(s)", gwOverbillVsHarness, tolerance, len(ledger.OverbilledPairs)))
	}
	if absGwCoordMismatch > 0 {
		parts = append(parts, fmt.Sprintf("gateway-coord ledger mismatch %d tokens across %d pair(s)", absGwCoordMismatch, len(ledger.GatewayCoordMismatchedPairs)))
	}
	if ambiguousGw > 0 {
		parts = append(parts, fmt.Sprintf("%d gateway exact-id ambiguities (id collision within window+account)", ambiguousGw))
	}
	if ambiguousCoord > 0 {
		parts = append(parts, fmt.Sprintf("%d coord exact-id ambiguities", ambiguousCoord))
	}
	c.Detail = strings.Join(parts, "; ")
	c.OffendingIDs = append(c.OffendingIDs, ledger.UnmatchedSuccesses...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.UnmatchedGatewayOKRows...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.UnmatchedCoordinator2xxRows...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.OverbilledPairs...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.MatchedCoordMissing...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.GatewayCoordMismatchedPairs...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.AmbiguousExactGatewayIDs...)
	c.OffendingIDs = append(c.OffendingIDs, ledger.AmbiguousExactCoordIDs...)
	return c
}

// I2 — no 5xx response without a billing settlement entry on the
// coordinator side. The gateway should write a settlement row for
// every response it sent, including 5xx (outcome=upstream_error etc.).
// Orphan 5xx is the signature of a billing-bypass path or a logging gap.
//
// In phase A we only check the gateway side: harness saw a 5xx response,
// is there a usage_events row for it? Coordinator-side request_log may
// legitimately omit 5xx that never reached coordinator routing (e.g.,
// gateway-side quota reject).
func checkI2(results []buyer.Result, ledger *reconcile.Result) Check {
	c := Check{ID: "I2", Title: "no 5xx response without billing settlement"}
	var orphans []string
	var fiveXX int
	if ledger == nil {
		for _, r := range results {
			if r.HTTPStatus >= 500 && r.HTTPStatus < 600 {
				fiveXX++
				if r.RequestID != "" {
					orphans = append(orphans, r.RequestID)
				} else {
					orphans = append(orphans, fmt.Sprintf("buyer=%d req=%d", r.BuyerIndex, r.RequestIndex))
				}
			}
		}
		if fiveXX == 0 {
			c.Passed = true
			c.Detail = "no 5xx responses observed"
			return c
		}
		c.Passed = false
		c.OffendingIDs = orphans
		c.EvidenceCount = len(orphans)
		c.Detail = fmt.Sprintf("%d 5xx responses observed but settlement DB not configured", fiveXX)
		return c
	}
	settled := map[string]bool{}
	if ledger.GatewayHasAccountID {
		for _, row := range ledger.GatewaySettlementRequests {
			if row.AccountID == "" || row.RequestID == "" {
				continue
			}
			settled[row.AccountID+"|"+row.RequestID] = true
		}
	} else {
		for _, id := range ledger.GatewaySettlementRequestIDs {
			settled[id] = true
		}
	}
	for _, r := range results {
		if r.HTTPStatus < 500 || r.HTTPStatus >= 600 {
			continue
		}
		fiveXX++
		if r.RequestID == "" {
			orphans = append(orphans, fmt.Sprintf("buyer=%d req=%d", r.BuyerIndex, r.RequestIndex))
			continue
		}
		if ledger.GatewayHasAccountID {
			if ledger.HarnessAccountID == "" {
				orphans = append(orphans, r.RequestID)
				continue
			}
			if !settled[ledger.HarnessAccountID+"|"+r.RequestID] {
				orphans = append(orphans, r.RequestID)
			}
			continue
		}
		if !settled[r.RequestID] {
			orphans = append(orphans, r.RequestID)
		}
	}
	if fiveXX == 0 {
		c.Passed = true
		c.Detail = "no 5xx responses observed"
		return c
	}
	if len(orphans) == 0 {
		c.Passed = true
		c.Detail = fmt.Sprintf("%d 5xx responses, all have gateway settlement rows", fiveXX)
		return c
	}
	c.Passed = false
	c.OffendingIDs = orphans
	c.EvidenceCount = len(orphans)
	c.Detail = fmt.Sprintf("%d 5xx responses without a request id — billing-bypass risk", len(orphans))
	return c
}

// I3 — no charged-tokens > delivered-tokens. The harness's own SSE
// parser produced CompletionTokensReceived; the gateway's usage block
// produced PromptTokensReported / CompletionTokensReceived (when the
// usage field was inlined). For successful requests we compare:
// reported_completion <= harness_observed_completion. Strict greater-
// than is a fail; equal or less is fine (provider may report fewer if
// usage is gateway-estimated).
//
// Phase A limitation: when the usage block is provider-reported and
// differs from the SSE-content count, we may flag false positives.
// Triage will tell us if that needs a tolerance.
func checkI3(sc *scenario.Scenario, ledger *reconcile.Result) Check {
	c := Check{ID: "I3", Title: "no charged-tokens > delivered-tokens"}
	if ledger == nil {
		c.Skipped = true
		c.Detail = "reconciliation skipped: charged-vs-delivered requires gateway settlement rows"
		return c
	}
	tolerance := int64(0)
	if sc != nil {
		tolerance = sc.ChargedDeliveredToleranceTokens
	}
	if ledger.GatewayOverbillVsHarnessTokens <= tolerance {
		c.Passed = true
		c.Detail = fmt.Sprintf("no overcharges observed above tolerance: gateway_overbill_vs_harness=%d tolerance=%d", ledger.GatewayOverbillVsHarnessTokens, tolerance)
		return c
	}
	c.Passed = false
	c.OffendingIDs = ledger.OverbilledPairs
	c.EvidenceCount = len(ledger.OverbilledPairs)
	c.Detail = fmt.Sprintf("gateway charged %d tokens above delivered tolerance %d across %d request(s)", ledger.GatewayOverbillVsHarnessTokens, tolerance, len(ledger.OverbilledPairs))
	return c
}

// I4 — silent hang. For each result, if:
//   - the stream stayed open long enough that (EndUTC - LastByteUTC) exceeds threshold, AND
//   - the request was streaming, AND
//   - we did NOT see the terminator, AND
//   - outcome is "ok"
//
// then the buyer was left waiting on dead air without an error. That's
// the worst-shaped UX failure — buyer thinks something's happening when
// nothing is. Promote Outcome to "silent_hang" in evidence.
func checkI4(sc *scenario.Scenario, results []buyer.Result) Check {
	c := Check{ID: "I4", Title: "no silent hang (open stream, no bytes, no terminator)"}
	threshold := sc.SilentHangThreshold
	var offenders []string
	for _, r := range results {
		if !r.Stream || r.Outcome != "ok" || r.SawTerminator {
			continue
		}
		if r.LastByteUTC.IsZero() {
			// Never saw any byte — that's a TTFT failure, classified
			// under transport_error normally. If outcome=ok with zero
			// bytes, that's also a silent-hang signature.
			offenders = append(offenders, r.RequestID)
			continue
		}
		gap := r.EndUTC.Sub(r.LastByteUTC)
		if gap >= threshold {
			offenders = append(offenders, r.RequestID)
		}
	}
	if len(offenders) == 0 {
		c.Passed = true
		c.Detail = fmt.Sprintf("no silent hangs (threshold=%s)", time.Duration(threshold))
		return c
	}
	c.Passed = false
	c.OffendingIDs = offenders
	c.EvidenceCount = len(offenders)
	c.Detail = fmt.Sprintf("%d streams stayed open past %s without bytes or terminator", len(offenders), time.Duration(threshold))
	return c
}
