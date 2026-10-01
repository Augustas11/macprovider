package ws

import (
	"context"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/poolmanifest"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

// SPEC-042-R015 / SPEC-047-R011 (#1816): pool-manifest admission. This file
// holds the catalog-identity probes the trust-pool store applies at manifest
// acceptance; the binding itself lives next to the catalog binding.

// IsCatalogModelID reports whether id equals or normalizes onto a SPEC-010
// canonical id in the live catalog (the autotune release catalog or the
// Tier-2 catalog). A pool_model_id or its slug that does is rejected at
// manifest acceptance (SPEC-042-R015 shadowing rule).
func (s *Server) IsCatalogModelID(id string) bool {
	id = strings.TrimSpace(id)
	if id == "" {
		return false
	}
	if tier2.Catalogued(id) {
		return true
	}
	current, _ := s.autotuneCatalogSnapshot()
	return catalogShadowsModelID(current, id)
}

func catalogShadowsModelID(current *autotune.Catalog, id string) bool {
	if current == nil {
		return false
	}
	if _, _, ok := current.HighestClaimedTier(id); ok {
		return true
	}
	normalized := billing.NormalizeModelKey(strings.ToLower(id))
	for _, key := range current.Keys() {
		row, _ := current.Row(key)
		if billing.NormalizeModelKey(strings.ToLower(row.ModelID)) == normalized ||
			billing.NormalizeModelKey(strings.ToLower(key)) == normalized {
			return true
		}
	}
	return false
}

// poolCatalogPairStatus is how one exact artifact pair stands against the
// current global catalog release (SPEC-042-R015 catalog overlap and
// precedence).
type poolCatalogPairStatus struct {
	// priceable holds the runtime classes for which the pair resolves to a
	// recommendable row with a verified member usable by that class.
	priceable map[string]bool
	// blocked is set when the pair resolves to a blocked row.
	blocked bool
	// observedKey is a candidate or listed row the pair resolves to (audit
	// only, never an identity, price, or route).
	observedKey string
}

func (st poolCatalogPairStatus) priceableFor(runtimes ...string) bool {
	for _, runtime := range runtimes {
		if st.priceable[runtime] {
			return true
		}
	}
	return false
}

// classifyCatalogPair resolves an exact pair against the current release
// (a row's own snapshot pair, or a release-bound artifact-feed member).
func (s *Server) classifyCatalogPair(algorithm, hash string) poolCatalogPairStatus {
	hash = strings.ToLower(strings.TrimSpace(hash))
	var status poolCatalogPairStatus
	if algorithm == "" || hash == "" {
		return status
	}
	s.withReleaseRead(func() {
		current, _ := s.autotuneCatalogSnapshot()
		status = classifyCatalogPairLocked(current, s.usableIdentitySetLocked(current), algorithm, hash)
	})
	return status
}

func classifyCatalogPairLocked(current *autotune.Catalog, set *artifactidentity.Index, algorithm, hash string) poolCatalogPairStatus {
	status := poolCatalogPairStatus{priceable: map[string]bool{}}
	if current == nil {
		return status
	}
	runtimes := []string{modelAdmissionRuntimeSourceMLXCache, poolmanifest.RuntimeSourceLlamacppLoopback, poolmanifest.RuntimeSourceLMStudioLoopback,
		poolmanifest.RuntimeSourceMLXLMLoopback, poolmanifest.RuntimeSourceOllamaLoopback, poolmanifest.RuntimeSourceOMLXLoopback}
	observe := func(key string, row autotune.Row, usable func(string) bool) {
		switch row.RuntimeStatus {
		case "blocked":
			status.blocked = true
		case "recommendable":
			for _, runtime := range runtimes {
				if usable(runtime) {
					status.priceable[runtime] = true
				}
			}
		case "candidate", "listed":
			if status.observedKey == "" || key < status.observedKey {
				status.observedKey = key
			}
		}
	}
	if algorithm == modelidentity.SnapshotManifestV1 {
		for _, key := range current.Keys() {
			row, _ := current.Row(key)
			if strings.TrimSpace(row.ModelSHA256) != hash {
				continue
			}
			observe(key, row, func(runtime string) bool { return candidateRowAllowsRuntimeSource(set, key, hash, runtime) })
		}
	}
	if set != nil {
		if binding, ok := set.Resolve(algorithm, hash); ok {
			if row, ok := current.Row(binding.Member.ModelKey); ok {
				observe(binding.Member.ModelKey, row, binding.Member.AllowsRuntimeSource)
			}
		}
	}
	return status
}

// ArtifactPairInCatalog is the SPEC-042-R015 acceptance-time overlap check:
// the pair is catalog-priceable for any listed runtime class (recommendable
// with a verified member usable by it) or resolves to a blocked row. A
// candidate or listed match leaves the entry valid.
func (s *Server) ArtifactPairInCatalog(algorithm, hash string, runtimes []string) bool {
	status := s.classifyCatalogPair(algorithm, hash)
	return status.blocked || status.priceableFor(runtimes...)
}

// ---- SPEC-047-R011 pool-manifest admission binding

// Closed R011 reasons: the signed pool manifest actor's bind and rebind, and
// the revocations of a pool-scoped binding.
const (
	ModelAdmissionReasonPoolManifestBound     = "pool_manifest_bound"
	ModelAdmissionReasonPoolManifestRebound   = "pool_manifest_rebound"
	ModelAdmissionRevokePoolBindingDrift      = "pool_manifest_binding_drift"
	ModelAdmissionRevokePoolEntryRevoked      = "pool_manifest_entry_revoked"
	ModelAdmissionRevokePoolMembershipRevoked = "pool_membership_revoked"
	ModelAdmissionRevokePoolHistoryInvalid    = "pool_manifest_history_invalid"
	ModelAdmissionRevokePoolCatalogSuperseded = "pool_manifest_catalog_superseded"

	modelAdmissionPoolManifestActorPrefix = "pool_manifest:"
	modelAdmissionPoolDecisionDomain      = "macprovider.model_admission.pool_manifest_decision.v1"
	modelAdmissionPoolRevocationDomain    = "macprovider.model_admission.pool_manifest_revocation.v1"
	poolManifestBindingSweepInterval      = 2 * time.Second
	poolManifestBindingSweepFullEvery     = 15
)

// modelAdmissionPoolBindStates are the heads the signed pool manifest actor
// may bind from: the offer, and the non-earning interim states the bounded
// synthetic probe moves a live offer into (an offer submitted before its
// pool entry existed must still bind once the entry lands).
func modelAdmissionPoolBindState(state string) bool {
	switch state {
	case modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled":
		return true
	}
	return false
}

// PoolModelSource is the trust-pool registry view the R011 binding reads.
type PoolModelSource interface {
	PoolIDs() []string
	Snapshot(poolID string) trustpool.Snapshot
	Revision() uint64
}

type poolModelWiring struct {
	source PoolModelSource
	bounds func() *poolmanifest.PoolModelPricingBounds
}

// SetPoolModelSource wires the SPEC-047-R011 binding input: the trust-pool
// registry and the configured SPEC-005-R015 pricing bounds. A nil source
// turns the pool-manifest binding off.
func (s *Server) SetPoolModelSource(source PoolModelSource, bounds func() *poolmanifest.PoolModelPricingBounds) {
	if source == nil {
		s.poolModels.Store(nil)
		return
	}
	s.poolModels.Store(&poolModelWiring{source: source, bounds: bounds})
}

// PoolManifestActor is the R001 signed pool manifest actor string.
func PoolManifestActor(poolID string, manifestVersion uint64, manifestCoreDigest string) string {
	return modelAdmissionPoolManifestActorPrefix + poolID + ":" + strconv.FormatUint(manifestVersion, 10) + ":" + manifestCoreDigest
}

// modelAdmissionPoolEdge reports whether event is one of the signed pool
// manifest actor's two edges from previous: the bind (a non-pool interim
// head -> pool catalog_priced, pool_manifest_bound) or the rebind (pool
// catalog_priced -> pool catalog_priced of the same pool and entry,
// pool_manifest_rebound).
func modelAdmissionPoolEdge(previous, event ModelAdmissionEvent) bool {
	if !event.PoolScoped() || event.State != "catalog_priced" {
		return false
	}
	switch {
	case event.ReasonCode == ModelAdmissionReasonPoolManifestBound:
		return !previous.PoolScoped() && modelAdmissionPoolBindState(previous.State)
	case event.ReasonCode == ModelAdmissionReasonPoolManifestRebound:
		return previous.PoolScoped() && previous.State == "catalog_priced" &&
			previous.PoolID == event.PoolID && previous.PoolModelID == event.PoolModelID &&
			previous.ExpectedCatalogModelHash == event.ExpectedCatalogModelHash &&
			previous.RuntimeSource == event.RuntimeSource &&
			event.PoolManifestVersion > previous.PoolManifestVersion
	}
	return false
}

// modelAdmissionEventHasPoolAuthority is the closed pool_binding object check
// for a bind/rebind append: every field present and in grammar, no catalog
// identity, and the actor derived from the recorded pool core.
func modelAdmissionEventHasPoolAuthority(event ModelAdmissionEvent) bool {
	poolID, _, ok := poolmanifest.ParsePoolModelID(event.PoolModelID)
	format, formatOK := poolmanifest.RuntimeSourceFormat(modelAdmissionRuntimeClass(event.RuntimeSource))
	return ok && poolID == event.PoolID &&
		strings.TrimSpace(event.CatalogModelKey) == "" &&
		event.PoolManifestVersion > 0 && validModelAdmissionSHA256Hex(event.PoolManifestCoreDigest) &&
		formatOK && event.ExpectedCatalogModelHashAlgorithm == format &&
		validModelAdmissionSHA256Hex(event.ExpectedCatalogModelHash) &&
		event.PoolPromptRatePerMtok >= 0 && event.PoolCompletionRatePerMtok >= 0 &&
		event.PoolPromptCacheHitRatePerMtok >= 0 && event.PoolPromptCacheHitRatePerMtok <= event.PoolPromptRatePerMtok &&
		event.PoolDisclosureClass == poolmanifest.PoolModelDisclosureClass &&
		event.PoolMaxContextTokens >= 1 && event.PoolMaxContextTokens <= poolmanifest.MaxPoolModelContext &&
		(event.PoolProbeEvidenceDigest == "" || validModelAdmissionSHA256Hex(event.PoolProbeEvidenceDigest)) &&
		event.Actor == PoolManifestActor(event.PoolID, event.PoolManifestVersion, event.PoolManifestCoreDigest)
}

// modelAdmissionRuntimeClass is the coordinator runtime class of a recorded
// or hello runtime source: an absent value is native mlx_cache.
func modelAdmissionRuntimeClass(runtimeSource string) string {
	if strings.TrimSpace(runtimeSource) == "" {
		return modelAdmissionRuntimeSourceMLXCache
	}
	return runtimeSource
}

// offeredPoolPair is the offer's single artifact pair whose format matches
// its signed runtime source; zero or several such pairs bind nothing.
func offeredPoolPair(event ModelAdmissionEvent) (string, string, bool) {
	format, ok := poolmanifest.RuntimeSourceFormat(modelAdmissionRuntimeClass(event.RuntimeSource))
	if !ok {
		return "", "", false
	}
	hash := strings.ToLower(strings.TrimSpace(event.OfferedArtifactHashes[format]))
	if !validModelAdmissionSHA256Hex(hash) {
		return "", "", false
	}
	return format, hash, true
}

// poolMemberAccount applies the SPEC-042-R004/R016 member predicate for one
// runtime class: a current member of an enforce-mode pool; for a loopback
// class the class on the signed allowlist and the provider creator-owned or
// named, through its recorded owner account, by an attestation for that
// class. It returns the provider account the binding records.
func poolMemberAccount(view trustpool.Snapshot, providerID, runtime string) (string, bool) {
	if !view.Exists || !view.Members[providerID] || view.SettlementMode != "enforce" {
		return "", false
	}
	owner := view.MemberOwnerAccounts[providerID]
	creatorOwned := view.CreatorAccountID != "" && view.CreatorOwnedMembers[providerID]
	if runtime == modelAdmissionRuntimeSourceMLXCache {
		if creatorOwned {
			return view.CreatorAccountID, true
		}
		return owner, true
	}
	allowed := false
	for _, source := range view.RuntimeAllowlist {
		allowed = allowed || source == runtime
	}
	if !allowed {
		return "", false
	}
	if creatorOwned {
		return view.CreatorAccountID, true
	}
	if owner == "" || owner == view.CreatorAccountID {
		return "", false
	}
	for _, a := range view.AttestedMembers {
		if a.ProviderAccountID != owner {
			continue
		}
		for _, source := range a.RuntimeClasses {
			if source == runtime {
				return owner, true
			}
		}
	}
	return "", false
}

func poolEntryForPair(view trustpool.Snapshot, algorithm, hash, runtime string) (poolmanifest.PoolModelEntry, bool) {
	for _, entry := range view.ModelEntries {
		if entry.ArtifactHashAlgorithm == algorithm && entry.ArtifactHash == hash && entry.AllowsRuntimeSource(runtime) {
			return entry, true
		}
	}
	return poolmanifest.PoolModelEntry{}, false
}

func (w *poolModelWiring) pricingBounds() *poolmanifest.PoolModelPricingBounds {
	if w == nil || w.bounds == nil {
		return nil
	}
	return w.bounds()
}

func entryWithinBounds(entry poolmanifest.PoolModelEntry, bounds *poolmanifest.PoolModelPricingBounds) bool {
	return bounds != nil && bounds.Contains(entry.Pricing)
}

// poolBindingDecision builds the signed pool manifest actor's bind or rebind
// event from the candidate head and the current entry of the active core.
func poolBindingDecision(head ModelAdmissionEvent, view trustpool.Snapshot, entry poolmanifest.PoolModelEntry, account, observedCatalogKey, reason string, now time.Time) ModelAdmissionEvent {
	evidence := strings.Join([]string{view.PoolID, strconv.FormatUint(view.ManifestVersion, 10), view.ManifestCoreDigest, entry.PoolModelID}, "|")
	event := modelAdmissionCoordinatorDecisionFromCurrent(head, "catalog_priced", reason, modelAdmissionPoolDecisionDomain, evidence, now)
	// A pool entry is never a catalog identity: no catalog key, catalog
	// envelope, member set, or feed binding is carried forward.
	event.CatalogModelKey = ""
	event.CatalogID, event.CatalogBodyDigest, event.CatalogSignatureKeyID, event.CatalogSignaturePubkeyFingerprint = "", "", "", ""
	event.CatalogMatchState, event.CatalogMatchReason, event.CatalogRowModelID, event.CatalogRowModelSHA256 = "", "", "", ""
	event.CatalogReleaseID, event.CatalogCandidateSHA256, event.CatalogSignerKeyID = "", "", ""
	event.CatalogMembers = nil
	event.ArtifactFeedSHA256, event.ArtifactID, event.ArtifactHash, event.ArtifactHashAlgorithm = "", "", "", ""
	event.ArtifactFeedSignerKeyID, event.ArtifactCandidateCatalogSHA256, event.BoundMemberSource = "", "", ""
	event.EvaluatedReleaseGeneration = 0
	event.SyntheticProbeCompletionTokens = 0
	event.OfferedArtifactHashes = nil
	event.ExpectedCatalogModelHashAlgorithm = entry.ArtifactHashAlgorithm
	event.ExpectedCatalogModelHash = entry.ArtifactHash
	event.BindingScope = ModelAdmissionBindingScopePool
	event.PoolID = view.PoolID
	event.PoolModelID = entry.PoolModelID
	event.PoolManifestVersion = view.ManifestVersion
	event.PoolManifestCoreDigest = view.ManifestCoreDigest
	event.PoolPromptRatePerMtok = int64(entry.Pricing.PromptRatePerMtok)
	event.PoolPromptCacheHitRatePerMtok = int64(entry.Pricing.PromptCacheHitRatePerMtok)
	event.PoolCompletionRatePerMtok = int64(entry.Pricing.CompletionRatePerMtok)
	event.PoolDisclosureClass = entry.DisclosureClass
	event.PoolMaxContextTokens = entry.MaxContextTokens
	event.PoolProviderAccountID = account
	event.PoolProbeEvidenceDigest = ""
	event.PoolObservedCatalogModelKey = observedCatalogKey
	event.Actor = PoolManifestActor(view.PoolID, view.ManifestVersion, view.ManifestCoreDigest)
	return event
}

// poolBindingDecisionForHead evaluates one candidate head against the
// current pool state and returns the single R011 event it calls for, if any.
// It is pure over its inputs (the caller supplies the catalog verdict).
func poolBindingDecisionForHead(wiring *poolModelWiring, providerID string, head ModelAdmissionEvent, classify func(algorithm, hash string) poolCatalogPairStatus, now time.Time) (ModelAdmissionEvent, bool) {
	if wiring == nil || wiring.source == nil {
		return ModelAdmissionEvent{}, false
	}
	runtime := modelAdmissionRuntimeClass(head.RuntimeSource)
	bounds := wiring.pricingBounds()
	if head.PoolScoped() {
		if head.State != "catalog_priced" {
			return ModelAdmissionEvent{}, false
		}
		revoke := func(reason string) (ModelAdmissionEvent, bool) {
			evidence := strings.Join([]string{head.PoolID, strconv.FormatUint(head.PoolManifestVersion, 10), head.PoolManifestCoreDigest, head.PoolModelID}, "|")
			return modelAdmissionCoordinatorDecisionFromCurrent(head, modelAdmissionRevoked, reason, modelAdmissionPoolRevocationDomain, evidence, now), true
		}
		catalog := classify(head.ExpectedCatalogModelHashAlgorithm, head.ExpectedCatalogModelHash)
		if catalog.blocked {
			return revoke(ModelAdmissionRevokePoolEntryRevoked)
		}
		if catalog.priceableFor(runtime) {
			return revoke(ModelAdmissionRevokePoolCatalogSuperseded)
		}
		view := wiring.source.Snapshot(head.PoolID)
		// Revocation needs positive evidence: an unknown, unrouteable, or
		// empty pool view only leaves the binding unroutable at route time.
		if !view.Exists || view.ManifestVersion == 0 || !view.Routeable {
			return ModelAdmissionEvent{}, false
		}
		switch {
		case view.ManifestVersion < head.PoolManifestVersion,
			view.ManifestVersion == head.PoolManifestVersion && view.ManifestCoreDigest != head.PoolManifestCoreDigest:
			return revoke(ModelAdmissionRevokePoolHistoryInvalid)
		}
		account, member := poolMemberAccount(view, providerID, runtime)
		if !member || (runtime != modelAdmissionRuntimeSourceMLXCache && account != head.PoolProviderAccountID) {
			return revoke(ModelAdmissionRevokePoolMembershipRevoked)
		}
		entry, ok := poolEntryForPair(view, head.ExpectedCatalogModelHashAlgorithm, head.ExpectedCatalogModelHash, runtime)
		if !ok || entry.PoolModelID != head.PoolModelID {
			return revoke(ModelAdmissionRevokePoolEntryRevoked)
		}
		if view.ManifestVersion == head.PoolManifestVersion {
			return ModelAdmissionEvent{}, false
		}
		if !entryWithinBounds(entry, bounds) {
			// Not rebound: the binding stays unroutable until the bounds
			// admit the entry (fail closed, no revocation).
			return ModelAdmissionEvent{}, false
		}
		return poolBindingDecision(head, view, entry, account, catalog.observedKey, ModelAdmissionReasonPoolManifestRebound, now), true
	}
	// A catalog match binds to a pool only while the pair is neither
	// catalog-priceable for the runtime class nor blocked (a candidate or
	// listed row pays nothing, SPEC-042-R015 precedence); that is decided by
	// the release classification below, not by the recorded match state.
	if !modelAdmissionPoolBindState(head.State) {
		return ModelAdmissionEvent{}, false
	}
	algorithm, hash, ok := offeredPoolPair(head)
	if !ok {
		return ModelAdmissionEvent{}, false
	}
	catalog := classify(algorithm, hash)
	if catalog.blocked || catalog.priceableFor(runtime) {
		return ModelAdmissionEvent{}, false
	}
	type match struct {
		view    trustpool.Snapshot
		entry   poolmanifest.PoolModelEntry
		account string
	}
	var matches []match
	for _, poolID := range wiring.source.PoolIDs() {
		view := wiring.source.Snapshot(poolID)
		if !view.Routeable || view.ManifestVersion == 0 {
			continue
		}
		account, member := poolMemberAccount(view, providerID, runtime)
		if !member {
			continue
		}
		entry, ok := poolEntryForPair(view, algorithm, hash, runtime)
		if !ok || !entryWithinBounds(entry, bounds) {
			continue
		}
		matches = append(matches, match{view: view, entry: entry, account: account})
	}
	// Cardinality: a candidate holds at most one pool binding.
	if len(matches) != 1 {
		return ModelAdmissionEvent{}, false
	}
	return poolBindingDecision(head, matches[0].view, matches[0].entry, matches[0].account, catalog.observedKey, ModelAdmissionReasonPoolManifestBound, now), true
}

// evaluatePoolManifestBindingsLocked re-evaluates every R011 candidate of
// one provider (caller holds the provider's section): it binds a matching
// interim offer, rebinds a binding to a new accepted generation, or revokes
// one whose entry, membership, history, or catalog status no longer holds.
func (s *Server) evaluatePoolManifestBindingsLocked(ctx context.Context, providerID string, section *providerSection) {
	wiring := s.poolModels.Load()
	if wiring == nil || s.modelAdmissions == nil {
		return
	}
	events, err := s.modelAdmissions.LatestModelAdmissionStatusesForProvider(ctx, providerID)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("pool manifest binding: listing failed")
		return
	}
	appended := false
	for _, head := range events {
		decision, ok := poolBindingDecisionForHead(wiring, providerID, head, s.classifyCatalogPair, s.now())
		if !ok {
			continue
		}
		stored, err := s.modelAdmissions.AppendModelAdmissionDecision(ctx, decision)
		if err != nil {
			s.log.Warn().Err(err).
				Str("provider_id", providerID).
				Str("candidate_id", head.CandidateID).
				Str("reason_code", decision.ReasonCode).
				Msg("pool manifest binding append failed")
			continue
		}
		appended = true
		section.generation.Add(1)
		s.log.Info().
			Str("event", "model_admission_pool_manifest").
			Str("provider_id", providerID).
			Str("candidate_id", stored.CandidateID).
			Str("pool_id", stored.PoolID).
			Str("pool_model_id", stored.PoolModelID).
			Uint64("manifest_version", stored.PoolManifestVersion).
			Str("state", stored.State).
			Str("reason_code", stored.ReasonCode).
			Msg("pool manifest admission decision appended")
	}
	if appended {
		s.refreshModelAdmissionBindingLocked(ctx, providerID, section)
	}
}

