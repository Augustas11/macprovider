package buyer_test

import (
	"crypto/ed25519"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// versionedArtifactBoundFeedSet is artifactBoundFeedSet with a release version,
// so two fixtures are two RELEASES (distinct candidate-catalog digests).
func versionedArtifactBoundFeedSet(t *testing.T, version string, artifacts func(candidateSHA256 string) []byte, key ed25519.PrivateKey, keyring map[string]ed25519.PublicKey) config.AutotuneFeedsConfig {
	t.Helper()
	dir := t.TempDir()
	const generatedAt, policyVersion = "2026-07-10T00:00:00Z", "autotune-policy-v1"
	candidate := validCandidateFeed(version)
	digest := sha256.Sum256(candidate)
	candidateJSONPath, candidateSigPath := writeSignedFeedPair(t, dir, "autotune-candidates", candidate, "test-key", key)
	demandJSONPath, demandSigPath := writeSignedFeedPair(t, dir, "demand-rank", validDemandFeedWith(version, generatedAt, policyVersion), "test-key", key)
	rateCardJSONPath, rateCardSigPath := writeSignedFeedPair(t, dir, "rate-card", validRateCardFeed(generatedAt, policyVersion), "test-key", key)
	artifactsJSONPath, artifactsSigPath := writeSignedFeedPair(t, dir, "autotune-artifacts", artifacts(hex.EncodeToString(digest[:])), "test-key", key)
	publicKeys := map[string]string{}
	for id, k := range keyring {
		publicKeys[id] = base64.StdEncoding.EncodeToString(k)
	}
	return config.AutotuneFeedsConfig{
		RateCardPath: rateCardJSONPath, RateCardSigPath: rateCardSigPath, DemandRankPath: demandJSONPath, DemandRankSigPath: demandSigPath,
		AutotuneCandidatesPath: candidateJSONPath, AutotuneCandidatesSigPath: candidateSigPath, CatalogArtifactsPath: artifactsJSONPath, CatalogArtifactsSigPath: artifactsSigPath,
		PublicKeys: publicKeys,
	}
}

// SPEC-010-R004 v1.8: one identity set per retained release. A retained
// previous release directory that carries its artifact feed contributes its
// own set keyed by its candidate-catalog digest; one without contributes none.
func TestArtifactIdentitySetsPerRetainedRelease(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	keyring := map[string]ed25519.PublicKey{"test-key": publicKey}
	hashA, hashB := strings.Repeat("4", 64), strings.Repeat("5", 64)
	currentCfg := versionedArtifactBoundFeedSet(t, "release-b", func(sha string) []byte {
		return catalogArtifactsFeedWithModels("release-b", "2026-07-10T00:00:00Z", "autotune-policy-v1", sha, `"test-model":`+artifactModelJSON(ggufArtifactJSON(hashB, "sha256:"+hashB)))
	}, privateKey, keyring)
	previousCfg := versionedArtifactBoundFeedSet(t, "release-a", func(sha string) []byte {
		return catalogArtifactsFeedWithModels("release-a", "2026-07-03T00:00:00Z", "autotune-policy-v1", sha, `"test-model":`+artifactModelJSON(ggufArtifactJSON(hashA, "sha256:"+hashA)))
	}, privateKey, keyring)
	currentFeeds, err := buyer.LoadAutotuneFeeds(currentCfg)
	if err != nil {
		t.Fatal(err)
	}
	previousFeeds, err := buyer.LoadAutotuneFeeds(previousCfg)
	if err != nil {
		t.Fatal(err)
	}
	sets, errs := buyer.BuildArtifactIdentitySets(currentFeeds, []buyer.AutotuneFeeds{previousFeeds})
	if len(errs) != 0 || len(sets) != 2 {
		t.Fatalf("sets=%d errs=%v", len(sets), errs)
	}
	if _, ok := sets[currentFeeds.AutotuneCandidatesVerification.SHA256].Resolve(modelidentity.GGUFFileV1, hashB); !ok {
		t.Fatal("current release set must resolve the current member")
	}
	if _, ok := sets[previousFeeds.AutotuneCandidatesVerification.SHA256].Resolve(modelidentity.GGUFFileV1, hashA); !ok {
		t.Fatal("previous release set must resolve its own member")
	}
	if _, ok := sets[previousFeeds.AutotuneCandidatesVerification.SHA256].Resolve(modelidentity.GGUFFileV1, hashB); ok {
		t.Fatal("a release's set must not resolve another release's member")
	}
	// A previous release without an artifact feed contributes no set; a
	// broken previous feed is reported and skipped, never fatal.
	fourFeed := previousFeeds
	fourFeed.CatalogArtifactsJSON, fourFeed.CatalogArtifactsSig = nil, nil
	sets, errs = buyer.BuildArtifactIdentitySets(currentFeeds, []buyer.AutotuneFeeds{fourFeed})
	if len(errs) != 0 || len(sets) != 1 {
		t.Fatalf("four-feed previous: sets=%d errs=%v", len(sets), errs)
	}
	broken := previousFeeds
	broken.CatalogArtifactsJSON = []byte("{")
	sets, errs = buyer.BuildArtifactIdentitySets(currentFeeds, []buyer.AutotuneFeeds{broken})
	if len(errs) != 1 || len(sets) != 1 {
		t.Fatalf("broken previous must be skipped: sets=%d errs=%v", len(sets), errs)
	}
}

// LoadPreviousAutotuneFeeds follows `.previous-target` to the retained release
// directory and loads its artifact feed when present.
func TestLoadPreviousAutotuneFeedsFollowsPreviousTarget(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	keyring := map[string]ed25519.PublicKey{"test-key": publicKey}
	hashA := strings.Repeat("6", 64)
	previous := artifactBoundFeedSet(t, func(sha string) []byte {
		return catalogArtifactsFeedWithModels("test-release", "2026-07-03T00:00:00Z", "autotune-policy-v1", sha, `"test-model":`+artifactModelJSON(ggufArtifactJSON(hashA, "sha256:"+hashA)))
	}, privateKey, "test-key", keyring, privateKey)
	root := t.TempDir()
	releaseDir := filepath.Join(root, "releases", "release-prev")
	if err := os.MkdirAll(releaseDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for src, dst := range map[string]string{
		previous.cfg.AutotuneCandidatesPath: "autotune-candidates.json", previous.cfg.AutotuneCandidatesSigPath: "autotune-candidates.json.sig",
		previous.cfg.CatalogArtifactsPath: "autotune-artifacts.json", previous.cfg.CatalogArtifactsSigPath: "autotune-artifacts.json.sig",
	} {
		data, err := os.ReadFile(src)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(releaseDir, dst), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, ".previous-target"), []byte("releases/release-prev\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg := previous.cfg
	cfg.AutotuneCandidatesPath = filepath.Join(root, "current", "autotune-candidates.json")
	feeds, err := buyer.LoadPreviousAutotuneFeeds(cfg)
	if err != nil || len(feeds) != 1 || len(feeds[0].CatalogArtifactsJSON) == 0 {
		t.Fatalf("previous feeds: %v %d", err, len(feeds))
	}
	// Without an artifact feed the candidate half still loads.
	if err := os.Remove(filepath.Join(releaseDir, "autotune-artifacts.json")); err != nil {
		t.Fatal(err)
	}
	feeds, err = buyer.LoadPreviousAutotuneFeeds(cfg)
	if err != nil || len(feeds) != 1 || len(feeds[0].CatalogArtifactsJSON) != 0 {
		t.Fatalf("previous feeds without artifacts: %v", err)
	}
	// No target recorded: nothing to load.
	if err := os.Remove(filepath.Join(root, ".previous-target")); err != nil {
		t.Fatal(err)
	}
	if feeds, err := buyer.LoadPreviousAutotuneFeeds(cfg); err != nil || feeds != nil {
		t.Fatalf("no previous target: %v %v", feeds, err)
	}
}
