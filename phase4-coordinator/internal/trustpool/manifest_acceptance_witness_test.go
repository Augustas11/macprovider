package trustpool_test

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func TestBootstrapManifestAcceptanceWitness_EmptyDB(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	if _, err := trustpool.NewStore(db); err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	witnessPath := filepath.Join(t.TempDir(), "witness.json")
	pools, err := trustpool.BootstrapManifestAcceptanceWitness(ctx, db, witnessPath)
	if err != nil {
		t.Fatalf("BootstrapManifestAcceptanceWitness: %v", err)
	}
	if len(pools) != 0 {
		t.Fatalf("pools=%d, want 0", len(pools))
	}
	info, err := os.Stat(witnessPath)
	if err != nil {
		t.Fatalf("stat witness: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("witness mode=%v, want 0600", info.Mode().Perm())
	}
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err != nil {
		t.Fatalf("NewStore with bootstrapped witness: %v", err)
	}
}

func TestBootstrapManifestAcceptanceWitness_ExistingHighWaterLetsStoreStart(t *testing.T) {
	t.Parallel()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(1800000700, 0).UTC()
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
	witnessPath := filepath.Join(t.TempDir(), "witness.json")
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err == nil {
		t.Fatalf("NewStore without bootstrap succeeded; want missing-witness failure")
	}
	pools, err := trustpool.BootstrapManifestAcceptanceWitness(ctx, db, witnessPath)
	if err != nil {
		t.Fatalf("BootstrapManifestAcceptanceWitness: %v", err)
	}
	if len(pools) != 1 || pools[0].PoolID != root.poolID || pools[0].ManifestVersion != 1 || pools[0].ManifestCoreDigest != manifest.ManifestCoreDigest {
		t.Fatalf("pools=%+v, want %s v1", pools, root.poolID)
	}
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err != nil {
		t.Fatalf("NewStore with bootstrapped witness: %v", err)
	}
}

func TestBootstrapManifestAcceptanceWitness_RefusesExistingFile(t *testing.T) {
	t.Parallel()
	db := openTrustPoolDB(t)
	if _, err := trustpool.NewStore(db); err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	witnessPath := filepath.Join(t.TempDir(), "witness.json")
	if err := os.WriteFile(witnessPath, []byte("keep"), 0o600); err != nil {
		t.Fatalf("write existing: %v", err)
	}
	if _, err := trustpool.BootstrapManifestAcceptanceWitness(context.Background(), db, witnessPath); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("err=%v, want already exists", err)
	}
	raw, err := os.ReadFile(witnessPath)
	if err != nil || string(raw) != "keep" {
		t.Fatalf("existing witness changed: %q err=%v", raw, err)
	}
}

func TestBootstrapManifestAcceptanceWitness_RefusesRelativePath(t *testing.T) {
	t.Parallel()
	db := openTrustPoolDB(t)
	if _, err := trustpool.NewStore(db); err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	if _, err := trustpool.BootstrapManifestAcceptanceWitness(context.Background(), db, "witness.json"); err == nil || !strings.Contains(err.Error(), "must be absolute") {
		t.Fatalf("err=%v, want must be absolute", err)
	}
	if _, err := os.Stat("witness.json"); !os.IsNotExist(err) {
		t.Fatalf("relative witness written: %v", err)
	}
}

// acceptV1WithWitness returns a store with the witness enabled, v1 accepted,
// and an unaccepted v2 extending it.
func acceptV1WithWitness(t *testing.T, opBase int64) (*sql.DB, *trustpool.Store, string, string, trustpool.DurableEvent) {
	t.Helper()
	ctx := context.Background()
	db := openTrustPoolDB(t)
	witnessPath := filepath.Join(t.TempDir(), "witness.json")
	store, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	ts := time.Unix(opBase, 0).UTC()
	root := newRootFixture(t)
	v1 := signedManifest(t, "op-manifest-v1", ts.Add(2*time.Second), root.poolID, 1, root)
	v2 := signedManifestExtendingWithPolicyCoreMutation(t, "op-manifest-v2", ts.Add(3*time.Second), v1, root, nil)
	appendTrustPoolEvents(t, ctx, store,
		ev("op-create", ts, trustpool.EventPoolCreated, root.poolID, func(e *trustpool.DurableEvent) {
			e.CreatorAccountID = "creator-a"
			e.ApprovalRecordID = "approval-v1"
		}),
		signedRootRegistrationForIssue(t, "op-root", ts.Add(time.Second), root.poolID, "creator-a", "approval-v1", issueRootNonce(t, store, "creator-a", "approval-v1", ts.Add(time.Hour)), root),
		v1,
	)
	return db, store, witnessPath, root.poolID, v2
}