// reevaluatePoolManifestBindings takes the provider's section and runs the
// R011 evaluation (offer submit, and the sweep).
func (s *Server) reevaluatePoolManifestBindings(ctx context.Context, providerID string) {
	if s.poolModels.Load() == nil || s.modelAdmissions == nil {
		return
	}
	s.withProviderSection(providerID, func(section *providerSection) {
		s.evaluatePoolManifestBindingsLocked(ctx, providerID, section)
	})
}

// RunPoolManifestBindingSweep re-evaluates R011 candidates whenever the
// trust-pool registry revision or the release generation changes (manifest
// acceptance, membership change, catalog promotion), and in full every
// poolManifestBindingSweepFullEvery ticks. Route time re-checks every
// predicate, so the sweep only records the durable transitions.
func (s *Server) RunPoolManifestBindingSweep(ctx context.Context) {
	ticker := time.NewTicker(poolManifestBindingSweepInterval)
	defer ticker.Stop()
	var lastRevision, lastRelease uint64
	tick := 0
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		wiring := s.poolModels.Load()
		if wiring == nil || s.modelAdmissions == nil {
			continue
		}
		tick++
		revision, release := wiring.source.Revision(), s.ReleaseGeneration()
		if revision == lastRevision && release == lastRelease && tick%poolManifestBindingSweepFullEvery != 0 {
			continue
		}
		lastRevision, lastRelease = revision, release
		s.sweepPoolManifestBindings(ctx)
	}
}

