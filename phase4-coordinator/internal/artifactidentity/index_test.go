package artifactidentity

import (
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

func hex(c byte) string { return strings.Repeat(string(c), 64) }

func provenance() Provenance {
	return Provenance{FeedSHA256: hex('a'), SignerKeyID: "k1", ReleaseID: "r1", CandidateCatalogSHA256: hex('b'), FeedGeneratedAt: time.Date(2026, 7, 10, 0, 0, 0, 0, time.UTC)}
}

func TestIndexResolvesExactPairOnly(t *testing.T) {
	t.Parallel()
	idx, err := New(provenance(), []Member{
		{ModelKey: "m", ArtifactID: "mlx-4bit", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: hex('1'), IsPrimary: true, RuntimeStatus: "recommendable"},
		{ModelKey: "m", ArtifactID: "gguf-q4", HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex('c'), RuntimeStatus: "recommendable"},
	})
	if err != nil {
		t.Fatal(err)
	}
	if b, ok := idx.Resolve(modelidentity.GGUFFileV1, hex('c')); !ok || b.Member.ArtifactID != "gguf-q4" || b.Provenance != provenance() || !b.ArtifactDerived() {
		t.Fatalf("gguf member not resolved: %+v %v", b, ok)
	}
	if _, ok := idx.Resolve(modelidentity.SnapshotManifestV1, hex('c')); ok {
		t.Fatal("algorithm is part of the pair")
	}
	if _, ok := idx.Resolve(modelidentity.GGUFFileV1, strings.ToUpper(hex('c'))); ok {
		t.Fatal("comparison is exact-string")
	}
	if !idx.BoundTo(hex('b')) || idx.BoundTo(hex('c')) {
		t.Fatal("release binding by candidate catalog digest")
	}
	var nilIndex *Index
	if _, ok := nilIndex.Resolve(modelidentity.GGUFFileV1, hex('c')); ok || nilIndex.BoundTo(hex('b')) {
		t.Fatal("nil index resolves nothing")
	}
}

func TestIndexRejectsDuplicatePairAndUnnamedAlgorithm(t *testing.T) {
	t.Parallel()
	if _, err := New(provenance(), []Member{
		{ModelKey: "m", ArtifactID: "a", HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex('2')},
		{ModelKey: "n", ArtifactID: "b", HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex('2')},
	}); err == nil {
		t.Fatal("duplicate pair must fail")
	}
	if _, err := New(provenance(), []Member{{ModelKey: "m", ArtifactID: "a", HashAlgorithm: "sha256", Hash: hex('2')}}); err == nil {
		t.Fatal("unnamed algorithm must fail")
	}
	if _, err := New(Provenance{}, nil); err == nil {
		t.Fatal("provenance is required")
	}
}

func TestProvenanceFreshnessFollowsSpec023Rules4And5(t *testing.T) {
	t.Parallel()
	p := provenance()
	stamp := p.FeedGeneratedAt
	if !p.Fresh(stamp.Add(13 * 24 * time.Hour)) {
		t.Fatal("13 days old is fresh")
	}
	if p.Fresh(stamp.Add(14 * 24 * time.Hour)) {
		t.Fatal("14 days old is stale: no artifact-derived capability")
	}
	if p.Fresh(stamp.Add(-time.Hour)) {
		t.Fatal("a future stamp is not fresh")
	}
	if !p.Fresh(stamp.Add(5 * time.Minute)) {
		t.Fatal("skew inside the 10-minute allowance is fresh")
	}
	if (Provenance{}).Fresh(stamp) {
		t.Fatal("no stamp, no freshness")
	}
	var nilIndex *Index
	if nilIndex.Fresh(stamp) {
		t.Fatal("nil index is never fresh")
	}
}
