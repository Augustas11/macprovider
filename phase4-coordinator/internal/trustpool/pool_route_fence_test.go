package trustpool_test

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-042-R015 (last paragraph) / SPEC-047-R011 / SPEC-022-R013 (#1816 F2):
// the durable route fence lets an in-flight attempt settle from its route
// snapshot across ordinary rotation and entry removal, and fails it only on
// a membership, delegation, attestation, or pool revocation after routing,
// for every pool route kind: a #1690 catalog loopback member, a pool-model
// loopback member (creator-owned and R016-attested), and a native pool-model
// member.
func TestPoolRouteFenceAcrossRotationAndRevocation(t *testing.T) {
	t.Parallel()
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	type mid func(t *testing.T, ctx context.Context, f *poolRouteFenceFixture)
	extend := func(mutate func(*poolmanifest.PolicyCore, string)) mid {
		return func(t *testing.T, ctx context.Context, f *poolRouteFenceFixture) {
			v3 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-3", f.ts.Add(10*time.Second), f.v2, f.root, func(core *poolmanifest.PolicyCore) {
				mutate(core, f.root.poolID)
			})
			insertPromotedEvent(t, ctx, f.db, v3)
		}
	}
	event := func(op, typ string, mutate func(*trustpool.DurableEvent)) mid {
		return func(t *testing.T, ctx context.Context, f *poolRouteFenceFixture) {
			insertPromotedEvent(t, ctx, f.db, ev(op, f.ts.Add(10*time.Second), typ, f.root.poolID, mutate))
		}
	}
	// want: catalog loopback (provider-a), pool-model owned (provider-a),
	// pool-model attested (provider-d), native pool-model (provider-d).
	for name, tc := range map[string]struct {
		midFlight mid
		want      [4]bool
	}{
		"nothing changed":        {func(*testing.T, context.Context, *poolRouteFenceFixture) {}, [4]bool{true, true, true, true}},
		"rotation, entries kept": {extend(func(*poolmanifest.PolicyCore, string) {}), [4]bool{true, true, true, true}},
		"rotation removes every entry": {extend(func(core *poolmanifest.PolicyCore, _ string) {
			if err := core.SetPoolExtensions(nil, members); err != nil {
				t.Fatal(err)
			}
		}), [4]bool{true, true, true, true}},
		"rotation removes the member attestation": {extend(func(core *poolmanifest.PolicyCore, poolID string) {
			if err := core.SetPoolExtensions(poolEntriesFor(poolID), nil); err != nil {
				t.Fatal(err)
			}
		}), [4]bool{true, true, false, true}},
		"provider-a membership revoked": {event("op-revoke-a", trustpool.EventMemberRevoked, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }),
			[4]bool{false, false, true, true}},
		"provider-d delegation revoked": {event("op-revoke-d", trustpool.EventDelegationRevoked, func(e *trustpool.DurableEvent) {
			e.ProviderID = "provider-d"
			e.DelegationID = "delegation-1"
		}), [4]bool{true, true, false, false}},
		"provider-d revoked immediately": {event("op-revoke-d", trustpool.EventMemberRevoked, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-d" }),
			[4]bool{true, true, false, false}},
		"pool retired": {event("op-retire", trustpool.EventLifecycleChanged, func(e *trustpool.DurableEvent) { e.Lifecycle = trustpool.LifecycleRetired }),
			[4]bool{false, false, false, false}},
		"other pool's revocation": {func(t *testing.T, ctx context.Context, f *poolRouteFenceFixture) {
			insertPromotedEvent(t, ctx, f.db, ev("op-revoke-other", f.ts.Add(10*time.Second), trustpool.EventMemberRevoked, "pool-other", func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }))
		}, [4]bool{true, true, true, true}},
	} {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			f := newPoolRouteFenceFixture(t, ctx, members)
			claims := f.claims()
			for i, c := range claims {
				if err := f.fenceHolds(ctx, c); err != nil {
					t.Fatalf("claim %d before the mid-flight change: %v", i, err)
				}
			}
			tc.midFlight(t, ctx, f)
			for i, c := range claims {
				err := f.fenceHolds(ctx, c)
				if tc.want[i] && err != nil {
					t.Errorf("claim %d: fence failed: %v", i, err)
				}
				if !tc.want[i] && !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
					t.Errorf("claim %d: err=%v, want ErrPoolOperatorAttestation", i, err)
				}
			}
		})
	}
}

