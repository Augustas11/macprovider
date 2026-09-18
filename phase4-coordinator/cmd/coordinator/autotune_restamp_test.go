package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

func TestLoadSameVersionRestampCatalogsAcceptsSignedLeftover(t *testing.T) {
	t.Parallel()
	pub, priv := mustRestampKey(t)
	currentRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T00:00:00Z")
	leftoverRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T12:00:00Z")
	current := mustParseRestampCatalog(t, currentRaw, "test-key")
	leftover := mustParseRestampCatalog(t, leftoverRaw, "test-key")
	root := t.TempDir()
	writeSignedRestampDir(t, root, leftover, leftoverRaw, "test-key", priv)
	got := loadSameVersionRestampCatalogs(restampFeedConfig(root, pub, nil), current)
	if len(got) != 1 || !strings.EqualFold(got[0].SHA256, leftover.SHA256) || got[0].SignerKeyID != "test-key" {
		t.Fatalf("leftover catalogs = %+v, want sha %s", got, leftover.SHA256)
	}
}

func TestLoadSameVersionRestampCatalogsSkipsWrongSigner(t *testing.T) {
	t.Parallel()
	currentPub, _ := mustRestampKey(t)
	otherPub, otherPriv := mustRestampKey(t)
	currentRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T00:00:00Z")
	leftoverRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T12:00:00Z")
	current := mustParseRestampCatalog(t, currentRaw, "test-key")
	leftover := mustParseRestampCatalog(t, leftoverRaw, "other-key")
	root := t.TempDir()
	writeSignedRestampDir(t, root, leftover, leftoverRaw, "other-key", otherPriv)
	got := loadSameVersionRestampCatalogs(restampFeedConfig(root, currentPub, map[string]ed25519.PublicKey{"other-key": otherPub}), current)
	if len(got) != 0 {
		t.Fatalf("wrong-signer leftover catalogs = %+v, want none", got)
	}
}

func TestLoadSameVersionRestampCatalogsSkipsCurrentSHA(t *testing.T) {
	t.Parallel()
	pub, priv := mustRestampKey(t)
	currentRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T00:00:00Z")
	current := mustParseRestampCatalog(t, currentRaw, "test-key")
	root := t.TempDir()
	writeSignedRestampDir(t, root, current, currentRaw, "test-key", priv)
	got := loadSameVersionRestampCatalogs(restampFeedConfig(root, pub, nil), current)
	if len(got) != 0 {
		t.Fatalf("current-sha catalogs = %+v, want none", got)
	}
}

func TestLoadSameVersionRestampCatalogsCapsExaminedDirs(t *testing.T) {
	prev := maxSameVersionRestampCatalogs
	maxSameVersionRestampCatalogs = 1
	defer func() { maxSameVersionRestampCatalogs = prev }()

	pub, priv := mustRestampKey(t)
	currentRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T00:00:00Z")
	leftoverRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T12:00:00Z")
	current := mustParseRestampCatalog(t, currentRaw, "test-key")
	leftover := mustParseRestampCatalog(t, leftoverRaw, "test-key")
	root := t.TempDir()
	invalid := filepath.Join(root, "releases", current.Version+"-0000000000000000")
	if err := os.MkdirAll(invalid, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(invalid, "autotune-candidates.json"), []byte(`{`), 0o600); err != nil {
		t.Fatal(err)
	}
	writeSignedRestampDir(t, root, leftover, leftoverRaw, "test-key", priv)
	got := loadSameVersionRestampCatalogs(restampFeedConfig(root, pub, nil), current)
	if len(got) != 0 {
		t.Fatalf("capped catalogs = %+v, want none after examining the invalid dir first", got)
	}
}

func TestLoadSameVersionRestampCatalogsSkipsUnsigned(t *testing.T) {
	t.Parallel()
	pub, _ := mustRestampKey(t)
	currentRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T00:00:00Z")
	leftoverRaw := restampCandidateFeed("published-restamp-test", "2026-07-08T12:00:00Z")
	current := mustParseRestampCatalog(t, currentRaw, "test-key")
	leftover := mustParseRestampCatalog(t, leftoverRaw, "test-key")
	root := t.TempDir()
	dir := filepath.Join(root, "releases", current.Version+"-"+strings.ToLower(leftover.SHA256[:16]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "autotune-candidates.json"), leftoverRaw, 0o600); err != nil {
		t.Fatal(err)
	}
	got := loadSameVersionRestampCatalogs(restampFeedConfig(root, pub, nil), current)
	if len(got) != 0 {
		t.Fatalf("unsigned leftover catalogs = %+v, want none", got)
	}
}

func restampCandidateFeed(version, generatedAt string) []byte {
	return []byte(fmt.Sprintf(
		`{"version":%q,"policy_version":"autotune-policy-v1","generated_at":%q,"source":"operator_curated_autotune_candidate_catalog","rows":{"test-model":{"model_id":"mlx-community/Test-Model-4bit","model_revision":"%s","model_sha256":"%s","min_ram_gb":4,"min_bandwidth_tier":"C","bench_gate":{"min_sustained_tps":1,"max_4k_ttft_ms":1000,"provenance":{"source":"legacy_unverified","notes":"test fixture"}},"runtime_status":"recommendable","notes":"fixture"}}}`,
		version,
		generatedAt,
		strings.Repeat("1", 40),
		strings.Repeat("2", 64),
	))
}

func mustParseRestampCatalog(t *testing.T, raw []byte, signer string) *autotune.Catalog {
	t.Helper()
	catalog, err := autotune.ParseCatalog(raw)
	if err != nil {
		t.Fatalf("ParseCatalog: %v", err)
	}
	catalog.SignerKeyID = signer
	return catalog
}

func mustRestampKey(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func restampFeedConfig(root string, currentPub ed25519.PublicKey, extra map[string]ed25519.PublicKey) config.AutotuneFeedsConfig {
	keys := map[string]string{
		"test-key": base64.StdEncoding.EncodeToString(currentPub),
	}
	for id, pub := range extra {
		keys[id] = base64.StdEncoding.EncodeToString(pub)
	}
	return config.AutotuneFeedsConfig{
		AutotuneCandidatesPath: filepath.Join(root, "current", "autotune-candidates.json"),
		PublicKeys:             keys,
	}
}

func writeSignedRestampDir(t *testing.T, root string, catalog *autotune.Catalog, raw []byte, keyID string, priv ed25519.PrivateKey) {
	t.Helper()
	dir := filepath.Join(root, "releases", catalog.Version+"-"+strings.ToLower(catalog.SHA256[:16]))
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	sidecar, err := json.Marshal(map[string]string{
		"key_id":    keyID,
		"alg":       "ed25519",
		"signature": base64.StdEncoding.EncodeToString(ed25519.Sign(priv, raw)),
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "autotune-candidates.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "autotune-candidates.json.sig"), sidecar, 0o600); err != nil {
		t.Fatal(err)
	}
}
