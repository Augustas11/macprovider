package trustpool_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestProviderPoolDelegationRejectsSupersededGrantWithoutRevoke(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	_, ownerPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	ownerPub := ownerPriv.Public().(ed25519.PublicKey)
	store, err := trustpool.NewStore(openTrustPoolDB(t), trustpool.WithProviderOwnerPublicKeys(map[string][]byte{
		"provider-b": ownerPub,
	}))
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
	firstGrant := creatorMVPDelegationGrantedEvent(t, ownerPriv, root.poolID, "creator-a", manifestDigest, "candidate", "provider-b", "del-b-1", "deleg-op-grant-1")
	firstGrant.OperationID = "op-delegation-grant-1"
	firstGrant.TimestampUTC = ts.Add(3 * time.Second)
	if _, _, _, err := store.AppendValidatedEvent(ctx, firstGrant); err != nil {
		t.Fatalf("first grant: %v", err)
	}

	secondGrant := creatorMVPDelegationGrantedEvent(t, ownerPriv, root.poolID, "creator-a", manifestDigest, "candidate", "provider-b", "del-b-2", "deleg-op-grant-2")
	secondGrant.OperationID = "op-delegation-grant-2"
	secondGrant.TimestampUTC = ts.Add(4 * time.Second)
	if _, _, _, err := store.AppendValidatedEvent(ctx, secondGrant); err == nil {
		t.Fatal("second grant without revoking first, want error")
	}

	admitOld := ev("op-member-b-old", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-b"
		e.DelegationID = "del-b-1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, admitOld); err != nil {
		t.Fatalf("admit with active delegation: %v", err)
	}

	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || !pool.Members["provider-b"] {
		t.Fatalf("pool after admit = %+v, want provider-b member", pool)
	}
}

func TestProviderPoolDelegationGrantFailsClosedWithoutOwnerKeyRegistry(t *testing.T) {
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

	_, ownerPriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	grant := creatorMVPDelegationGrantedEvent(t, ownerPriv, root.poolID, "creator-a", events[len(events)-1].ManifestCoreDigest, "candidate", "provider-b", "del-b-1", "deleg-op-grant")
	grant.OperationID = "op-delegation-grant"
	grant.TimestampUTC = ts.Add(3 * time.Second)
	if _, _, _, err := store.AppendValidatedEvent(ctx, grant); err == nil {
		t.Fatal("grant without owner key registry, want error")
	}
}
