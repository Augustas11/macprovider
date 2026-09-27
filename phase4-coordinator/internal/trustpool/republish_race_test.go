package trustpool_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// #1690 review MEDIUM (F-5 follow-up): an on-call readiness write
// republishes route gates at the revision it reconstructed. A concurrent
// publish of a newer revision (an admin event, the refresher) can land in
// between; that publish already carries the current gates, so the
// republish must succeed without disabling routing for every pool. The
// newer publish is placed in the registry directly, which is the state the
// race leaves behind.
func TestAdminHandler_OnCallRepublishLosingToNewerRevisionIsNotAFailure(t *testing.T) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	t.Setenv("MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256", trustpool.OnCallAuthorityKeySHA256(priv.Public().(ed25519.PublicKey)))
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	root := seedCandidatePoolViaAdmin(t, handler, store)
	state, err := store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if err := registry.LoadRouteableSnapshotsAtRevision(state.Revision+1, state.RouteableSnapshots()); err != nil {
		t.Fatalf("publish newer revision: %v", err)
	}
	signed, err := trustpool.SignOnCallReadiness(priv, validOnCallReadiness("op-oncall-behind", "launch-staging"))
	if err != nil {
		t.Fatalf("SignOnCallReadiness: %v", err)
	}
	postAdminOnCall(t, handler, "operator-secret", signed, http.StatusOK)
	if snap := registry.Snapshot(root.poolID); !snap.Exists {
		t.Fatal("on-call republish behind a newer revision disabled the registry")
	}
	if registry.Revision() != state.Revision+1 {
		t.Fatalf("registry revision=%d, want the newer %d kept", registry.Revision(), state.Revision+1)
	}
}

// The locked republish: an older revision is a no-op success, the current
// revision is a same-revision refresh, and a newer one publishes.
func TestRegistryRepublishRouteGatesAtRevision(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	snap := func(buyer string, gen uint64) []trustpool.RouteableSnapshot {
		return []trustpool.RouteableSnapshot{{PoolID: "pool-a", BuyerAccounts: []string{buyer}, SettlementMode: "observe", Routeable: true, Generation: gen}}
	}
	if err := registry.LoadRouteableSnapshotsAtRevision(3, snap("acct-3", 3)); err != nil {
		t.Fatalf("load: %v", err)
	}
	if err := registry.RepublishRouteGatesAtRevision(2, snap("acct-stale", 2)); err != nil {
		t.Fatalf("older revision: %v, want a no-op success", err)
	}
	if !registry.BuyerAuthorized("pool-a", "acct-3") || registry.BuyerAuthorized("pool-a", "acct-stale") || registry.Revision() != 3 {
		t.Fatal("older revision replaced the registry")
	}
	if err := registry.RepublishRouteGatesAtRevision(3, snap("acct-3b", 3)); err != nil || !registry.BuyerAuthorized("pool-a", "acct-3b") {
		t.Fatalf("same revision: err=%v, want the gate refresh applied", err)
	}
	if err := registry.RepublishRouteGatesAtRevision(4, snap("acct-4", 4)); err != nil || !registry.BuyerAuthorized("pool-a", "acct-4") || registry.Revision() != 4 {
		t.Fatalf("newer revision: err=%v, want it published", err)
	}
}
