package catalogbind

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/rs/zerolog"
)

const (
	hashA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	hashB = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
)

func TestRequireActiveReleaseBindingAcceptsMatchingHashes(t *testing.T) {
	auto := mustAutotune(t, "mlx-community/Qwen3-8B-4bit", hashA)
	t2 := mustTier2(t, "mlx-community/Qwen3-8B-4bit", hashA)
	if err := RequireActiveReleaseBinding(auto, t2); err != nil {
		t.Fatalf("matching catalogs must bind: %v", err)
	}
}

func TestRequireActiveReleaseBindingDetectsHashConflict(t *testing.T) {
	auto := mustAutotune(t, "mlx-community/Qwen3-8B-4bit", hashA)
	t2 := mustTier2(t, "mlx-community/Qwen3-8B-4bit", hashB)
	err := RequireActiveReleaseBinding(auto, t2)
	if err == nil {
		t.Fatal("conflicting hashes must fail closed")
	}
	if !strings.Contains(err.Error(), "mlx-community/Qwen3-8B-4bit") {
		t.Fatalf("conflict error missing model_id: %v", err)
	}
	if !strings.Contains(err.Error(), hashA) || !strings.Contains(err.Error(), hashB) {
		t.Fatalf("conflict error missing hashes: %v", err)
	}
}

func TestRequireActiveReleaseBindingIgnoresTier2OnlyRows(t *testing.T) {
	auto := mustAutotune(t, "mlx-community/Qwen3-8B-4bit", hashA)
	t2 := mustTier2(t, "mlx-community/Only-In-Tier2-4bit", hashB)
	if err := RequireActiveReleaseBinding(auto, t2); err != nil {
		t.Fatalf("tier2-only rows are not conflicts yet: %v", err)
	}
}

func TestRequireActiveReleaseBindingIgnoresAutotuneOnlyRows(t *testing.T) {
	auto := mustAutotune(t, "mlx-community/Qwen3-8B-4bit", hashA)
	t2 := mustTier2(t, "mlx-community/Other-Model-4bit", hashA)
	if err := RequireActiveReleaseBinding(auto, t2); err != nil {
		t.Fatalf("non-overlapping rows must not conflict: %v", err)
	}
}

func TestRequireActiveReleaseBindingSkipsWhenTier2Inactive(t *testing.T) {
	auto := mustAutotune(t, "mlx-community/Qwen3-8B-4bit", hashA)
	if err := RequireActiveReleaseBinding(auto, tier2.NewCatalog()); err != nil {
		t.Fatalf("inactive tier2 must not bind-fail: %v", err)
	}
	if err := RequireActiveReleaseBinding(auto, nil); err != nil {
		t.Fatalf("nil tier2 must not bind-fail: %v", err)
	}
}

func TestRequireActiveReleaseBindingRejectsStaleBackupHash(t *testing.T) {
	// Simulates restoring an older Tier-2 backup whose Qwen hash no longer
	// matches the active autotune release (#585 / #608 drift shape).
	auto := mustAutotune(t, "mlx-community/Qwen3-8B-4bit", hashA)
	stale := mustTier2(t, "mlx-community/Qwen3-8B-4bit", hashB)
	if err := RequireActiveReleaseBinding(auto, stale); err == nil {
		t.Fatal("stale tier2 backup with drifted hash must fail closed")
	}
}

func TestTier2AgreesWithAdmittedHash(t *testing.T) {
	t2 := mustTier2(t, "mlx-community/Qwen3-8B-4bit", hashA)
	agrees, ok := Tier2AgreesWithAdmittedHash(t2, "mlx-community/Qwen3-8B-4bit", hashA)
	if !ok || !agrees {
		t.Fatalf("matching hash: agrees=%v ok=%v", agrees, ok)
	}
	agrees, ok = Tier2AgreesWithAdmittedHash(t2, "mlx-community/Qwen3-8B-4bit", hashB)
	if !ok || agrees {
		t.Fatalf("mismatched hash: agrees=%v ok=%v", agrees, ok)
	}
	agrees, ok = Tier2AgreesWithAdmittedHash(t2, "missing", hashA)
	if ok || agrees {
		t.Fatalf("missing model: agrees=%v ok=%v", agrees, ok)
	}
}

