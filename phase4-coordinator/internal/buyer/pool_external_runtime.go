package buyer

import (
	"context"
	"fmt"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-042-R004/R005/R013, SPEC-047-R003(iv) pool route-time clause,
// SPEC-032-R004 (#1690 M4). An external-runtime member session (a SPEC-046
// loopback runtime) is selectable only on a pool route, and only when every
// condition of the runtime-allowlist predicate holds at that attempt, read
// from the one consistent routeable snapshot captured at selection. Global
// routes, the route-less admission bar, and the hello sandbox are unchanged.

// poolRouteView is the slice of the selection-time pool snapshot the
// external-runtime predicate reads. The zero value is a global route.
type poolRouteView struct {
	poolID           string
	members          map[string]bool
	runtimeAllowlist []string
	creatorAccountID string
	creatorOwned     map[string]bool
}

func (st *forwardState) poolRouteView() poolRouteView {
	if st == nil || st.poolID == "" {
		return poolRouteView{}
	}
	return poolRouteView{
		poolID:           st.poolID,
		members:          st.poolMembers,
		runtimeAllowlist: st.poolRuntimeAllowlist,
		creatorAccountID: st.poolCreatorAccountID,
		creatorOwned:     st.poolCreatorOwnedMembers,
	}
}

func (v poolRouteView) allowsRuntime(runtimeSource string) bool {
	for _, allowed := range v.runtimeAllowlist {
		if allowed == runtimeSource {
			return true
		}
	}
	return false
}

// externalRuntimeCandidate is the snapshot half of the SPEC-042-R004
// predicate: (a) a pool route, (b) a current member, (c) the hello-time
// runtime_source on the pool's signed allowlist, and (e) a member owned by
// the pool creator. The binding half, (c) against the coordinator-derived
// class and (d), is poolExternalRuntimeRouteBinding. The hello value only
// narrows: it has to be allowlisted AND equal the derived class.
func (v poolRouteView) externalRuntimeCandidate(p pool.Provider) bool {
	return v.poolID != "" &&
		providerws.IsBYOMLoopbackRuntimeSource(p.RuntimeSource) &&
		v.members[p.ProviderID] &&
		v.creatorAccountID != "" &&
		v.creatorOwned[p.ProviderID] &&
		v.allowsRuntime(p.RuntimeSource)
}

// poolHasExternalRuntimeMember reports whether any session in scope is a
// pool member served by a SPEC-046 loopback runtime.
func poolHasExternalRuntimeMember(providers []pool.Provider, members map[string]bool) bool {
	for _, p := range providers {
		if members[p.ProviderID] && providerws.IsBYOMLoopbackRuntimeSource(p.RuntimeSource) {
			return true
		}
	}
	return false
}

// routingEligibleForRoute is SPEC-042-R005 site (2): RoutingEligible keeps its
// global answer (a sandboxed session is excluded), and a separate pool-scoped
// predicate lets a pool route select a sandboxed external-runtime member
// session. Every caller also applies byomPaidRoutingEligibilityForRoute, so
// the sandbox term is only ever skipped together with the full predicate.
func routingEligibleForRoute(p pool.Provider, view poolRouteView) bool {
	if view.externalRuntimeCandidate(p) {
		return p.PoolExternalRuntimeRoutingEligible()
	}
	return p.RoutingEligible()
}

// providerForRoute is the slot-queue form of routingEligibleForRoute: the
// queue re-derives capacity and routing gates by hand, so a pool route that
// already establishes the external-runtime predicate sees the member session
// without its hello sandbox term, exactly as the candidate and pinned paths
// do. Every other provider and every global route is returned unchanged, and
// the paid-routing predicate (binding half) is still applied by the caller.
func providerForRoute(p pool.Provider, view poolRouteView) pool.Provider {
	if view.externalRuntimeCandidate(p) {
		p.AdmissionSandboxed = false
	}
	return p
}

type poolRouteViewKey struct{}

// withPoolRouteView carries a pool route's selection-time view on the route
// admission context, so the shared paid-routing predicate can apply the pool
// branch without widening any global signature. A context without a view is
// a global route.
func withPoolRouteView(ctx context.Context, view poolRouteView) context.Context {
	if ctx == nil {
		ctx = context.Background()
	}
	if view.poolID == "" {
		return ctx
	}
	return context.WithValue(ctx, poolRouteViewKey{}, view)
}

func poolRouteViewFrom(ctx context.Context) poolRouteView {
	if ctx == nil {
		return poolRouteView{}
	}
	view, _ := ctx.Value(poolRouteViewKey{}).(poolRouteView)
	return view
}

// byomPaidRoutingEligibilityForRoute is SPEC-042-R005 site (1) for the pinned
// and slot-queue paths, which hold the view on their forward state.
func (s *Server) byomPaidRoutingEligibilityForRoute(ctx context.Context, p pool.Provider, view poolRouteView) modelAdmissionPaidRoutingEligibility {
	return s.byomDefaultPaidRoutingEligibilityWithContext(withPoolRouteView(ctx, view), p)
}

// poolExternalRuntimeEligibility is the loopback branch of the shared
// paid-routing predicate: eligible only through the pool route-time binding.
func (s *Server) poolExternalRuntimeEligibility(ctx context.Context, p pool.Provider) modelAdmissionPaidRoutingEligibility {
	view := poolRouteViewFrom(ctx)
	if !view.externalRuntimeCandidate(p) {
		return modelAdmissionPaidRoutingEligibility{}
	}
	material, ok := tier2.SnapshotMaterial(p.ModelID, byomMaterialHash(p))
	if !ok {
		return modelAdmissionPaidRoutingEligibility{}
	}
	_, eligible, err := s.poolExternalRuntimeRouteBinding(ctx, p, material, view)
	if err != nil {
		return modelAdmissionEligibilityFromError(err)
	}
	return modelAdmissionPaidRoutingEligibility{eligible: eligible}
}

// poolExternalRuntimeRouteBinding is SPEC-042-R005 sites (3) and (4): the pool
// branch of byomRouteSnapshotBinding. The bound candidate's head may be
// catalog_priced; the serving member is derived at route time
// (SPEC-047-R003(iv) steps 1-3); byomBoundMemberMatchesSession, which rejects
// every loopback session, stays global-only and is not consulted here.
func (s *Server) poolExternalRuntimeRouteBinding(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial, view poolRouteView) (providerws.ModelAdmissionSettlementBinding, bool, error) {
	if s == nil || s.modelAdmissionStore == nil || !view.externalRuntimeCandidate(p) || !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, false, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	event, found, err := s.modelAdmissionStore.LatestModelAdmissionStatus(ctx, p.ProviderID, strings.TrimSpace(p.ModelAdmissionCandidateID))
	if err != nil || !found {
		return providerws.ModelAdmissionSettlementBinding{}, false, err
	}
	// Head equality and provenance are unchanged from the global path.
	if event.CoordinatorEventID == "" || event.CoordinatorEventID != strings.TrimSpace(p.ModelAdmissionCoordinatorEventID) {
		return providerws.ModelAdmissionSettlementBinding{}, false, nil
	}
	// The coordinator-recorded runtime class is the candidate's signed offer
	// runtime_source. A hello that differs from it removes the session; the
	// allowlist is checked against that class.
	if !providerws.IsBYOMLoopbackRuntimeSource(event.RuntimeSource) || event.RuntimeSource != p.RuntimeSource || !view.allowsRuntime(event.RuntimeSource) {
		return providerws.ModelAdmissionSettlementBinding{}, false, nil
	}
	if !s.byomSettlementPrereqsReady(p, material) {
		return providerws.ModelAdmissionSettlementBinding{}, false, nil
	}
	// Step 1: the recorded member the session's pin names; its format must
	// agree with the loopback class (GGUF feed member, or for mlxlm_loopback
	// a snapshot-manifest feed member or the row's own pair).
	member, ok := providerws.PoolRouteSessionBoundMember(p, event)
	if !ok {
		return providerws.ModelAdmissionSettlementBinding{}, false, nil
	}
	// Step 2: the expected identity is the derived member; the six values
	// come from the session's current binding provenance.
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
		ExpectedCatalogModelHash:          member.Hash,
		ExpectedCatalogModelHashAlgorithm: member.HashAlgorithm,
	}
	byomArtifactPredicate(p, &predicate)
	if member.ArtifactID == "" {
		// A row pair (mlxlm_loopback only): no feed binding, no six values.
		if p.ArtifactIdentity != nil || predicate.ArtifactDerived() {
			return providerws.ModelAdmissionSettlementBinding{}, false, nil
		}
	} else if predicate.ArtifactID != member.ArtifactID || predicate.ArtifactHash != member.Hash || predicate.ArtifactHashAlgorithm != member.HashAlgorithm {
		return providerws.ModelAdmissionSettlementBinding{}, false, nil
	}
	// Step 3: every other field compares exactly as the global helper does.
	binding, ok := providerws.ModelAdmissionPoolSettlementBindingForRouteSnapshot(event, predicate)
	return binding, ok, nil
}

