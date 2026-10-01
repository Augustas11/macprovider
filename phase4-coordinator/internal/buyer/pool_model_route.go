package buyer

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

// SPEC-042-R015 / SPEC-047-R011 / SPEC-005-R015 / SPEC-022-R013 /
// SPEC-006-R018 (#1816): a pool route for a `pool/<pool_id>/<slug>` model id
// selects only a member session whose SPEC-047-R011 binding is to that exact
// entry of the pool's active core, prices it from the entry within the
// configured bounds, and records a pool_manifest route snapshot. Global and
// other-pool routes never see a pool model: the request answers as an
// unknown model before selection.

const (
	poolModelDisclosureHeader    = "X-MacProvider-Model-Disclosure"
	poolManifestCoreDigestHeader = "X-MacProvider-Pool-Manifest-Core-Digest"
	poolModelDisclosureText      = "Pool-attested, not network-verified"
	poolModelPriceSource         = "pool_creator_signed"
)

// WithPoolModelPricingBounds wires the SPEC-005-R015 configured pool-model
// pricing bounds. A nil source (or nil bounds) fails every pool model closed.
func WithPoolModelPricingBounds(bounds func() *poolmanifest.PoolModelPricingBounds) Option {
	return func(s *Server) {
		s.poolModelPricingBounds = bounds
	}
}

func (s *Server) poolModelBounds() *poolmanifest.PoolModelPricingBounds {
	if s == nil || s.poolModelPricingBounds == nil {
		return nil
	}
	bounds := s.poolModelPricingBounds()
	if bounds == nil || bounds.Validate() != nil {
		return nil
	}
	return bounds
}

// requestedPoolModelEntry resolves a pool/ model id against the authorized
// pool snapshot: the entry exists only when the id names this pool and its
// active core carries it. Any other pool/ request has no entry.
func requestedPoolModelEntry(model, poolID string, snap trustpool.Snapshot) (poolmanifest.PoolModelEntry, bool) {
	if poolID == "" || !snap.Exists {
		return poolmanifest.PoolModelEntry{}, false
	}
	idPool, _, ok := poolmanifest.ParsePoolModelID(model)
	if !ok || idPool != poolID {
		return poolmanifest.PoolModelEntry{}, false
	}
	for _, entry := range snap.ModelEntries {
		if entry.PoolModelID == model {
			return entry, true
		}
	}
	return poolmanifest.PoolModelEntry{}, false
}

// providerRuntimeClass is the coordinator runtime class of a session: an
// absent runtime_source is native mlx_cache.
func providerRuntimeClass(p pool.Provider) string {
	if strings.TrimSpace(p.RuntimeSource) == "" {
		return engineClassNative
	}
	return p.RuntimeSource
}

// attestedMemberAccount is the SPEC-042-R016 half of condition (e): the
// provider's recorded owner account, when it is not the creator and the
// active core attests it for the session's runtime class.
func (v poolRouteView) attestedMemberAccount(p pool.Provider) (string, bool) {
	owner := v.memberOwnerAccounts[p.ProviderID]
	if v.poolID == "" || owner == "" || owner == v.creatorAccountID {
		return "", false
	}
	for _, a := range v.attestedMembers {
		if a.ProviderAccountID != owner {
			continue
		}
		for _, source := range a.RuntimeClasses {
			if source == p.RuntimeSource {
				return owner, true
			}
		}
	}
	return "", false
}

// poolModelCandidate is the snapshot half of the pool-model route predicate:
// a pool-model request on this pool, a current member whose live session is
// bound to exactly the requested entry and serves its exact pair under a
// runtime class the entry lists; a loopback class must also satisfy the
// SPEC-042-R004 external-runtime predicate (allowlist, creator or R016).
func (v poolRouteView) poolModelCandidate(p pool.Provider) bool {
	entry := v.poolModel
	if v.poolID == "" || entry == nil || !v.members[p.ProviderID] {
		return false
	}
	if p.ModelAdmissionPoolID != v.poolID || p.ModelAdmissionPoolModelID != entry.PoolModelID {
		return false
	}
	runtime := providerRuntimeClass(p)
	if !entry.AllowsRuntimeSource(runtime) {
		return false
	}
	if p.ModelHashAlgorithm != entry.ArtifactHashAlgorithm || strings.ToLower(strings.TrimSpace(p.ModelHash)) != entry.ArtifactHash {
		return false
	}
	if runtime == engineClassNative {
		return true
	}
	return v.externalRuntimeCandidate(p)
}

