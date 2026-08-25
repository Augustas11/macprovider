package trustpool_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	_ "modernc.org/sqlite"
)

func TestDurableStore_AppendValidatedEventRejectsRawActivation(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000500, 0).UTC()
	root := newRootFixture(t)
	prefix := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
	}
	for _, e := range prefix {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	active := ev("op-active", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
		e.Lifecycle = trustpool.LifecycleActive
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, active); !errors.Is(err, trustpool.ErrActivationRequiresPromotion) {
		t.Fatalf("raw activation append error = %v, want ErrActivationRequiresPromotion", err)
	}
	reconstructed, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if got := reconstructed.Pools[root.poolID].Lifecycle; got != trustpool.LifecycleCreated {
		t.Fatalf("lifecycle after rejected activation = %q, want created", got)
	}
}

func TestDurableStore_PromotePoolActivatesAfterPreflight(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000600, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	}
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}

	state, committed, applied, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID: "op-promote",
		PoolID:      root.poolID,
	})
	if err != nil {
		t.Fatalf("PromotePool: %v", err)
	}
	if !applied || committed.EventType != trustpool.EventLifecycleChanged || committed.Lifecycle != trustpool.LifecycleActive {
		t.Fatalf("promotion committed=%+v applied=%v, want new active event", committed, applied)
	}
	if got := state.Pools[root.poolID].Lifecycle; got != trustpool.LifecycleActive {
		t.Fatalf("lifecycle after promotion = %q, want active", got)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] {
		t.Fatalf("routeable snapshot after promotion = %+v, want provider-a routeable", snap)
	}
	if !registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatal("acct-a should remain authorized after promotion")
	}

	againState, againCommitted, againApplied, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID: "op-promote",
		PoolID:      root.poolID,
	})
	if err != nil {
		t.Fatalf("PromotePool idempotent retry: %v", err)
	}
	if againApplied {
		t.Fatal("idempotent promotion retry applied a second event")
	}
	if againCommitted.OperationID != committed.OperationID || againCommitted.TimestampUTC != committed.TimestampUTC {
		t.Fatalf("idempotent committed event = %+v, want original %+v", againCommitted, committed)
	}
	if againState.Revision != state.Revision {
		t.Fatalf("idempotent revision = %d, want unchanged %d", againState.Revision, state.Revision)
	}
}

func TestDurableStore_PromotePoolReactivatesPausedPoolAfterPreflight(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000650, 0).UTC()
	root := newRootFixture(t)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	)
	if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID:  "op-promote",
		TimestampUTC: ts.Add(5 * time.Second),
		PoolID:       root.poolID,
	}); err != nil {
		t.Fatalf("initial PromotePool: %v", err)
	}
	appendTrustPoolEvents(t, ctx, store,
		ev("op-pause", ts.Add(6*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecyclePaused
		}),
	)

	state, committed, applied, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID:  "op-resume",
		TimestampUTC: ts.Add(7 * time.Second),
		PoolID:       root.poolID,
		Reason:       "post-maintenance preflight passed",
	})
	if err != nil {
		t.Fatalf("reactivation PromotePool: %v", err)
	}
	if !applied || committed.OperationID != "op-resume" || committed.Lifecycle != trustpool.LifecycleActive {
		t.Fatalf("reactivation committed=%+v applied=%v, want active op-resume", committed, applied)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || pool.Lifecycle != trustpool.LifecycleActive || pool.LifecycleReason != "post-maintenance preflight passed" {
		t.Fatalf("reactivated pool = %+v, want active with reason", pool)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || !snap.Routeable || !snap.Members["provider-a"] {
		t.Fatalf("reactivated snapshot = %+v, want routeable provider-a", snap)
	}
	if !registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatal("acct-a should remain authorized after reactivation")
	}
}

func TestDurableStore_PromotePoolRejectsPausedPoolWhenPreflightRegresses(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000655, 0).UTC()
	root := newRootFixture(t)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	)
	if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID:  "op-promote",
		TimestampUTC: ts.Add(5 * time.Second),
		PoolID:       root.poolID,
	}); err != nil {
		t.Fatalf("initial PromotePool: %v", err)
	}
	appendTrustPoolEvents(t, ctx, store,
		ev("op-pause", ts.Add(6*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecyclePaused
		}),
		ev("op-remove-buyer", ts.Add(7*time.Second), trustpool.EventBuyerAuthorizationRm, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	)

	_, _, _, err = store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID:  "op-resume",
		TimestampUTC: ts.Add(8 * time.Second),
		PoolID:       root.poolID,
	})
	var precondition trustpool.PromotionPreconditionError
	if !errors.As(err, &precondition) {
		t.Fatalf("reactivation PromotePool err=%v, want PromotionPreconditionError", err)
	}
	if precondition.Reason != "buyer_authorization_missing" {
		t.Fatalf("precondition reason = %q, want buyer_authorization_missing", precondition.Reason)
	}
}

func TestDurableStore_RejectsMalformedMemberProviderID(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000610, 0).UTC()
	root := newRootFixture(t)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
	)

	for _, eventType := range []string{trustpool.EventMemberAdmitted, trustpool.EventMemberRevoked} {
		eventType := eventType
		t.Run(eventType, func(t *testing.T) {
			_, _, _, err := store.AppendValidatedEvent(ctx, ev("op-"+eventType, ts.Add(3*time.Second), eventType, root.poolID, func(e *trustpool.DurableEvent) {
				e.ProviderID = "bad/provider"
			}))
			if err == nil || !strings.Contains(err.Error(), `invalid provider_id "bad/provider"`) {
				t.Fatalf("AppendValidatedEvent err=%v, want invalid provider_id", err)
			}
		})
	}
}

func TestDurableStore_PersistsManifestAcceptanceProjection(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000620, 0).UTC()
	root := newRootFixture(t)
	manifest := signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		manifest,
	)

	var projectionOp, highWaterOp, projectionDigest, highWaterDigest string
	if err := db.QueryRowContext(ctx, `SELECT operation_id, manifest_core_digest FROM trustpool_manifest_acceptances WHERE pool_id = ? AND manifest_version = ?`, root.poolID, uint64(1)).Scan(&projectionOp, &projectionDigest); err != nil {
		t.Fatalf("query manifest acceptance projection: %v", err)
	}
	if err := db.QueryRowContext(ctx, `SELECT operation_id, manifest_core_digest FROM trustpool_manifest_acceptance_high_water WHERE pool_id = ?`, root.poolID).Scan(&highWaterOp, &highWaterDigest); err != nil {
		t.Fatalf("query manifest acceptance high-water: %v", err)
	}
	if projectionOp != manifest.OperationID || highWaterOp != manifest.OperationID || projectionDigest != manifest.ManifestCoreDigest || highWaterDigest != manifest.ManifestCoreDigest {
		t.Fatalf("projection op/digest=(%q,%q) high-water=(%q,%q), want manifest (%q,%q)", projectionOp, projectionDigest, highWaterOp, highWaterDigest, manifest.OperationID, manifest.ManifestCoreDigest)
	}
}

