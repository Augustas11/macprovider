package buyer_test

import (
	"crypto/ed25519"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// SPEC-010 v1.7 R007(b): the expected-identity set is every `verified`
// artifact of a listed/recommendable row, keyed by the exact pair, carrying
// the feed's provenance; `declared` artifacts are never members.
func TestBuildArtifactIdentityIndexFromBoundFeeds(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	ggufHash := strings.Repeat("4", 64)
	verifiedGGUF := strings.Replace(ggufArtifactJSON(ggufHash, "sha256:"+ggufHash), `"verification_status":"declared","verified_at":null`, `"verification_status":"verified","verified_at":"2026-09-01"`, 1)
	fixture := artifactBoundFeedSet(t, func(candidateSHA string) []byte {
		models := `"test-model":` + artifactModelJSON(verifiedGGUF)
		return catalogArtifactsFeedWithModels("test-release", "2026-07-10T00:00:00Z", "autotune-policy-v1", candidateSHA, models)
	}, privateKey, "test-key", map[string]ed25519.PublicKey{"test-key": publicKey}, privateKey)
	feeds, err := buyer.LoadAutotuneFeeds(fixture.cfg)
	if err != nil {
		t.Fatal(err)
	}
	index, err := buyer.BuildArtifactIdentityIndex(feeds)
	if err != nil {
		t.Fatal(err)
	}
	if index == nil {
		t.Fatal("artifact-bound release must yield an index")
	}
	members := index.Members()
	if len(members) != 2 {
		t.Fatalf("members = %+v", members)
	}
	primary, ok := index.Resolve(modelidentity.SnapshotManifestV1, strings.Repeat("2", 64))
	if !ok || !primary.Member.IsPrimary || primary.Member.ModelKey != "test-model" || primary.Member.ArtifactID != "mlx-4bit" {
		t.Fatalf("primary member: %+v %v", primary, ok)
	}
	gguf, ok := index.Resolve(modelidentity.GGUFFileV1, ggufHash)
	if !ok || gguf.Member.IsPrimary || gguf.Member.ArtifactID != "gguf-q4" || gguf.Member.RuntimeStatus != "recommendable" {
		t.Fatalf("gguf member: %+v %v", gguf, ok)
	}
	prov := index.Provenance()
	if prov.FeedSHA256 != feeds.CatalogArtifactsVerification.SHA256 || prov.SignerKeyID != "test-key" ||
		prov.ReleaseID != "test-release" || prov.CandidateCatalogSHA256 != feeds.AutotuneCandidatesVerification.SHA256 {
		t.Fatalf("provenance: %+v", prov)
	}
	if !index.BoundTo(feeds.AutotuneCandidatesVerification.SHA256) || index.BoundTo(strings.Repeat("f", 64)) {
		t.Fatal("index must be bound to the served candidate catalog only")
	}
	if prov.FeedGeneratedAt.IsZero() || !prov.FeedGeneratedAt.Equal(feeds.CatalogArtifactsVerification.GeneratedAt) {
		t.Fatalf("index must carry the feed's release stamp for freshness: %v", prov.FeedGeneratedAt)
	}
	if !index.Fresh(prov.FeedGeneratedAt.Add(24*time.Hour)) || index.Fresh(prov.FeedGeneratedAt.Add(15*24*time.Hour)) {
		t.Fatal("freshness follows SPEC-023 §3.7.6 rules 4–5")
	}
}

func TestBuildArtifactIdentityIndexSkipsDeclaredArtifactsAndFourFeedReleases(t *testing.T) {
	t.Parallel()
	publicKey, privateKey := testSigningKey(t)
	hash := strings.Repeat("4", 64)
	fixture := artifactBoundFeedSet(t, func(candidateSHA string) []byte {
		return catalogArtifactsFeedWithModels("test-release", "2026-07-10T00:00:00Z", "autotune-policy-v1", candidateSHA, `"test-model":`+artifactModelJSON(ggufArtifactJSON(hash, "sha256:"+hash)))
	}, privateKey, "test-key", map[string]ed25519.PublicKey{"test-key": publicKey}, privateKey)
	feeds, err := buyer.LoadAutotuneFeeds(fixture.cfg)
	if err != nil {
		t.Fatal(err)
	}
	index, err := buyer.BuildArtifactIdentityIndex(feeds)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := index.Resolve(modelidentity.GGUFFileV1, hash); ok {
		t.Fatal("a declared artifact is never an expected identity")
	}
	if len(index.Members()) != 1 {
		t.Fatalf("only the verified primary remains: %+v", index.Members())
	}
	fourFeed := feeds
	fourFeed.CatalogArtifactsJSON, fourFeed.CatalogArtifactsSig = nil, nil
	index, err = buyer.BuildArtifactIdentityIndex(fourFeed)
	if err != nil || index != nil {
		t.Fatalf("four-feed release must yield no index: %v %v", index, err)
	}
}