// poolModelEligibility is the pool-model branch of the shared paid-routing
// predicate: eligible only on a pool-model route through the current R011
// binding. A pool-bound session is never eligible anywhere else.
func (s *Server) poolModelEligibility(ctx context.Context, p pool.Provider) modelAdmissionPaidRoutingEligibility {
	view := poolRouteViewFrom(ctx)
	if !view.poolModelCandidate(p) {
		return modelAdmissionPaidRoutingEligibility{}
	}
	_, eligible, err := s.poolModelRouteBinding(ctx, p, view)
	if err != nil {
		return modelAdmissionEligibilityFromError(err)
	}
	return modelAdmissionPaidRoutingEligibility{eligible: eligible}
}

// poolModelRouteBinding is the SPEC-047-R011 current-route predicate,
// re-evaluated before every selection and snapshot insert: the session's
// head is the pool-scoped catalog_priced event bound to the requested entry
// of the pool's ACTIVE core, or of the immediately prior core when that core
// carries the same entry byte-identically (the sweep records the rebind
// asynchronously, so routing never gaps; #1816 F3), its pair,
// runtime class, rates, and account match the entry and member state, the
// entry's price is inside the configured bounds, and the receipt and
// enforce-mode prerequisites hold.
func (s *Server) poolModelRouteBinding(ctx context.Context, p pool.Provider, view poolRouteView) (providerws.ModelAdmissionEvent, bool, error) {
	if s == nil || s.modelAdmissionStore == nil || !view.poolModelCandidate(p) || !byomAdmissionCandidate(p) {
		return providerws.ModelAdmissionEvent{}, false, nil
	}
	if ctx == nil {
		ctx = context.Background()
	}
	event, found, err := s.modelAdmissionStore.LatestModelAdmissionStatus(ctx, p.ProviderID, strings.TrimSpace(p.ModelAdmissionCandidateID))
	if err != nil || !found {
		return providerws.ModelAdmissionEvent{}, false, err
	}
	entry := *view.poolModel
	runtime := providerRuntimeClass(p)
	eventRuntime := event.RuntimeSource
	if strings.TrimSpace(eventRuntime) == "" {
		eventRuntime = engineClassNative
	}
	if event.CoordinatorEventID == "" || event.CoordinatorEventID != strings.TrimSpace(p.ModelAdmissionCoordinatorEventID) ||
		!event.PoolScoped() || event.State != "catalog_priced" || event.CatalogModelKey != "" ||
		event.PoolID != view.poolID || event.PoolModelID != entry.PoolModelID ||
		!view.bindingGenerationRoutable(event.PoolManifestVersion, event.PoolManifestCoreDigest) ||
		event.ExpectedCatalogModelHashAlgorithm != entry.ArtifactHashAlgorithm || event.ExpectedCatalogModelHash != entry.ArtifactHash ||
		eventRuntime != runtime ||
		event.PoolPromptRatePerMtok != int64(entry.Pricing.PromptRatePerMtok) ||
		event.PoolPromptCacheHitRatePerMtok != int64(entry.Pricing.PromptCacheHitRatePerMtok) ||
		event.PoolCompletionRatePerMtok != int64(entry.Pricing.CompletionRatePerMtok) {
		return providerws.ModelAdmissionEvent{}, false, nil
	}
	if runtime != engineClassNative {
		account := view.creatorAccountID
		if !view.creatorOwned[p.ProviderID] {
			attested, ok := view.attestedMemberAccount(p)
			if !ok {
				return providerws.ModelAdmissionEvent{}, false, nil
			}
			account = attested
		}
		if event.PoolProviderAccountID != account {
			return providerws.ModelAdmissionEvent{}, false, nil
		}
	}
	bounds := s.poolModelBounds()
	if bounds == nil || !bounds.Contains(entry.Pricing) {
		return providerws.ModelAdmissionEvent{}, false, nil
	}
	if !s.settlementEnforceMode() || !validProviderReceiptPubkey(p) || p.ModelAdmissionValidatedReleaseGeneration == 0 {
		return providerws.ModelAdmissionEvent{}, false, nil
	}
	return event, true, nil
}