func TestDurableStore_ManifestAcceptanceProjectionTamperFailsClosed(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000621, 0).UTC()
	root := newRootFixture(t)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
	)
	if _, err := db.ExecContext(ctx, `UPDATE trustpool_manifest_acceptances SET manifest_core_digest = ? WHERE pool_id = ? AND manifest_version = ?`, strings.Repeat("a", 64), root.poolID, uint64(1)); err != nil {
		t.Fatalf("tamper manifest acceptance projection: %v", err)
	}
	if _, err := store.Reconstruct(ctx); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("Reconstruct err=%v, want ErrMalformedDurableEvent", err)
	}
}

func TestDurableStore_ManifestAcceptanceProjectionTamperFailsClosedOnOpen(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000622, 0).UTC()
	root := newRootFixture(t)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
	)
	if _, err := db.ExecContext(ctx, `UPDATE trustpool_manifest_acceptances SET manifest_core_digest = ? WHERE pool_id = ? AND manifest_version = ?`, strings.Repeat("a", 64), root.poolID, uint64(1)); err != nil {
		t.Fatalf("tamper manifest acceptance projection: %v", err)
	}

	if _, err := trustpool.NewStore(db); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("reopen NewStore err=%v, want ErrMalformedDurableEvent", err)
	}
}

func TestDurableStore_RouteabilityFailsClosedWhenMinEligibleMembersDropsAfterPromotion(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000650, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.MinEligibleMembers = 2
		}),
		ev("op-member-a", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-member-b", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-buyer", ts.Add(5*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	}
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
		OperationID: "op-promote",
		PoolID:      root.poolID,
	}); err != nil {
		t.Fatalf("PromotePool: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, ev("op-revoke-b", ts.Add(6*time.Second), trustpool.EventMemberRevoked, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-b"
	})); err != nil {
		t.Fatalf("AppendValidatedEvent revoke: %v", err)
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	poolState := state.Pools[root.poolID]
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || len(snap.Members) != 0 {
		t.Fatalf("routeable snapshot after under-minimum revocation = %+v, want present but non-routeable with no members", snap)
	}
	if snap.Generation <= poolState.EffectiveGeneration() {
		t.Fatalf("routeable generation = %d, want advanced over effective generation %d", snap.Generation, poolState.EffectiveGeneration())
	}
}

func TestDurableStore_RouteabilityFailsClosedForActivePoolWithUnresolvedRetentionPolicy(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name              string
		retentionPolicyID string
	}{
		{name: "unknown", retentionPolicyID: "unknown-retention-policy"},
		{name: "noncanonical whitespace", retentionPolicyID: " standard "},
	} {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			ctx := context.Background()
			db := openTrustPoolDB(t)
			store, err := trustpool.NewStore(db)
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			ts := time.Unix(1800000675, 0).UTC()
			root := newRootFixture(t)
			for _, e := range []trustpool.DurableEvent{
				ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
				signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
					core.RetentionPolicyID = tc.retentionPolicyID
				}),
				ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
					e.ProviderID = "provider-a"
				}),
				ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
					e.BuyerAccountID = "acct-a"
				}),
			} {
				if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
					t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
				}
			}
			insertPromotedEvent(t, ctx, db, ev("op-active", ts.Add(5*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
				e.Lifecycle = trustpool.LifecycleActive
			}))
			state, err := store.Reconstruct(ctx)
			if err != nil {
				t.Fatalf("Reconstruct: %v", err)
			}
			registry, err := state.BuildRegistry()
			if err != nil {
				t.Fatalf("BuildRegistry: %v", err)
			}
			snap := registry.Snapshot(root.poolID)
			if !snap.Exists || snap.Routeable || len(snap.Members) != 0 {
				t.Fatalf("routeable snapshot with unresolved retention %q = %+v, want present but non-routeable with no members", tc.retentionPolicyID, snap)
			}
		})
	}
}

func TestDurableStore_PromotePoolRejectsMissingPreconditions(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ts := time.Unix(1800000700, 0).UTC()
	tests := []struct {
		name   string
		build  func(*testing.T, *trustpool.Store, rootFixture)
		poolID func(rootFixture) string
		want   string
	}{
		{
			name:   "pool not found",
			build:  func(*testing.T, *trustpool.Store, rootFixture) {},
			poolID: func(root rootFixture) string { return root.poolID },
			want:   "pool_not_found",
		},
		{
			name: "root issuer missing",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
				)
			},
			want: "root_issuer_missing",
		},
		{
			name: "manifest missing",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
				)
			},
			want: "manifest_missing",
		},
		{
			name: "member missing",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
					ev("op-buyer", ts.Add(3*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
			},
			want: "member_missing",
		},
		{
			name: "buyer authorization missing",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
				)
			},
			want: "buyer_authorization_missing",
		},
		{
			name: "manifest min eligible members unmet",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
						core.MinEligibleMembers = 2
					}),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
					ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
			},
			want: "member_missing",
		},
		{
			name: "creator suspended",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
					ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
				approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusSuspended)
			},
			want: "creator_suspended",
		},
		{
			name: "unknown retention policy",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
						core.RetentionPolicyID = "unknown-retention-policy"
					}),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
					ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
			},
			want: "retention_policy_unresolved",
		},
		{
			name: "noncanonical retention policy",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
						core.RetentionPolicyID = "standard "
					}),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
					ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
			},
			want: "retention_policy_unresolved",
		},
		{
			name: "production launch environment requires future gate",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "production", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssueInEnvironment(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonceInEnvironment(t, store, "creator-a", "approval-v1", "production", ts.Add(time.Hour)), root, "production"),
					signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
					ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
			},
			want: "launch_environment_not_candidate",
		},
		{
			name: "active re-promotion requires a restrictive transition first",
			build: func(t *testing.T, store *trustpool.Store, root rootFixture) {
				appendTrustPoolEvents(t, ctx, store,
					ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
						e.CreatorAccountID = "creator-a"
						e.ApprovalRecordID = "approval-v1"
					}),
					signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
					signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
					ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
						e.ProviderID = "provider-a"
					}),
					ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
						e.BuyerAccountID = "acct-a"
					}),
				)
				if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
					OperationID:  "op-first-promote",
					TimestampUTC: ts.Add(5 * time.Second),
					PoolID:       root.poolID,
				}); err != nil {
					t.Fatalf("first PromotePool: %v", err)
				}
			},
			want: "lifecycle_active",
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store, err := trustpool.NewStore(openTrustPoolDB(t))
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			root := newRootFixture(t)
			poolID := root.poolID
			if tc.poolID == nil {
				tc.poolID = func(rootFixture) string { return poolID }
			}
			approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
			tc.build(t, store, root)
			_, _, _, err = store.PromotePool(ctx, trustpool.DurableEvent{
				OperationID: "op-promote",
				PoolID:      tc.poolID(root),
			})
			var precondition trustpool.PromotionPreconditionError
			if !errors.As(err, &precondition) {
				t.Fatalf("PromotePool err=%v, want PromotionPreconditionError", err)
			}
			if precondition.Reason != tc.want {
				t.Fatalf("precondition reason = %q, want %q", precondition.Reason, tc.want)
			}
		})
	}
}

