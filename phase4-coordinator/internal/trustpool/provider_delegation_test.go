package trustpool_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestProviderPoolDelegationGrantAndRevokeReplay(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	root := newRootFixture(t)
	ts := testAdminTS(0)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)

	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(24*time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
	}
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("append %s: %v", e.OperationID, err)
		}
	}

	manifestDigest := events[len(events)-1].ManifestCoreDigest
	_, ownerPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	grant := creatorMVPDelegationGrantedEvent(t, ownerPriv, root.poolID, "creator-a", manifestDigest, "candidate", "provider-b", "del-b-1", "deleg-op-grant")
	grant.OperationID = "op-delegation-grant"
	grant.TimestampUTC = ts.Add(3 * time.Second)
	if _, _, _, err := store.AppendValidatedEvent(ctx, grant); err != nil {
		t.Fatalf("grant: %v", err)
	}
	admit := ev("op-member-b", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-b"
		e.DelegationID = "del-b-1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, admit); err != nil {
		t.Fatalf("admit: %v", err)
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || !pool.Members["provider-b"] {
		t.Fatalf("pool after admit = %+v, want provider-b member", pool)
	}

	revoke := creatorMVPDelegationRevokedEvent(t, ownerPriv, root.poolID, "creator-a", manifestDigest, "candidate", "provider-b", "del-b-1", "deleg-op-revoke")
	revoke.OperationID = "op-delegation-revoke"
	revoke.TimestampUTC = ts.Add(5 * time.Second)
	if _, _, _, err := store.AppendValidatedEvent(ctx, revoke); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	state, err = store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct after revoke: %v", err)
	}
	pool = state.Pools[root.poolID]
	if pool == nil || pool.Members["provider-b"] {
		t.Fatalf("pool after revoke = %+v, want provider-b removed", pool)
	}
	snapshots := state.RouteableSnapshots()
	if len(snapshots) != 1 {
		t.Fatalf("snapshots=%d, want 1", len(snapshots))
	}
	for _, member := range snapshots[0].Members {
		if member == "provider-b" {
			t.Fatalf("routeable snapshot still includes provider-b: %#v", snapshots[0])
		}
	}
}
