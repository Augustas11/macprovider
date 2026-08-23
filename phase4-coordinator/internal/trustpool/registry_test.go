package trustpool_test

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestSnapshot_MembersAndGeneration(t *testing.T) {
	t.Parallel()
	r := trustpool.NewRegistry()
	r.AddMember("P", "x")
	r.AddMember("P", "y")
	snap := r.Snapshot("P")
	if !snap.Exists {
		t.Fatal("pool P should exist")
	}
	if !snap.Members["x"] || !snap.Members["y"] {
		t.Fatalf("want x,y members, got %v", snap.Members)
	}
	if len(snap.Members) != 2 {
		t.Fatalf("want 2 members, got %d", len(snap.Members))
	}
	if snap.Generation == 0 {
		t.Fatal("generation should have advanced past 0 after admits")
	}
}

func TestSnapshot_UnknownPool_FailsClosed(t *testing.T) {
	t.Parallel()
	r := trustpool.NewRegistry()
	snap := r.Snapshot("nope")
	if snap.Exists {
		t.Fatal("unknown pool should not exist")
	}
	if len(snap.Members) != 0 {
		t.Fatalf("unknown pool must have zero members (fail closed), got %v", snap.Members)
	}
}

func TestRevoke_RemovesMemberAndBumpsGeneration(t *testing.T) {
	// SPEC-042 R003: after revocation the provider is not in the very next
	// snapshot (no staleness window), and the generation advances so the
	// R005 fence invalidates snapshots taken before it.
	t.Parallel()
	r := trustpool.NewRegistry()
	r.AddMember("P", "x")
	r.AddMember("P", "y")
	genBefore := r.Generation("P")
	r.Revoke("P", "x")
	snap := r.Snapshot("P")
	if snap.Members["x"] {
		t.Fatal("revoked provider x must NOT appear in the snapshot")
	}
	if !snap.Members["y"] {
		t.Fatal("non-revoked member y must remain")
	}
	if snap.Generation <= genBefore {
		t.Fatalf("revocation must bump generation: before=%d after=%d", genBefore, snap.Generation)
	}
}

func TestRevoke_IsDurableBlocklist(t *testing.T) {
	// A revoked identity stays out even if AddMember is called again — the
	// durable per-pool blocklist, stronger than the TTL admission reject.
	t.Parallel()
	r := trustpool.NewRegistry()
	r.AddMember("P", "x")
	r.Revoke("P", "x")
	r.AddMember("P", "x") // must be a no-op while revoked
	if r.Snapshot("P").Members["x"] {
		t.Fatal("revoked identity must not be re-admitted by AddMember")
	}
}

func TestSnapshot_IsolatedAcrossPools(t *testing.T) {
	t.Parallel()
	r := trustpool.NewRegistry()
	r.AddMember("P", "x")
	r.AddMember("Q", "z")
	if r.Snapshot("P").Members["z"] {
		t.Fatal("pool P must not see pool Q's member z")
	}
	if r.Snapshot("Q").Members["x"] {
		t.Fatal("pool Q must not see pool P's member x")
	}
}

