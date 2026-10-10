package trustpool_test

import (
	"context"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-047-R012: the licence of a counted attempt comes from the accepted core
// that authorized it, replayed from the durable log; a core without entries
// (v1, or v2 before the extension) carries none.
func TestAcceptedPoolModelEntriesReplaysEveryAcceptedCore(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(acceptAllPoolModels))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800030000, 0).UTC()
	root := newRootFixture(t)
	approveCreator(t, store, "creator-a", "approval-v1", "approval-version-1", "candidate", time.Now().Add(24*time.Hour), trustpool.CreatorStatusEnabled)
	v1 := signedManifestWithPolicyCoreMutation(t, "op-manifest", ts.Add(2*time.Second), root.poolID, 1, root, func(core *poolmanifest.PolicyCore) {
		core.SettlementMode = "enforce"
	})
	v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-2", ts.Add(3*time.Second), v1, root, withPoolModels(root.poolID, nil))
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v1,
		v2,
	)
	cores, err := trustpool.AcceptedPoolModelEntries(ctx, db, root.poolID)
	if err != nil {
		t.Fatalf("AcceptedPoolModelEntries: %v", err)
	}
	entries := cores[trustpool.AcceptedCoreKey{ManifestVersion: 2, ManifestCoreDigest: v2.ManifestCoreDigest}]
	if len(entries) != 2 || entries[0].License != "Apache-2.0" || !entries[0].PaidServingAttested || entries[1].License != "MIT" {
		t.Fatalf("v2 entries = %+v", entries)
	}
	if len(cores[trustpool.AcceptedCoreKey{ManifestVersion: 1, ManifestCoreDigest: v1.ManifestCoreDigest}]) != 0 {
		t.Fatalf("v1 core carries entries: %+v", cores)
	}
	if other, err := trustpool.AcceptedPoolModelEntries(ctx, db, "AAAAAAAAAAAAAAAAAAAAAA"); err != nil || len(other) != 0 {
		t.Fatalf("unknown pool = %+v err=%v", other, err)
	}
}