func mustAutotune(t *testing.T, modelID, sha string) *autotune.Catalog {
	t.Helper()
	raw := []byte(`{
		"version":"release-under-test",
		"policy_version":"autotune-policy-v1",
		"source":"operator_curated_autotune_candidate_catalog",
		"rows":{
			"test-row":{
				"model_id":"` + modelID + `",
				"model_revision":"abc123",
				"model_sha256":"` + sha + `",
				"min_ram_gb":12,
				"min_bandwidth_tier":"C",
				"bench_gate":{"min_sustained_tps":15,"max_4k_ttft_ms":4500},
				"runtime_status":"recommendable"
			}
		}
	}`)
	catalog, err := autotune.ParseCatalog(raw)
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	return catalog
}

func mustTier2(t *testing.T, modelID, sha string) *tier2.Catalog {
	t.Helper()
	raw, pub := signedTier2(t, modelID, sha)
	path := filepath.Join(t.TempDir(), "tier2-catalog.json")
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatalf("write tier2: %v", err)
	}
	catalog := tier2.NewCatalog()
	cfg := config.Tier2Config{
		CatalogPath:      path,
		CatalogPublicKey: pub,
	}
	if err := catalog.ConfigureStrict(cfg, zerolog.Nop()); err != nil {
		t.Fatalf("ConfigureStrict: %v", err)
	}
	if !catalog.Active() {
		t.Fatal("tier2 catalog inactive after configure")
	}
	return catalog
}

func signedTier2(t *testing.T, modelID, sha string) ([]byte, string) {
	t.Helper()
	seed := make([]byte, ed25519.SeedSize)
	for i := range seed {
		seed[i] = 7
	}
	privateKey := ed25519.NewKeyFromSeed(seed)
	publicKey := privateKey.Public().(ed25519.PublicKey)
	minRAM := 16
	issuedAt := time.Now().UTC().Add(-time.Hour).Format(time.RFC3339)
	expiresAt := time.Now().UTC().Add(time.Hour).Format(time.RFC3339)
	// Sign over the same struct field order ParseCatalog re-marshals.
	type canonicalBody struct {
		CatalogID string             `json:"catalog_id"`
		ExpiresAt string             `json:"expires_at"`
		IssuedAt  string             `json:"issued_at"`
		Models    []tier2.ModelEntry `json:"models"`
		Version   int                `json:"version"`
	}
	type signature struct {
		Alg   string `json:"alg"`
		KeyID string `json:"key_id"`
		Sig   string `json:"sig"`
	}
	type catalogFile struct {
		CatalogID string             `json:"catalog_id"`
		ExpiresAt string             `json:"expires_at"`
		IssuedAt  string             `json:"issued_at"`
		Models    []tier2.ModelEntry `json:"models"`
		Signature signature          `json:"signature"`
		Version   int                `json:"version"`
	}
	body := canonicalBody{
		CatalogID: "test-catalog",
		ExpiresAt: expiresAt,
		IssuedAt:  issuedAt,
		Models: []tier2.ModelEntry{{
			ArtifactKind: "mlx_weight_file",
			HashScope:    "primary_weight_file",
			ModelID:      modelID,
			MinRAMGB:     &minRAM,
			SHA256:       sha,
			Source:       "operator-curated",
		}},
		Version: 1,
	}
	canonical, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("canonical marshal: %v", err)
	}
	sig := ed25519.Sign(privateKey, canonical)
	file := catalogFile{
		CatalogID: body.CatalogID,
		ExpiresAt: body.ExpiresAt,
		IssuedAt:  body.IssuedAt,
		Models:    body.Models,
		Signature: signature{Alg: "Ed25519", KeyID: "test-key", Sig: base64.RawURLEncoding.EncodeToString(sig)},
		Version:   body.Version,
	}
	raw, err := json.Marshal(file)
	if err != nil {
		t.Fatalf("catalog marshal: %v", err)
	}
	return raw, base64.RawURLEncoding.EncodeToString(publicKey)
}
