package router

import "testing"

// #1816 freeze R1 SECURITY H6: a pool-provenance attempt is pinned to the
// coordinator's route_snapshot_v2 policy version; the gateway settles it
// exactly like v1 and still holds an unknown version.
func TestSettlementFinalityAcceptsRouteSnapshotV2(t *testing.T) {
	for _, version := range []string{settlementPolicyVersion, settlementPolicyVersionV2} {
		h := settlementFinalityTrailerForTest("enforce", version, "verified", "valid", "true", "receipt_verified")
		if got := coordinatorSettlementFinalityFromHeaders(h); got.Action != settlementFinalityDebit {
			t.Fatalf("policy %q: action=%v reason=%q, want debit", version, got.Action, got.Reason)
		}
	}
	h := settlementFinalityTrailerForTest("enforce", "spec022-route-snapshot-v9", "verified", "valid", "true", "receipt_verified")
	if got := coordinatorSettlementFinalityFromHeaders(h); got.Action != settlementFinalityHold || got.Reason != "invalid_settlement_policy_version" {
		t.Fatalf("unknown policy: action=%v reason=%q, want hold", got.Action, got.Reason)
	}
}
