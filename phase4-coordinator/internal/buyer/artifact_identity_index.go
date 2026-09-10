package buyer

import (
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
)

// BuildArtifactIdentityIndex derives the SPEC-010 v1.7 R007 expected-identity
// set from feeds LoadAutotuneFeeds already authenticated and release-bound:
// every `verified` artifact of a `listed`/`recommendable` candidate row,
// keyed by its globally unique (hash_algorithm, hash) pair, with the feed's
// provenance (exact feed digest, authenticated signer, release id, and the
// candidate-catalog digest it is bound to). A rate-card-bound (four-feed)
// release yields nil: every consumer then keeps the v1.6 primary-only path.
// ArtifactIdentitySets is the identity set of every retained release, keyed by
// the release's candidate-catalog body digest (SPEC-010-R004 v1.8): a session
// resolves artifact-derived identity only in the set of its OWN admitted
// release, so a scheduled catalog re-stamp — which retains the previous
// release as compatible — changes nothing for live sessions.
type ArtifactIdentitySets map[string]*artifactidentity.Index

// BuildArtifactIdentitySets builds the current release's set and one set per
// retained previous release that carries an artifact feed; a release without
// one contributes no set (primary-row path only). A current-release build
// error is fatal; a previous release's is logged by the caller and skipped,
// so a bad retained feed never blocks the current release.
func BuildArtifactIdentitySets(current AutotuneFeeds, previous []AutotuneFeeds) (ArtifactIdentitySets, []error) {
	sets := ArtifactIdentitySets{}
	var errs []error
	index, err := BuildArtifactIdentityIndex(current)
	if err != nil {
		return nil, []error{err}
	}
	if index != nil {
		sets[index.Provenance().CandidateCatalogSHA256] = index
	}
	for _, feeds := range previous {
		prev, err := BuildArtifactIdentityIndex(feeds)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if prev == nil {
			continue
		}
		sha := prev.Provenance().CandidateCatalogSHA256
		if _, dup := sets[sha]; !dup {
			sets[sha] = prev
		}
	}
	return sets, errs
}

func BuildArtifactIdentityIndex(feeds AutotuneFeeds) (*artifactidentity.Index, error) {
	if !feeds.catalogArtifactsEnabled() {
		return nil, nil
	}
	var feed catalogArtifactsFeed
	if err := decodeStrictJSON(feeds.CatalogArtifactsJSON, &feed); err != nil {
		return nil, fmt.Errorf("artifact identity index: %w", err)
	}
	var catalog candidateCatalogFeed
	if err := decodeStrictJSON(feeds.AutotuneCandidatesJSON, &catalog); err != nil {
		return nil, fmt.Errorf("artifact identity index: candidate catalog: %w", err)
	}
	if feed.CandidateCatalogSHA256 != feeds.AutotuneCandidatesVerification.SHA256 {
		return nil, fmt.Errorf("artifact identity index: feed is bound to candidate catalog %q, served catalog is %q", feed.CandidateCatalogSHA256, feeds.AutotuneCandidatesVerification.SHA256)
	}
	var members []artifactidentity.Member
	for _, key := range sortedKeys(feed.Models) {
		row, ok := catalog.Rows[key]
		if !ok {
			continue
		}
		// SPEC-010-R007(b): an artifact of a `candidate` or `blocked` row is
		// never an expected identity, whatever its own status says.
		if row.RuntimeStatus != "listed" && row.RuntimeStatus != "recommendable" {
			continue
		}
		model := feed.Models[key]
		for _, artifactID := range sortedKeys(model.Artifacts) {
			entry := model.Artifacts[artifactID]
			if entry.VerificationStatus != "verified" {
				continue
			}
			members = append(members, artifactidentity.Member{
				ModelKey:      key,
				ModelID:       strings.ToLower(strings.TrimSpace(row.ModelID)),
				ArtifactID:    artifactID,
				HashAlgorithm: entry.HashAlgorithm,
				Hash:          entry.Hash,
				IsPrimary:     artifactID == model.PrimaryArtifactID,
				RuntimeStatus: row.RuntimeStatus,
			})
		}
	}
	return artifactidentity.New(artifactidentity.Provenance{
		FeedSHA256:             feeds.CatalogArtifactsVerification.SHA256,
		SignerKeyID:            feeds.CatalogArtifactsVerification.KeyID,
		ReleaseID:              feed.ReleaseID,
		CandidateCatalogSHA256: feed.CandidateCatalogSHA256,
		FeedGeneratedAt:        feeds.CatalogArtifactsVerification.GeneratedAt,
	}, members)
}
