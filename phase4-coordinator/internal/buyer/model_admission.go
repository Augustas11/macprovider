package buyer

import (
	"context"
	"errors"
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

type modelAdmissionRouteGenerationSource interface {
	ModelAdmissionBindingGeneration(providerID string) uint64
}

type modelAdmissionEventsEmptyStore interface {
	ModelAdmissionEventsEmpty(context.Context) (bool, error)
}

type modelAdmissionProviderRouteGenerationStore interface {
	ModelAdmissionProviderRouteGeneration(context.Context, string) (uint64, error)
}

type modelAdmissionLegacyRouteCacheEntry struct {
	routeGeneration uint64
	storeGeneration uint64
	eligible        bool
}

type modelAdmissionPaidRoutingEligibility struct {
	eligible                         bool
	storePressure                    bool
	requestCanceled                  bool
	legacyProviderRouteGeneration    uint64
	hasLegacyProviderRouteGeneration bool
}

// byomAdmissionCandidate reports whether the session carries a
// coordinator-derived session-to-candidate binding (SPEC-047-R003 v0.1.5).
// Provider-reported names and keys are never a binding.
func byomAdmissionCandidate(p pool.Provider) bool {
	return strings.TrimSpace(p.ModelAdmissionCandidateID) != ""
}

func (s *Server) byomDefaultPaidRoutingEligible(p pool.Provider) bool {
	return s.byomDefaultPaidRoutingEligibility(p).eligible
}

func (s *Server) byomDefaultPaidRoutingEligibility(p pool.Provider) modelAdmissionPaidRoutingEligibility {
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	return s.byomDefaultPaidRoutingEligibilityWithContext(ctx, p)
}

func (s *Server) byomDefaultPaidRoutingEligibilityWithContext(ctx context.Context, p pool.Provider) modelAdmissionPaidRoutingEligibility {
	bound := byomAdmissionCandidate(p)
	// SPEC-010-R007(d): a session bound to a feed member routes only with the
	// admission evidence its route snapshot must carry (which needs a store).
	if p.ArtifactIdentity != nil && (s == nil || s.modelAdmissionStore == nil) {
		return modelAdmissionPaidRoutingEligibility{}
	}
	if s == nil || s.modelAdmissionStore == nil {
		return modelAdmissionPaidRoutingEligibility{eligible: !bound}
	}
	if ctx == nil {
		ctx = context.Background()
	}
	material, ok := tier2.SnapshotMaterial(p.ModelID, byomMaterialHash(p))
	if !ok {
		return s.byomLegacyRoutingEligible(ctx, p)
	}
	_, found, eligible, err := s.byomRouteSnapshotBinding(ctx, p, material)
	if err != nil {
		return modelAdmissionEligibilityFromError(err)
	}
	if found {
		return modelAdmissionPaidRoutingEligibility{eligible: eligible}
	}
	return s.byomLegacyRoutingEligible(ctx, p)
}

// byomLegacyRoutingEligible is the non-BYOM session path: a session with no
// binding routes as an ordinary catalog session only when its provider has
// no admission record at all — a provider with candidates and no binding is
// never routed by default (served-model-name or asserted-key lookups are
// never a fallback, SPEC-047-R003 v0.1.5). SPEC-010-R007(d): a session bound
// to a feed member is excluded on every fallback.
func (s *Server) byomLegacyRoutingEligible(ctx context.Context, p pool.Provider) modelAdmissionPaidRoutingEligibility {
	if byomAdmissionCandidate(p) || p.ArtifactIdentity != nil {
		return modelAdmissionPaidRoutingEligibility{}
	}
	routeGeneration, cacheable := s.legacyModelAdmissionRouteGeneration(p.ProviderID)
	storeGeneration, storeCacheable, err := s.legacyModelAdmissionStoreGeneration(ctx, p.ProviderID)
	if err != nil {
		return modelAdmissionEligibilityFromError(err)
	}
	cacheable = cacheable && storeCacheable
	if cacheable {
		if eligible, ok := s.cachedLegacyModelAdmissionRouteEligibility(p.ProviderID, routeGeneration, storeGeneration); ok {
			return modelAdmissionPaidRoutingEligibility{
				eligible:                         eligible,
				legacyProviderRouteGeneration:    storeGeneration,
				hasLegacyProviderRouteGeneration: true,
			}
		}
	}
	storeEligibility := func(eligible bool) modelAdmissionPaidRoutingEligibility {
		if cacheable {
			s.storeLegacyModelAdmissionRouteEligibility(ctx, p.ProviderID, routeGeneration, storeGeneration, eligible)
		}
		return modelAdmissionPaidRoutingEligibility{
			eligible:                         eligible,
			legacyProviderRouteGeneration:    storeGeneration,
			hasLegacyProviderRouteGeneration: storeCacheable,
		}
	}
	eligible := false
	empty, err := s.modelAdmissionEventsEmpty(ctx)
	if err != nil {
		return modelAdmissionEligibilityFromError(err)
	}
	if empty {
		eligible = true
		return storeEligibility(eligible)
	}
	_, found, err := s.modelAdmissionStore.LatestModelAdmissionRouteStatus(ctx, p.ProviderID, "", "")
	if err != nil {
		return modelAdmissionEligibilityFromError(err)
	}
	eligible = !found
	return storeEligibility(eligible)
}

func modelAdmissionEligibilityFromError(err error) modelAdmissionPaidRoutingEligibility {
	if errors.Is(err, context.Canceled) {
		return modelAdmissionPaidRoutingEligibility{requestCanceled: true}
	}
	if billing.IsRouteSnapshotStorePressure(err) {
		return modelAdmissionPaidRoutingEligibility{storePressure: true}
	}
	return modelAdmissionPaidRoutingEligibility{}
}

func (s *Server) rememberLegacyModelAdmissionRouteExpectation(state *forwardState, p pool.Provider, eligibility modelAdmissionPaidRoutingEligibility) {
	if state == nil {
		return
	}
	state.legacyModelAdmissionRouteProviderID = ""
	state.legacyModelAdmissionRouteGeneration = 0
	state.legacyModelAdmissionRouteSet = false
	if s == nil || s.modelAdmissionStore == nil || !eligibility.eligible || !eligibility.hasLegacyProviderRouteGeneration ||
		byomAdmissionCandidate(p) || p.ArtifactIdentity != nil {
		return
	}
	state.legacyModelAdmissionRouteProviderID = p.ProviderID
	state.legacyModelAdmissionRouteGeneration = eligibility.legacyProviderRouteGeneration
	state.legacyModelAdmissionRouteSet = true
}

func (s *Server) modelAdmissionEventsEmpty(ctx context.Context) (bool, error) {
	if s == nil || s.modelAdmissionStore == nil {
		return false, nil
	}
	store, ok := s.modelAdmissionStore.(modelAdmissionEventsEmptyStore)
	if !ok {
		return false, nil
	}
	empty, err := store.ModelAdmissionEventsEmpty(ctx)
	if err != nil {
		return false, err
	}
	return empty, nil
}

func (s *Server) cachedLegacyModelAdmissionRouteEligibility(providerID string, routeGeneration, storeGeneration uint64) (bool, bool) {
	if s == nil || providerID == "" {
		return false, false
	}
	value, ok := s.modelAdmissionLegacyRouteCache.Load(providerID)
	if !ok {
		return false, false
	}
	entry, ok := value.(modelAdmissionLegacyRouteCacheEntry)
	if !ok || entry.routeGeneration != routeGeneration || entry.storeGeneration != storeGeneration {
		return false, false
	}
	return entry.eligible, true
}

func (s *Server) storeLegacyModelAdmissionRouteEligibility(ctx context.Context, providerID string, routeGeneration, storeGeneration uint64, eligible bool) {
	if s == nil || providerID == "" {
		return
	}
	currentGeneration, ok := s.legacyModelAdmissionRouteGeneration(providerID)
	if !ok || currentGeneration != routeGeneration {
		return
	}
	currentStoreGeneration, ok, err := s.legacyModelAdmissionStoreGeneration(ctx, providerID)
	if err != nil || !ok || currentStoreGeneration != storeGeneration {
		return
	}
	s.modelAdmissionLegacyRouteCache.Store(providerID, modelAdmissionLegacyRouteCacheEntry{
		routeGeneration: routeGeneration,
		storeGeneration: storeGeneration,
		eligible:        eligible,
	})
}

func (s *Server) legacyModelAdmissionRouteGeneration(providerID string) (uint64, bool) {
	if s == nil || providerID == "" || s.modelAdmissionRouteGuard == nil {
		return 0, false
	}
	source, ok := s.modelAdmissionRouteGuard.(modelAdmissionRouteGenerationSource)
	if !ok {
		return 0, false
	}
	return source.ModelAdmissionBindingGeneration(providerID), true
}

func (s *Server) legacyModelAdmissionStoreGeneration(ctx context.Context, providerID string) (uint64, bool, error) {
	if s == nil || providerID == "" || s.modelAdmissionStore == nil {
		return 0, false, nil
	}
	store, ok := s.modelAdmissionStore.(modelAdmissionProviderRouteGenerationStore)
	if !ok {
		return 0, false, nil
	}
	generation, err := store.ModelAdmissionProviderRouteGeneration(ctx, providerID)
	if err != nil {
		return 0, false, err
	}
	return generation, true, nil
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
func (s *Server) byomRouteSnapshotBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial) (providerws.ModelAdmissionSettlementBinding, bool, bool, error) {
	if s == nil || s.modelAdmissionStore == nil || !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, false, false, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	candidateID := strings.TrimSpace(p.ModelAdmissionCandidateID)
	event, found, err := s.modelAdmissionStore.LatestModelAdmissionStatus(ctx, p.ProviderID, candidateID)
	if err != nil || !found {
		return providerws.ModelAdmissionSettlementBinding{}, true, false, err
	}
	// Route-time event-id equality: the binding must name the candidate's
	// latest event (a revocation refreshes the binding to the terminal event).
	if event.CoordinatorEventID == "" || event.CoordinatorEventID != strings.TrimSpace(p.ModelAdmissionCoordinatorEventID) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false, nil
	}
	if !s.byomSettlementPrereqsReady(p, material) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false, nil
	}
	if !byomBoundMemberMatchesSession(p, event) {
		return providerws.ModelAdmissionSettlementBinding{}, true, false, nil
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
	return binding, true, ok, nil
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
	binding, found, eligible, err := s.byomRouteSnapshotBinding(ctx, p, material)
	if err != nil {
		return providerws.ModelAdmissionSettlementBinding{}, err
	}
	if !found && !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, nil
	}
	if !eligible {
		return providerws.ModelAdmissionSettlementBinding{}, fmt.Errorf("BYOM model admission is not settlement capable")
	}
	return binding, nil
}

