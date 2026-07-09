// Tests for I1's consumption of the reconciler's per-pair drift signals
// (#229 R4 audit MEDIUM). The reconciler-layer tests in
// internal/reconcile/ verify that the drift fields are computed
// correctly; these tests verify that I1 INTERPRETS them correctly,
// catching every failure mode and PASSing on a clean run.
package invariants

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-network-harness/internal/buyer"
	"github.com/augstar/macprovider-network-harness/internal/reconcile"
	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

func TestCheckI1_CleanRun_AllSignalsZero(t *testing.T) {
	ledger := &reconcile.Result{
		HarnessSuccessful:  10,
		GatewayRowsOK:      10,
		CoordinatorRows2xx: 10,
		MatchedSuccesses:   []reconcile.MatchedPair{{}, {}, {}, {}, {}, {}, {}, {}, {}, {}},
	}
	c := checkI1(nil, ledger)
	if !c.Passed {
		t.Fatalf("clean run should pass, got fail: %s", c.Detail)
	}
	if !strings.Contains(c.Detail, "per_matched_pair_v2") {
		t.Errorf("pass detail should advertise drift basis: %s", c.Detail)
	}
}

func TestCheckI1_NoReconcile_Skips(t *testing.T) {
	c := checkI1(nil, nil)
	if !c.Skipped {
		t.Errorf("nil ledger should SKIP, got: %s", c.Detail)
	}
}

func TestCheckI1_UnmatchedHarnessSuccess_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		UnmatchedSuccesses: []string{"h1", "h2"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("should fail on unmatched harness successes")
	}
	if !strings.Contains(c.Detail, "unmatched on gateway") {
		t.Errorf("detail should call out unmatched, got: %s", c.Detail)
	}
	if !contains(c.OffendingIDs, "h1") || !contains(c.OffendingIDs, "h2") {
		t.Errorf("offending ids should include unmatched: %v", c.OffendingIDs)
	}
}

func TestCheckI1_OrphanCoord2xx_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		UnmatchedCoordinator2xxRows: []string{"COORD_ORPHAN"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("should fail on orphan coord 2xx rows")
	}
	if !contains(c.OffendingIDs, "COORD_ORPHAN") {
		t.Errorf("offending ids should include orphan coord id: %v", c.OffendingIDs)
	}
}

func TestCheckI1_OrphanGatewayOK_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		UnmatchedGatewayOKRows: []string{"GW_ORPHAN"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("should fail on orphan gateway-ok rows")
	}
	if !contains(c.OffendingIDs, "GW_ORPHAN") {
		t.Errorf("offending ids should include orphan id: %v", c.OffendingIDs)
	}
}

func TestCheckI1_CoordMissingOnOK_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		MatchedCoordMissing: []string{"h_OK_no_coord"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("should fail when gateway-ok pair has no coord row")
	}
	if !strings.Contains(c.Detail, "no coord row") {
		t.Errorf("detail should call out coord-missing: %s", c.Detail)
	}
}

func TestCheckI1_GatewayOverbillVsHarness_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		GatewayOverbillVsHarnessTokens: 10,
		OverbilledPairs:                []string{"OVERBILLED"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("should fail on gateway-vs-harness overbill")
	}
	if !contains(c.OffendingIDs, "OVERBILLED") {
		t.Errorf("offending should include overbilled pair: %v", c.OffendingIDs)
	}
}

func TestCheckI1_GatewayOverbillVsHarness_AppliesScenarioTolerance(t *testing.T) {
	sc := &scenario.Scenario{ChargedDeliveredToleranceTokens: 10}
	ledger := &reconcile.Result{
		GatewayOverbillVsHarnessTokens: 10,
		OverbilledPairs:                []string{"OVERBILLED"},
	}
	c := checkI1(sc, ledger)
	if !c.Passed {
		t.Fatalf("I1 should pass overbill within scenario tolerance: %+v", c)
	}
	sc.ChargedDeliveredToleranceTokens = 9
	c = checkI1(sc, ledger)
	if c.Passed {
		t.Fatal("I1 should fail overbill above scenario tolerance")
	}
}

// CRITICAL regression: gateway-vs-coord undercharge (gateway billed
// LESS than coord) was missed pre-#229 R2. Verify checkI1 catches it
// via the abs-mismatch signal.
func TestCheckI1_CoordOverbill_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		AbsGatewayCoordinatorMismatchTokens: 10,
		GatewayCoordMismatchedPairs:         []string{"MISMATCH"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("should fail on absolute gateway-coord mismatch (either direction)")
	}
	if !strings.Contains(c.Detail, "gateway-coord ledger mismatch") {
		t.Errorf("detail should call out gw-coord mismatch: %s", c.Detail)
	}
}