func TestDurableStore_PromotePoolProductionRequiresActivationEvidence(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	ts := time.Unix(1800000750, 0).UTC()
	custodyHash := hexDigest("custody")
	evidenceHash := strings.Repeat("b", 64)
	tests := []struct {
		name        string
		gateCustody string
		wantReason  string
		wantActive  bool
	}{
		{
			name:        "custody mismatch rejects",
			gateCustody: strings.Repeat("c", 64),
			wantReason:  "production_root_custody_unapproved",
		},
		{
			name:        "matching evidence and custody activates",
			gateCustody: custodyHash,
			wantActive:  true,
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			store, err := trustpool.NewStore(openTrustPoolDB(t), trustpool.WithProductionActivationGate(trustpool.ProductionActivationGate{
				AllowedLaunchEnvironments: []string{"production"},
				RootCustodyHashes:         []string{tc.gateCustody},
				EvidenceSHA256:            evidenceHash,
			}))
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			root := newRootFixture(t)
			approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "production", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
			appendTrustPoolEvents(t, ctx, store,
				ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				signedRootRegistrationForIssueInEnvironment(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonceInEnvironment(t, store, "creator-a", "approval-v1", "production", ts.Add(time.Hour)), root, "production"),
				signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
				ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
					e.ProviderID = "provider-a"
				}),
				ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
					e.BuyerAccountID = "acct-a"
				}),
			)
			state, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{
				OperationID: "op-promote",
				PoolID:      root.poolID,
			})
			if tc.wantActive {
				if err != nil {
					t.Fatalf("PromotePool: %v", err)
				}
				if got := state.Pools[root.poolID].Lifecycle; got != trustpool.LifecycleActive {
					t.Fatalf("promoted lifecycle=%q, want active", got)
				}
				return
			}
			var precondition trustpool.PromotionPreconditionError
			if !errors.As(err, &precondition) {
				t.Fatalf("PromotePool err=%v, want PromotionPreconditionError", err)
			}
			if precondition.Reason != tc.wantReason {
				t.Fatalf("precondition reason=%q, want %q", precondition.Reason, tc.wantReason)
			}
		})
	}
}

func TestDurableStore_ReconstructsRouteableRegistryAcrossRestart(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000000, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-floor", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
			e.MinBinaryVersion = "1.8.33"
		}),
		ev("op-member-a", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-member-b", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-revoke-b", ts.Add(6*time.Second), trustpool.EventMemberRevoked, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-buyer", ts.Add(7*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", ts.Add(8*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
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

	store2, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore restart: %v", err)
	}
	reconstructed, err := store2.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	poolState := reconstructed.Pools[root.poolID]
	if poolState == nil {
		t.Fatal("pool-a missing after replay")
	}
	if poolState.CreatorAccountID != "creator-a" || poolState.ManifestVersion != 1 || poolState.ManifestCoreDigest == "" {
		t.Fatalf("unexpected admin state: %+v", poolState)
	}
	if !poolState.BuyerAccounts["acct-a"] {
		t.Fatalf("buyer authorization not replayed: %+v", poolState.BuyerAccounts)
	}

	registry, err := reconstructed.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists {
		t.Fatal("pool-a should exist in registry")
	}
	if !snap.Members["provider-a"] || snap.Members["provider-b"] {
		t.Fatalf("routeable members = %v, want only provider-a", snap.Members)
	}
	if snap.MinBinaryVersion != "1.8.33" {
		t.Fatalf("min floor = %q, want 1.8.33", snap.MinBinaryVersion)
	}
	if snap.Generation != uint64(len(events)+1) {
		t.Fatalf("generation = %d, want durable event count plus creator approval revision %d", snap.Generation, len(events)+1)
	}
	if !registry.BuyerAuthorized(root.poolID, "acct-a") {
		t.Fatal("acct-a should be authorized for pool-a after durable replay")
	}
	if registry.BuyerAuthorized(root.poolID, "acct-other") {
		t.Fatal("acct-other should not be authorized for pool-a")
	}
}

func TestDurableStore_PausedPoolReplaysButFailsClosedForRouting(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800001000, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-member", ts.Add(time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(2*time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(3*time.Second), root.poolID, 1, root),
		ev("op-active", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
		ev("op-pause", ts.Add(5*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecyclePaused
			e.Reason = "creator_suspended"
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
	reconstructed, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if got := reconstructed.Pools[root.poolID].Lifecycle; got != trustpool.LifecyclePaused {
		t.Fatalf("lifecycle = %q, want paused", got)
	}
	registry, err := reconstructed.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists {
		t.Fatal("paused pool should still exist so the coordinator can fail closed for selected pool traffic")
	}
	if snap.Routeable {
		t.Fatal("paused pool must be present but not routeable")
	}
	if len(snap.Members) != 0 {
		t.Fatalf("paused pool exposed routeable members: %v", snap.Members)
	}
	if snap.Generation != uint64(len(events)+1) {
		t.Fatalf("paused generation = %d, want durable event count plus creator approval revision %d", snap.Generation, len(events)+1)
	}
}

func TestDurableStore_IdempotentOperationAndConflict(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800002000, 0).UTC()
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	create := ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("AppendValidatedEvent first: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("AppendValidatedEvent exact replay should be idempotent: %v", err)
	}
	conflict := create
	conflict.CreatorAccountID = "creator-b"
	if _, _, _, err := store.AppendValidatedEvent(ctx, conflict); !errors.Is(err, trustpool.ErrConflictingOperationID) {
		t.Fatalf("conflicting idempotency key error = %v, want ErrConflictingOperationID", err)
	}
	events, err := store.Events(ctx)
	if err != nil {
		t.Fatalf("Events: %v", err)
	}
	if len(events) != 1 {
		t.Fatalf("stored events = %d, want 1", len(events))
	}
}

func TestDurableStore_RootRegistrationNonceIssuedConsumedAndServerTimed(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	root := newRootFixture(t)
	ts := time.Unix(1800002500, 0).UTC()
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("AppendValidatedEvent create: %v", err)
	}

	unissued := signedRootRegistration(t, "op-root-unissued", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root)
	if _, _, _, err := store.AppendValidatedEvent(ctx, unissued); !errors.Is(err, trustpool.ErrRootRegistrationNonce) {
		t.Fatalf("unissued nonce err=%v, want ErrRootRegistrationNonce", err)
	}

	nonce, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		CreatorAccountID:       "creator-a",
		CreatorCredentialID:    "creator-a-cred",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           ts.Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce: %v", err)
	}
	mismatchedCredential := signedRootRegistrationForIssue(t, "op-root-credential-mismatch", ts.Add(1500*time.Millisecond), root.poolID, "creator-a", "approval-v1", nonce, root)
	mismatchedCredential.CreatorCredentialID = "creator-a-cred-v2"
	if _, _, _, err := store.AppendValidatedEvent(ctx, mismatchedCredential); !errors.Is(err, trustpool.ErrRootRegistrationNonce) {
		t.Fatalf("credential-mismatched nonce err=%v, want ErrRootRegistrationNonce", err)
	}
	accepted := signedRootRegistrationForIssue(t, "op-root", ts.Add(2*time.Second), root.poolID, "creator-a", "approval-v1", nonce, root)
	accepted.CreatorCredentialID = "creator-a-cred"
	if _, _, _, err := store.AppendValidatedEvent(ctx, accepted); err != nil {
		t.Fatalf("AppendValidatedEvent root: %v", err)
	}
	reuse := accepted
	reuse.OperationID = "op-root-reuse"
	if _, _, _, err := store.AppendValidatedEvent(ctx, reuse); !errors.Is(err, trustpool.ErrRootRegistrationNonce) {
		t.Fatalf("reused nonce err=%v, want ErrRootRegistrationNonce", err)
	}

	root2 := newRootFixture(t)
	approveCreator(t, store, "creator-b", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	create2 := ev("op-create-2", ts, trustpool.EventPoolCreated, root2.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-b"
		e.ApprovalRecordID = "approval-v1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, create2); err != nil {
		t.Fatalf("AppendValidatedEvent create2: %v", err)
	}
	expired, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-expired",
		CreatorAccountID:       "creator-b",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(50 * time.Millisecond),
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce short TTL: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
	backdated := signedRootRegistrationForIssue(t, "op-root-expired", ts.Add(3*time.Second), root2.poolID, "creator-b", "approval-v1", expired, root2)
	if _, _, _, err := store.AppendValidatedEvent(ctx, backdated); !errors.Is(err, trustpool.ErrRootRegistrationNonce) {
		t.Fatalf("backdated expired nonce err=%v, want ErrRootRegistrationNonce", err)
	}
}

func TestDurableStore_RootRegistrationNonceIssueIsIdempotent(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	issue := trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		CreatorAccountID:       "creator-a",
		CreatorCredentialID:    "creator-a-cred",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(250 * time.Millisecond).UTC().Truncate(time.Nanosecond),
	}
	first, err := store.IssueRootRegistrationNonce(ctx, issue)
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce first: %v", err)
	}
	second, err := store.IssueRootRegistrationNonce(ctx, issue)
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce retry: %v", err)
	}
	if second.Nonce != first.Nonce || !second.IssuedAtUTC.Equal(first.IssuedAtUTC) || second.OperationID != "op-nonce" || second.CreatorCredentialID != "creator-a-cred" {
		t.Fatalf("retry record = %+v, want original %+v", second, first)
	}
	time.Sleep(time.Until(issue.ExpiresAtUTC.Add(time.Millisecond)))
	expiredRetry, err := store.IssueRootRegistrationNonce(ctx, issue)
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce expired retry: %v", err)
	}
	if expiredRetry.Nonce != first.Nonce || !expiredRetry.IssuedAtUTC.Equal(first.IssuedAtUTC) {
		t.Fatalf("expired retry record = %+v, want original %+v", expiredRetry, first)
	}
	newExpired := issue
	newExpired.OperationID = "op-nonce-new-expired"
	if _, err := store.IssueRootRegistrationNonce(ctx, newExpired); !errors.Is(err, trustpool.ErrRootRegistrationNonce) {
		t.Fatalf("new expired nonce issue err=%v, want ErrRootRegistrationNonce", err)
	}
	conflictingCredential := issue
	conflictingCredential.CreatorCredentialID = "creator-a-cred-v2"
	if _, err := store.IssueRootRegistrationNonce(ctx, conflictingCredential); !errors.Is(err, trustpool.ErrConflictingOperationID) {
		t.Fatalf("conflicting credential nonce issue err=%v, want ErrConflictingOperationID", err)
	}
	conflict := issue
	conflict.LaunchEnvironment = "production"
	if _, err := store.IssueRootRegistrationNonce(ctx, conflict); !errors.Is(err, trustpool.ErrConflictingOperationID) {
		t.Fatalf("conflicting nonce issue err=%v, want ErrConflictingOperationID", err)
	}
}