// #1816 freeze R1 SECURITY H5: a later core that drops an R016 attestation
// revokes the member's in-flight routes only once it takes effect. A creator
// that pre-accepts a future-dated core cannot zero-bill traffic that routes,
// legitimately, under the core active at route time before that core starts.
func TestPoolRouteFenceIgnoresFutureDatedAttestationRemoval(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	f := newPoolRouteFenceFixture(t, ctx, members)
	var notBefore uint64
	v3 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-3", f.ts.Add(10*time.Second), f.v2, f.root, func(core *poolmanifest.PolicyCore) {
		if err := core.SetPoolExtensions(poolEntriesFor(f.root.poolID), nil); err != nil {
			t.Fatal(err)
		}
		notBefore = core.NotBeforeUnix
	})
	insertPromotedEvent(t, ctx, f.db, v3)
	attested := f.claims()[2]
	// The pre-accepted v3 is not yet in effect: v2 still attests the member.
	f.clock = time.Unix(int64(notBefore)-1, 0).UTC()
	if err := f.fenceHolds(ctx, attested); err != nil {
		t.Fatalf("future-dated attestation removal revoked an in-flight route: %v", err)
	}
	// Once v3 takes effect the removal is a revocation since routing.
	f.clock = time.Unix(int64(notBefore), 0).UTC()
	if err := f.fenceHolds(ctx, attested); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
		t.Fatalf("attestation removal in effect: err=%v, want ErrPoolOperatorAttestation", err)
	}
}

// #1816 freeze R1 CODE H1: the fence reads only the claim's pool. A
// malformed event of another pool (which a global-log replay would decode
// and fail on) is never visited.
func TestPoolRouteFenceReadsOnlyTheClaimPool(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	f := newPoolRouteFenceFixture(t, ctx, members)
	if _, err := f.db.ExecContext(ctx, `INSERT INTO trustpool_events (operation_id, ts_utc, event_type, pool_id, manifest_version, payload_json) VALUES ('op-junk', '2026-01-01T00:00:00Z', 'member_revoked', 'pool-unrelated', 0, '{not json')`); err != nil {
		t.Fatalf("insert unrelated malformed event: %v", err)
	}
	for i, c := range f.claims() {
		if err := f.fenceHolds(ctx, c); err != nil {
			t.Fatalf("claim %d: fence visited an unrelated pool's event: %v", i, err)
		}
	}
}

// #1816 freeze R1 SECURITY H2: a pool_manifest claim holds only when the
// accepted core it names carries its exact entry.
func TestPoolRouteFenceRequiresTheExactPoolManifestEntry(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	members := []poolmanifest.AttestedMember{{ProviderAccountID: "acct-member-d", RuntimeClasses: []string{poolmanifest.RuntimeSourceLlamacppLoopback}}}
	f := newPoolRouteFenceFixture(t, ctx, members)
	native := f.claims()[3]
	forged := native
	forged.ExpectedModelHash = poolEntryGGUFHash
	if err := f.fenceHolds(ctx, forged); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
		t.Fatalf("forged entry pair: err=%v, want ErrPoolOperatorAttestation", err)
	}
	unknown := native
	unknown.PoolModelID = "pool/" + f.root.poolID + "/not-an-entry"
	if err := f.fenceHolds(ctx, unknown); !errors.Is(err, trustpool.ErrPoolOperatorAttestation) {
		t.Fatalf("unknown entry: err=%v, want ErrPoolOperatorAttestation", err)
	}
}

type poolRouteFenceFixture struct {
	clock time.Time
	ts    time.Time
	root  rootFixture
	v2    trustpool.DurableEvent
	db    *sql.DB
	store *trustpool.Store
}

// newPoolRouteFenceFixture records: 1 create, 2 root, 3 v1, 4 v2 (pool
// entries and an R016 attestation of acct-member-d), 5 provider-a admitted
// creator-owned, 6 provider-d admitted through a delegation. Every claim is
// routed at generation 6.
func newPoolRouteFenceFixture(t *testing.T, ctx context.Context, members []poolmanifest.AttestedMember) *poolRouteFenceFixture {
	t.Helper()
	db := openTrustPoolDB(t)
	// The fence clock defaults to after every core the fixtures accept, so
	// a later core is in effect unless a test moves the clock back.
	f := &poolRouteFenceFixture{clock: time.Unix(1<<50, 0).UTC()}
	store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(acceptAllPoolModels),
		trustpool.WithClock(func() time.Time { return f.clock }))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800030000, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.SettlementMode = "enforce"
	})
	v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), v1, root, withPoolModels(root.poolID, members))
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v1,
		v2,
		ev("op-member-owned", ts.Add(4*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) { e.ProviderID = "provider-a" }),
	)
	// The routing projection carries the core before the active one (F3).
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	raw, err := base64.StdEncoding.DecodeString(v2.ManifestSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	parsed, err := poolmanifest.ParseManifestSnapshot(raw)
	if err != nil {
		t.Fatal(err)
	}
	// Route at an instant inside v2's validity window, so v2 is active.
	state.RouteGateCheckedAt = time.Unix(int64(parsed.Policies[len(parsed.Policies)-1].SignedCore.Core.NotBeforeUnix), 0).UTC()
	for _, snap := range state.RouteableSnapshots() {
		if snap.PoolID == root.poolID && (snap.PriorManifestVersion != 1 || snap.PriorManifestCoreDigest != v1.ManifestCoreDigest || len(snap.PriorModelEntries) != 0 || snap.ManifestVersion != 2) {
			t.Fatalf("prior generation projection = %d %s %d", snap.PriorManifestVersion, snap.PriorManifestCoreDigest, len(snap.PriorModelEntries))
		}
	}
	insertPromotedEvent(t, ctx, db, ev("op-member-delegated", ts.Add(5*time.Second), trustpool.EventMemberAdmitted, root.poolID, func(e *trustpool.DurableEvent) {
		e.ProviderID = "provider-d"
		e.DelegationID = "delegation-1"
	}))
	f.ts, f.root, f.v2, f.db, f.store = ts, root, v2, db, store
	return f
}

