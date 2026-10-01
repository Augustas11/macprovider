package buyer

import (
	"context"
	"testing"
)

// #1816 VM acceptance A-8: a durable-replay failure that is not malformed
// state (a timeout while the single SQLite connection is busy) fails that
// request closed but must not empty the routing registry: Disable kept the
// revision, so every later pool request answered pool_unavailable until the
// next registry refresh, and that reload re-kicked the binding sweep.
func TestAuthorizeTrustPoolTransientReplayErrorKeepsRegistry(t *testing.T) {
	s, _, tp := poolIsolationServer(t)
	tp.AddMember("P", "member-x")
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, _, err := s.authorizeTrustPoolFromDurableState(ctx, "P", "acct-buyer"); err == nil {
		t.Fatal("replay with a cancelled context succeeded")
	}
	if snap := tp.Snapshot("P"); !snap.Exists || !snap.Members["member-x"] {
		t.Fatalf("a transient replay error emptied the trusted-pool registry: %+v", snap)
	}
}