func TestDurableStore_ReconstructRejectsDuplicateRootRegistrationNonce(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	rootA := newRootFixture(t)
	rootB := newRootFixture(t)
	ts := time.Unix(1800002520, 0).UTC()
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	for _, create := range []trustpool.DurableEvent{
		ev("op-create-a", ts, trustpool.EventPoolCreated, rootA.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-create-b", ts.Add(time.Second), trustpool.EventPoolCreated, rootB.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
	} {
		if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", create.OperationID, err)
		}
	}
	nonce := issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour))
	rootEventA := signedRootRegistrationForIssue(t, "op-root-a", ts.Add(2*time.Second), rootA.poolID, "creator-a", "approval-v1", nonce, rootA)
	rootEventB := signedRootRegistrationForIssue(t, "op-root-b", ts.Add(3*time.Second), rootB.poolID, "creator-a", "approval-v1", nonce, rootB)
	insertPromotedEvent(t, ctx, db, rootEventA)
	insertPromotedEvent(t, ctx, db, rootEventB)
	if _, err := store.Reconstruct(ctx); !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("Reconstruct duplicate root nonce err=%v, want ErrMalformedDurableEvent", err)
	}
}

func TestDurableStore_CreatorApprovalGatesNonceAndExpansiveMutations(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800002550, 0).UTC()
	if _, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-unapproved",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	}); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
		t.Fatalf("unapproved nonce err=%v, want ErrCreatorApprovalGate", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusSuspended)
	if _, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-suspended",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	}); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
		t.Fatalf("suspended nonce err=%v, want ErrCreatorApprovalGate", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	if _, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-wrong-version",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-2",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	}); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
		t.Fatalf("wrong version nonce err=%v, want ErrCreatorApprovalGate", err)
	}
	if _, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-wrong-environment",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "production",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	}); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
		t.Fatalf("wrong environment nonce err=%v, want ErrCreatorApprovalGate", err)
	}
	root := newRootFixture(t)
	pendingNonce, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-pending",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce pending: %v", err)
	}
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("AppendValidatedEvent create: %v", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusSuspended)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	staleRoot := signedRootRegistrationForIssue(t, "op-root-stale", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", pendingNonce, root)
	if _, _, _, err := store.AppendValidatedEvent(ctx, staleRoot); !errors.Is(err, trustpool.ErrRootRegistrationNonce) {
		t.Fatalf("root registration with suspension-invalidated nonce err=%v, want ErrRootRegistrationNonce", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusSuspended)
	buyer := ev("op-buyer", ts.Add(2*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
		e.BuyerAccountID = "acct-a"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, buyer); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
		t.Fatalf("buyer authorization while suspended err=%v, want ErrCreatorApprovalGate", err)
	}
	retire := ev("op-retire", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
		e.Lifecycle = trustpool.LifecycleRetired
		e.Reason = "creator_suspended"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, retire); err != nil {
		t.Fatalf("restrictive retire should remain available to operators: %v", err)
	}
}

func TestDurableStore_RootCompromiseFreeze(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800003550, 0).UTC()
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	root := newRootFixture(t)
	create := ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("create: %v", err)
	}
	nonce, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("nonce: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", nonce, root)); err != nil {
		t.Fatalf("root: %v", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusSuspended)
	freeze := ev("op-freeze", ts.Add(2*time.Second), trustpool.EventRootCompromiseFrozen, root.poolID, func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.RootIssuerPublicKeyFingerprint = root.fingerprint
		e.Reason = trustpool.RootCompromiseFreezeReason
	})
	state, _, _, err := store.AppendValidatedEvent(ctx, freeze)
	if err != nil {
		t.Fatalf("freeze while suspended: %v", err)
	}
	pool := state.Pools[root.poolID]
	if pool == nil || pool.CreatorGateReason != trustpool.RootCompromiseFreezeReason {
		t.Fatalf("frozen pool = %+v", pool)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	if _, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "op-nonce-after-freeze",
		CreatorAccountID:       "creator-a",
		ApprovalRecordID:       "approval-v1",
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           time.Now().Add(time.Hour),
	}); !errors.Is(err, trustpool.ErrRootCompromiseFreeze) {
		t.Fatalf("nonce after freeze err=%v, want ErrRootCompromiseFreeze", err)
	}
	descendant := signedManifestWithPolicyCoreMutation(t, "op-descendant", ts.Add(3*time.Second), root.poolID, 1, root, nil)
	descendant.RootIssuerKeyID = root.authorityRoot.KeyID
	if _, _, _, err := store.AppendValidatedEvent(ctx, descendant); !errors.Is(err, trustpool.ErrRootCompromiseFreeze) {
		t.Fatalf("descendant manifest err=%v, want ErrRootCompromiseFreeze", err)
	}
}

