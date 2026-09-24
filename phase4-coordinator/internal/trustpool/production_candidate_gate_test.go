package trustpool_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// seedCandidatePromotablePool builds a candidate-environment pool with a
// manifest, one member, and one authorized buyer, ready for PromotePool.
func seedCandidatePromotablePool(t *testing.T, store *trustpool.Store) rootFixture {
	t.Helper()
	ctx := context.Background()
	ts := time.Unix(1800000900, 0).UTC()
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
	return root
}

func TestPromotePool_ProductionCoordinatorRejectsCandidateRoot(t *testing.T) {
	t.Parallel()
	store := newProductionActivationStore(t, openTrustPoolDB(t))
	root := seedCandidatePromotablePool(t, store)
	_, _, _, err := store.PromotePool(context.Background(), trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID})
	var precondition trustpool.PromotionPreconditionError
	if !errors.As(err, &precondition) || precondition.Reason != "launch_environment_candidate_on_production" {
		t.Fatalf("PromotePool err=%v, want launch_environment_candidate_on_production", err)
	}
	state, err := store.Reconstruct(context.Background())
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if got := state.Pools[root.poolID].Lifecycle; got != trustpool.LifecycleCreated {
		t.Fatalf("lifecycle=%q, want created", got)
	}
}

func TestPromotePool_NonProductionCoordinatorStillPromotesCandidateRoot(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	root := seedCandidatePromotablePool(t, store)
	state, committed, _, err := store.PromotePool(context.Background(), trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID})
	if err != nil {
		t.Fatalf("PromotePool: %v", err)
	}
	if committed.RootCustodyClass != "" || state.Pools[root.poolID].RootIssuer.CustodyClass != "" {
		t.Fatalf("candidate promotion must not record a custody class: event=%q root=%q", committed.RootCustodyClass, state.Pools[root.poolID].RootIssuer.CustodyClass)
	}
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot(root.poolID)
	if !snap.Routeable || snap.ManifestVersion != 1 || snap.ManifestCoreDigest != state.Pools[root.poolID].ManifestCoreDigest {
		t.Fatalf("candidate pool snapshot=%+v, want routeable with manifest labels", snap)
	}
}

func TestRegistry_ProductionCoordinatorFailsClosedOnCandidateRoot(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	root := seedCandidatePromotablePool(t, store)
	state, _, _, err := store.PromotePool(context.Background(), trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID})
	if err != nil {
		t.Fatalf("PromotePool: %v", err)
	}

	// Flag set after the snapshots were loaded (the coordinator boot order).
	registry, err := state.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	registry.RejectCandidateLaunchEnvironment()
	if snap, _ := registry.AuthorizeAndSnapshot(root.poolID, "acct-a"); snap.Routeable {
		t.Fatalf("candidate pool must not be routeable on a production coordinator: %+v", snap)
	}
	if _, ok := registry.BeginPoolDeliveryAtGeneration(root.poolID, registry.Generation(root.poolID)); ok {
		t.Fatal("candidate pool delivery must fail closed on a production coordinator")
	}

	// Later refreshes keep it non-routeable.
	if err := registry.LoadRouteableSnapshotsAtRevision(state.Revision+1, state.RouteableSnapshots()); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if registry.Snapshot(root.poolID).Routeable {
		t.Fatal("candidate pool became routeable after a snapshot reload")
	}
}

func TestPromotePool_ProductionRequiresOnCallAndRecordsCustodyClass(t *testing.T) {
	t.Parallel()
	db := openTrustPoolDB(t)
	store := newProductionActivationStore(t, db)
	root := seedProductionPromotablePool(t, store)
	ctx := context.Background()

	_, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID})
	if !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("PromotePool without on-call err=%v, want ErrOnCallReadiness", err)
	}
	upsertSignedOnCall(t, store, "op-oncall", "production")
	expireStoredOnCall(t, db, "production")
	if _, _, _, err := store.PromotePool(ctx, trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID}); !errors.Is(err, trustpool.ErrOnCallReadiness) {
		t.Fatalf("PromotePool with expired on-call err=%v, want ErrOnCallReadiness", err)
	}
	upsertSignedOnCall(t, store, "op-oncall-2", "production")

	// A caller-supplied class is ignored; the operator-approved class wins.
	state, committed, applied, err := store.PromotePool(ctx, trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID, RootCustodyClass: trustpool.RootCustodyClassOther})
	if err != nil || !applied {
		t.Fatalf("PromotePool: applied=%v err=%v", applied, err)
	}
	if committed.RootCustodyClass != trustpool.RootCustodyClassHSM || state.Pools[root.poolID].RootIssuer.CustodyClass != trustpool.RootCustodyClassHSM {
		t.Fatalf("custody class event=%q root=%q, want hsm", committed.RootCustodyClass, state.Pools[root.poolID].RootIssuer.CustodyClass)
	}
	again, againCommitted, againApplied, err := store.PromotePool(ctx, trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID, TimestampUTC: committed.TimestampUTC})
	if err != nil || againApplied || againCommitted.RootCustodyClass != trustpool.RootCustodyClassHSM || again.Revision != state.Revision {
		t.Fatalf("idempotent retry applied=%v class=%q err=%v", againApplied, againCommitted.RootCustodyClass, err)
	}
	restarted, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore restart: %v", err)
	}
	replayed, err := restarted.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if got := replayed.Pools[root.poolID].RootIssuer.CustodyClass; got != trustpool.RootCustodyClassHSM {
		t.Fatalf("replayed custody class=%q, want hsm", got)
	}
}

func TestProductionActivationGate_RequiresApprovedCustodyClass(t *testing.T) {
	t.Parallel()
	hash := hexDigest("custody")
	for name, classes := range map[string]map[string]string{
		"missing":    nil,
		"software":   {hash: trustpool.RootCustodyClassSoftware},
		"unknown":    {hash: "vault"},
		"extra hash": {hash: trustpool.RootCustodyClassHSM, strings.Repeat("c", 64): trustpool.RootCustodyClassMPC},
	} {
		_, err := trustpool.NewStore(openTrustPoolDB(t), trustpool.WithProductionActivationGate(trustpool.ProductionActivationGate{
			AllowedLaunchEnvironments: []string{"production"},
			RootCustodyHashes:         []string{hash},
			RootCustodyClasses:        classes,
			EvidenceSHA256:            strings.Repeat("b", 64),
		}))
		if !errors.Is(err, trustpool.ErrPromotionPreconditionFailed) {
			t.Fatalf("%s: NewStore err=%v, want ErrPromotionPreconditionFailed", name, err)
		}
	}
}

func TestValidateEvent_RejectsCallerSuppliedCustodyClass(t *testing.T) {
	t.Parallel()
	store, err := trustpool.NewStore(openTrustPoolDB(t))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	root := seedCandidatePromotablePool(t, store)
	admit := ev("op-member-b", time.Unix(1800001000, 0).UTC(), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-b"
		e.RootCustodyClass = trustpool.RootCustodyClassHSM
	})
	if _, _, _, err := store.AppendValidatedEvent(context.Background(), admit); err == nil || !strings.Contains(err.Error(), "root_custody_class") {
		t.Fatalf("AppendValidatedEvent err=%v, want root_custody_class rejection", err)
	}
}
