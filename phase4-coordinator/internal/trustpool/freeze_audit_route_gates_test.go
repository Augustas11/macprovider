package trustpool_test

import (
	"context"
	"database/sql"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// Freeze audit R1 (#1690) SECURITY H2/H3: an active production pool stays
// routeable only while the CURRENT production activation gate and the CURRENT
// on-call readiness of its launch environment hold, on every publication path.

func promotedProductionPool(t *testing.T) (*trustpool.Store, rootFixture, *trustpool.ReconstructedState, *sql.DB) {
	t.Helper()
	db := openTrustPoolDB(t)
	store := newProductionActivationStore(t, db)
	root := seedProductionPromotablePool(t, store)
	upsertSignedOnCall(t, store, "op-oncall", "production")
	state, _, applied, err := store.PromotePool(context.Background(), trustpool.DurableEvent{OperationID: "op-promote", PoolID: root.poolID})
	if err != nil || !applied {
		t.Fatalf("PromotePool applied=%v err=%v", applied, err)
	}
	return store, root, state, db
}

func routeableFor(t *testing.T, state *trustpool.ReconstructedState, poolID string) trustpool.RouteableSnapshot {
	t.Helper()
	for _, snap := range state.RouteableSnapshots() {
		if snap.PoolID == poolID {
			return snap
		}
	}
	t.Fatalf("pool %s missing from routeable snapshots", poolID)
	return trustpool.RouteableSnapshot{}
}

func TestProductionPoolStopsRoutingWhenOnCallReadinessLapses(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	store, root, promoted, db := promotedProductionPool(t)
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	snap := routeableFor(t, state, root.poolID)
	if !snap.Routeable || len(snap.Members) == 0 {
		t.Fatalf("promoted production pool with current on-call must route: %+v", snap)
	}
	if snap.RouteableUntilUTC.IsZero() || snap.RouteableUntilUTC.After(time.Now().Add(91*24*time.Hour)) {
		t.Fatalf("routeable_until must carry the on-call expiry deadline, got %v", snap.RouteableUntilUTC)
	}
	expireStoredOnCall(t, db, "production")
	state, err = store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct after expiry: %v", err)
	}
	snap = routeableFor(t, state, root.poolID)
	if snap.Routeable || len(snap.Members) != 0 || state.Pools[root.poolID].ProductionGateReason != "oncall_readiness_expired" {
		t.Fatalf("expired on-call must stop routing: snap=%+v reason=%q", snap, state.Pools[root.poolID].ProductionGateReason)
	}
	// The refresher publishes the same verdict to the live registry.
	registry, err := promoted.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	if _, err := trustpool.RefreshRegistry(ctx, store, registry); err != nil {
		t.Fatalf("RefreshRegistry: %v", err)
	}
	if registry.Snapshot(root.poolID).Routeable {
		t.Fatal("registry kept routing a pool whose on-call readiness lapsed")
	}
	// Admin publication of a state produced before the lapse re-checks too.
	if err := store.ApplyRouteGates(ctx, promoted); err != nil {
		t.Fatalf("ApplyRouteGates: %v", err)
	}
	if routeableFor(t, promoted, root.poolID).Routeable {
		t.Fatal("ApplyRouteGates left a lapsed pool routeable")
	}
}

func TestProductionPoolStopsRoutingWhenCurrentGateNoLongerApprovesIt(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	_, root, _, db := promotedProductionPool(t)
	for name, gate := range map[string]*trustpool.ProductionActivationGate{
		"custody hash removed": {
			AllowedLaunchEnvironments: []string{"production"},
			RootCustodyHashes:         []string{strings.Repeat("c", 64)},
			RootCustodyClasses:        map[string]string{strings.Repeat("c", 64): trustpool.RootCustodyClassHSM},
			EvidenceSHA256:            strings.Repeat("b", 64),
		},
		"custody class unmapped": {
			AllowedLaunchEnvironments: []string{"production"},
			RootCustodyHashes:         []string{hexDigest("custody")},
			EvidenceSHA256:            strings.Repeat("b", 64),
		},
		"environment removed": {
			AllowedLaunchEnvironments: []string{"staging"},
			RootCustodyHashes:         []string{hexDigest("custody")},
			RootCustodyClasses:        map[string]string{hexDigest("custody"): trustpool.RootCustodyClassHSM},
			EvidenceSHA256:            strings.Repeat("b", 64),
		},
		"gate disabled": nil,
	} {
		opts := []trustpool.StoreOption{}
		if gate != nil {
			opts = append(opts, trustpool.WithProductionActivationGate(*gate))
		}
		restarted, err := trustpool.NewStore(db, opts...)
		if err != nil {
			t.Fatalf("%s: NewStore: %v", name, err)
		}
		state, err := restarted.Reconstruct(ctx)
		if err != nil {
			t.Fatalf("%s: Reconstruct: %v", name, err)
		}
		if snap := routeableFor(t, state, root.poolID); snap.Routeable || len(snap.Members) != 0 {
			t.Fatalf("%s: replayed active pool must be revalidated against the current gate: %+v reason=%q", name, snap, state.Pools[root.poolID].ProductionGateReason)
		}
		if state.Pools[root.poolID].Lifecycle != trustpool.LifecycleActive {
			t.Fatalf("%s: gating must not rewrite the durable lifecycle", name)
		}
	}
}
