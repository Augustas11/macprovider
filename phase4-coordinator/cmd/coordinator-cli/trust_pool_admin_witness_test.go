package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	_ "modernc.org/sqlite"
)

func writeWitnessInitConfig(t *testing.T, dir, dbPath, extra string) string {
	t.Helper()
	cfgPath := filepath.Join(dir, "coordinator.yaml")
	yaml := "auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nstorage:\n  db_path: " + quoteYAML(dbPath) + "\n" + extra
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	return cfgPath
}

func runWitnessInit(args ...string) (string, error) {
	var out bytes.Buffer
	err := trustPoolAdmin(append([]string{"manifest-witness-init"}, args...), func(string) string { return "" }, strings.NewReader(""), &out)
	return out.String(), err
}

func TestTrustPoolAdminManifestWitnessInitFlagValidation(t *testing.T) {
	dir := t.TempDir()
	cfgPath := writeWitnessInitConfig(t, dir, filepath.Join(dir, "absent.db"), "")
	relCfg := writeWitnessInitConfig(t, t.TempDir(), "coordinator.db", "")
	mismatchDir := t.TempDir()
	mismatchCfg := writeWitnessInitConfig(t, mismatchDir, filepath.Join(dir, "absent.db"), "trusted_pools:\n  manifest_acceptance_witness_path: /var/lib/macprovider/other.json\n")
	out := filepath.Join(dir, "w.json")
	cases := []struct {
		name string
		args []string
		want string
	}{
		{"free-form db refused", []string{"--db", filepath.Join(dir, "x.db"), "--config", cfgPath, "--out", out}, "flag provided but not defined: -db"},
		{"missing config", []string{"--out", out}, "--config is required"},
		{"missing out", []string{"--config", cfgPath}, "--out is required"},
		{"relative out", []string{"--config", cfgPath, "--out", "w.json"}, "--out must be an absolute path"},
		{"positional", []string{"--config", cfgPath, "--out", out, "extra"}, "unexpected positional arguments"},
		{"relative db_path", []string{"--config", relCfg, "--out", out}, "must be an absolute path to the coordinator DB"},
		{"out differs from config", []string{"--config", mismatchCfg, "--out", out}, "differs from trusted_pools.manifest_acceptance_witness_path"},
		{"missing db file", []string{"--config", cfgPath, "--out", out}, "absent.db\": stat"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := runWitnessInit(tc.args...); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("err=%v, want %q", err, tc.want)
			}
		})
	}
	if _, err := os.Stat(filepath.Join(dir, "absent.db")); !os.IsNotExist(err) {
		t.Fatalf("missing DB path was created: %v", err)
	}
	if _, err := os.Stat(out); !os.IsNotExist(err) {
		t.Fatalf("witness written on a failed run: %v", err)
	}
}

// acceptWitnessTestManifest drives a real pool through pool_created, root
// registration and a signed genesis manifest, leaving accepted high-water.
func acceptWitnessTestManifest(t *testing.T, store *trustpool.Store) (signFixture, trustpool.DurableEvent) {
	t.Helper()
	ctx := context.Background()
	f := newSignFixture(t)
	approveSignTestCreator(t, store, f)
	nonce, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID:            "m1-nonce-1",
		CreatorAccountID:       f.creator,
		ApprovalRecordID:       f.approval,
		CurrentApprovalVersion: "approval-version-1",
		LaunchEnvironment:      "candidate",
		Purpose:                trustpool.RootRegistrationPurposeDefault,
		ExpiresAtUTC:           f.now.Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce: %v", err)
	}
	create := trustpool.DurableEvent{OperationID: "m1-create-1", TimestampUTC: f.now, EventType: trustpool.EventPoolCreated,
		PoolID: f.poolID, CreatorAccountID: f.creator, ApprovalRecordID: f.approval}
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("append pool_created: %v", err)
	}
	var out bytes.Buffer
	rootOut := filepath.Join(f.dir, "root.json")
	if err := trustPoolAdmin(f.rootArgs(nonce.Nonce, nonce.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), rootOut), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-root: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, readSignedEvent(t, rootOut)); err != nil {
		t.Fatalf("append root_issuer_registered: %v", err)
	}
	manifestOut := filepath.Join(f.dir, "manifest-v1.json")
	notBefore := f.now.Add(-time.Minute).Truncate(time.Second)
	if err := trustPoolAdmin(f.manifestArgs("m1-manifest-1", manifestOut, notBefore, notBefore.Add(30*24*time.Hour)), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest: %v", err)
	}
	manifest := readSignedEvent(t, manifestOut)
	if _, _, _, err := store.AppendValidatedEvent(ctx, manifest); err != nil {
		t.Fatalf("append manifest_accepted: %v", err)
	}
	return f, manifest
}

func sha256File(t *testing.T, path string) [32]byte {
	t.Helper()
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return sha256.Sum256(raw)
}

func TestTrustPoolAdminManifestWitnessInitBootstrapsLiveWALDB(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(dbPath))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := trustpool.NewStore(db)
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	f, manifest := acceptWitnessTestManifest(t, store)
	var journal string
	if err := db.QueryRow(`PRAGMA journal_mode`).Scan(&journal); err != nil || journal != "wal" {
		t.Fatalf("journal_mode=%q err=%v, want wal", journal, err)
	}
	witnessPath := filepath.Join(dir, "witness.json")
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err == nil {
		t.Fatal("store started with accepted high-water and no witness")
	}
	dbBefore, walBefore := sha256File(t, dbPath), sha256File(t, dbPath+"-wal")
	cfgPath := writeWitnessInitConfig(t, dir, dbPath, "")

	// The writer connection stays open, as on a live coordinator.
	out, err := runWitnessInit("--config", cfgPath, "--out", witnessPath)
	if err != nil {
		t.Fatalf("manifest-witness-init: %v", err)
	}
	for _, want := range []string{"db=" + dbPath + "\n", "pools=1\n", "pool_id=" + f.poolID + " manifest_version=1 operation_id=" + manifest.OperationID, "manifest_core_digest=" + manifest.ManifestCoreDigest[:12] + "..."} {
		if !strings.Contains(out, want) {
			t.Fatalf("output missing %q:\n%s", want, out)
		}
	}
	if sha256File(t, dbPath) != dbBefore || sha256File(t, dbPath+"-wal") != walBefore {
		t.Fatal("manifest-witness-init changed the coordinator DB")
	}
	info, err := os.Stat(witnessPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("witness stat=%v err=%v, want mode 0600", info, err)
	}
	if _, err := trustpool.NewStore(db, trustpool.WithManifestAcceptanceWitnessPath(witnessPath)); err != nil {
		t.Fatalf("NewStore with bootstrapped witness: %v", err)
	}
	if _, err := runWitnessInit("--config", cfgPath, "--out", witnessPath); err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("second run err=%v, want already exists", err)
	}
}
