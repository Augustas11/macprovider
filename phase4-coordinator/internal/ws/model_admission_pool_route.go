package ws

import (
	"context"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-047-R003(iv) pool route-time member derivation (v0.2.0, #1690 M4).
// A catalog_priced event records the member set but no bound member, so the
// global route helper cannot bind a GGUF member from it. On a SPEC-042 pool
// route that passes the SPEC-042-R004 runtime-allowlist predicate, and only
// there, the serving member is derived at route time from the session's
// pinned, hash-verified identity. Nothing here is reachable from a global
// route, the route-less admission bar, or the hello sandbox.

// PoolRouteSessionBoundMember is the pool-route wrapper over sessionBoundMember:
// the recorded member the session's pinned verified identity names, which
// must be an artifact_feed GGUF member whose release-bound artifact allows
// the candidate's recorded runtime_source. No other member, and no row pair,
// binds on this path.
func PoolRouteSessionBoundMember(provider pool.Provider, candidate ModelAdmissionEvent) (ModelAdmissionCatalogMember, bool) {
	member, ok := sessionBoundMember(provider, candidate)
	if !ok {
		return ModelAdmissionCatalogMember{}, false
	}
	if member.Source != modelAdmissionMemberSourceArtifactFeed || member.HashAlgorithm != modelidentity.GGUFFileV1 {
		return ModelAdmissionCatalogMember{}, false
	}
	binding := provider.ArtifactIdentity
	if binding == nil ||
		binding.Member.ArtifactID != member.ArtifactID ||
		binding.Member.HashAlgorithm != member.HashAlgorithm ||
		binding.Member.Hash != member.Hash ||
		!binding.Member.AllowsRuntimeSource(candidate.RuntimeSource) {
		return ModelAdmissionCatalogMember{}, false
	}
	return member, true
}

// ModelAdmissionPoolSettlementBindingForRouteSnapshot is the pool-only sibling
// of ModelAdmissionSettlementBindingForRouteSnapshot. It compares every
// predicate field with the event exactly as the global function does, with
// two differences: the event state is catalog_priced, and the expected
// identity comes from the route-time member derivation instead of the event.
// The global function is unchanged.
func ModelAdmissionPoolSettlementBindingForRouteSnapshot(event ModelAdmissionEvent, predicate ModelAdmissionSettlementPredicate) (ModelAdmissionSettlementBinding, bool) {
	if event.State != "catalog_priced" ||
		event.ProviderID == "" || event.CandidateID == "" || event.ServedModelRef == "" ||
		event.CatalogModelKey == "" || event.CoordinatorEventID == "" {
		return ModelAdmissionSettlementBinding{}, false
	}
	if !IsBYOMLoopbackRuntimeSource(event.RuntimeSource) {
		return ModelAdmissionSettlementBinding{}, false
	}
	if event.ProviderID != predicate.ProviderID ||
		event.CandidateID != predicate.CandidateID ||
		event.ServedModelRef != predicate.ServedModelRef ||
		event.CatalogModelKey != predicate.CatalogModelKey ||
		event.DiscoveryDigestSHA256 != predicate.DiscoveryDigestSHA256 ||
		event.EvaluationDigestSHA256 != predicate.EvaluationDigestSHA256 ||
		event.CatalogID != predicate.CatalogID ||
		event.CatalogBodyDigest != predicate.CatalogBodyDigest ||
		event.CatalogSignatureKeyID != predicate.CatalogSignatureKeyID ||
		event.CatalogSignaturePubkeyFingerprint != predicate.CatalogSignaturePubkeyFingerprint {
		return ModelAdmissionSettlementBinding{}, false
	}
	// The derived member is a GGUF artifact-feed member: all six values, and
	// the expected identity equal to that member.
	if predicate.ExpectedCatalogModelHashAlgorithm != modelidentity.GGUFFileV1 ||
		!predicate.ArtifactDerived() || !predicate.artifactEvidenceComplete() {
		return ModelAdmissionSettlementBinding{}, false
	}
	if !validModelAdmissionSHA256Hex(event.CoordinatorEventID) ||
		!validModelAdmissionSHA256Hex(predicate.DiscoveryDigestSHA256) ||
		!validModelAdmissionSHA256Hex(predicate.EvaluationDigestSHA256) ||
		!validModelAdmissionSHA256Hex(predicate.CatalogBodyDigest) ||
		!validModelAdmissionSHA256Hex(predicate.ExpectedCatalogModelHash) {
		return ModelAdmissionSettlementBinding{}, false
	}
	if strings.TrimSpace(predicate.CatalogID) == "" ||
		strings.TrimSpace(predicate.CatalogSignatureKeyID) == "" ||
		!validModelAdmissionReceiptKeyFingerprint(predicate.CatalogSignaturePubkeyFingerprint) {
		return ModelAdmissionSettlementBinding{}, false
	}
	return ModelAdmissionSettlementBinding{
		CandidateID:                    event.CandidateID,
		CoordinatorEventID:             event.CoordinatorEventID,
		ServedModelRef:                 event.ServedModelRef,
		CatalogModelKey:                event.CatalogModelKey,
		DiscoveryDigestSHA256:          event.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:         event.EvaluationDigestSHA256,
		ArtifactFeedSHA256:             predicate.ArtifactFeedSHA256,
		ArtifactID:                     predicate.ArtifactID,
		ArtifactHash:                   predicate.ArtifactHash,
		ArtifactHashAlgorithm:          predicate.ArtifactHashAlgorithm,
		ArtifactFeedSignerKeyID:        predicate.ArtifactFeedSignerKeyID,
		ArtifactCandidateCatalogSHA256: predicate.ArtifactCandidateCatalogSHA256,
	}, true
}

// CompareAndInsertPoolModelAdmissionRouteSnapshot is the SPEC-047-R003(iv)
// pool route-time sibling of CompareAndInsertModelAdmissionRouteSnapshot. It
// re-reads the candidate head, the session binding, and the release and
// binding generations exactly as that guard does, except that the head must
// be the catalog_priced event the pool route-time member derivation bound
// (a loopback candidate never reaches settlement_capable). Only the buyer's
// pool branch for an external-runtime member session calls it. It is a
// separate copy so the mapped global guard, and the conformance evidence
// bound to it, stay unchanged.
func (s *Server) CompareAndInsertPoolModelAdmissionRouteSnapshot(ctx context.Context, expect ModelAdmissionRouteExpectation, insert func() error) error {
	if s.modelAdmissions == nil || s.pool == nil {
		return ErrModelAdmissionRouteStale
	}
	if strings.TrimSpace(expect.CandidateID) == "" {
		// A pool route-time binding always names a candidate.
		return ErrModelAdmissionRouteStale
	}
	provider, ok := s.pool.Resolve(expect.ProviderID, "")
	if !ok {
		return modelAdmissionRouteDriftError()
	}
	if provider.ModelAdmissionCandidateID != expect.CandidateID || provider.ModelAdmissionCoordinatorEventID != expect.CoordinatorEventID ||
		provider.ModelAdmissionSessionEpoch != expect.SessionEpoch || s.modelAdmissionSections.get(expect.ProviderID).generation.Load() != expect.BindingGeneration {
		return modelAdmissionRouteDriftError()
	}
	if provider.ModelAdmissionValidatedReleaseGeneration == 0 {
		return ErrModelAdmissionRouteStale
	}
	headOK := func() (bool, error) {
		head, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, expect.ProviderID, expect.CandidateID)
		if err != nil {
			return false, err
		}
		return found && head.CoordinatorEventID == expect.CoordinatorEventID && head.State == "catalog_priced", nil
	}
	var generation uint64
	stale := false
	var headErr error
	s.withReleaseRead(func() {
		generation = s.artifactIdentitySets.generationLocked()
		var ok bool
		ok, headErr = headOK()
		stale = provider.ModelAdmissionValidatedReleaseGeneration != generation || !ok
	})
	if headErr != nil {
		return headErr
	}
	if generation == 0 {
		return ErrModelAdmissionRouteStale
	}
	if stale {
		return modelAdmissionRouteDriftError()
	}
	if err := insert(); err != nil {
		return err
	}
	s.withReleaseRead(func() {
		var ok bool
		ok, headErr = headOK()
		stale = s.artifactIdentitySets.generationLocked() != generation || !ok ||
			s.modelAdmissionSections.get(expect.ProviderID).generation.Load() != expect.BindingGeneration
	})
	if headErr != nil {
		return headErr
	}
	if stale {
		return modelAdmissionRouteDriftError()
	}
	after, ok := s.pool.Resolve(expect.ProviderID, "")
	if !ok || after.ModelAdmissionCandidateID != expect.CandidateID || after.ModelAdmissionCoordinatorEventID != expect.CoordinatorEventID ||
		after.ModelAdmissionBindingGeneration != provider.ModelAdmissionBindingGeneration || after.ModelAdmissionSessionEpoch != expect.SessionEpoch ||
		after.ModelAdmissionValidatedReleaseGeneration != generation {
		return modelAdmissionRouteDriftError()
	}
	return nil
}