// Allowed: gateway billed FEWER tokens than harness observed (streaming
// rounding). NetGatewayMinusHarnessTokens can be negative without
// failing I1 — only the positive-overbill sum is the headline gate.
func TestCheckI1_HarnessUnderbillAlone_Passes(t *testing.T) {
	ledger := &reconcile.Result{
		HarnessSuccessful:              10,
		GatewayRowsOK:                  10,
		CoordinatorRows2xx:             10,
		MatchedSuccesses:               []reconcile.MatchedPair{{}, {}, {}, {}, {}, {}, {}, {}, {}, {}},
		NetGatewayMinusHarnessTokens:   -5, // underbill only
		GatewayOverbillVsHarnessTokens: 0,
	}
	c := checkI1(nil, ledger)
	if !c.Passed {
		t.Errorf("underbill alone should not fail I1: %s", c.Detail)
	}
}

func TestCheckI1_MaxCompletionTokenDeltaFailsEitherDirection(t *testing.T) {
	sc := &scenario.Scenario{MaxCompletionTokenDelta: 2}
	ledger := &reconcile.Result{
		MatchedSuccesses: []reconcile.MatchedPair{
			{HarnessRequestID: "under", HarnessCompletionTokens: 20, GatewayCompletionTokens: 17},
			{HarnessRequestID: "over", HarnessCompletionTokens: 20, GatewayCompletionTokens: 23},
			{HarnessRequestID: "inside", HarnessCompletionTokens: 20, GatewayCompletionTokens: 18},
		},
	}
	c := checkI1(sc, ledger)
	if c.Passed {
		t.Fatal("I1 should fail when configured completion-token delta is exceeded")
	}
	if !contains(c.OffendingIDs, "under") || !contains(c.OffendingIDs, "over") {
		t.Fatalf("offending ids should include both over-limit deltas, got %v", c.OffendingIDs)
	}
	if contains(c.OffendingIDs, "inside") {
		t.Fatalf("delta at tolerance should not be offending, got %v", c.OffendingIDs)
	}
	if !strings.Contains(c.Detail, "completion-token") {
		t.Fatalf("detail should call out completion-token delta: %s", c.Detail)
	}
}

func TestCheckI1_RequiredGatewayOutcomeFailsMismatches(t *testing.T) {
	sc := &scenario.Scenario{RequiredGatewayOutcome: "ok"}
	ledger := &reconcile.Result{
		MatchedSuccesses: []reconcile.MatchedPair{
			{HarnessRequestID: "ok", GatewayOutcome: "ok"},
			{HarnessRequestID: "fallback", GatewayOutcome: "stream_output_exceeded"},
		},
	}
	c := checkI1(sc, ledger)
	if c.Passed {
		t.Fatal("I1 should fail when a matched pair has the wrong gateway outcome")
	}
	if !contains(c.OffendingIDs, "fallback") || contains(c.OffendingIDs, "ok") {
		t.Fatalf("offending ids should contain only the mismatched outcome pair, got %v", c.OffendingIDs)
	}
	if !strings.Contains(c.Detail, "required gateway outcome") {
		t.Fatalf("detail should call out required gateway outcome: %s", c.Detail)
	}
}

func TestCheckI1_RequiredGatewayTokenSourceFailsMismatches(t *testing.T) {
	sc := &scenario.Scenario{RequiredGatewayTokenSource: "provider_reported"}
	ledger := &reconcile.Result{
		MatchedSuccesses: []reconcile.MatchedPair{
			{HarnessRequestID: "reported", GatewayTokenSource: "provider_reported"},
			{HarnessRequestID: "estimated", GatewayTokenSource: "gateway_estimated"},
		},
	}
	c := checkI1(sc, ledger)
	if c.Passed {
		t.Fatal("I1 should fail when a matched pair has the wrong gateway token source")
	}
	if !contains(c.OffendingIDs, "estimated") || contains(c.OffendingIDs, "reported") {
		t.Fatalf("offending ids should contain only the mismatched token-source pair, got %v", c.OffendingIDs)
	}
	if !strings.Contains(c.Detail, "required gateway token source") {
		t.Fatalf("detail should call out required gateway token source: %s", c.Detail)
	}
}

