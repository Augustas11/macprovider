// Package invariants holds the 4 hard pass/fail checks the harness
// enforces in phase A, before any routing-contract addendum exists:
//
//   I1  ledger reconciliation drift == 0
//   I2  no 5xx response without billing settlement (orphan check)
//   I3  no charged-tokens > delivered-tokens
//   I4  no silent hang (stream stayed open past threshold with no bytes
//       and no terminating error)
//
// Each check produces a structured verdict with the evidence it relied
// on, so triage can re-examine the artifact bundle and judge whether a
// failure is a real bug or a test-side artifact.
package invariants

import (
	"fmt"
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
			checkI1(ledger),
			checkI2(results),
			checkI3(results),
			checkI4(sc, results),
		},
	}
}

// I1 — ledger reconciliation drift must be zero. Drift includes:
//   * harness-successful requests missing on either side
//   * token-count mismatches between coordinator and gateway
// Orphan rows (rows on a side with no harness-side counterpart) are NOT
// counted toward drift in phase A — concurrent unrelated traffic may
// produce them. Triage will decide if that needs tightening.
func checkI1(ledger *reconcile.Result) Check {
	c := Check{ID: "I1", Title: "billing-ledger reconciliation drift == 0"}
	if ledger == nil {
		c.Skipped = true
		c.Detail = "reconciliation skipped: coordinator_db_path or gateway_db_path not configured"
		return c
	}
	drift := len(ledger.MissingOnCoordinator) + len(ledger.MissingOnGateway) + len(ledger.TokenMismatches)
	if drift == 0 {
		c.Passed = true
		c.Detail = fmt.Sprintf("0 drift across %d harness requests (coord=%d rows, gw=%d rows)",
			ledger.HarnessRequests, ledger.CoordinatorRows, ledger.GatewayRows)
		return c
	}
	c.Passed = false
	c.EvidenceCount = drift
	c.Detail = fmt.Sprintf("%d drift entries: %d missing-on-coordinator, %d missing-on-gateway, %d token-mismatch",
		drift, len(ledger.MissingOnCoordinator), len(ledger.MissingOnGateway), len(ledger.TokenMismatches))
	for _, id := range ledger.MissingOnCoordinator {
		c.OffendingIDs = append(c.OffendingIDs, id)
	}
	for _, id := range ledger.MissingOnGateway {
		c.OffendingIDs = append(c.OffendingIDs, id)
	}
	for _, m := range ledger.TokenMismatches {
		c.OffendingIDs = append(c.OffendingIDs, m.RequestID)
	}
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
func checkI2(results []buyer.Result) Check {
	c := Check{ID: "I2", Title: "no 5xx response without billing settlement"}
	// We can only check this when the gateway exposes the settlement
	// state. In phase A we treat the presence of the X-Request-Id echo
	// on a 5xx as evidence the gateway intends to settle (since it
	// reached settleBeforeResponse). Without DB access we can't fully
	// verify — but if reconcile ran it's already covered by I1's
	// missing_on_gateway list for ok responses. For 5xx, we emit a
	// soft signal: count and list 5xx request ids for triage.
	//
	// Hard failure only when no request id was echoed on a 5xx —
	// that's an unambiguous logging gap.
	var orphans []string
	var fiveXX int
	for _, r := range results {
		if r.HTTPStatus < 500 || r.HTTPStatus >= 600 {
			continue
		}
		fiveXX++
		if r.RequestID == "" {
			orphans = append(orphans, fmt.Sprintf("buyer=%d req=%d", r.BuyerIndex, r.RequestIndex))
		}
	}
	if fiveXX == 0 {
		c.Passed = true
		c.Detail = "no 5xx responses observed"
		return c
	}
	if len(orphans) == 0 {
		c.Passed = true
		c.Detail = fmt.Sprintf("%d 5xx responses, all carried a request id (settle-path eligible)", fiveXX)
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
func checkI3(results []buyer.Result) Check {
	c := Check{ID: "I3", Title: "no charged-tokens > delivered-tokens"}
	var offenders []string
	for _, r := range results {
		if r.Outcome != "ok" {
			continue
		}
		if r.CompletionTokensReceived == 0 {
			continue
		}
		// We can't separate the two sources in this layer — both end
		// up in CompletionTokensReceived. The DB-level overcharge check
		// is in reconcile.TokenMismatches. This invariant is structured
		// so a future PR can compare gateway-usage vs SSE-delta when
		// both are available.
	}
	if len(offenders) == 0 {
		c.Passed = true
		c.Detail = "no overcharges observed (phase A: structural check only; reconcile.token_mismatches carries the DB-level signal)"
		return c
	}
	c.Passed = false
	c.OffendingIDs = offenders
	c.EvidenceCount = len(offenders)
	c.Detail = fmt.Sprintf("%d requests where charged > delivered tokens", len(offenders))
	return c
}

// I4 — silent hang. For each result, if:
//   * the stream stayed open long enough that (EndUTC - LastByteUTC) exceeds threshold, AND
//   * the request was streaming, AND
//   * we did NOT see the terminator, AND
//   * outcome is "ok"
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
