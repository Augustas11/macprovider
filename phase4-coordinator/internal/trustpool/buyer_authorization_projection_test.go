package trustpool

import (
	"reflect"
	"testing"
)

// SPEC-043-R007 (#1690 BUG-3 audit r1): the gateway projection carries only
// routeable pools. A creator-agreement-expired pool and a candidate-blocked
// pool (with or without the expired bit) are omitted, so the gateway refuses
// them on the same local floored path as unknown and unauthorized pools.
func TestBuyerAuthorizationsOmitEveryNonRouteablePool(t *testing.T) {
	r := NewRegistry()
	r.RejectCandidateLaunchEnvironment()
	if err := r.LoadRouteableSnapshotsAtRevision(3, []RouteableSnapshot{
		{PoolID: "routeablexxxxxxxxxxxxx", BuyerAccounts: []string{"acct"}, SettlementMode: "observe", Routeable: true, Generation: 1},
		{PoolID: "expiredxxxxxxxxxxxxxxx", BuyerAccounts: []string{"acct"}, SettlementMode: "observe", RouteableExpired: true, Generation: 1},
		{PoolID: "candidatexxxxxxxxxxxxx", BuyerAccounts: []string{"acct"}, SettlementMode: "observe", Routeable: true, LaunchEnvironment: "candidate", Generation: 1},
		{PoolID: "candexpiredxxxxxxxxxxx", BuyerAccounts: []string{"acct"}, SettlementMode: "observe", RouteableExpired: true, LaunchEnvironment: "candidate", Generation: 1},
		{PoolID: "pausedxxxxxxxxxxxxxxxx", BuyerAccounts: []string{"acct"}, SettlementMode: "observe", Generation: 1},
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshotsAtRevision: %v", err)
	}
	accounts, _ := r.BuyerAuthorizations()
	if want := map[string][]string{"acct": {"routeablexxxxxxxxxxxxx"}}; !reflect.DeepEqual(accounts, want) {
		t.Fatalf("BuyerAuthorizations=%v, want %v", accounts, want)
	}
	if got, want := r.RouteablePoolIDs(), []string{"routeablexxxxxxxxxxxxx"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("RouteablePoolIDs=%v, want %v", got, want)
	}
}