func TestDurableStore_CreatorApprovalRequiresR001Fields(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	cases := []struct {
		name   string
		mutate func(*trustpool.CreatorApproval)
	}{
		{name: "public_display_name", mutate: func(a *trustpool.CreatorApproval) { a.PublicDisplayName = "" }},
		{name: "legal_support_contact", mutate: func(a *trustpool.CreatorApproval) { a.LegalSupportContact = "" }},
		{name: "billing_contact", mutate: func(a *trustpool.CreatorApproval) { a.BillingContact = "" }},
		{name: "emergency_notification_endpoint", mutate: func(a *trustpool.CreatorApproval) { a.EmergencyNotificationEndpoint = "" }},
		{name: "acknowledged_max_response_time", mutate: func(a *trustpool.CreatorApproval) { a.AcknowledgedMaxResponseTime = "" }},
		{name: "allowed_product_category", mutate: func(a *trustpool.CreatorApproval) { a.AllowedProductCategory = "" }},
		{name: "data_retention_category", mutate: func(a *trustpool.CreatorApproval) { a.DataRetentionCategory = "" }},
		{name: "support_owner", mutate: func(a *trustpool.CreatorApproval) { a.SupportOwner = "" }},
		{name: "pricing_schedule_id", mutate: func(a *trustpool.CreatorApproval) { a.PricingScheduleID = "" }},
		{name: "pricing_schedule_version", mutate: func(a *trustpool.CreatorApproval) { a.PricingScheduleVersion = "" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, err := trustpool.NewStore(openTrustPoolDB(t))
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			approval := validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
			tc.mutate(&approval)
			if _, err := store.UpsertCreatorApproval(ctx, approval); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
				t.Fatalf("UpsertCreatorApproval missing %s err=%v, want ErrCreatorApprovalGate", tc.name, err)
			}
		})
	}
}

func TestDurableStore_CreatorApprovalRejectsBuyerVisiblePromiseClaims(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	cases := []struct {
		name   string
		mutate func(*trustpool.CreatorApproval)
	}{
		{name: "creator_account_id", mutate: func(a *trustpool.CreatorApproval) { a.CreatorAccountID = "privacy-pool-law" }},
		{name: "approval_record_id", mutate: func(a *trustpool.CreatorApproval) { a.ApprovalRecordID = "approval-zero-knowledge" }},
		{name: "current_approval_version", mutate: func(a *trustpool.CreatorApproval) { a.CurrentApprovalVersion = "end-to-end-encryption-v1" }},
		{name: "public_display_name", mutate: func(a *trustpool.CreatorApproval) { a.PublicDisplayName = "Privacy Pool" }},
		{name: "ferpa_public_display_name", mutate: func(a *trustpool.CreatorApproval) { a.PublicDisplayName = "FERPA compliant pool" }},
		{name: "allowed_product_category", mutate: func(a *trustpool.CreatorApproval) { a.AllowedProductCategory = "confidential compute" }},
		{name: "data_retention_category", mutate: func(a *trustpool.CreatorApproval) { a.DataRetentionCategory = "HIPAA" }},
		{name: "allowed_launch_environment", mutate: func(a *trustpool.CreatorApproval) { a.AllowedLaunchEnvironment = "zk inference" }},
		{name: "zk_public_display_name", mutate: func(a *trustpool.CreatorApproval) { a.PublicDisplayName = "ZK proof pool" }},
		{name: "standalone_zk_public_display_name", mutate: func(a *trustpool.CreatorApproval) { a.PublicDisplayName = "ZK-backed Trusted Pool" }},
		{name: "creator_agreement_id", mutate: func(a *trustpool.CreatorApproval) { a.CreatorAgreementID = "agreement-soc2" }},
		{name: "creator_agreement_version", mutate: func(a *trustpool.CreatorApproval) { a.CreatorAgreementVersion = "gdpr adequacy" }},
		{name: "pricing_schedule_id", mutate: func(a *trustpool.CreatorApproval) { a.PricingScheduleID = "pci-dss" }},
		{name: "pricing_schedule_version", mutate: func(a *trustpool.CreatorApproval) { a.PricingScheduleVersion = "anonymous routing" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			store, err := trustpool.NewStore(openTrustPoolDB(t))
			if err != nil {
				t.Fatalf("NewStore: %v", err)
			}
			approval := validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
			tc.mutate(&approval)
			if _, err := store.UpsertCreatorApproval(ctx, approval); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
				t.Fatalf("UpsertCreatorApproval %s err=%v, want ErrProhibitedPromiseClaim", tc.name, err)
			}
		})
	}
}

