package buyer

import (
	"fmt"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
)

// BuildArtifactIdentityIndex derives the SPEC-010 v1.7 R007 expected-identity
// set from feeds LoadAutotuneFeeds already authenticated and release-bound:
// every `verified` artifact of a `listed`/`recommendable` candidate row,
// keyed by its globally unique (hash_algorithm, hash) pair, with the feed's
// provenance (exact feed digest, authenticated signer, release id, and the
// candidate-catalog digest it is bound to). A rate-card-bound (four-feed)
// release yields nil: every consumer then keeps the v1.6 primary-only path.
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
	}, members)
}