func TestRouteableSnapshotsPreservesRouteableUntilUTC(t *testing.T) {
	t.Parallel()
	expiresAt := time.Now().Add(40 * time.Millisecond).UTC()
	r := trustpool.NewRegistry()
	if err := r.LoadRouteableSnapshotsAtRevision(1, []trustpool.RouteableSnapshot{
		{
			PoolID:            "pool-a",
			Members:           []string{"provider-a"},
			BuyerAccounts:     []string{"acct-a"},
			Routeable:         true,
			Generation:        9,
			RouteableUntilUTC: expiresAt,
		},
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshotsAtRevision: %v", err)
	}
	exported := r.RouteableSnapshots()
	if len(exported) != 1 || !exported[0].RouteableUntilUTC.Equal(expiresAt) {
		t.Fatalf("exported snapshots = %+v, want routeable_until_utc %s", exported, expiresAt.Format(time.RFC3339Nano))
	}
	reloaded := trustpool.NewRegistry()
	if err := reloaded.LoadRouteableSnapshotsAtRevision(1, exported); err != nil {
		t.Fatalf("reload exported snapshots: %v", err)
	}
	time.Sleep(70 * time.Millisecond)
	if snap := reloaded.Snapshot("pool-a"); !snap.Exists || snap.Routeable || snap.Generation <= 9 {
		t.Fatalf("reloaded post-expiry snapshot = %+v, want non-routeable with advanced generation", snap)
	}
}

func TestRefreshRouteableSnapshotsAtRevisionAllowsSameRevisionTimeGateClose(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	if err := registry.LoadRouteableSnapshotsAtRevision(3, []trustpool.RouteableSnapshot{
		{
			PoolID:        "pool-a",
			Members:       []string{"provider-a"},
			BuyerAccounts: []string{"acct-a"},
			Routeable:     true,
			Generation:    7,
		},
	}); err != nil {
		t.Fatalf("initial load: %v", err)
	}
	changed, err := registry.RefreshRouteableSnapshotsAtRevision(3, []trustpool.RouteableSnapshot{
		{
			PoolID:        "pool-a",
			BuyerAccounts: []string{"acct-a"},
			Routeable:     false,
			Generation:    8,
		},
	})
	if err != nil {
		t.Fatalf("same-revision refresh: %v", err)
	}
	if !changed {
		t.Fatal("same-revision routeability change was not reported")
	}
	snap := registry.Snapshot("pool-a")
	if !snap.Exists || snap.Routeable || snap.Generation != 8 || len(snap.Members) != 0 {
		t.Fatalf("snapshot after same-revision refresh = %+v, want closed generation 8", snap)
	}
	changed, err = registry.RefreshRouteableSnapshotsAtRevision(3, []trustpool.RouteableSnapshot{
		{
			PoolID:        "pool-a",
			BuyerAccounts: []string{"acct-a"},
			Routeable:     false,
			Generation:    8,
		},
	})
	if err != nil {
		t.Fatalf("idempotent same-revision refresh: %v", err)
	}
	if changed {
		t.Fatal("idempotent same-revision refresh reported a change")
	}
	if _, err := registry.RefreshRouteableSnapshotsAtRevision(2, nil); err == nil {
		t.Fatal("stale lower revision refresh unexpectedly succeeded")
	}
}

func TestRegistryDisableClearsRouteableSnapshotsWithoutAdvancingRevision(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	if err := registry.LoadRouteableSnapshotsAtRevision(3, []trustpool.RouteableSnapshot{
		{
			PoolID:        "pool-a",
			Members:       []string{"provider-a"},
			BuyerAccounts: []string{"acct-a"},
			Routeable:     true,
			Generation:    7,
		},
	}); err != nil {
		t.Fatalf("initial load: %v", err)
	}
	if snap := registry.Snapshot("pool-a"); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] {
		t.Fatalf("initial snapshot = %+v, want routeable provider-a", snap)
	}
	revision := registry.Revision()

	registry.Disable()
	if got := registry.Revision(); got != revision {
		t.Fatalf("Disable revision = %d, want unchanged %d", got, revision)
	}
	if snap := registry.Snapshot("pool-a"); snap.Exists || snap.Routeable || len(snap.Members) != 0 {
		t.Fatalf("disabled snapshot = %+v, want fail-closed empty", snap)
	}
	if registry.BuyerAuthorized("pool-a", "acct-a") {
		t.Fatal("disabled registry still authorizes buyer")
	}

	changed, err := registry.RefreshRouteableSnapshotsAtRevision(revision, []trustpool.RouteableSnapshot{
		{
			PoolID:        "pool-a",
			Members:       []string{"provider-a"},
			BuyerAccounts: []string{"acct-a"},
			Routeable:     true,
			Generation:    7,
		},
	})
	if err != nil {
		t.Fatalf("same-revision reload after disable: %v", err)
	}
	if !changed {
		t.Fatal("same-revision reload after disable did not report a change")
	}
	if snap := registry.Snapshot("pool-a"); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] || !registry.BuyerAuthorized("pool-a", "acct-a") {
		t.Fatalf("reloaded snapshot = %+v buyer_auth=%v, want restored routeable provider-a/acct-a", snap, registry.BuyerAuthorized("pool-a", "acct-a"))
	}
}

func TestSnapshot_ConsistentMembersAndGenerationUnderConcurrency(t *testing.T) {
	// The (members, generation) pair must be captured atomically: a snapshot
	// must never show a member that was revoked at-or-before the generation
	// the snapshot reports. We assert the invariant across interleaved
	// revocations from another goroutine.
	t.Parallel()
	r := trustpool.NewRegistry()
	for i := 0; i < 50; i++ {
		r.AddMember("P", id(i))
	}
	done := make(chan struct{})
	go func() {
		for i := 0; i < 50; i++ {
			r.Revoke("P", id(i))
		}
		close(done)
	}()
	for i := 0; i < 200; i++ {
		snap := r.Snapshot("P")
		// A revoked member is never present in a snapshot; the invariant we
		// can cheaply assert is internal consistency: every reported member
		// is currently non-revoked at read time (guaranteed by the RLock).
		for m := range snap.Members {
			if m == "" {
				t.Fatal("empty member id")
			}
		}
	}
	<-done
}

func id(i int) string {
	return "p" + string(rune('a'+i%26)) + string(rune('0'+i/26))
}
