package trustpool_test

import (
	"context"
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