func TestDurableStore_LegacyCreatorApprovalOverclaimFailsClosedOnRead(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	approval := validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	approval.PublicDisplayName = "Privacy Pool"
	now := time.Unix(1800004000, 0).UTC().Format(time.RFC3339Nano)
	if _, err := db.ExecContext(ctx, `
INSERT INTO trustpool_creator_approvals (
    creator_account_id, approval_record_id, current_approval_version,
    public_display_name, legal_support_contact, billing_contact, emergency_notification_endpoint,
    acknowledged_max_response_time, allowed_product_category, data_retention_category,
    support_owner, allowed_launch_environment,
    creator_agreement_id, creator_agreement_version, creator_agreement_expires_at_utc,
    creator_agreement_grace_ends_at_utc, pricing_schedule_id, pricing_schedule_version,
    prohibited_claim_acknowledgment_hash, buyer_disclosure_commitment_hash, approval_criteria_hash,
    approved_by, approved_at_utc, approval_revision, status, suspension_reason, updated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		approval.CreatorAccountID,
		approval.ApprovalRecordID,
		approval.CurrentApprovalVersion,
		approval.PublicDisplayName,
		approval.LegalSupportContact,
		approval.BillingContact,
		approval.EmergencyNotificationEndpoint,
		approval.AcknowledgedMaxResponseTime,
		approval.AllowedProductCategory,
		approval.DataRetentionCategory,
		approval.SupportOwner,
		approval.AllowedLaunchEnvironment,
		approval.CreatorAgreementID,
		approval.CreatorAgreementVersion,
		approval.CreatorAgreementExpiresAtUTC.Format(time.RFC3339Nano),
		approval.CreatorAgreementGraceEndsAtUTC.Format(time.RFC3339Nano),
		approval.PricingScheduleID,
		approval.PricingScheduleVersion,
		approval.ProhibitedClaimAcknowledgmentHash,
		approval.BuyerDisclosureCommitmentHash,
		approval.ApprovalCriteriaHash,
		approval.ApprovedBy,
		approval.ApprovedAtUTC.Format(time.RFC3339Nano),
		1,
		approval.Status,
		approval.SuspensionReason,
		now,
	); err != nil {
		t.Fatalf("insert legacy approval: %v", err)
	}
	if _, _, err := store.CreatorApproval(ctx, "creator-a"); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("CreatorApproval err=%v, want ErrProhibitedPromiseClaim", err)
	}
	if _, err := store.Reconstruct(ctx); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("Reconstruct err=%v, want ErrProhibitedPromiseClaim", err)
	}
}

func TestDurableStore_CreatorApprovalExactRetryDoesNotBumpRevision(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	approval := validCreatorApproval("creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	first, err := store.UpsertCreatorApproval(ctx, approval)
	if err != nil {
		t.Fatalf("first UpsertCreatorApproval: %v", err)
	}
	second, err := store.UpsertCreatorApproval(ctx, approval)
	if err != nil {
		t.Fatalf("retry UpsertCreatorApproval: %v", err)
	}
	if second.ApprovalRevision != first.ApprovalRevision {
		t.Fatalf("retry approval_revision = %d, want unchanged %d", second.ApprovalRevision, first.ApprovalRevision)
	}
	withReturnedFields := second
	third, err := store.UpsertCreatorApproval(ctx, withReturnedFields)
	if err != nil {
		t.Fatalf("GET-body retry UpsertCreatorApproval: %v", err)
	}
	if third.ApprovalRevision != first.ApprovalRevision {
		t.Fatalf("GET-body retry approval_revision = %d, want unchanged %d", third.ApprovalRevision, first.ApprovalRevision)
	}
}

func TestDurableStore_CreatorApprovalControlsRouteability(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800002580, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-member", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(4*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", ts.Add(5*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
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
	reconstructed, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct enabled: %v", err)
	}
	registry, err := reconstructed.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry enabled: %v", err)
	}
	enabledSnap := registry.Snapshot(root.poolID)
	if !enabledSnap.Routeable || !enabledSnap.Members["provider-a"] {
		t.Fatalf("enabled creator snapshot = %+v, want routeable provider-a", enabledSnap)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusSuspended)
	reconstructed, err = store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct suspended: %v", err)
	}
	poolState := reconstructed.Pools[root.poolID]
	if poolState.CreatorGateReason != "creator_suspended" {
		t.Fatalf("creator gate reason = %q, want creator_suspended", poolState.CreatorGateReason)
	}
	registry, err = reconstructed.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry suspended: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Exists || snap.Routeable || len(snap.Members) != 0 {
		t.Fatalf("suspended creator snapshot = %+v, want present but non-routeable with no members", snap)
	}
	if snap.Generation <= enabledSnap.Generation {
		t.Fatalf("suspended creator generation = %d, want > pre-suspension generation %d", snap.Generation, enabledSnap.Generation)
	}
	reEnable, ok, err := store.CreatorApproval(ctx, "creator-a")
	if err != nil {
		t.Fatalf("CreatorApproval suspended: %v", err)
	}
	if !ok {
		t.Fatal("creator approval missing after suspension")
	}
	reEnable.Status = trustpool.CreatorStatusEnabled
	reEnable.SuspensionReason = ""
	reEnable.CreatorAgreementGraceEndsAtUTC = time.Now().Add(time.Hour).UTC()
	reEnable.CreatorAgreementExpiresAtUTC = reEnable.CreatorAgreementGraceEndsAtUTC.Add(-time.Hour)
	if _, err := store.UpsertCreatorApproval(ctx, reEnable); !errors.Is(err, trustpool.ErrCreatorApprovalGate) {
		t.Fatalf("valid re-enable without reactivation sweep err=%v, want ErrCreatorApprovalGate", err)
	}
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(-time.Hour), trustpool.CreatorStatusEnabled)
	reconstructed, err = store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct expired: %v", err)
	}
	if got := reconstructed.Pools[root.poolID].CreatorGateReason; got != "creator_agreement_expired" {
		t.Fatalf("expired gate reason = %q, want creator_agreement_expired", got)
	}
}

func TestRegistryRouteableUntilExpiresAtRouteTimeAndBumpsGeneration(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	expiresAt := time.Now().Add(50 * time.Millisecond).UTC()
	if err := registry.LoadRouteableSnapshotsAtRevision(1, []trustpool.RouteableSnapshot{
		{
			PoolID:            "pool-a",
			Members:           []string{"provider-a"},
			BuyerAccounts:     []string{"acct-a"},
			SettlementMode:    "observe",
			Routeable:         true,
			Generation:        7,
			RouteableUntilUTC: expiresAt,
		},
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshotsAtRevision: %v", err)
	}
	snap, authorized := registry.AuthorizeAndSnapshot("pool-a", "acct-a")
	if !authorized || !snap.Routeable || snap.Generation != 7 {
		t.Fatalf("pre-expiry snap=%+v authorized=%v, want routeable generation 7", snap, authorized)
	}
	time.Sleep(80 * time.Millisecond)
	expired := registry.Snapshot("pool-a")
	if !expired.Exists || expired.Routeable || expired.Generation <= snap.Generation {
		t.Fatalf("post-expiry snap=%+v, want non-routeable with advanced generation over %d", expired, snap.Generation)
	}
	if registry.Generation("pool-a") != expired.Generation {
		t.Fatalf("Generation() = %d, want expired snapshot generation %d", registry.Generation("pool-a"), expired.Generation)
	}
}

func TestReconstructEvents_RejectsLegacyUnsignedManifestAccepted(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800002700, 0).UTC()
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, "legacy-pool", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-manifest-legacy", ts.Add(time.Second), trustpool.EventManifestAccepted, "legacy-pool", func(e *trustpool.DurableEvent) {
			e.ManifestVersion = 1
			e.ManifestCoreDigest = hexDigest("legacy")
		}),
	}
	if _, err := trustpool.ReconstructEvents(events); err == nil {
		t.Fatal("legacy unsigned manifest replay should fail closed")
	}
}

func TestReconstructEvents_RejectsMalformedStateMachine(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800003000, 0).UTC()
	tests := []struct {
		name   string
		events []trustpool.DurableEvent
	}{
		{
			name: "member before create",
			events: []trustpool.DurableEvent{
				ev("op-member", ts, trustpool.EventMemberAdmitted, "pool-a", func(e *trustpool.DurableEvent) {
					e.ProviderID = "provider-a"
				}),
			},
		},
		{
			name: "active before manifest",
			events: []trustpool.DurableEvent{
				ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				ev("op-active", ts.Add(time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleActive
				}),
			},
		},
		{
			name: "duplicate create",
			events: []trustpool.DurableEvent{
				ev("op-create-1", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				ev("op-create-2", ts.Add(time.Second), trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
			},
		},
		{
			name: "event after retired",
			events: []trustpool.DurableEvent{
				ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				ev("op-retire", ts.Add(time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleRetired
				}),
				ev("op-member", ts.Add(2*time.Second), trustpool.EventMemberAdmitted, "pool-a", func(e *trustpool.DurableEvent) {
					e.ProviderID = "provider-a"
				}),
			},
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := trustpool.ReconstructEvents(tc.events)
			if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
				t.Fatalf("ReconstructEvents error = %v, want ErrMalformedDurableEvent", err)
			}
		})
	}
}

func TestReconstructEvents_RejectsInvalidLifecycleTransitions(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800003500, 0).UTC()
	root := newRootFixture(t)
	prefix := func() []trustpool.DurableEvent {
		return []trustpool.DurableEvent{
			ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
				e.CreatorAccountID = "creator-a"
				e.ApprovalRecordID = "approval-v1"
			}),
			signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root),
			signedManifest(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root),
			ev("op-active", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
				e.Lifecycle = trustpool.LifecycleActive
			}),
		}
	}
	tests := []struct {
		name   string
		events []trustpool.DurableEvent
	}{
		{
			name: "draining cannot reactivate",
			events: append(prefix(),
				ev("op-draining", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleDraining
				}),
				ev("op-reactivate", ts.Add(5*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleActive
				}),
			),
		},
		{
			name: "active cannot return to created",
			events: append(prefix(),
				ev("op-created-again", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleCreated
				}),
			),
		},
		{
			name: "active cannot retire without draining",
			events: append(prefix(),
				ev("op-retire-direct", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleRetired
				}),
			),
		},
		{
			name: "created cannot pause before activation",
			events: []trustpool.DurableEvent{
				ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
					e.CreatorAccountID = "creator-a"
					e.ApprovalRecordID = "approval-v1"
				}),
				ev("op-pause", ts.Add(time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecyclePaused
				}),
			},
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := trustpool.ReconstructEvents(tc.events)
			if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
				t.Fatalf("ReconstructEvents error = %v, want ErrMalformedDurableEvent", err)
			}
		})
	}
}

func TestReconstructEvents_RejectsDuplicateOperationIDs(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800004000, 0).UTC()
	events := []trustpool.DurableEvent{
		ev("op-same", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-same", ts.Add(time.Second), trustpool.EventPoolCreated, "pool-b", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-b"
			e.ApprovalRecordID = "approval-v1"
		}),
	}
	_, err := trustpool.ReconstructEvents(events)
	if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("ReconstructEvents error = %v, want ErrMalformedDurableEvent", err)
	}
}

func TestReconstructEvents_RejectsLifecycleReasonPromiseClaims(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800004100, 0).UTC()
	root := newRootFixture(t)
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-pause", ts.Add(time.Second), trustpool.EventLifecycleChanged, root.poolID, func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecyclePaused
			e.Reason = "HIPAA Privacy Pool review"
		}),
	}
	if _, err := trustpool.ReconstructEvents(events); !errors.Is(err, trustpool.ErrProhibitedPromiseClaim) {
		t.Fatalf("ReconstructEvents error = %v, want ErrProhibitedPromiseClaim", err)
	}
}

func TestReconstructEvents_RejectsManifestAndFloorDowngrades(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800004200, 0).UTC()
	root := newRootFixture(t)
	prefix := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root),
		signedManifest(t, "op-manifest-1", ts.Add(2*time.Second), root.poolID, 1, root),
		ev("op-floor-2", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
			e.MinBinaryVersion = "1.8.2"
		}),
	}
	tests := []struct {
		name  string
		event trustpool.DurableEvent
	}{
		{
			name:  "manifest version cannot go backward",
			event: signedManifest(t, "op-manifest-1", ts.Add(4*time.Second), root.poolID, 1, root),
		},
		{
			name: "binary floor cannot be lowered",
			event: ev("op-floor-low", ts.Add(4*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
				e.MinBinaryVersion = "1.8.1"
			}),
		},
		{
			name: "binary floor cannot be cleared",
			event: ev("op-floor-clear", ts.Add(4*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
				e.MinBinaryVersion = ""
			}),
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := trustpool.ReconstructEvents(append(append([]trustpool.DurableEvent(nil), prefix...), tc.event))
			if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
				t.Fatalf("ReconstructEvents error = %v, want ErrMalformedDurableEvent", err)
			}
		})
	}
}

func TestReconstructEvents_RejectsExplicitFloorBelowManifestFloor(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800004300, 0).UTC()
	root := newRootFixture(t)
	prefix := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root),
		signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
			core.MinBinaryVersion = "1.8.33"
		}),
	}
	tests := []struct {
		name  string
		event trustpool.DurableEvent
	}{
		{
			name: "explicit floor cannot lower manifest floor",
			event: ev("op-floor-low", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
				e.MinBinaryVersion = "1.8.32"
			}),
		},
		{
			name: "explicit floor cannot clear manifest floor",
			event: ev("op-floor-clear", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
				e.MinBinaryVersion = ""
			}),
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := trustpool.ReconstructEvents(append(append([]trustpool.DurableEvent(nil), prefix...), tc.event))
			if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
				t.Fatalf("ReconstructEvents error = %v, want ErrMalformedDurableEvent", err)
			}
		})
	}
}

func TestReconstructEvents_RejectsManifestFloorDowngrade(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800004400, 0).UTC()
	root := newRootFixture(t)
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest-1", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.MinBinaryVersion = "1.8.33"
		core.ExpiresAtUnix = 100
	})
	prefix := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistration(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", root),
		v1,
	}
	tests := []struct {
		name string
		v2   trustpool.DurableEvent
	}{
		{
			name: "manifest floor cannot lower previous manifest floor",
			v2: signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2-low", ts.Add(3*time.Second), v1, root, func(core *poolmanifest.PolicyCore) {
				core.MinBinaryVersion = "1.8.32"
			}),
		},
		{
			name: "manifest floor cannot clear previous manifest floor",
			v2: signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2-clear", ts.Add(3*time.Second), v1, root, func(core *poolmanifest.PolicyCore) {
				core.MinBinaryVersion = ""
			}),
		},
	}
	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			_, err := trustpool.ReconstructEvents(append(append([]trustpool.DurableEvent(nil), prefix...), tc.v2))
			if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
				t.Fatalf("ReconstructEvents error = %v, want ErrMalformedDurableEvent", err)
			}
		})
	}
}

func TestReconstructEvents_ManifestRaiseOverridesOlderExplicitFloor(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800004500, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(time.Hour), trustpool.CreatorStatusEnabled)
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest-1", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.MinBinaryVersion = "1.8.2"
		core.ExpiresAtUnix = 100
	})
	v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2-high", ts.Add(4*time.Second), v1, root, func(core *poolmanifest.PolicyCore) {
		core.MinBinaryVersion = "1.8.33"
		core.SettlementMode = "enforce"
	})
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v1,
		ev("op-floor-explicit-low", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, root.poolID, func(e *trustpool.DurableEvent) {
			e.MinBinaryVersion = "1.8.2"
		}),
		v2,
		ev("op-member", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-buyer", ts.Add(6*time.Second), trustpool.EventBuyerAuthorized, root.poolID, func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
	}
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	snapshots := state.RouteableSnapshots()
	if len(snapshots) != 1 {
		t.Fatalf("RouteableSnapshots len=%d, want 1", len(snapshots))
	}
	if snapshots[0].MinBinaryVersion != "1.8.33" {
		t.Fatalf("routeable min_binary_version = %q, want raised manifest floor", snapshots[0].MinBinaryVersion)
	}
	if len(snapshots[0].ModelAllowlist) != 1 || snapshots[0].ModelAllowlist[0] != "model-a" {
		t.Fatalf("routeable model_allowlist = %+v, want [model-a]", snapshots[0].ModelAllowlist)
	}
	if snapshots[0].SettlementMode != "enforce" {
		t.Fatalf("routeable settlement_mode = %q, want enforce", snapshots[0].SettlementMode)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	if snap := registry.Snapshot(root.poolID); snap.MinBinaryVersion != "1.8.33" || len(snap.ModelAllowlist) != 1 || snap.ModelAllowlist[0] != "model-a" || snap.SettlementMode != "enforce" {
		t.Fatalf("registry snapshot = %+v, want raised floor, model-a allowlist, and enforce settlement mode", snap)
	}
	statusDoc, found, err := trustpool.BuildStatusDocument(ctx, store, registry, root.poolID, "acct-a", ts.Add(7*time.Second))
	if err != nil || !found {
		t.Fatalf("BuildStatusDocument found=%v err=%v, want found nil", found, err)
	}
	if statusDoc.Policy.MinBinaryVersion != "1.8.33" {
		t.Fatalf("status min_binary_version = %q, want raised manifest floor", statusDoc.Policy.MinBinaryVersion)
	}
	if len(statusDoc.Policy.ModelAllowlist) != 1 || statusDoc.Policy.ModelAllowlist[0] != "model-a" {
		t.Fatalf("status model_allowlist = %+v, want [model-a]", statusDoc.Policy.ModelAllowlist)
	}
	policyDoc, found, err := trustpool.BuildPolicyDocument(ctx, store, registry, root.poolID, "acct-a", ts.Add(7*time.Second))
	if err != nil || !found {
		t.Fatalf("BuildPolicyDocument found=%v err=%v, want found nil", found, err)
	}
	if policyDoc.Policy.MinBinaryVersion != "1.8.33" {
		t.Fatalf("policy min_binary_version = %q, want raised manifest floor", policyDoc.Policy.MinBinaryVersion)
	}
	if len(policyDoc.Policy.ModelAllowlist) != 1 || policyDoc.Policy.ModelAllowlist[0] != "model-a" {
		t.Fatalf("policy model_allowlist = %+v, want [model-a]", policyDoc.Policy.ModelAllowlist)
	}
	handler := trustpool.NewAdminHandler(trustpool.AdminDeps{
		Store:       store,
		Registry:    registry,
		OperatorKey: "operator-secret",
	})
	req := httptest.NewRequest(http.MethodGet, "/admin/trust-pools/pools/"+root.poolID, nil)
	req.Header.Set("Authorization", "Bearer operator-secret")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("GET pool status=%d body=%s, want 200", rec.Code, rec.Body.String())
	}
	var body struct {
		Pool struct {
			MinBinaryVersion string `json:"min_binary_version"`
		} `json:"pool"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode GET pool body: %v", err)
	}
	if body.Pool.MinBinaryVersion != "1.8.33" {
		t.Fatalf("admin min_binary_version = %q, want raised manifest floor", body.Pool.MinBinaryVersion)
	}
}