func (s *Server) sweepPoolManifestBindings(ctx context.Context) {
	heads, err := s.modelAdmissions.LatestModelAdmissionStatusesInStates(ctx, []string{
		modelAdmissionOfferSubmitted, "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced",
	})
	if err != nil {
		s.log.Warn().Err(err).Msg("pool manifest binding sweep: listing failed")
		return
	}
	providers := map[string]struct{}{}
	for _, head := range heads {
		if head.PoolScoped() || len(head.OfferedArtifactHashes) > 0 {
			providers[head.ProviderID] = struct{}{}
		}
	}
	ids := make([]string, 0, len(providers))
	for id := range providers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, providerID := range ids {
		sweepCtx, cancel := context.WithTimeout(ctx, modelAdmissionRuntimeRevocationTimeout)
		s.reevaluatePoolManifestBindings(sweepCtx, providerID)
		cancel()
	}
}

// bindablePoolCandidates returns the provider's pool-scoped catalog_priced
// candidates whose recorded pair and runtime class the live session serves
// exactly (SPEC-047-R011 session binding).
func bindablePoolCandidates(events []ModelAdmissionEvent, provider pool.Provider) []ModelAdmissionEvent {
	var out []ModelAdmissionEvent
	for _, event := range events {
		if !event.PoolScoped() || event.State != "catalog_priced" {
			continue
		}
		if poolSessionDrift(provider, event) {
			continue
		}
		out = append(out, event)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CandidateID < out[j].CandidateID })
	return out
}