// Net-zero with hidden overbill: +10 in one pair, -10 in another → Net
// = 0 but positive-overbill = 10. Must fail. This is the CRITICAL the
// R1 audit caught.
func TestCheckI1_NetZeroButHiddenOverbill_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		NetGatewayMinusHarnessTokens:   0,  // cancels to zero
		GatewayOverbillVsHarnessTokens: 10, // but one pair really overbilled
		OverbilledPairs:                []string{"hidden"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("net-zero must not hide per-pair overbill — this is the headline #229 R1 CRITICAL")
	}
}

func TestCheckI2_FailsWhen5xxHasNoGatewaySettlementRow(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 502, RequestID: "req-5xx"}}
	ledger := &reconcile.Result{GatewaySettlementRequestIDs: []string{"other-req"}}

	c := checkI2(results, ledger)

	if c.Passed || c.Skipped {
		t.Fatalf("I2 should fail missing 5xx settlement row: %+v", c)
	}
	if !contains(c.OffendingIDs, "req-5xx") {
		t.Fatalf("offending IDs=%v want req-5xx", c.OffendingIDs)
	}
}

func TestCheckI2_FailsWhen5xxSettlementBelongsToForeignAccount(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 502, RequestID: "req-5xx"}}
	ledger := &reconcile.Result{
		GatewayHasAccountID: true,
		HarnessAccountID:    "acct-harness",
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			AccountID: "acct-foreign",
			RequestID: "req-5xx",
		}},
	}

	c := checkI2(results, ledger)

	if c.Passed || c.Skipped {
		t.Fatalf("I2 should fail foreign-account 5xx settlement row: %+v", c)
	}
	if !contains(c.OffendingIDs, "req-5xx") {
		t.Fatalf("offending IDs=%v want req-5xx", c.OffendingIDs)
	}
}

func TestCheckI2_PassesNoProviderOnlyWhenZeroTokenRefunded(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-5xx"}}
	ledger := &reconcile.Result{
		GatewayHasAccountID: true,
		HarnessAccountID:    "acct-harness",
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			AccountID:         "acct-harness",
			RequestID:         "req-5xx",
			Outcome:           "no_provider_available",
			TotalTokens:       0,
			ReservationStatus: "refunded",
		}},
	}

	c := checkI2(results, ledger)

	if !c.Passed || c.Skipped {
		t.Fatalf("I2 should pass zero-token refunded no-provider evidence: %+v", c)
	}
}

func TestCheckI2_FailsNoProviderEvidenceWhenNotRefunded(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-5xx"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-5xx",
			Outcome:           "no_provider_available",
			TotalTokens:       0,
			ReservationStatus: "active",
		}},
	}

	c := checkI2(results, ledger)

	if c.Passed || c.Skipped {
		t.Fatalf("I2 should fail active no-provider reservation evidence: %+v", c)
	}
	if !contains(c.OffendingIDs, "req-5xx") {
		t.Fatalf("offending IDs=%v want req-5xx", c.OffendingIDs)
	}
}

func TestCheckI2_PassesTier2OnlyWhenZeroTokenRefunded(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-tier2"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-tier2",
			Outcome:           "tier2_hash_verified_required",
			TotalTokens:       0,
			ReservationStatus: "refunded",
		}},
	}

	c := checkI2(results, ledger)

	if !c.Passed || c.Skipped {
		t.Fatalf("I2 should pass zero-token refunded tier2 evidence: %+v", c)
	}
}

func TestCheckI2_FailsTier2EvidenceWhenChargedOrActive(t *testing.T) {
	cases := []struct {
		name              string
		totalTokens       int64
		reservationStatus string
	}{
		{name: "nonzero_tokens", totalTokens: 1, reservationStatus: "refunded"},
		{name: "active_reservation", totalTokens: 0, reservationStatus: "active"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-tier2"}}
			ledger := &reconcile.Result{
				GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
					RequestID:         "req-tier2",
					Outcome:           "tier2_hash_verified_required",
					TotalTokens:       tc.totalTokens,
					ReservationStatus: tc.reservationStatus,
				}},
			}

			c := checkI2(results, ledger)

			if c.Passed || c.Skipped {
				t.Fatalf("I2 should fail invalid tier2 evidence: %+v", c)
			}
			if !contains(c.OffendingIDs, "req-tier2") {
				t.Fatalf("offending IDs=%v want req-tier2", c.OffendingIDs)
			}
		})
	}
}

