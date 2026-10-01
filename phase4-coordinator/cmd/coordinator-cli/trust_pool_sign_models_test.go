package main

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

const signModelsGGUFHash = "3333333333333333333333333333333333333333333333333333333333333333"

// writePoolModels writes a --pool-models input with one GGUF entry (listed
// out of canonical order on purpose) and one attested member.
func writePoolModels(t *testing.T, f signFixture, completionRate int64) string {
	t.Helper()
	path := filepath.Join(f.dir, "pool-models.json")
	body := `{
  "model_entries": [{
    "pool_model_id": "pool/` + f.poolID + `/creator-gguf",
    "artifact_hash_algorithm": "macprovider.gguf-file.v1",
    "artifact_hash": "` + signModelsGGUFHash + `",
    "allowed_runtime_sources": ["llamacpp_loopback"],
    "license": "Apache-2.0",
    "paid_serving_attested": true,
    "pricing": {"prompt_rate_per_mtok": 120, "prompt_cache_hit_rate_per_mtok": 12, "completion_rate_per_mtok": ` + strconv.FormatInt(completionRate, 10) + `},
    "disclosure_class": "pool_attested_unverified",
    "max_context_tokens": 32768
  }],
  "attested_members": [{"provider_account_id": "acct-member-1", "runtime_classes": ["llamacpp_loopback"]}]
}`
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func openSignModelsStore(t *testing.T, bounds *poolmanifest.PoolModelPricingBounds) *trustpool.Store {
	t.Helper()
	db, err := sql.Open("sqlite", sqliteutil.WithPragmas(filepath.Join(t.TempDir(), "trustpool.sqlite")))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := trustpool.NewStore(db, trustpool.WithPoolModelAcceptance(func() poolmanifest.PoolModelAcceptanceContext {
		return poolmanifest.PoolModelAcceptanceContext{
			PricingBounds:     bounds,
			IsCatalogModelID:  func(string) bool { return false },
			ArtifactInCatalog: func(string, string) bool { return false },
		}
	}))
	if err != nil {
		t.Fatalf("NewStore: %v", err)
	}
	return store
}

func registerSignModelsPool(t *testing.T, store *trustpool.Store, f signFixture) {
	t.Helper()
	ctx := context.Background()
	approveSignTestCreator(t, store, f)
	nonce, err := store.IssueRootRegistrationNonce(ctx, trustpool.RootRegistrationNonceIssue{
		OperationID: "models-nonce-1", CreatorAccountID: f.creator, ApprovalRecordID: f.approval,
		CurrentApprovalVersion: "approval-version-1", LaunchEnvironment: "candidate",
		Purpose: trustpool.RootRegistrationPurposeDefault, ExpiresAtUTC: f.now.Add(time.Hour),
	})
	if err != nil {
		t.Fatalf("IssueRootRegistrationNonce: %v", err)
	}
	create := trustpool.DurableEvent{OperationID: "models-create-1", TimestampUTC: f.now, EventType: trustpool.EventPoolCreated,
		PoolID: f.poolID, CreatorAccountID: f.creator, ApprovalRecordID: f.approval}
	if _, _, _, err := store.AppendValidatedEvent(ctx, create); err != nil {
		t.Fatalf("append pool_created: %v", err)
	}
	rootOut := filepath.Join(t.TempDir(), "root.json")
	var out bytes.Buffer
	if err := trustPoolAdmin(f.rootArgs(nonce.Nonce, nonce.ExpiresAtUTC.UTC().Format(time.RFC3339Nano), rootOut), os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-root: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, readSignedEvent(t, rootOut)); err != nil {
		t.Fatalf("append root_issuer_registered: %v", err)
	}
}

// TestTrustPoolSignManifestPoolModels signs a v2 core carrying the
// pool_model_entries/v1 and pool_attested_members/v1 extensions from a
// --pool-models file and appends it through the coordinator's validated
// path, which projects the entries; the configured pricing bounds and the
// missing-bounds case gate acceptance.
func TestTrustPoolSignManifestPoolModels(t *testing.T) {
	ctx := context.Background()
	f := newSignFixture(t)
	bounds := &poolmanifest.PoolModelPricingBounds{
		MinPromptRatePerMtok: 1, MaxPromptRatePerMtok: 1000,
		MinPromptCacheHitRatePerMtok: 0, MaxPromptCacheHitRatePerMtok: 1000,
		MinCompletionRatePerMtok: 1, MaxCompletionRatePerMtok: 1000,
	}
	notBefore := f.now.Add(-time.Minute).Truncate(time.Second)
	expiresAt := notBefore.Add(30 * 24 * time.Hour)
	var out bytes.Buffer

	// Missing bounds fail the entry closed at acceptance.
	unbounded := openSignModelsStore(t, nil)
	registerSignModelsPool(t, unbounded, f)
	manifestOut := filepath.Join(f.dir, "manifest-models.json")
	args := append(f.manifestArgs("models-manifest-1", manifestOut, notBefore, expiresAt), "--pool-models", writePoolModels(t, f, 360))
	if err := trustPoolAdmin(args, os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign-manifest --pool-models: %v", err)
	}
	signed := readSignedEvent(t, manifestOut)
	if _, _, _, err := unbounded.AppendValidatedEvent(ctx, signed); !errors.Is(err, trustpool.ErrPoolModelEntryRejected) ||
		!strings.Contains(err.Error(), trustpool.PoolModelRejectPricingBounds) {
		t.Fatalf("append without bounds: err=%v", err)
	}

	store := openSignModelsStore(t, bounds)
	registerSignModelsPool(t, store, f)
	if _, _, _, err := store.AppendValidatedEvent(ctx, signed); err != nil {
		t.Fatalf("append manifest with pool models: %v", err)
	}
	state, err := store.Reconstruct(ctx)
	if err != nil {
		t.Fatalf("Reconstruct: %v", err)
	}
	pool := state.Pools[f.poolID]
	if pool == nil || len(pool.ManifestModelEntries) != 1 || len(pool.ManifestAttestedMembers) != 1 {
		t.Fatalf("pool models not projected: %+v", pool)
	}
	entry := pool.ManifestModelEntries[0]
	if entry.PoolModelID != "pool/"+f.poolID+"/creator-gguf" || entry.ArtifactHash != signModelsGGUFHash ||
		entry.Pricing != (poolmanifest.PoolModelPricing{PromptRatePerMtok: 120, PromptCacheHitRatePerMtok: 12, CompletionRatePerMtok: 360}) {
		t.Fatalf("projected entry = %+v", entry)
	}
	snaps := state.RouteableSnapshots()
	if len(snaps) != 1 || len(snaps[0].ModelEntries) != 1 || len(snaps[0].AttestedMembers) != 1 {
		t.Fatalf("routeable snapshot lacks pool models: %+v", snaps)
	}

	// An out-of-bounds successor is refused with the bounds code.
	successorOut := filepath.Join(f.dir, "manifest-models-2.json")
	succ := withoutFlag(f.manifestArgs("models-manifest-2", successorOut, expiresAt, expiresAt.Add(time.Hour)), "--manifest-authority-key")
	succ = append(succ, "--prev", manifestOut, "--pool-models", writePoolModels(t, f, 5000))
	if err := trustPoolAdmin(succ, os.Getenv, nil, &out); err != nil {
		t.Fatalf("sign successor: %v", err)
	}
	if _, _, _, err := store.AppendValidatedEvent(ctx, readSignedEvent(t, successorOut)); !errors.Is(err, trustpool.ErrPoolModelEntryRejected) {
		t.Fatalf("out-of-bounds successor: err=%v", err)
	}
}

func TestTrustPoolSignManifestPoolModelsRejectsBadInput(t *testing.T) {
	f := newSignFixture(t)
	now := f.now.Truncate(time.Second)
	var out bytes.Buffer
	for name, body := range map[string]string{
		"unknown field": `{"model_entries": [], "extra": 1}`,
		"missing price": `{"model_entries": [{"pool_model_id": "pool/` + f.poolID + `/x", "artifact_hash_algorithm": "macprovider.gguf-file.v1", "artifact_hash": "` + signModelsGGUFHash + `", "allowed_runtime_sources": ["llamacpp_loopback"], "license": "MIT", "paid_serving_attested": true, "disclosure_class": "pool_attested_unverified", "max_context_tokens": 10}]}`,
		"wrong pool":    `{"model_entries": [{"pool_model_id": "pool/AAAAAAAAAAAAAAAAAAAAAA/x", "artifact_hash_algorithm": "macprovider.gguf-file.v1", "artifact_hash": "` + signModelsGGUFHash + `", "allowed_runtime_sources": ["llamacpp_loopback"], "license": "MIT", "paid_serving_attested": true, "pricing": {"prompt_rate_per_mtok": 1, "prompt_cache_hit_rate_per_mtok": 1, "completion_rate_per_mtok": 1}, "disclosure_class": "pool_attested_unverified", "max_context_tokens": 10}]}`,
	} {
		path := filepath.Join(f.dir, strings.ReplaceAll(name, " ", "-")+".json")
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		args := append(f.manifestArgs("bad-"+strings.ReplaceAll(name, " ", "-"), filepath.Join(f.dir, "out-"+strings.ReplaceAll(name, " ", "-")+".json"), now, now.Add(time.Hour)), "--pool-models", path)
		if err := trustPoolAdmin(args, os.Getenv, nil, &out); err == nil {
			t.Errorf("%s: sign-manifest accepted bad --pool-models", name)
		}
	}
	// --pool-models needs encoding 2.
	v1 := f.manifestArgs("bad-v1", filepath.Join(f.dir, "v1.json"), now, now.Add(time.Hour))
	for i := range v1 {
		if v1[i] == "--encoding" {
			v1[i+1] = "1"
		}
	}
	v1 = append(withoutFlag(v1, "--runtime-allowlist"), "--pool-models", writePoolModels(t, f, 1))
	if err := trustPoolAdmin(v1, os.Getenv, nil, &out); err == nil || !strings.Contains(err.Error(), "--pool-models needs --encoding 2") {
		t.Fatalf("--pool-models on encoding 1: err=%v", err)
	}
}