// tier2ProviderExcludedForRoute is the Tier-2 gate with the one pool-model
// exception: a pool-model candidate's identity is its R011 binding, so an
// uncatalogued hash status does not exclude it on that route; a mismatch,
// encrypted-leg, or attestation failure still does.
func (s *Server) tier2ProviderExcludedForRoute(p pool.Provider, view poolRouteView) bool {
	if view.poolModelCandidate(p) {
		cfg := s.tier2Config()
		status := s.effectiveHashStatus(p, cfg)
		if status == pool.HashStatusUncatalogued || status == pool.HashStatusCatalogUnavailable {
			p.HashStatus = pool.HashStatusVerified
		}
	}
	return s.tier2ProviderExcluded(p)
}

// recordPoolModelRouteSnapshot is recordRouteSnapshot for a pool-model
// attempt: a SPEC-022-R013 pool_manifest snapshot whose expected identity and
// price are the bound entry of the pool's active core, inserted under the
// pool compare-and-insert. The catalog_* members carry the global catalog
// envelope in force (which does not price this pair), never the identity.
func (b *billingRecorder) recordPoolModelRouteSnapshot(ctx context.Context, providerBody []byte, provider pool.Provider, attemptN int, store *billing.Store, routeMode string, pendingDeadlineSeconds int) (*providerws.SettlementReceiptMetadata, error) {
	view := b.state.poolRouteView()
	if routeMode != billing.RouteSnapshotModeEnforce {
		return nil, fmt.Errorf("pool model attempt requires enforce-mode settlement")
	}
	entry := view.poolModel
	keyID, err := billing.ReceiptKeyID(provider.ReceiptPubkey)
	if err != nil || entry == nil {
		return nil, fmt.Errorf("pool model attempt requires a provider receipt key")
	}
	reportedHash := strings.ToLower(strings.TrimSpace(provider.ModelHash))
	if !modelidentity.CanonicalAlgorithm(provider.ModelHashAlgorithm) || provider.ModelHashAlgorithm != entry.ArtifactHashAlgorithm || reportedHash != entry.ArtifactHash {
		return nil, fmt.Errorf("provider model identity does not match the pool model entry")
	}
	event, eligible, err := b.server.poolModelRouteBinding(ctx, provider, view)
	if err != nil {
		return nil, wrapRouteSnapshotGuardPressure(err)
	}
	if !eligible {
		return nil, fmt.Errorf("pool model binding is not current for this route")
	}
	envelope, ok := tier2.Default().EnvelopeMaterial()
	if !ok {
		return nil, fmt.Errorf("pool model attempt requires the signed catalog envelope")
	}
	bounds := b.server.poolModelBounds()
	if bounds == nil {
		return nil, fmt.Errorf("pool model attempt requires configured pricing bounds")
	}
	promptHash, err := coordinatorPromptHash(providerBody)
	if err != nil {
		return nil, err
	}
	snapshot := billing.RouteSnapshot{
		AccountScope:                         accountScopeForSettlement(b.accountID),
		RequestID:                            b.requestID,
		AttemptN:                             int64(attemptN),
		ProviderID:                           provider.ProviderID,
		ProviderSessionID:                    stringPtrOrNil(provider.AssignedID),
		PaidEntrypoint:                       "coordinator_buyer_v1_chat_completions",
		ProviderReceiptKeyID:                 keyID,
		ProviderReceiptKeySource:             "auth_session",
		ModelID:                              provider.ModelID,
		ProviderReportedModelHash:            reportedHash,
		ProviderReportedModelHashAlgorithm:   entry.ArtifactHashAlgorithm,
		ExpectedCatalogModelHash:             entry.ArtifactHash,
		ExpectedCatalogModelHashAlgorithm:    entry.ArtifactHashAlgorithm,
		CatalogID:                            envelope.CatalogID,
		CatalogBodyDigest:                    envelope.CatalogBodyDigest,
		CatalogSignatureKeyID:                envelope.CatalogSignatureKeyID,
		CatalogSignaturePubkeyFingerprint:    envelope.CatalogSignaturePubkeyFingerprint,
		CatalogExpiresAtUnixMS:               envelope.CatalogExpiresAt.UnixMilli(),
		Spec008HashStatus:                    string(pool.HashStatusUncatalogued),
		RouteSnapshotPolicyVersion:           billing.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:                    routeMode,
		RouteDecisionTSUnixMS:                b.state.routingDone.UnixMilli(),
		RequestStartTSUnixMS:                 b.startedAt.UnixMilli(),
		PendingDeadlineSeconds:               int64(pendingDeadlineSeconds),
		PromptHashBasis:                      promptHashBasisCoordinatorV1,
		PromptHash:                           promptHash,
		PoolID:                               view.poolID,
		ManifestVersion:                      view.manifestVersion,
		ManifestCoreDigest:                   view.manifestCoreDigest,
		PoolGeneration:                       b.state.poolGeneration,
		ExpectedModelHashSource:              billing.ExpectedModelHashSourcePoolManifest,
		PoolModelID:                          entry.PoolModelID,
		PoolModelPromptRatePerMtok:           int64(entry.Pricing.PromptRatePerMtok),
		PoolModelPromptCacheHitRatePerMtok:   int64(entry.Pricing.PromptCacheHitRatePerMtok),
		PoolModelCompletionRatePerMtok:       int64(entry.Pricing.CompletionRatePerMtok),
		PoolModelPricingBoundsSHA256:         bounds.SHA256Hex(),
		ModelAdmissionCandidateID:            event.CandidateID,
		ModelAdmissionCoordinatorEventID:     event.CoordinatorEventID,
		ModelAdmissionServedModelRef:         event.ServedModelRef,
		ModelAdmissionDiscoveryDigestSHA256:  event.DiscoveryDigestSHA256,
		ModelAdmissionEvaluationDigestSHA256: event.EvaluationDigestSHA256,
	}
	if providerRuntimeClass(provider) != engineClassNative {
		snapshot.RuntimeSource = provider.RuntimeSource
		snapshot.PoolOperatorAccountID = view.creatorAccountID
		if !view.creatorOwned[provider.ProviderID] {
			snapshot.PoolMemberAccountID = event.PoolProviderAccountID
		}
	}
	computeIntegrityRequired, computeIntegrityCovered, computeIntegrityHardwareDigest, err := computeIntegrityRouteBinding(provider, routeMode)
	if err != nil {
		return nil, err
	}
	snapshot.ComputeIntegrityCaptureRequired = computeIntegrityRequired
	snapshot.ComputeIntegritySamplingCovered = computeIntegrityCovered
	snapshot.ComputeIntegrityHardwareDigest = computeIntegrityHardwareDigest
	var digest string
	insertErr := b.server.insertPoolModelRouteSnapshot(ctx, provider, event, func() error {
		inserted, err := store.InsertRouteSnapshot(ctx, snapshot)
		digest = inserted
		return err
	})
	if insertErr != nil {
		return nil, wrapRouteSnapshotGuardPressure(insertErr)
	}
	b.settlementAttemptN = attemptN
	b.hasSettlementAttemptN = true
	b.settlementRouteSnapshotDigest = digest
	b.settlementPolicyMode = snapshot.RouteSnapshotMode
	b.settlementPolicyVersion = snapshot.RouteSnapshotPolicyVersion
	recorded := snapshot
	b.settlementRouteSnapshot = &recorded
	meta := &providerws.SettlementReceiptMetadata{
		AccountScope:               snapshot.AccountScope,
		RequestID:                  snapshot.RequestID,
		AttemptN:                   snapshot.AttemptN,
		ProviderID:                 snapshot.ProviderID,
		ProviderReceiptKeyID:       snapshot.ProviderReceiptKeyID,
		ModelID:                    snapshot.ModelID,
		ExpectedCatalogModelHash:   snapshot.ExpectedCatalogModelHash,
		CatalogID:                  snapshot.CatalogID,
		CatalogBodyDigest:          snapshot.CatalogBodyDigest,
		RouteSnapshotDigest:        digest,
		RouteSnapshotPolicyVersion: snapshot.RouteSnapshotPolicyVersion,
		RouteSnapshotMode:          snapshot.RouteSnapshotMode,
		PromptHash:                 snapshot.PromptHash,
		OutputPrefixStartByte:      b.outputCursorByte,
		PendingDeadlineSeconds:     snapshot.PendingDeadlineSeconds,
	}
	if snapshot.RuntimeSource != "" {
		meta.PoolRuntimeAuthorization = &providerws.PoolRuntimeAuthorization{
			PoolID:              snapshot.PoolID,
			ManifestCoreDigest:  snapshot.ManifestCoreDigest,
			RuntimeSource:       snapshot.RuntimeSource,
			RequestID:           snapshot.RequestID,
			AttemptN:            snapshot.AttemptN,
			ProviderID:          snapshot.ProviderID,
			RouteSnapshotDigest: digest,
		}
	}
	return meta, nil
}