func TestCheckI2_PassesGenericZeroToken5xxAuditOnlyWhenRefunded(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-upstream"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-upstream",
			Outcome:           "upstream_error",
			TotalTokens:       0,
			ReservationStatus: "refunded",
		}},
	}

	c := checkI2(results, ledger)

	if !c.Passed || c.Skipped {
		t.Fatalf("I2 should pass zero-token refunded generic 5xx audit evidence: %+v", c)
	}
}

func TestCheckI2_FailsGenericZeroToken5xxAuditWhenNotRefunded(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-upstream"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-upstream",
			Outcome:           "upstream_error",
			TotalTokens:       0,
			ReservationStatus: "active",
		}},
	}

	c := checkI2(results, ledger)

	if c.Passed || c.Skipped {
		t.Fatalf("I2 should fail zero-token active generic 5xx audit evidence: %+v", c)
	}
	if !contains(c.OffendingIDs, "req-upstream") {
		t.Fatalf("offending IDs=%v want req-upstream", c.OffendingIDs)
	}
}

func TestCheckI2_FailsGeneric5xxAuditWithNonzeroTokens(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 503, RequestID: "req-upstream"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-upstream",
			Outcome:           "upstream_error",
			TotalTokens:       7,
			ReservationStatus: "active",
		}},
	}

	c := checkI2(results, ledger)

	if c.Passed || c.Skipped {
		t.Fatalf("I2 should fail generic 5xx settlement evidence with active reservation: %+v", c)
	}
	if !contains(c.OffendingIDs, "req-upstream") {
		t.Fatalf("offending IDs=%v want req-upstream", c.OffendingIDs)
	}
}

func TestCheckI2_PassesGeneric5xxSettlementWithNonzeroTokens(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 502, RequestID: "req-upstream"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-upstream",
			Outcome:           "upstream_error",
			TotalTokens:       7,
			ReservationStatus: "settled",
		}},
	}

	c := checkI2(results, ledger)

	if !c.Passed || c.Skipped {
		t.Fatalf("I2 should pass prompt-billed generic 5xx settlement evidence: %+v", c)
	}
}

func TestCheckI2_PassesValidAuditEvidenceWithout5xx(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 400, RequestID: "req-tier2-400"}}
	ledger := &reconcile.Result{
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			RequestID:         "req-tier2-400",
			Outcome:           "tier2_hard_pin_predicate_failed",
			TotalTokens:       0,
			ReservationStatus: "refunded",
		}},
	}

	c := checkI2(results, ledger)

	if !c.Passed || c.Skipped {
		t.Fatalf("I2 should pass valid refunded audit evidence without 5xx responses: %+v", c)
	}
}

func TestCheckI2_FailsInvalidAuditEvidenceWithout5xx(t *testing.T) {
	cases := []struct {
		name              string
		requestID         string
		outcome           string
		totalTokens       int64
		reservationStatus string
	}{
		{
			name:              "tier2_400_active",
			requestID:         "req-tier2-400",
			outcome:           "tier2_hard_pin_predicate_failed",
			totalTokens:       0,
			reservationStatus: "active",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			results := []buyer.Result{{HTTPStatus: 400, RequestID: tc.requestID}}
			ledger := &reconcile.Result{
				GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
					RequestID:         tc.requestID,
					Outcome:           tc.outcome,
					TotalTokens:       tc.totalTokens,
					ReservationStatus: tc.reservationStatus,
				}},
			}

			c := checkI2(results, ledger)

			if c.Passed || c.Skipped {
				t.Fatalf("I2 should fail invalid audit evidence without 5xx responses: %+v", c)
			}
			if !contains(c.OffendingIDs, tc.requestID) {
				t.Fatalf("offending IDs=%v want %s", c.OffendingIDs, tc.requestID)
			}
		})
	}
}

func TestCheckI2_IgnoresUnownedInvalidAuditEvidenceWithout5xx(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 200, RequestID: "owned-ok"}}
	ledger := &reconcile.Result{
		GatewayHasAccountID: true,
		HarnessAccountID:    "acct-harness",
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{
			{
				AccountID:         "acct-harness",
				RequestID:         "owned-ok",
				Outcome:           "ok",
				TotalTokens:       7,
				ReservationStatus: "settled",
			},
			{
				AccountID:         "acct-other",
				RequestID:         "other-tier2-400",
				Outcome:           "tier2_hard_pin_predicate_failed",
				TotalTokens:       0,
				ReservationStatus: "active",
			},
		},
	}

	c := checkI2(results, ledger)

	if !c.Passed || c.Skipped {
		t.Fatalf("I2 should ignore unowned invalid audit evidence in live window: %+v", c)
	}
}

