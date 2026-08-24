package trustpool_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestRefreshRegistryClosesExpiredCreatorGateAtSameRevision(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	root := newRootFixture(t)
	graceEndsAt := time.Now().Add(30 * time.Second).UTC()
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", graceEndsAt, trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		ev("op-create", testAdminTS(0), trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", time.Now().Add(time.Hour)), root),
		signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root),
		ev("op-member", testAdminTS(3), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", testAdminTS(4), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", testAdminTS(5), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
	}
	for _, e := range events {
		if e.EventType == trustpool.EventLifecycleChanged && e.Lifecycle == trustpool.LifecycleActive {
			insertPromotedEvent(t, ctx, db, e)
			continue
		}
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}

	initial, err := trustpool.RefreshRegistry(ctx, store, registry)
	if err != nil {
		t.Fatalf("initial RefreshRegistry: %v", err)
	}
	if !initial.Changed || initial.NextRefreshAtUTC.IsZero() {
		t.Fatalf("initial refresh = %+v, want changed with next deadline", initial)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Routeable || !snap.Members["provider-a"] {
		t.Fatalf("pre-expiry snapshot = %+v, want routeable provider-a", snap)
	}
	initialGeneration := snap.Generation

	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(-time.Second), trustpool.CreatorStatusEnabled)
	expired, err := trustpool.RefreshRegistry(ctx, store, registry)
	if err != nil {
		t.Fatalf("expired RefreshRegistry: %v", err)
	}
	if !expired.Changed {
		t.Fatalf("expired refresh = %+v, want changed", expired)
	}
	snap = registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || !snap.RouteableExpired || len(snap.Members) != 0 || snap.Generation <= initialGeneration {
		t.Fatalf("post-expiry snapshot = %+v, want expired closed with generation > %d", snap, initialGeneration)
	}
	if expired.NextRefreshAtUTC != (time.Time{}) {
		t.Fatalf("expired refresh next deadline = %s, want none", expired.NextRefreshAtUTC)
	}
}

func TestRefreshRegistryClearsRouteableSnapshotsOnMalformedDurableState(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	registry := trustpool.NewRegistry()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	events := []trustpool.DurableEvent{
		ev("op-create", testAdminTS(0), trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", testAdminTS(1), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", time.Now().Add(time.Hour)), root),
		signedManifest(t, "op-manifest", testAdminTS(2), root.poolID, 1, root),
		ev("op-member", testAdminTS(3), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", testAdminTS(4), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", testAdminTS(5), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
	}
	for _, e := range events {
		if e.EventType == trustpool.EventLifecycleChanged && e.Lifecycle == trustpool.LifecycleActive {
			insertPromotedEvent(t, ctx, db, e)
			continue
		}
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}

	if _, err := trustpool.RefreshRegistry(ctx, store, registry); err != nil {
		t.Fatalf("initial RefreshRegistry: %v", err)
	}
	if snap := registry.Snapshot(root.poolID); !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] || !registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatalf("initial snapshot = %+v buyer_auth=%v, want routeable provider-a/acct-a", snap, registry.BuyerAuthorized(root.poolID, "acct-a"))
	}
	if _, err := db.ExecContext(ctx, `UPDATE trustpool_manifest_acceptances SET manifest_core_digest = ? WHERE pool_id = ? AND manifest_version = ?`, strings.Repeat("a", 64), root.poolID, uint64(1)); err != nil {
		t.Fatalf("tamper manifest acceptance projection: %v", err)
	}

	if _, err := trustpool.RefreshRegistry(ctx, store, registry); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("tampered RefreshRegistry err=%v, want ErrMalformedDurableEvent", err)
	}
	if snap := registry.Snapshot(root.poolID); snap.Exists || snap.Routeable || len(snap.Members) != 0 || registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatalf("disabled snapshot = %+v buyer_auth=%v, want fail-closed empty", snap, registry.BuyerAuthorized(root.poolID, "acct-a"))
	}
}

func TestRefreshLoopNormalizesScheduleBounds(t *testing.T) {
	t.Parallel()
	if got := trustpool.DefaultRefreshInterval; got != 30*time.Second {
		t.Fatalf("DefaultRefreshInterval = %s, want 30s", got)
	}
	if got := trustpool.MaxRefreshInterval; got != time.Minute {
		t.Fatalf("MaxRefreshInterval = %s, want 60s", got)
	}
}
