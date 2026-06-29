// Tests for I1's consumption of the reconciler's per-pair drift signals
// (#229 R4 audit MEDIUM). The reconciler-layer tests in
// internal/reconcile/ verify that the drift fields are computed
// correctly; these tests verify that I1 INTERPRETS them correctly,
// catching every failure mode and PASSing on a clean run.
package invariants

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-network-harness/internal/reconcile"
)

func TestCheckI1_CleanRun_AllSignalsZero(t *testing.T) {
	ledger := &reconcile.Result{
		HarnessSuccessful:  10,
		GatewayRowsOK:      10,
		CoordinatorRows2xx: 10,
		MatchedSuccesses:   []reconcile.MatchedPair{{}, {}, {}, {}, {}, {}, {}, {}, {}, {}},
	}
	c := checkI1(ledger)
	if !c.Passed {
		t.Fatalf("clean run should pass, got fail: %s", c.Detail)
	}
	if !strings.Contains(c.Detail, "per_matched_pair_v2") {
		t.Errorf("pass detail should advertise drift basis: %s", c.Detail)
	}
}

func TestCheckI1_NoReconcile_Skips(t *testing.T) {
	c := checkI1(nil)
	if !c.Skipped {
		t.Errorf("nil ledger should SKIP, got: %s", c.Detail)
	}
}

func TestCheckI1_UnmatchedHarnessSuccess_Fails(t *testing.T) {
	ledger := &reconcile.Result{
		UnmatchedSuccesses: []string{"h1", "h2"},
	}
	c := checkI1(ledger)
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
	c := checkI1(ledger)
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
	c := checkI1(ledger)
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
	c := checkI1(ledger)
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
	c := checkI1(ledger)
	if c.Passed {
		t.Fatal("should fail on gateway-vs-harness overbill")
	}
	if !contains(c.OffendingIDs, "OVERBILLED") {
		t.Errorf("offending should include overbilled pair: %v", c.OffendingIDs)
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
	c := checkI1(ledger)
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
		HarnessSuccessful:                10,
		GatewayRowsOK:                    10,
		CoordinatorRows2xx:               10,
		MatchedSuccesses:                 []reconcile.MatchedPair{{}, {}, {}, {}, {}, {}, {}, {}, {}, {}},
		NetGatewayMinusHarnessTokens:     -5, // underbill only
		GatewayOverbillVsHarnessTokens:   0,
	}
	c := checkI1(ledger)
	if !c.Passed {
		t.Errorf("underbill alone should not fail I1: %s", c.Detail)
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
	c := checkI1(ledger)
	if c.Passed {
		t.Fatal("net-zero must not hide per-pair overbill — this is the headline #229 R1 CRITICAL")
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
	c := checkI1(ledger)
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
	c := checkI1(ledger)
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
	c := checkI1(ledger)
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
