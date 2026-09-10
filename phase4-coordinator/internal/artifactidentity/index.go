// Package artifactidentity is the SPEC-010 v1.7 R007 expected-identity set:
// the `verified` artifacts the release-bound SPEC-023 §3.7 artifact feed
// publishes for each `listed`/`recommendable` catalog model key, keyed by the
// globally unique (hash_algorithm, hash) pair. It is a leaf package so the
// provider pool, the WebSocket admission path, and the buyer settlement path
// share one index without an import cycle.
package artifactidentity

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
)

// Member is one artifact of a model key's identity set.
type Member struct {
	ModelKey string
	// ModelID is the candidate row's `model_id` (normalized lowercase): the
	// identity a session serves, routes, and prices under. A row KEY is not
	// a model id, so a session is tied to a member through this field, and
	// through ModelKey only when it asserted a key (SPEC-010-R007(c)).
	ModelID       string
	ArtifactID    string
	HashAlgorithm string
	Hash          string
	IsPrimary     bool
	RuntimeStatus string
}

// Provenance is what a later trusted binding records about the feed the
// member came from (SPEC-047-R003's six values, minus the member's own).
type Provenance struct {
	// FeedSHA256 is the digest of the exact signed artifact-feed bytes.
	FeedSHA256 string
	// SignerKeyID is the authenticated signer of those bytes.
	SignerKeyID string
	ReleaseID   string
	// CandidateCatalogSHA256 is the exact candidate-catalog body digest the
	// feed is release-bound to (SPEC-023 §3.7.4).
	CandidateCatalogSHA256 string
	// FeedGeneratedAt is the feed's release stamp: SPEC-023 §3.7.6 rules 4–5
	// make a feed 14 days past it (or ahead of the clock) unusable for every
	// artifact-derived capability while the primary-row path continues.
	FeedGeneratedAt time.Time
}

const (
	artifactFeedStaleAfter = 14 * 24 * time.Hour
	artifactFeedClockSkew  = 10 * time.Minute
)

// Fresh reports whether artifact-derived capability may be exercised at `now`.
func (p Provenance) Fresh(now time.Time) bool {
	if p.FeedGeneratedAt.IsZero() || p.FeedGeneratedAt.After(now.Add(artifactFeedClockSkew)) {
		return false
	}
	return now.Sub(p.FeedGeneratedAt) < artifactFeedStaleAfter
}

// Binding is a verified provider identity resolved through the index: the
// matched member plus the provenance the route snapshot must carry.
type Binding struct {
	Member     Member
	Provenance Provenance
}

// ArtifactDerived reports whether a route-time binding must carry the
// SPEC-047-R003 six values: every feed-derived binding does, the feed's
// primary entry included (only a primary identity bound directly through the
// signed candidate row is exempt, and that path never produces a Binding).
func (b Binding) ArtifactDerived() bool { return b.Member.ArtifactID != "" }

// Index resolves a provider-reported (algorithm, hash) pair to exactly one
// member, and is bound to exactly one candidate-catalog release.
type Index struct {
	provenance Provenance
	members    map[string]Member
}

func memberKey(algorithm, hash string) string { return algorithm + "\x00" + hash }

// New builds an index; a duplicate (hash_algorithm, hash) pair, an
// unnamed algorithm, or a malformed digest is a construction error — the
// generator and loader reject such feeds, so this is a second line only.
func New(provenance Provenance, members []Member) (*Index, error) {
	if !isLowerHex64(provenance.CandidateCatalogSHA256) || !isLowerHex64(provenance.FeedSHA256) {
		return nil, fmt.Errorf("artifact identity index: provenance digests must be lowercase sha256")
	}
	if strings.TrimSpace(provenance.SignerKeyID) == "" || strings.TrimSpace(provenance.ReleaseID) == "" {
		return nil, fmt.Errorf("artifact identity index: provenance signer and release id are required")
	}
	if provenance.FeedGeneratedAt.IsZero() {
		return nil, fmt.Errorf("artifact identity index: provenance feed generated_at is required")
	}
	index := &Index{provenance: provenance, members: make(map[string]Member, len(members))}
	for _, member := range members {
		if !modelidentity.CanonicalAlgorithm(member.HashAlgorithm) {
			return nil, fmt.Errorf("artifact identity index: %s/%s algorithm %q is not a SPEC-010-R002 wire pair", member.ModelKey, member.ArtifactID, member.HashAlgorithm)
		}
		if !isLowerHex64(member.Hash) {
			return nil, fmt.Errorf("artifact identity index: %s/%s hash is not lowercase sha256", member.ModelKey, member.ArtifactID)
		}
		if member.ModelKey == "" || member.ArtifactID == "" || member.ModelID == "" {
			return nil, fmt.Errorf("artifact identity index: member without model key, model id, or artifact id")
		}
		if member.ModelID != strings.ToLower(strings.TrimSpace(member.ModelID)) {
			return nil, fmt.Errorf("artifact identity index: %s/%s model id must be normalized", member.ModelKey, member.ArtifactID)
		}
		key := memberKey(member.HashAlgorithm, member.Hash)
		if existing, dup := index.members[key]; dup {
			return nil, fmt.Errorf("artifact identity index: (%s, %s) appears under %s/%s and %s/%s", member.HashAlgorithm, member.Hash, existing.ModelKey, existing.ArtifactID, member.ModelKey, member.ArtifactID)
		}
		index.members[key] = member
	}
	return index, nil
}

// Provenance returns the feed provenance every resolved binding carries.
func (i *Index) Provenance() Provenance {
	if i == nil {
		return Provenance{}
	}
	return i.provenance
}

// Fresh reports whether the feed behind this index may authorize artifact-
// derived capability at `now` (SPEC-023 §3.7.6 rules 4–5).
func (i *Index) Fresh(now time.Time) bool {
	return i != nil && i.provenance.Fresh(now)
}

// BoundTo reports whether the index is release-bound to the candidate
// catalog a provider was admitted against (SPEC-010-R007(b): the feed of the
// SAME exact release, never an independently loaded one).
func (i *Index) BoundTo(candidateCatalogSHA256 string) bool {
	if i == nil {
		return false
	}
	// Exact string equality: R007(b) binds the release by the exact digest,
	// as Resolve binds the pair.
	return candidateCatalogSHA256 == i.provenance.CandidateCatalogSHA256
}

// Resolve returns the single member the exact (algorithm, hash) pair names.
// Comparison is exact-string on both halves (R007(b)); nothing is
// "approximately matched".
func (i *Index) Resolve(algorithm, hash string) (Binding, bool) {
	if i == nil {
		return Binding{}, false
	}
	member, ok := i.members[memberKey(algorithm, hash)]
	if !ok {
		return Binding{}, false
	}
	return Binding{Member: member, Provenance: i.provenance}, true
}

// Members returns every member in a deterministic order (diagnostics/tests).
func (i *Index) Members() []Member {
	if i == nil {
		return nil
	}
	out := make([]Member, 0, len(i.members))
	for _, member := range i.members {
		out = append(out, member)
	}
	sort.Slice(out, func(a, b int) bool {
		if out[a].ModelKey != out[b].ModelKey {
			return out[a].ModelKey < out[b].ModelKey
		}
		return out[a].ArtifactID < out[b].ArtifactID
	})
	return out
}

func isLowerHex64(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, ch := range value {
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') {
			return false
		}
	}
	return true
}