// insertPoolModelRouteSnapshot inserts a pool-model attempt's snapshot under
// the pool compare-and-insert (the head must still be the bound pool event).
func (s *Server) insertPoolModelRouteSnapshot(ctx context.Context, p pool.Provider, event providerws.ModelAdmissionEvent, insert func() error) error {
	guard, ok := s.modelAdmissionRouteGuard.(poolModelAdmissionRouteGuard)
	if !ok || event.CandidateID == "" {
		return providerws.ErrModelAdmissionRouteStale
	}
	return guard.CompareAndInsertPoolModelAdmissionRouteSnapshot(ctx, providerws.ModelAdmissionRouteExpectation{
		ProviderID:         p.ProviderID,
		CandidateID:        event.CandidateID,
		CoordinatorEventID: event.CoordinatorEventID,
		BindingGeneration:  p.ModelAdmissionBindingGeneration,
		SessionEpoch:       p.ModelAdmissionSessionEpoch,
	}, insert)
}

// poolManifestVerification is the recorder's SPEC-022-R013 decision for a
// pool_manifest attempt: the durable records re-verify the exact entry in the
// immutable core the snapshot names (and, for a loopback class, the full
// pool_operator_attested predicate), the label is undisputed, and the fence
// pins the pool state the decision used.
func (b *billingRecorder) poolManifestVerification(ctx context.Context, store *billing.Store, providerID string, poolAttested bool, poolFence *billing.PoolAttestationFence) (route *billing.RouteSnapshot, verified bool, fence *billing.PoolAttestationFence) {
	snap := b.settlementRouteSnapshot
	if b == nil || store == nil || snap == nil || !snap.PoolManifestSourced() || !b.hasSettlementAttemptN ||
		snap.ProviderID != providerID || snap.AttemptN != int64(b.settlementAttemptN) {
		return nil, false, nil
	}
	if snap.RuntimeSource != "" {
		// A loopback pool-model attempt is verified exactly when it is
		// pool_operator_attested (that authority replays the entry too).
		return snap, poolAttested, poolFence
	}
	f, ok := store.PoolAttestationFenceFor(ctx, *snap)
	if !ok || !billing.PoolAttestationFenceMatchesRoute(f, *snap) {
		return snap, false, nil
	}
	if err := store.PoolManifestRouteEligible(ctx, *snap); err != nil {
		if b.server != nil {
			b.server.log.Warn().Err(err).
				Str("event", "pool_manifest_route_rejected").
				Str("pool_id", snap.PoolID).
				Str("request_id", b.requestID).
				Str("provider_id", providerID).
				Msg("pool-model attempt zero-billed: durable pool records do not support the pool_manifest route")
		}
		return snap, false, nil
	}
	if !billing.PoolOperatorAttestedLabelVerified(*snap, b.settlementRouteSnapshotDigest, b.settlementPoolLabels()) {
		return snap, false, nil
	}
	return snap, true, f
}