// poolSessionDrift reports whether the live session no longer serves the
// pool binding's exact pair under its runtime class.
func poolSessionDrift(provider pool.Provider, candidate ModelAdmissionEvent) bool {
	return modelAdmissionRuntimeClass(provider.RuntimeSource) != modelAdmissionRuntimeClass(candidate.RuntimeSource) ||
		provider.ModelHashAlgorithm != candidate.ExpectedCatalogModelHashAlgorithm ||
		strings.ToLower(strings.TrimSpace(provider.ModelHash)) != candidate.ExpectedCatalogModelHash
}

// modelAdmissionPoolBindingObject is the closed status-readback pool_binding
// object (SPEC-047-R011); nil for every global event.
func modelAdmissionPoolBindingObject(event ModelAdmissionEvent) map[string]any {
	if !event.PoolScoped() {
		return nil
	}
	return map[string]any{
		"binding_scope":                  event.BindingScope,
		"pool_id":                        event.PoolID,
		"pool_model_id":                  event.PoolModelID,
		"manifest_version":               event.PoolManifestVersion,
		"manifest_core_digest":           event.PoolManifestCoreDigest,
		"artifact_hash_algorithm":        event.ExpectedCatalogModelHashAlgorithm,
		"artifact_hash":                  event.ExpectedCatalogModelHash,
		"runtime_source":                 modelAdmissionRuntimeClass(event.RuntimeSource),
		"prompt_rate_per_mtok":           event.PoolPromptRatePerMtok,
		"prompt_cache_hit_rate_per_mtok": event.PoolPromptCacheHitRatePerMtok,
		"completion_rate_per_mtok":       event.PoolCompletionRatePerMtok,
		"disclosure_class":               event.PoolDisclosureClass,
		"max_context_tokens":             event.PoolMaxContextTokens,
		"provider_account_id":            event.PoolProviderAccountID,
		"observed_catalog_model_key":     nullString(event.PoolObservedCatalogModelKey),
		"probe_evidence_digest":          nullString(event.PoolProbeEvidenceDigest),
	}
}

