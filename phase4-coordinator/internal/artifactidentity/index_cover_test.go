package artifactidentity

import (
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

func TestJoinRuntimeSourcesSortsTrimsAndDropsBlanks(t *testing.T) {
	t.Parallel()
	if got := JoinRuntimeSources([]string{" mlx ", "", "  ", "gguf", "apple"}); got != "apple,gguf,mlx" {
		t.Fatalf("got %q", got)
	}
	if got := JoinRuntimeSources(nil); got != "" {
		t.Fatalf("empty list should join to empty, got %q", got)
	}
}

func TestAllowsRuntimeSourceExactMembership(t *testing.T) {
	t.Parallel()
	m := Member{AllowedRuntimeSources: JoinRuntimeSources([]string{"mlx", "gguf"})}
	if !m.AllowsRuntimeSource("mlx") || !m.AllowsRuntimeSource("gguf") {
		t.Fatal("listed sources must be allowed")
	}
	if m.AllowsRuntimeSource("ml") || m.AllowsRuntimeSource("mlx,gguf") || m.AllowsRuntimeSource("other") {
		t.Fatal("only exact members are allowed")
	}
	if m.AllowsRuntimeSource("") || (Member{}).AllowsRuntimeSource("") {
		t.Fatal("empty source is never allowed")
	}
}

func TestNewRejectsBadProvenance(t *testing.T) {
	t.Parallel()
	cases := map[string]func(*Provenance){
		"upper feed digest":    func(p *Provenance) { p.FeedSHA256 = strings.ToUpper(hex('a')) },
		"short feed digest":    func(p *Provenance) { p.FeedSHA256 = "abc" },
		"bad catalog digest":   func(p *Provenance) { p.CandidateCatalogSHA256 = "zz" + hex('b')[2:] },
		"blank signer":         func(p *Provenance) { p.SignerKeyID = "  " },
		"blank release":        func(p *Provenance) { p.ReleaseID = "" },
		"zero generated stamp": func(p *Provenance) { p.FeedGeneratedAt = time.Time{} },
	}
	for name, mutate := range cases {
		p := provenance()
		mutate(&p)
		if _, err := New(p, nil); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestNewRejectsMalformedMembers(t *testing.T) {
	t.Parallel()
	ok := Member{ModelKey: "m", ModelID: "x", ArtifactID: "a", HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex('2')}
	cases := map[string]struct {
		mutate func(*Member)
		want   string
	}{
		"short hash":      {func(m *Member) { m.Hash = "12" }, "lowercase sha256"},
		"uppercase hash":  {func(m *Member) { m.Hash = strings.ToUpper(hex('c')) }, "lowercase sha256"},
		"non-hex hash":    {func(m *Member) { m.Hash = strings.Repeat("g", 64) }, "lowercase sha256"},
		"no model key":    {func(m *Member) { m.ModelKey = "" }, "without model key"},
		"no artifact id":  {func(m *Member) { m.ArtifactID = "" }, "without model key"},
		"no model id":     {func(m *Member) { m.ModelID = "" }, "without model key"},
		"padded model id": {func(m *Member) { m.ModelID = " x" }, "normalized"},
		"bad algorithm":   {func(m *Member) { m.HashAlgorithm = "md5" }, "wire pair"},
	}
	for name, c := range cases {
		m := ok
		c.mutate(&m)
		_, err := New(provenance(), []Member{m})
		if err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: want error containing %q, got %v", name, c.want, err)
		}
	}
	dup := ok
	dup.ModelKey, dup.ArtifactID = "n", "b"
	if _, err := New(provenance(), []Member{ok, dup}); err == nil || !strings.Contains(err.Error(), "appears under") {
		t.Errorf("duplicate pair: got %v", err)
	}
	if _, err := New(provenance(), []Member{ok}); err != nil {
		t.Fatalf("baseline member must be accepted: %v", err)
	}
}

func TestBlockedPairsDenyAndNeverBecomeMembers(t *testing.T) {
	t.Parallel()
	member := Member{ModelKey: "m", ModelID: "x", ArtifactID: "a", HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex('2')}
	blocked := Member{ModelKey: "bad", HashAlgorithm: modelidentity.SnapshotManifestV1, Hash: hex('3')}
	idx, err := NewWithBlocked(provenance(), []Member{member}, []Member{blocked})
	if err != nil {
		t.Fatal(err)
	}
	if !idx.Blocked(modelidentity.SnapshotManifestV1, hex('3')) {
		t.Fatal("blocked pair must be denied")
	}
	if idx.Blocked(modelidentity.GGUFFileV1, hex('3')) || idx.Blocked(modelidentity.GGUFFileV1, hex('2')) {
		t.Fatal("block is exact on the pair and members are not blocked")
	}
	if _, ok := idx.Resolve(modelidentity.SnapshotManifestV1, hex('3')); ok {
		t.Fatal("blocked pair must not resolve")
	}
	var nilIndex *Index
	if nilIndex.Blocked(modelidentity.GGUFFileV1, hex('2')) {
		t.Fatal("nil index blocks nothing")
	}
	// A blocked pair must not collide with a member.
	if _, err := NewWithBlocked(provenance(), []Member{member}, []Member{{ModelKey: "bad", HashAlgorithm: member.HashAlgorithm, Hash: member.Hash}}); err == nil {
		t.Fatal("member that is also blocked must fail")
	}
	// Malformed blocked entries.
	for name, b := range map[string]Member{
		"bad algorithm": {ModelKey: "bad", HashAlgorithm: "sha256", Hash: hex('3')},
		"bad hash":      {ModelKey: "bad", HashAlgorithm: modelidentity.GGUFFileV1, Hash: "xx"},
		"no model key":  {HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex('3')},
	} {
		if _, err := NewWithBlocked(provenance(), nil, []Member{b}); err == nil {
			t.Errorf("%s: expected error", name)
		}
	}
}

func TestIndexProvenanceAndFreshness(t *testing.T) {
	t.Parallel()
	idx, err := New(provenance(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if idx.Provenance() != provenance() {
		t.Fatalf("provenance mismatch: %+v", idx.Provenance())
	}
	stamp := provenance().FeedGeneratedAt
	if !idx.Fresh(stamp.Add(time.Hour)) || idx.Fresh(stamp.Add(15*24*time.Hour)) {
		t.Fatal("index freshness follows its provenance stamp")
	}
	var nilIndex *Index
	if nilIndex.Provenance() != (Provenance{}) {
		t.Fatal("nil index has zero provenance")
	}
}

func TestMembersAreOrderedByKeyThenArtifact(t *testing.T) {
	t.Parallel()
	mk := func(key, art string, h byte) Member {
		return Member{ModelKey: key, ModelID: "x", ArtifactID: art, HashAlgorithm: modelidentity.GGUFFileV1, Hash: hex(h)}
	}
	in := []Member{mk("b", "z", '1'), mk("a", "y", '2'), mk("b", "a", '3'), mk("a", "b", '4')}
	idx, err := New(provenance(), in)
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, m := range idx.Members() {
		got = append(got, m.ModelKey+"/"+m.ArtifactID)
	}
	if want := []string{"a/b", "a/y", "b/a", "b/z"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v want %v", got, want)
	}
	var nilIndex *Index
	if nilIndex.Members() != nil {
		t.Fatal("nil index has no members")
	}
}

func TestBindingArtifactDerivedRequiresArtifactID(t *testing.T) {
	t.Parallel()
	if (Binding{}).ArtifactDerived() {
		t.Fatal("no artifact id means not artifact-derived")
	}
	if !(Binding{Member: Member{ArtifactID: "a"}}).ArtifactDerived() {
		t.Fatal("artifact id means artifact-derived")
	}
}