// setPoolModelResponseHeaders adds the SPEC-006-R018 disclosure headers to a
// response for a pool model (never for any other model).
func setPoolModelResponseHeaders(w http.ResponseWriter, manifestCoreDigest string) {
	if w == nil || !isLowerHex64(manifestCoreDigest) {
		return
	}
	w.Header().Set(poolModelDisclosureHeader, poolmanifest.PoolModelDisclosureClass)
	w.Header().Set(poolManifestCoreDigestHeader, manifestCoreDigest)
}

// poolModelListEntry is the SPEC-006-R018 pool view model object.
type poolModelListEntry struct {
	PoolID                string             `json:"pool_id"`
	PoolModelID           string             `json:"pool_model_id"`
	DisclosureClass       string             `json:"disclosure_class"`
	DisclosureText        string             `json:"disclosure_text"`
	RuntimeSources        []string           `json:"runtime_sources"`
	ArtifactHashAlgorithm string             `json:"artifact_hash_algorithm"`
	ArtifactHash          string             `json:"artifact_hash"`
	MaxContextTokens      uint64             `json:"max_context_tokens"`
	Price                 poolModelListPrice `json:"price"`
	PriceSource           string             `json:"price_source"`
	ManifestVersion       uint64             `json:"manifest_version"`
	ManifestCoreDigest    string             `json:"manifest_core_digest"`
}

type poolModelListPrice struct {
	PromptRatePerMtok         int64 `json:"prompt_rate_per_mtok"`
	PromptCacheHitRatePerMtok int64 `json:"prompt_cache_hit_rate_per_mtok"`
	CompletionRatePerMtok     int64 `json:"completion_rate_per_mtok"`
	GlobalMultiplierPPM       int64 `json:"global_multiplier_ppm"`
}