func highWaterVersion(t *testing.T, db *sql.DB, poolID string) uint64 {
	t.Helper()
	var v uint64
	if err := db.QueryRow(`SELECT manifest_version FROM trustpool_manifest_acceptance_high_water WHERE pool_id = ?`, poolID).Scan(&v); err != nil {
		t.Fatalf("query high-water: %v", err)
	}
	return v
}

// Not parallel: installs a package-level test seam.
func TestDurableStore_ManifestAcceptanceWitnessUnchangedWhenCommitFails(t *testing.T) {
	ctx := context.Background()
	db, store, witnessPath, poolID, v2 := acceptV1WithWitness(t, 1800000710)
	before, err := os.ReadFile(witnessPath)
	if err != nil {
		t.Fatalf("read v1 witness: %v", err)
	}
	injected := errors.New("injected commit failure")
	restore := trustpool.SetBeforeManifestAcceptanceCommitForTest(func() error { return injected })
	_, _, _, err = store.AppendValidatedEvent(ctx, v2)
	restore()
	if !errors.Is(err, injected) {
		t.Fatalf("append err=%v, want injected failure", err)
	}
	after, err := os.ReadFile(witnessPath)
	if err != nil || string(after) != string(before) {
		t.Fatalf("witness changed by a rolled-back acceptance: err=%v\n%s", err, after)
	}
	if v := highWaterVersion(t, db, poolID); v != 1 {
		t.Fatalf("high-water=%d, want 1 after rollback", v)
	}
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err != nil {
		t.Fatalf("NewStore after rolled-back acceptance: %v", err)
	}
}

// Not parallel: installs a package-level test seam.
func TestDurableStore_ManifestAcceptanceWitnessPublishFailureAfterCommitRecoversAtStartup(t *testing.T) {
	ctx := context.Background()
	db, store, witnessPath, poolID, v2 := acceptV1WithWitness(t, 1800000720)
	restore := trustpool.SetPublishManifestAcceptanceWitnessForTest(func(string, map[string]trustpool.ManifestAcceptanceProjection) error {
		return errors.New("injected publish failure")
	})
	_, committed, applied, err := store.AppendValidatedEvent(ctx, v2)
	restore()
	if !errors.Is(err, trustpool.ErrManifestAcceptanceWitnessPublish) || errors.Is(err, trustpool.ErrMalformedDurableEvent) {
		t.Fatalf("append err=%v, want ErrManifestAcceptanceWitnessPublish only", err)
	}
	if !applied || committed.OperationID != v2.OperationID {
		t.Fatalf("applied=%v committed=%q, want v2 committed", applied, committed.OperationID)
	}
	if v := highWaterVersion(t, db, poolID); v != 2 {
		t.Fatalf("high-water=%d, want 2 committed", v)
	}
	raw, err := os.ReadFile(witnessPath)
	if err != nil || !strings.Contains(string(raw), `"manifest_version": 1`) {
		t.Fatalf("witness should still be v1 (behind the DB): err=%v\n%s", err, raw)
	}
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err != nil {
		t.Fatalf("startup with witness behind the DB: %v", err)
	}
	raw, err = os.ReadFile(witnessPath)
	if err != nil || !strings.Contains(string(raw), `"manifest_version": 2`) {
		t.Fatalf("startup did not advance the witness to v2: err=%v\n%s", err, raw)
	}
}