// claims are the four route kinds, in the order of the test's want arrays.
func (f *poolRouteFenceFixture) claims() [4]billing.PoolOperatorAttestationClaim {
	base := billing.PoolOperatorAttestationClaim{
		PoolID: f.root.poolID, ManifestVersion: 2, ManifestCoreDigest: f.v2.ManifestCoreDigest, PoolGeneration: 6,
		PoolOperatorAccountID: "creator-a", RuntimeSource: poolmanifest.RuntimeSourceLlamacppLoopback, ProviderID: "provider-a",
	}
	catalog := base
	owned := base
	owned.ExpectedModelHashSource = billing.ExpectedModelHashSourcePoolManifest
	owned.PoolModelID = "pool/" + f.root.poolID + "/creator-gguf"
	owned.ExpectedModelHashAlgorithm, owned.ExpectedModelHash = poolmanifest.ArtifactHashAlgorithmGGUFFileV1, poolEntryGGUFHash
	attested := owned
	attested.ProviderID, attested.PoolMemberAccountID = "provider-d", "acct-member-d"
	native := billing.PoolOperatorAttestationClaim{
		PoolID: f.root.poolID, ManifestVersion: 2, ManifestCoreDigest: f.v2.ManifestCoreDigest, PoolGeneration: 6, ProviderID: "provider-d",
		ExpectedModelHashSource:    billing.ExpectedModelHashSourcePoolManifest,
		PoolModelID:                "pool/" + f.root.poolID + "/creator-mlx",
		ExpectedModelHashAlgorithm: poolmanifest.ArtifactHashAlgorithmSnapshotManifestV1, ExpectedModelHash: poolEntrySnapshotHash,
	}
	return [4]billing.PoolOperatorAttestationClaim{catalog, owned, attested, native}
}

func (f *poolRouteFenceFixture) fenceHolds(ctx context.Context, claim billing.PoolOperatorAttestationClaim) error {
	tx, err := f.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	return f.store.PoolRouteFenceHolds(ctx, tx, claim)
}

// #1816 F3: the registry reports, at load time, a newly active accepted
// generation (never a reload of the same one) and carries the prior core's
// entries for route-time rebind tolerance.
func TestRegistryManifestActivationHookAndPriorGeneration(t *testing.T) {
	t.Parallel()
	registry := trustpool.NewRegistry()
	fired := 0
	registry.SetManifestActivationHook(func() { fired++ })
	entries := poolEntriesFor("QpsclmzwdJaWJTk3zowcXQ")
	snap := trustpool.RouteableSnapshot{
		PoolID: "QpsclmzwdJaWJTk3zowcXQ", CreatorAccountID: "creator-a", Members: []string{"provider-a"},
		SettlementMode: "enforce", Routeable: true, Generation: 3, RouteableUntilUTC: time.Now().Add(time.Hour),
		ManifestVersion: 1, ManifestCoreDigest: hexDigest("v1"), ModelEntries: entries,
	}
	if err := registry.LoadRouteableSnapshotsAtRevision(1, []trustpool.RouteableSnapshot{snap}); err != nil {
		t.Fatal(err)
	}
	if fired != 1 {
		t.Fatalf("hook fired %d times on the first active generation, want 1", fired)
	}
	same := snap
	same.Generation = 4
	if err := registry.LoadRouteableSnapshotsAtRevision(2, []trustpool.RouteableSnapshot{same}); err != nil {
		t.Fatal(err)
	}
	if fired != 1 {
		t.Fatalf("hook fired on a reload of the same generation (%d)", fired)
	}
	next := same
	next.ManifestVersion, next.ManifestCoreDigest = 2, hexDigest("v2")
	next.PriorManifestVersion, next.PriorManifestCoreDigest, next.PriorModelEntries = 1, hexDigest("v1"), entries
	if err := registry.LoadRouteableSnapshotsAtRevision(3, []trustpool.RouteableSnapshot{next}); err != nil {
		t.Fatal(err)
	}
	if fired != 2 {
		t.Fatalf("hook fired %d times after a new generation, want 2", fired)
	}
	view := registry.Snapshot(snap.PoolID)
	if view.PriorManifestVersion != 1 || view.PriorManifestCoreDigest != hexDigest("v1") || len(view.PriorModelEntries) != len(entries) {
		t.Fatalf("prior generation view = %d %s %d", view.PriorManifestVersion, view.PriorManifestCoreDigest, len(view.PriorModelEntries))
	}
}
