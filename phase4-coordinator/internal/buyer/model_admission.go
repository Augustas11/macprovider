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

// ModelAdmissionRouteGuard is the SPEC-047-R001 v0.1.5 route-time
// compare-and-insert: under the coordinator's release read lock it re-reads
// the candidate's head, the session binding and the provider's binding
// generation immediately before the route snapshot insert and fails the
// attempt closed on any difference. The ws server implements it.
type ModelAdmissionRouteGuard interface {
	CompareAndInsertModelAdmissionRouteSnapshot(context.Context, providerws.ModelAdmissionRouteExpectation, func() error) error
}

// byomAdmissionCandidate reports whether the session carries a
// coordinator-derived session-to-candidate binding (SPEC-047-R003 v0.1.5).
// Provider-reported names and keys are never a binding.
func byomAdmissionCandidate(p pool.Provider) bool {
	return strings.TrimSpace(p.ModelAdmissionCandidateID) != ""
}

func (s *Server) byomDefaultPaidRoutingEligible(p pool.Provider) bool {
	bound := byomAdmissionCandidate(p)
	// SPEC-010-R007(d): a session bound to a feed member routes only with the
	// admission evidence its route snapshot must carry (which needs a store).
	if p.ArtifactIdentity != nil && (s == nil || s.modelAdmissionStore == nil) {
		return false
	}
	if s == nil || s.modelAdmissionStore == nil {
		return !bound
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	material, ok := tier2.SnapshotMaterial(p.ModelID, byomMaterialHash(p))
	if !ok {
		return s.byomLegacyRoutingEligible(ctx, p)
	}
	_, found, eligible := s.byomRouteSnapshotBinding(ctx, p, material)
	if found {
		return eligible
	}
	return s.byomLegacyRoutingEligible(ctx, p)
}

// byomLegacyRoutingEligible is the non-BYOM session path: a session with no
// binding routes as an ordinary catalog session only when its provider has
// no admission record at all — a provider with candidates and no binding is
// never routed by default (served-model-name or asserted-key lookups are
// never a fallback, SPEC-047-R003 v0.1.5). SPEC-010-R007(d): a session bound
// to a feed member is excluded on every fallback.
func (s *Server) byomLegacyRoutingEligible(ctx context.Context, p pool.Provider) bool {
	if byomAdmissionCandidate(p) || p.ArtifactIdentity != nil {
		return false
	}
	_, found, err := s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, "", "")
	return err == nil && !found
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

// byomRouteSnapshotBinding resolves the session's BOUND candidate: its
// latest event must be the binding's head and settlement_capable, the
// session's verified pair (and artifact id, for a feed member) must equal
// the decision's bound member by CONTENT, and the route-time snapshot
// carries the session's CURRENT binding provenance. Returns (binding,
// found, eligible): found=false only when the session carries no binding.
func (s *Server) byomRouteSnapshotBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial) (providerws.ModelAdmissionSettlementBinding, bool, bool) {
	if s == nil || s.modelAdmissionStore == nil || !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, false, false
	}
	if ctx == nil {
		ctx = context.Background()
	}
	candidateID := strings.TrimSpace(p.ModelAdmissionCandidateID)
	event, found, err := s.modelAdmissionStore.LatestModelAdmissionStatus(ctx, p.ProviderID, candidateID)
	if err != nil || !found {
		return providerws.ModelAdmissionSettlementBinding{}, true, false
	}
	// Route-time event-id equality: the binding must name the candidate's
	// latest event (a revocation refreshes the binding to the terminal event).
	if event.CoordinatorEventID == "" || event.CoordinatorEventID != strings.TrimSpace(p.ModelAdmissionCoordinatorEventID) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false
	}
	if !s.byomSettlementPrereqsReady(p, material) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false
	}
	if !byomBoundMemberMatchesSession(p, event) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false
	}
	expectedAlgorithm, expectedHash := byomExpectedIdentity(p, material)
	predicate := providerws.ModelAdmissionSettlementPredicate{
		ProviderID:                        p.ProviderID,
		CandidateID:                       event.CandidateID,
		ServedModelRef:                    event.ServedModelRef,
		CatalogModelKey:                   strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey)),
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