func TestDurableStore_RejectsColumnPayloadOperationMismatchOnReplay(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	e := ev("payload-op", time.Unix(1800005000, 0).UTC(), trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
		e.CreatorAccountID = "creator-a"
		e.ApprovalRecordID = "approval-v1"
	})
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO trustpool_events (
    operation_id, ts_utc, event_type, pool_id, payload_json
) VALUES (?, ?, ?, ?, ?)`,
		"column-op", e.TimestampUTC.Format(time.RFC3339Nano), e.EventType, e.PoolID, string(raw),
	); err != nil {
		t.Fatalf("insert malformed row: %v", err)
	}
	_, err = store.Events(ctx)
	if !errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("Events error = %v, want ErrMalformedDurableEvent", err)
	}
}

func TestRegistryLoadRouteableSnapshots_AllOrNothingValidation(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	if err := registry.LoadRouteableSnapshot(trustpool.RouteableSnapshot{
		PoolID:         "pool-good",
		Members:        []string{"provider-a"},
		SettlementMode: "observe",
		Generation:     9,
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshot good: %v", err)
	}
	err := registry.LoadRouteableSnapshots([]trustpool.RouteableSnapshot{
		{PoolID: "pool-new", Members: []string{"provider-b"}, SettlementMode: "observe", Generation: 1},
		{PoolID: "pool-bad", MinBinaryVersion: "not a version", Generation: 2},
	})
	if err == nil {
		t.Fatal("LoadRouteableSnapshots accepted malformed version floor")
	}
	snap := registry.Snapshot("pool-good")
	if !snap.Exists || !snap.Members["provider-a"] || snap.Generation != 9 {
		t.Fatalf("existing registry mutated by failed bulk load: %+v", snap)
	}
	if registry.Snapshot("pool-new").Exists {
		t.Fatal("failed bulk load partially inserted pool-new")
	}
}

func TestRegistryLoadRouteableSnapshotsAtRevisionRejectsStalePublish(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	if err := registry.LoadRouteableSnapshotsAtRevision(2, []trustpool.RouteableSnapshot{
		{PoolID: "pool-a", BuyerAccounts: []string{"acct-a"}, SettlementMode: "observe", Routeable: true, Generation: 2},
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshotsAtRevision fresh: %v", err)
	}
	if err := registry.LoadRouteableSnapshotsAtRevision(1, []trustpool.RouteableSnapshot{
		{PoolID: "pool-a", BuyerAccounts: []string{"acct-stale"}, SettlementMode: "observe", Routeable: true, Generation: 1},
	}); err == nil {
		t.Fatal("stale routeable snapshot publish was accepted")
	}
	if !registry.BuyerAuthorized("pool-a", "acct-a") || registry.BuyerAuthorized("pool-a", "acct-stale") {
		t.Fatalf("stale publish mutated buyer authorization: %+v", registry.RouteableSnapshots())
	}
}

func openTrustPoolDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "trustpool.sqlite")))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	t.Cleanup(func() { _ = db.Close() })
	return db
}

func insertPromotedEvent(t *testing.T, ctx context.Context, db *sql.DB, e trustpool.DurableEvent) {
	t.Helper()
	raw, err := json.Marshal(e)
	if err != nil {
		t.Fatalf("marshal promoted event: %v", err)
	}
	if _, err := db.ExecContext(ctx, `