// catalogAdmissionPoolEntry is the hello catalog-admission mode of a session
// serving a current SPEC-042-R015 pool entry (SPEC-032-R004): not a catalog
// envelope mode (no row re-check), never legacy (routable on its pool only).
const catalogAdmissionPoolEntry = "pool_entry"

// poolEntryForSession reports the single pool whose current SPEC-042-R015
// entry lists this runtime class for this exact pair, when the provider is a
// member there (for a loopback class: allowlisted and creator-owned or
// attested) and the pair is neither catalog-priceable for the class nor
// blocked (SPEC-032-R004).
func (s *Server) poolEntryForSession(providerID, runtimeSource, algorithm, hash string) (string, bool) {
	wiring := s.poolModels.Load()
	hash = strings.ToLower(strings.TrimSpace(hash))
	runtime := modelAdmissionRuntimeClass(runtimeSource)
	format, ok := poolmanifest.RuntimeSourceFormat(runtime)
	if wiring == nil || wiring.source == nil || !ok || algorithm != format || !validModelAdmissionSHA256Hex(hash) {
		return "", false
	}
	status := s.classifyCatalogPair(algorithm, hash)
	if status.blocked || status.priceableFor(runtime) {
		return "", false
	}
	matched := ""
	for _, poolID := range wiring.source.PoolIDs() {
		view := wiring.source.Snapshot(poolID)
		if !view.Routeable {
			continue
		}
		if _, member := poolMemberAccount(view, providerID, runtime); !member {
			continue
		}
		if _, ok := poolEntryForPair(view, algorithm, hash, runtime); !ok {
			continue
		}
		if matched != "" {
			return "", false
		}
		matched = poolID
	}
	return matched, matched != ""
}
