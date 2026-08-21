package trustpool_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"path/filepath"
	"testing"
	"time"

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
	prefix := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-manifest", ts.Add(time.Second), trustpool.EventManifestAccepted, "pool-a", func(e *trustpool.DurableEvent) {
			e.ManifestVersion = 1
			e.ManifestCoreDigest = "digest-a"
		}),
	}
	for _, e := range prefix {
		if _, _, _, err := store.AppendValidatedEvent(ctx, e); err != nil {
			t.Fatalf("AppendValidatedEvent(%s): %v", e.OperationID, err)
		}
	}
	active := ev("op-active", ts.Add(2*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
		e.Lifecycle = trustpool.LifecycleActive
	})
	if _, _, _, err := store.AppendValidatedEvent(ctx, active); !errors.Is(err, trustpool.ErrActivationRequiresPromotion) {
		t.Fatalf("raw activation append error = %v, want ErrActivationRequiresPromotion", err)
	}
	reconstructed, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	if got := reconstructed.Pools["pool-a"].Lifecycle; got != trustpool.LifecycleCreated {
		t.Fatalf("lifecycle after rejected activation = %q, want created", got)
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
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-manifest", ts.Add(time.Second), trustpool.EventManifestAccepted, "pool-a", func(e *trustpool.DurableEvent) {
			e.ManifestVersion = 1
			e.ManifestCoreDigest = "digest-a"
		}),
		ev("op-floor", ts.Add(2*time.Second), trustpool.EventMinBinaryVersionSet, "pool-a", func(e *trustpool.DurableEvent) {
			e.MinBinaryVersion = "1.8.33"
		}),
		ev("op-member-a", ts.Add(3*time.Second), trustpool.EventMemberAdmitted, "pool-a", func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-member-b", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, "pool-a", func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-revoke-b", ts.Add(5*time.Second), trustpool.EventMemberRevoked, "pool-a", func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-b"
		}),
		ev("op-buyer", ts.Add(6*time.Second), trustpool.EventBuyerAuthorized, "pool-a", func(e *trustpool.DurableEvent) {
			e.BuyerAccountID = "acct-a"
		}),
		ev("op-active", ts.Add(7*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
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
	poolState := reconstructed.Pools["pool-a"]
	if poolState == nil {
		t.Fatal("pool-a missing after replay")
	}
	if poolState.CreatorAccountID != "creator-a" || poolState.ManifestVersion != 1 || poolState.ManifestCoreDigest != "digest-a" {
		t.Fatalf("unexpected admin state: %+v", poolState)
	}
	if !poolState.BuyerAccounts["acct-a"] {
		t.Fatalf("buyer authorization not replayed: %+v", poolState.BuyerAccounts)
	}

	registry, err := reconstructed.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot("pool-a")
	if !snap.Exists {
		t.Fatal("pool-a should exist in registry")
	}
	if !snap.Members["provider-a"] || snap.Members["provider-b"] {
		t.Fatalf("routeable members = %v, want only provider-a", snap.Members)
	}
	if snap.MinBinaryVersion != "1.8.33" {
		t.Fatalf("min floor = %q, want 1.8.33", snap.MinBinaryVersion)
	}
	if snap.Generation != uint64(len(events)) {
		t.Fatalf("generation = %d, want durable event count %d", snap.Generation, len(events))
	}
	if !registry.BuyerAuthorized("pool-a", "acct-a") {
		t.Fatal("acct-a should be authorized for pool-a after durable replay")
	}
	if registry.BuyerAuthorized("pool-a", "acct-other") {
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
	events := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, "pool-paused", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-member", ts.Add(time.Second), trustpool.EventMemberAdmitted, "pool-paused", func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-a"
		}),
		ev("op-manifest", ts.Add(2*time.Second), trustpool.EventManifestAccepted, "pool-paused", func(e *trustpool.DurableEvent) {
			e.ManifestVersion = 1
			e.ManifestCoreDigest = "digest-paused"
		}),
		ev("op-active", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, "pool-paused", func(e *trustpool.DurableEvent) {
			e.Lifecycle = trustpool.LifecycleActive
		}),
		ev("op-pause", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, "pool-paused", func(e *trustpool.DurableEvent) {
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
	if got := reconstructed.Pools["pool-paused"].Lifecycle; got != trustpool.LifecyclePaused {
		t.Fatalf("lifecycle = %q, want paused", got)
	}
	registry, err := reconstructed.BuildRegistry()
	if err != nil {
		t.Fatalf("BuildRegistry: %v", err)
	}
	snap := registry.Snapshot("pool-paused")
	if !snap.Exists {
		t.Fatal("paused pool should still exist so the coordinator can fail closed for selected pool traffic")
	}
	if snap.Routeable {
		t.Fatal("paused pool must be present but not routeable")
	}
	if len(snap.Members) != 0 {
		t.Fatalf("paused pool exposed routeable members: %v", snap.Members)
	}
	if snap.Generation != uint64(len(events)) {
		t.Fatalf("paused generation = %d, want %d", snap.Generation, len(events))
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
	prefix := func() []trustpool.DurableEvent {
		return []trustpool.DurableEvent{
			ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
				e.CreatorAccountID = "creator-a"
				e.ApprovalRecordID = "approval-v1"
			}),
			ev("op-manifest", ts.Add(time.Second), trustpool.EventManifestAccepted, "pool-a", func(e *trustpool.DurableEvent) {
				e.ManifestVersion = 1
				e.ManifestCoreDigest = "digest-a"
			}),
			ev("op-active", ts.Add(2*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
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
				ev("op-draining", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleDraining
				}),
				ev("op-reactivate", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleActive
				}),
			),
		},
		{
			name: "active cannot return to created",
			events: append(prefix(),
				ev("op-created-again", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleCreated
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
		{
			name: "paused cannot reactivate through raw lifecycle event",
			events: append(prefix(),
				ev("op-pause", ts.Add(3*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecyclePaused
				}),
				ev("op-reactivate", ts.Add(4*time.Second), trustpool.EventLifecycleChanged, "pool-a", func(e *trustpool.DurableEvent) {
					e.Lifecycle = trustpool.LifecycleActive
				}),
			),
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

func TestReconstructEvents_RejectsManifestAndFloorDowngrades(t *testing.T) {
	t.Parallel()
	ts := time.Unix(1800004200, 0).UTC()
	prefix := []trustpool.DurableEvent{
		ev("op-create", ts, trustpool.EventPoolCreated, "pool-a", func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		ev("op-manifest-2", ts.Add(time.Second), trustpool.EventManifestAccepted, "pool-a", func(e *trustpool.DurableEvent) {
			e.ManifestVersion = 2
			e.ManifestCoreDigest = "digest-v2"
		}),
		ev("op-floor-2", ts.Add(2*time.Second), trustpool.EventMinBinaryVersionSet, "pool-a", func(e *trustpool.DurableEvent) {
			e.MinBinaryVersion = "1.8.2"
		}),
	}
	tests := []struct {
		name  string
		event trustpool.DurableEvent
	}{
		{
			name: "manifest version cannot go backward",
			event: ev("op-manifest-1", ts.Add(3*time.Second), trustpool.EventManifestAccepted, "pool-a", func(e *trustpool.DurableEvent) {
				e.ManifestVersion = 1
				e.ManifestCoreDigest = "digest-v1"
			}),
		},
		{
			name: "binary floor cannot be lowered",
			event: ev("op-floor-low", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, "pool-a", func(e *trustpool.DurableEvent) {
				e.MinBinaryVersion = "1.8.1"
			}),
		},
		{
			name: "binary floor cannot be cleared",
			event: ev("op-floor-clear", ts.Add(3*time.Second), trustpool.EventMinBinaryVersionSet, "pool-a", func(e *trustpool.DurableEvent) {
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
		PoolID:     "pool-good",
		Members:    []string{"provider-a"},
		Generation: 9,
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshot good: %v", err)
	}
	err := registry.LoadRouteableSnapshots([]trustpool.RouteableSnapshot{
		{PoolID: "pool-new", Members: []string{"provider-b"}, Generation: 1},
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
		{PoolID: "pool-a", BuyerAccounts: []string{"acct-a"}, Routeable: true, Generation: 2},
	}); err != nil {
		t.Fatalf("LoadRouteableSnapshotsAtRevision fresh: %v", err)
	}
	if err := registry.LoadRouteableSnapshotsAtRevision(1, []trustpool.RouteableSnapshot{
		{PoolID: "pool-a", BuyerAccounts: []string{"acct-stale"}, Routeable: true, Generation: 1},
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