// poolModelListedMember reports whether a live session counts toward a pool
// model's listed capacity: a current member of the pool, bound to exactly
// this entry, serving its exact pair under a runtime class the entry lists,
// and ready or busy. A pool-entry session stays admission_sandboxed for every
// global purpose, so the global capacity predicate does not apply; route time
// still re-checks every pool predicate.
func poolModelListedMember(p pool.Provider, snap trustpool.Snapshot, entry poolmanifest.PoolModelEntry) bool {
	return snap.Members[p.ProviderID] && (p.State == pool.StateReady || p.State == pool.StateBusy) &&
		p.ModelAdmissionPoolID == snap.PoolID && p.ModelAdmissionPoolModelID == entry.PoolModelID &&
		entry.AllowsRuntimeSource(providerRuntimeClass(p)) &&
		p.ModelHashAlgorithm == entry.ArtifactHashAlgorithm && strings.ToLower(strings.TrimSpace(p.ModelHash)) == entry.ArtifactHash
}

// errPoolModelViewUnauthorized means a pool view was requested without an
// authorized pool selection.
var errPoolModelViewUnauthorized = errors.New("pool view requires an authorized pool selection")

// poolModelListEntries is the SPEC-006-R018 pool view of /v1/models: the
// authorized pool's current entries only.
func (s *Server) poolModelListEntries(r *http.Request) ([]modelEntry, error) {
	rawPool := strings.TrimSpace(r.Header.Get("X-MacProvider-Pool"))
	poolID := sanitizeAccountID(rawPool)
	if poolID == "" || s.trustPools == nil || !s.internalBearerAuthorizedRemote(r.Header, r.RemoteAddr) {
		return nil, errPoolModelViewUnauthorized
	}
	accountID := sanitizeAccountID(r.Header.Get("X-MacProvider-Account"))
	if accountID == "" {
		return nil, errPoolModelViewUnauthorized
	}
	snap, authorized, err := s.authorizeTrustPoolFromDurableState(r.Context(), poolID, accountID)
	if err != nil || !authorized || !snap.Exists || !snap.Routeable {
		return nil, errPoolModelViewUnauthorized
	}
	economics := s.economicsSnapshotForModel("default")
	providers := s.pool.Snapshot()
	out := make([]modelEntry, 0, len(snap.ModelEntries))
	for _, entry := range snap.ModelEntries {
		// #1816 F6: capacity is the pool's live members bound to this exact
		// entry; the context bound is the entry's signed max_context_tokens.
		providerCount, totalSlots := 0, 0
		for _, p := range providers {
			if poolModelListedMember(p, snap, entry) {
				providerCount++
				totalSlots += p.SlotsTotal
			}
		}
		maxContext := 0
		if entry.MaxContextTokens <= uint64(math.MaxInt32) {
			maxContext = int(entry.MaxContextTokens)
		}
		out = append(out, modelEntry{
			ID:               entry.PoolModelID,
			Object:           "model",
			Created:          s.createdAt,
			OwnedBy:          "macprovider",
			ProviderCount:    providerCount,
			MaxContextTokens: maxContext,
			TotalSlots:       totalSlots,
			ComputeIntegrity: unavailableModelComputeIntegrityStatus(),
			PoolModel: &poolModelListEntry{
				PoolID:                snap.PoolID,
				PoolModelID:           entry.PoolModelID,
				DisclosureClass:       entry.DisclosureClass,
				DisclosureText:        poolModelDisclosureText,
				RuntimeSources:        append([]string(nil), entry.AllowedRuntimeSources...),
				ArtifactHashAlgorithm: entry.ArtifactHashAlgorithm,
				ArtifactHash:          entry.ArtifactHash,
				MaxContextTokens:      entry.MaxContextTokens,
				Price: poolModelListPrice{
					PromptRatePerMtok:         int64(entry.Pricing.PromptRatePerMtok),
					PromptCacheHitRatePerMtok: int64(entry.Pricing.PromptCacheHitRatePerMtok),
					CompletionRatePerMtok:     int64(entry.Pricing.CompletionRatePerMtok),
					GlobalMultiplierPPM:       economics.multiplierPPM,
				},
				PriceSource:        poolModelPriceSource,
				ManifestVersion:    snap.ManifestVersion,
				ManifestCoreDigest: snap.ManifestCoreDigest,
			},
		})
	}
	return out, nil
}