func (s *Server) compareAndInsertLegacyModelAdmissionRouteSnapshot(ctx context.Context, p pool.Provider, state *forwardState, insert func() error) error {
	if s == nil || s.modelAdmissionStore == nil {
		return insert()
	}
	if s.modelAdmissionRouteGuard == nil || state == nil || !state.legacyModelAdmissionRouteSet ||
		state.legacyModelAdmissionRouteProviderID != p.ProviderID {
		return providerws.ErrModelAdmissionRouteStale
	}
	return s.modelAdmissionRouteGuard.CompareAndInsertModelAdmissionRouteSnapshot(ctx, providerws.ModelAdmissionRouteExpectation{
		ProviderID:              p.ProviderID,
		BindingGeneration:       p.ModelAdmissionBindingGeneration,
		ProviderRouteGeneration: state.legacyModelAdmissionRouteGeneration,
		SessionEpoch:            p.ModelAdmissionSessionEpoch,
	}, insert)
}

func (s *Server) insertBYOMRouteSnapshot(ctx context.Context, p pool.Provider, binding providerws.ModelAdmissionSettlementBinding, state *forwardState, insert func() error) error {
	if binding.CandidateID == "" {
		return s.compareAndInsertLegacyModelAdmissionRouteSnapshot(ctx, p, state, insert)
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
