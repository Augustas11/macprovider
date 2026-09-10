package buyer

import (
	"context"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

func byomAdmissionCandidate(p pool.Provider) bool {
	return strings.TrimSpace(p.ModelAdmissionCandidateID) != "" ||
		strings.TrimSpace(p.ModelAdmissionServedModelRef) != "" ||
		strings.TrimSpace(p.ModelAdmissionCatalogModelKey) != ""
}

func (s *Server) byomDefaultPaidRoutingEligible(p pool.Provider) bool {
	marked := byomAdmissionCandidate(p)
	// SPEC-010-R007(d): a session bound to a feed member routes only with the
	// admission evidence its route snapshot must carry (which needs a store).
	if p.ArtifactIdentity != nil && (s == nil || s.modelAdmissionStore == nil) {
		return false
	}
	if s == nil || s.modelAdmissionStore == nil {
		return !marked
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	material, ok := tier2.SnapshotMaterial(p.ModelID, byomMaterialHash(p))
	if !ok {
		_, found, err := s.modelAdmissionStore.LatestModelAdmissionRouteStatus(
			ctx,
			p.ProviderID,
			"",
			"",
		)
		if err != nil || found {
			return false
		}
		return byomLegacyRoutingEligible(p, marked)
	}
	_, found, eligible := s.byomRouteSnapshotBinding(ctx, p, material)
	if found {
		return eligible
	}
	return byomLegacyRoutingEligible(p, marked)
}

// byomLegacyRoutingEligible is the v0.1 default for a session with no
// admission record: routable unless it marked itself as a BYOM candidate.
// SPEC-010-R007(d): a session bound to a feed member routes only with the
// admission evidence its route snapshot must carry, so it is excluded here
// on every fallback — never dispatched to fail at the snapshot.
func byomLegacyRoutingEligible(p pool.Provider, marked bool) bool {
	return !marked && p.ArtifactIdentity == nil
}

// byomCatalogModelKey is the admission catalog key a route-time lookup and
// predicate name for a session: the key the session asserted; else, for a
// session bound to a feed member, the member's row KEY (what a decision that
// resolved the member records); else tier-2's normalized row model id. The
// member's ModelID is compared separately against the tier-2 row.
func byomCatalogModelKey(p pool.Provider, material tier2.RouteSnapshotMaterial) string {
	if asserted := strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey)); asserted != "" {
		return asserted
	}
	if binding := p.ArtifactIdentity; binding != nil {
		return binding.Member.ModelKey
	}
	return strings.ToLower(strings.TrimSpace(material.CatalogModelKey))
}

// byomMaterialHash is the tier-2 material lookup digest for a session: the
// admitted ROW digest for a session bound to a feed member (tier-2 material
// is keyed by the row), the reported digest otherwise. Every route-time
// consumer derives the material the same way.
func byomMaterialHash(p pool.Provider) string {
	if p.ArtifactIdentity != nil {
		return strings.TrimSpace(p.ExpectedModelHash)
	}
	return strings.TrimSpace(p.ModelHash)
}

func (s *Server) byomRouteSnapshotBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial) (providerws.ModelAdmissionSettlementBinding, bool, bool) {
	if s == nil || s.modelAdmissionStore == nil {
		return providerws.ModelAdmissionSettlementBinding{}, false, false
	}
	if ctx == nil {
		ctx = context.Background()
	}
	marked := byomAdmissionCandidate(p)
	candidateID := strings.TrimSpace(p.ModelAdmissionCandidateID)
	servedModelRef := strings.TrimSpace(p.ModelAdmissionServedModelRef)
	if servedModelRef == "" {
		servedModelRef = strings.TrimSpace(p.ModelID)
	}
	catalogModelKey := byomCatalogModelKey(p, material)

	var (
		event providerws.ModelAdmissionEvent
		found bool
		err   error
	)
	if candidateID != "" {
		event, found, err = s.modelAdmissionStore.LatestModelAdmissionStatus(ctx, p.ProviderID, candidateID)
	} else if marked {
		event, found, err = s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, servedModelRef, catalogModelKey)
	} else {
		event, found, err = s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, servedModelRef, catalogModelKey)
		if err == nil && !found {
			event, found, err = s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, "", catalogModelKey)
		}
		if err == nil && !found {
			_, providerFound, providerErr := s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, "", "")
			if providerErr != nil || providerFound {
				return providerws.ModelAdmissionSettlementBinding{}, true, false
			}
		}
	}
	if err != nil || !found {
		if err != nil {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
		return providerws.ModelAdmissionSettlementBinding{}, false, false
	}
	if marked {
		if candidateID != "" && event.CandidateID != candidateID {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
		if explicitServed := strings.TrimSpace(p.ModelAdmissionServedModelRef); explicitServed != "" && event.ServedModelRef != explicitServed {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
		if explicitCatalogKey := strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey)); explicitCatalogKey != "" && event.CatalogModelKey != explicitCatalogKey {
			return providerws.ModelAdmissionSettlementBinding{}, true, false
		}
	}
	if !s.byomSettlementPrereqsReady(p, material) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false
	}
	expectedAlgorithm, expectedHash := byomExpectedIdentity(p, material)
	predicate := providerws.ModelAdmissionSettlementPredicate{
		ProviderID:                        p.ProviderID,
		CandidateID:                       event.CandidateID,
		ServedModelRef:                    event.ServedModelRef,
		CatalogModelKey:                   byomCatalogModelKey(p, material),
		DiscoveryDigestSHA256:             event.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:            event.EvaluationDigestSHA256,
		CatalogID:                         material.CatalogID,
		CatalogBodyDigest:                 material.CatalogBodyDigest,
		CatalogSignatureKeyID:             material.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint: material.CatalogSignaturePubkeyFingerprint,
		ExpectedCatalogModelHash:          expectedHash,
		ExpectedCatalogModelHashAlgorithm: expectedAlgorithm,
	}
	byomArtifactPredicate(p, &predicate)
	binding, ok := providerws.ModelAdmissionSettlementBindingForRouteSnapshot(event, predicate)
	return binding, true, ok
}