// byomBoundMemberMatchesSession compares the decision's bound member to the
// session's verified identity by CONTENT: a feed member needs the session's
// feed binding for the same artifact id; a candidate_row member (or a
// pre-v0.1.5 record, which bound the row) needs the primary-row session.
func byomBoundMemberMatchesSession(p pool.Provider, event providerws.ModelAdmissionEvent) bool {
	switch event.BoundMemberSource {
	case "artifact_feed":
		// SPEC-047-R003(ii) defence in depth: the member must still allow
		// the recorded runtime source (the sweep revokes on reload; the
		// route re-checks before any snapshot).
		return p.ArtifactIdentity != nil &&
			p.ArtifactIdentity.Member.ArtifactID == event.ArtifactID &&
			p.ArtifactIdentity.Member.HashAlgorithm == event.ExpectedCatalogModelHashAlgorithm &&
			p.ArtifactIdentity.Member.Hash == event.ExpectedCatalogModelHash &&
			p.ArtifactIdentity.Member.AllowsRuntimeSource(event.RuntimeSource)
	case "candidate_row":
		return p.ArtifactIdentity == nil && event.ExpectedCatalogModelHashAlgorithm == modelidentity.SnapshotManifestV1 &&
			event.RuntimeSource == "mlx_cache"
	default:
		// A record with no bound member source predates v0.1.5: it never
		// bound a session's member, so it never settles.
		return false
	}
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
	// SPEC-047-R003 v0.1.5 (ii) defence in depth: the coordinator stamps the
	// bound row's status on the session; a row that is no longer
	// recommendable stops here even before the linearized revocation lands.
	if strings.TrimSpace(p.ModelAdmissionCatalogRowStatus) != "recommendable" {
		return false
	}
	// SPEC-010 v1.7 R007: a pair that resolved through the release-bound
	// artifact feed is the expected identity — the member's exact pair, for
	// the key the session is admitted for, verified by the heartbeat path.
	if binding := p.ArtifactIdentity; binding != nil {
		boundKey := strings.ToLower(strings.TrimSpace(p.ModelAdmissionCatalogModelKey))
		return p.ModelHashAlgorithm == binding.Member.HashAlgorithm &&
			reportedHash == binding.Member.Hash &&
			modelidentity.CanonicalAlgorithm(binding.Member.HashAlgorithm) &&
			p.HashStatus == pool.HashStatusVerified &&
			// The member belongs to the row this session serves (tier-2
			// material is keyed by the row's model id) and to the key the
			// session is bound for (SPEC-010-R007(c)).
			material.CatalogModelKey == binding.Member.ModelID &&
			(boundKey == "" || boundKey == binding.Member.ModelKey) &&
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
// feed-derived binding (every member, the primary included) from the
// session's CURRENT binding provenance.
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

// insertBYOMRouteSnapshot performs the SPEC-047-R001 compare-and-insert for
// a BYOM-bound route through the coordinator's guard (release read lock,
// head, binding, binding generation, validated release generation). A
// server composed with an admission store but no guard fails every
// BYOM-bound route closed: there is no weaker path.
func (s *Server) insertBYOMRouteSnapshot(ctx context.Context, p pool.Provider, binding providerws.ModelAdmissionSettlementBinding, insert func() error) error {
	if binding.CandidateID == "" {
		return insert()
	}
	if s.modelAdmissionRouteGuard == nil {
		return providerws.ErrModelAdmissionRouteStale
	}
	return s.modelAdmissionRouteGuard.CompareAndInsertModelAdmissionRouteSnapshot(ctx, providerws.ModelAdmissionRouteExpectation{
		ProviderID:         p.ProviderID,
		CandidateID:        binding.CandidateID,
		CoordinatorEventID: binding.CoordinatorEventID,
		BindingGeneration:  p.ModelAdmissionBindingGeneration,
		SessionEpoch:       p.ModelAdmissionSessionEpoch,
	}, insert)
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