// poolModelAdmissionRouteGuard is the SPEC-047-R003(iv) pool sibling of the
// route-time compare-and-insert: it accepts a catalog_priced head. The ws
// server implements it.
type poolModelAdmissionRouteGuard interface {
	CompareAndInsertPoolModelAdmissionRouteSnapshot(context.Context, providerws.ModelAdmissionRouteExpectation, func() error) error
}

// insertPoolBYOMRouteSnapshot inserts an external-runtime pool attempt's route
// snapshot under the pool compare-and-insert. insertBYOMRouteSnapshot keeps
// requiring a settlement_capable head for every other route.
func (s *Server) insertPoolBYOMRouteSnapshot(ctx context.Context, p pool.Provider, binding providerws.ModelAdmissionSettlementBinding, insert func() error) error {
	guard, ok := s.modelAdmissionRouteGuard.(poolModelAdmissionRouteGuard)
	if !ok || binding.CandidateID == "" {
		return providerws.ErrModelAdmissionRouteStale
	}
	return guard.CompareAndInsertPoolModelAdmissionRouteSnapshot(ctx, providerws.ModelAdmissionRouteExpectation{
		ProviderID:         p.ProviderID,
		CandidateID:        binding.CandidateID,
		CoordinatorEventID: binding.CoordinatorEventID,
		BindingGeneration:  p.ModelAdmissionBindingGeneration,
		SessionEpoch:       p.ModelAdmissionSessionEpoch,
	}, insert)
}

// requireBYOMRouteSnapshotBindingForRoute is the route-snapshot entry point:
// a loopback session binds only through the pool branch, and fails closed
// before dispatch everywhere else.
func (s *Server) requireBYOMRouteSnapshotBindingForRoute(ctx context.Context, p pool.Provider, material tier2.RouteSnapshotMaterial, view poolRouteView) (providerws.ModelAdmissionSettlementBinding, error) {
	if !providerws.IsBYOMLoopbackRuntimeSource(p.RuntimeSource) {
		return s.requireBYOMRouteSnapshotBinding(ctx, p, material)
	}
	if !view.externalRuntimeCandidate(p) {
		return providerws.ModelAdmissionSettlementBinding{}, fmt.Errorf("loopback runtime is not settlement eligible outside an authorizing pool route")
	}
	binding, eligible, err := s.poolExternalRuntimeRouteBinding(ctx, p, material, view)
	if err != nil {
		return providerws.ModelAdmissionSettlementBinding{}, err
	}
	if !eligible || binding.CandidateID == "" {
		return providerws.ModelAdmissionSettlementBinding{}, fmt.Errorf("pool external runtime binding is not settlement eligible")
	}
	return binding, nil
}
