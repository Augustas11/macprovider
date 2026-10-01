package trustpool_test

import (
	"context"
	"database/sql"
	"fmt"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// #1816 VM acceptance A-8: every pool buyer request and every registry
// refresh replays the durable history, and each manifest_accepted snapshot
// carries the whole policy history, so replay re-verified O(N^2) policy
// signatures while holding the single SQLite connection (the coordinator
// spun a core and listings timed out). A replay of an unchanged history
// now verifies nothing again; a new core verifies once.
func TestReconstructVerifiesEachAcceptedManifestOnce(t *testing.T) {
	ctx := context.Background()
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "coordinator.db")))
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
	if err != nil {
		t.Fatal(err)
	}
	ts := time.Unix(1800040000, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	v := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.SettlementMode = "enforce"
	})
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v)
	const cores = 24
	for i := 2; i <= cores; i++ {
		v = signedManifestExtendingWithPolicyCoreMutation(t, fmt.Sprintf("op-manifest-%d", i), ts.Add(time.Duration(i+2)*time.Second), v, root, withPoolModels(root.poolID, nil))
		appendTrustPoolEvents(t, ctx, store, v)
	}
	if _, err := store.Reconstruct(ctx); err != nil {
		t.Fatal(err)
	}
	before := trustpool.ManifestVerificationsForTest()
	for i := 0; i < 5; i++ {
		state, err := store.Reconstruct(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if got := state.Pools[root.poolID].ManifestVersion; got != cores {
			t.Fatalf("replayed manifest version %d, want %d", got, cores)
		}
	}
	if n := trustpool.ManifestVerificationsForTest() - before; n != 0 {
		t.Fatalf("5 replays of an unchanged %d-core history re-verified %d manifests, want 0", cores, n)
	}
	next := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-next", ts.Add(time.Minute), v, root, withPoolModels(root.poolID, nil))
	appendTrustPoolEvents(t, ctx, store, next)
	before = trustpool.ManifestVerificationsForTest()
	if _, err := store.Reconstruct(ctx); err != nil {
		t.Fatal(err)
	}
	if n := trustpool.ManifestVerificationsForTest() - before; n != 0 {
		// The append already verified the new core once.
		t.Fatalf("replay after one new core re-verified %d manifests, want 0", n)
	}
}