INSERT INTO trustpool_events (
    operation_id, ts_utc, event_type, pool_id, creator_account_id, approval_record_id, provider_id,
    buyer_account_id, lifecycle, min_binary_version, manifest_version,
    manifest_core_digest, reason, payload_json
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		e.OperationID,
		e.TimestampUTC.Format(time.RFC3339Nano),
		e.EventType,
		e.PoolID,
		nullString(e.CreatorAccountID),
		nullString(e.ApprovalRecordID),
		nullString(e.ProviderID),
		nullString(e.BuyerAccountID),
		nullString(e.Lifecycle),
		nullString(e.MinBinaryVersion),
		e.ManifestVersion,
		nullString(e.ManifestCoreDigest),
		nullString(e.Reason),
		string(raw),
	); err != nil {
		t.Fatalf("insert promoted event: %v", err)
	}
}

func appendTrustPoolEvents(t *testing.T, ctx context.Context, store *trustpool.Store, events ...trustpool.DurableEvent) {
	t.Helper()
	for _, e := range events {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
}

func nullString(v string) sql.NullString {
	if v == "" {
		return sql.NullString{}
	}
	return sql.NullString{String: v, Valid: true}
}

func ev(op string, ts time.Time, typ, poolID string, mutate func(*trustpool.DurableEvent)) trustpool.DurableEvent {
	e := trustpool.DurableEvent{
		OperationID:  op,
		TimestampUTC: ts,
		EventType:    typ,
		PoolID:       poolID,
	}
	if mutate != nil {
		mutate(&e)
	}
	return e
}