func (s *Server) byomSettlementPrereqsReady(p pool.Provider, material tier2.RouteSnapshotMaterial) bool {
	if s == nil || !s.settlementEnforceMode() {
		return false
	}
	reportedHash := strings.TrimSpace(p.ModelHash)
	expectedHash := strings.TrimSpace(p.ExpectedModelHash)
	if !validProviderReceiptPubkey(p) || !isLowerHex64(reportedHash) {
		return false
	}
	// SPEC-010 v1.7 R007: a pair that resolved through the release-bound
	// artifact feed is the expected identity — the member's exact pair, for
	// the key the session is admitted for, verified by the heartbeat path.
	if binding := p.ArtifactIdentity; binding != nil {
		assertedKey := strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey))
		return p.ModelHashAlgorithm == binding.Member.HashAlgorithm &&
			reportedHash == binding.Member.Hash &&
			modelidentity.CanonicalAlgorithm(binding.Member.HashAlgorithm) &&
			p.HashStatus == pool.HashStatusVerified &&
			// The member belongs to the row this session serves (tier-2
			// material is keyed by the row's model id) and agrees with any
			// key the session asserted (SPEC-010-R007(c)).
			material.CatalogModelKey == binding.Member.ModelID &&
			(assertedKey == "" || assertedKey == binding.Member.ModelKey) &&
			// SPEC-023 §3.7.4 / AC-CAT-7(iii): a `listed` row stops at
			// network_visible_unpriced whatever its admission state says.
			binding.Member.RuntimeStatus == "recommendable" &&
			// SPEC-023 §3.7.6 rules 4–5 at route time, not only at the last heartbeat.
			binding.Provenance.Fresh(s.now())
	}
	return p.ModelHashAlgorithm == modelidentity.SnapshotManifestV1 &&
		isLowerHex64(expectedHash) &&
		reportedHash == expectedHash &&
		material.HashStatus == pool.HashStatusVerified &&
		material.ExpectedModelHash == expectedHash
}

// byomExpectedIdentity is the (algorithm, hash) the route snapshot and the
// admission predicate bind for this provider: the artifact member when the
// session resolved through the feed, the tier-2 row otherwise.
func byomExpectedIdentity(p pool.Provider, material tier2.RouteSnapshotMaterial) (algorithm, hash string) {
	if binding := p.ArtifactIdentity; binding != nil {
		return binding.Member.HashAlgorithm, binding.Member.Hash
	}
	return material.ExpectedModelHashAlgorithm, material.ExpectedModelHash
}

// byomArtifactPredicate fills the SPEC-047-R003 six values for a
// feed-derived binding (every member, the primary included).
func byomArtifactPredicate(p pool.Provider, predicate *providerws.ModelAdmissionSettlementPredicate) {
	binding := p.ArtifactIdentity
	if binding == nil {
		return
	}
	predicate.ArtifactFeedSHA256 = binding.Provenance.FeedSHA256
	predicate.ArtifactID = binding.Member.ArtifactID
	predicate.ArtifactHash = binding.Member.Hash
	predicate.ArtifactHashAlgorithm = binding.Member.HashAlgorithm
	predicate.ArtifactFeedSignerKeyID = binding.Provenance.SignerKeyID
	predicate.ArtifactCandidateCatalogSHA256 = binding.Provenance.CandidateCatalogSHA256
}

func validProviderReceiptPubkey(p pool.Provider) bool {
	_, err := billing.ReceiptKeyID(p.ReceiptPubkey)
	return err == nil
}

func (s *Server) requireBYOMRouteSnapshotBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial) (providerws.ModelAdmissionSettlementBinding, error) {
	binding, found, eligible := s.byomRouteSnapshotBinding(ctx, p, material)
	if !found && !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, nil
	}
	if !eligible {
		return providerws.ModelAdmissionSettlementBinding{}, fmt.Errorf("BYOM model admission is not settlement capable")
	}
	return binding, nil
}

func applyBYOMRouteSnapshotBinding(snapshot *billing.RouteSnapshot, binding providerws.ModelAdmissionSettlementBinding) {
	if snapshot == nil || binding.CandidateID == "" {
		return
	}
	snapshot.ModelAdmissionCandidateID = binding.CandidateID
	snapshot.ModelAdmissionCoordinatorEventID = binding.CoordinatorEventID
	snapshot.ModelAdmissionServedModelRef = binding.ServedModelRef
	snapshot.ModelAdmissionCatalogModelKey = binding.CatalogModelKey
	snapshot.ModelAdmissionDiscoveryDigestSHA256 = binding.DiscoveryDigestSHA256
	snapshot.ModelAdmissionEvaluationDigestSHA256 = binding.EvaluationDigestSHA256
	// SPEC-010 v1.7 R007(d) / SPEC-047-R003: a feed-derived binding's six
	// values ride in the IMMUTABLE route-time record.
	snapshot.ArtifactFeedSHA256 = binding.ArtifactFeedSHA256
	snapshot.ArtifactID = binding.ArtifactID
	snapshot.ArtifactHash = binding.ArtifactHash
	snapshot.ArtifactHashAlgorithm = binding.ArtifactHashAlgorithm
	snapshot.ArtifactFeedSignerKeyID = binding.ArtifactFeedSignerKeyID
	snapshot.ArtifactCandidateCatalogSHA256 = binding.ArtifactCandidateCatalogSHA256
}