func TestCheckI2_PassesWhen5xxSettlementMatchesHarnessAccount(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 502, RequestID: "req-5xx"}}
	ledger := &reconcile.Result{
		GatewayHasAccountID: true,
		HarnessAccountID:    "acct-harness",
		GatewaySettlementRequests: []reconcile.SettlementRequestIdentity{{
			AccountID: "acct-harness",
			RequestID: "req-5xx",
		}},
	}

	c := checkI2(results, ledger)

	if !c.Passed {
		t.Fatalf("I2 should pass account-scoped 5xx settlement row: %+v", c)
	}
}

func TestCheckI3_FailsWhenGatewayOverbillExceedsTolerance(t *testing.T) {
	sc := &scenario.Scenario{ChargedDeliveredToleranceTokens: 2}
	ledger := &reconcile.Result{
		GatewayOverbillVsHarnessTokens: 3,
		OverbilledPairs:                []string{"overbilled-req"},
	}

	c := checkI3(sc, ledger)

	if c.Passed || c.Skipped {
		t.Fatalf("I3 should fail overbill above tolerance: %+v", c)
	}
	if !contains(c.OffendingIDs, "overbilled-req") {
		t.Fatalf("offending IDs=%v want overbilled-req", c.OffendingIDs)
	}
}

func TestCheckI3_AllowsConfiguredTolerance(t *testing.T) {
	sc := &scenario.Scenario{ChargedDeliveredToleranceTokens: 3}
	ledger := &reconcile.Result{GatewayOverbillVsHarnessTokens: 3}

	c := checkI3(sc, ledger)

	if !c.Passed {
		t.Fatalf("I3 should pass at tolerance: %+v", c)
	}
}

func TestCheckI2_FailsClosedWhen5xxHasNoLedger(t *testing.T) {
	results := []buyer.Result{{HTTPStatus: 502, RequestID: "req-5xx"}}

	c := checkI2(results, nil)

	if c.Passed || c.Skipped {
		t.Fatalf("I2 should fail closed without settlement DB evidence: %+v", c)
	}
	if !contains(c.OffendingIDs, "req-5xx") {
		t.Fatalf("offending IDs=%v want req-5xx", c.OffendingIDs)
	}
}

// TestCheckI1_ReconcileError_Fails is the R3 audit code HIGH
// regression: when reconcile.Run errored, the harness sets
// ReconcileError. I1 must hard-fail on that signal independently of
// the drift counters, otherwise a snapshot-failure run with zero
// successes (and zero per-pair signals) would pass green.
func TestCheckI1_ReconcileError_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		ReconcileError: "coordinator query: no such column: account_id",
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("reconcile error must fail I1 closed")
	}
	if c.Skipped {
		t.Fatal("reconcile error must FAIL, not SKIP — fail-closed money-path gate")
	}
	if !strings.Contains(c.Detail, "reconcile errored") {
		t.Errorf("detail should call out reconcile error: %s", c.Detail)
	}
}

// TestCheckI1_AmbiguousExactGatewayIDs_Fails is the R2 audit HIGH
// regression: ambiguous exact-id MUST fail I1, not silently fall to
// fuzzy. Even one ambiguous id is hard evidence of cross-account PK
// collision or duplicate settlement.
func TestCheckI1_AmbiguousExactGatewayIDs_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		AmbiguousExactGatewayIDs: []string{"AMBIG_GW"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("ambiguous exact-id must fail I1")
	}
	if !contains(c.OffendingIDs, "AMBIG_GW") {
		t.Errorf("offending ids should include ambiguous id, got %v", c.OffendingIDs)
	}
	if !strings.Contains(c.Detail, "ambiguities") {
		t.Errorf("detail should call out ambiguity, got: %s", c.Detail)
	}
}

func TestCheckI1_AmbiguousExactCoordIDs_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		AmbiguousExactCoordIDs: []string{"AMBIG_COORD"},
	}
	c := checkI1(nil, ledger)
	if c.Passed {
		t.Fatal("ambiguous coord exact-id must fail I1")
	}
	if !contains(c.OffendingIDs, "AMBIG_COORD") {
		t.Errorf("offending should include ambiguous coord id, got %v", c.OffendingIDs)
	}
}

func contains(s []string, want string) bool {
	for _, v := range s {
		if v == want {
			return true
		}
	}
	return false
}
