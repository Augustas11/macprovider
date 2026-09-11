package ws

import (
	"context"
	"crypto/ed25519"
	"errors"
	"sort"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/augstar/macprovider-coordinator/internal/artifactidentity"
	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/modelidentity"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

// artifactidentityBinding aliases the feed binding a settlement decision
// records the six values from.
type artifactidentityBinding = artifactidentity.Binding

// SPEC-047 v0.1.5 catalog binding in production: the per-provider decision
// critical section and binding generation (R001), offer-time catalog
// matching (R001 "Match"), the coordinator-derived session-to-candidate
// binding (R003), content-only drift at hello/heartbeat/refresh (R006 a, d),
// and the post-publication release sweeps (R006 b, c).
//
// Lock order: provider section → registry (pool) → release read lock. A
// section is never taken while the registry lock or the release lock is held.

// Closed drift reason set (R001 transition origins; R006).
const (
	modelAdmissionDriftRuntimeIdentity        = "runtime_identity_drift"
	modelAdmissionDriftArtifactFeedChanged    = "catalog_artifact_feed_changed"
	modelAdmissionDriftRowChanged             = "catalog_row_changed"
	modelAdmissionDriftRowIneligible          = "catalog_row_ineligible"
	modelAdmissionDriftRuntimeSourceDisallow  = "catalog_runtime_source_disallowed"
	modelAdmissionDriftReceiptKeyUnavailable  = "receipt_key_unavailable"
	modelAdmissionDriftRevocationDomain       = "macprovider.model_admission.drift_revocation.v1"
	modelAdmissionRuntimeSourceMLXCache       = "mlx_cache"
	modelAdmissionMatchReasonNone             = "none"
	modelAdmissionMatchReasonNoArtifactMatch  = "no_artifact_match"
	modelAdmissionMatchReasonKeyDisagrees     = "catalog_model_key_disagrees"
	modelAdmissionMatchReasonSpanKeys         = "artifact_hashes_span_keys"
	modelAdmissionMatchReasonFeedIntegrity    = "catalog_artifact_feed_integrity_failure"
	modelAdmissionMatchReasonPrimaryAmbiguous = "primary_row_ambiguous"
	modelAdmissionMatchReasonSourceNotAllowed = "runtime_source_not_allowed"
)

// modelAdmissionDriftReasons is the closed drift origin reason set.
var modelAdmissionDriftReasons = map[string]struct{}{
	modelAdmissionDriftRuntimeIdentity:       {},
	modelAdmissionDriftArtifactFeedChanged:   {},
	modelAdmissionDriftRowChanged:            {},
	modelAdmissionDriftRowIneligible:         {},
	modelAdmissionDriftRuntimeSourceDisallow: {},
	modelAdmissionDriftReceiptKeyUnavailable: {},
}

// ---- provider decision critical sections

type providerSection struct {
	mu sync.Mutex
	// generation is the provider's monotonic binding generation: incremented
	// under the section on every event appended for any of the provider's
	// candidates and on every binding mutation.
	generation atomic.Uint64
}

type providerSections struct {
	mu       sync.Mutex
	sections map[string]*providerSection
}

func (ps *providerSections) get(providerID string) *providerSection {
	ps.mu.Lock()
	defer ps.mu.Unlock()
	if ps.sections == nil {
		ps.sections = map[string]*providerSection{}
	}
	section, ok := ps.sections[providerID]
	if !ok {
		section = &providerSection{}
		ps.sections[providerID] = section
	}
	return section
}

// withProviderSection runs fn inside the provider's decision critical
// section. Never nest for the same provider.
func (s *Server) withProviderSection(providerID string, fn func(section *providerSection)) {
	section := s.modelAdmissionSections.get(providerID)
	section.mu.Lock()
	defer section.mu.Unlock()
	fn(section)
}

// ModelAdmissionBindingGeneration is the provider's current binding
// generation (read without the section; route time compares it to the value
// captured at evaluation).
func (s *Server) ModelAdmissionBindingGeneration(providerID string) uint64 {
	return s.modelAdmissionSections.get(providerID).generation.Load()
}

// appendModelAdmissionEventInSection runs one store append inside the
// provider's section and, when it appended a new event, increments the
// binding generation and refreshes the provider's session binding — the one
// linearization point every append origin shares (R001).
func (s *Server) appendModelAdmissionEventInSection(ctx context.Context, providerID string, appendFn func(ctx context.Context) (ModelAdmissionEvent, bool, error)) (ModelAdmissionEvent, bool, error) {
	var (
		stored ModelAdmissionEvent
		replay bool
		err    error
	)
	s.withProviderSection(providerID, func(section *providerSection) {
		stored, replay, err = appendFn(ctx)
		if err != nil || replay {
			return
		}
		s.afterModelAdmissionAppendLocked(ctx, providerID, section)
	})
	return stored, replay, err
}

// appendModelAdmissionDecisionInSection is AppendModelAdmissionDecision under
// the provider's section (probe and drift origins).
func (s *Server) appendModelAdmissionDecisionInSection(ctx context.Context, decision ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	if s.modelAdmissions == nil {
		return ModelAdmissionEvent{}, errors.New("model admission store is required")
	}
	stored, _, err := s.appendModelAdmissionEventInSection(ctx, decision.ProviderID, func(ctx context.Context) (ModelAdmissionEvent, bool, error) {
		stored, err := s.modelAdmissions.AppendModelAdmissionDecision(ctx, decision)
		return stored, false, err
	})
	return stored, err
}

// afterModelAdmissionAppendLocked: caller holds the section and has just
// appended an event for one of the provider's candidates.
func (s *Server) afterModelAdmissionAppendLocked(ctx context.Context, providerID string, section *providerSection) {
	section.generation.Add(1)
	s.refreshModelAdmissionBindingLocked(ctx, providerID, section)
}

// ---- session-to-candidate binding (R003)

func modelAdmissionStateTerminal(state string) bool {
	switch state {
	case modelAdmissionWithdrawn, modelAdmissionRevoked, "offer_rejected", modelAdmissionNotOffered, "":
		return true
	}
	return false
}

func modelAdmissionStateDecided(state string) bool {
	return state == "catalog_priced" || state == "settlement_capable"
}

// bindableCandidates returns the provider's candidates whose latest
// non-terminal event is catalog_matched on the row whose model id the
// session serves, ordered by candidate id.
func bindableCandidates(events []ModelAdmissionEvent, servedModelID string) []ModelAdmissionEvent {
	served := autotune.NormalizeModelID(servedModelID)
	if served == "" {
		return nil
	}
	var out []ModelAdmissionEvent
	for _, event := range events {
		if modelAdmissionStateTerminal(event.State) || event.CatalogMatchState != modelAdmissionCatalogMatched {
			continue
		}
		if autotune.NormalizeModelID(event.CatalogRowModelID) != served {
			continue
		}
		out = append(out, event)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].CandidateID < out[j].CandidateID })
	return out
}

// refreshModelAdmissionBindingLocked re-derives the provider's session
// binding from recorded state (caller holds the section). Zero candidates
// bind nothing; two or more bind nothing, log `ambiguous_candidates`, and
// revoke the affected decided candidates as identity drift (R006(a)).
func (s *Server) refreshModelAdmissionBindingLocked(ctx context.Context, providerID string, section *providerSection) {
	if s.modelAdmissions == nil || s.pool == nil {
		return
	}
	provider, ok := s.pool.Resolve(providerID, "")
	if !ok {
		return
	}
	for attempt := 0; attempt < 2; attempt++ {
		events, err := s.modelAdmissions.LatestModelAdmissionStatusesForProvider(ctx, providerID)
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("model admission binding refresh: listing failed; binding cleared")
			s.setModelAdmissionBindingLocked(providerID, nil, section)
			return
		}
		candidates := bindableCandidates(events, provider.ModelID)
		switch len(candidates) {
		case 0:
			s.setModelAdmissionBindingLocked(providerID, nil, section)
			return
		case 1:
			binding := s.modelAdmissionBindingFor(candidates[0])
			s.setModelAdmissionBindingLocked(providerID, &binding, section)
			return
		}
		ids := make([]string, 0, len(candidates))
		revoked := false
		for _, candidate := range candidates {
			ids = append(ids, candidate.CandidateID)
			if !modelAdmissionStateDecided(candidate.State) {
				continue
			}
			if s.appendDriftRevocationLocked(ctx, candidate, modelAdmissionDriftRuntimeIdentity, "ambiguous_candidates", section) {
				revoked = true
			}
		}
		s.log.Warn().
			Str("event", "ambiguous_candidates").
			Str("provider_id", providerID).
			Str("model_id", provider.ModelID).
			Strs("candidate_ids", ids).
			Msg("model admission: several catalog-matched candidates serve the session's model; nothing bound")
		if !revoked {
			break
		}
	}
	s.setModelAdmissionBindingLocked(providerID, nil, section)
}

// modelAdmissionBindingFor derives the binding record for one candidate under
// the current release: the row status and, when the recorded content still
// resolves, the published generation (the R006(c) sweep re-stamps it).
func (s *Server) modelAdmissionBindingFor(candidate ModelAdmissionEvent) pool.ModelAdmissionBinding {
	binding := pool.ModelAdmissionBinding{
		CandidateID:        candidate.CandidateID,
		CoordinatorEventID: candidate.CoordinatorEventID,
		ServedModelRef:     candidate.ServedModelRef,
		CatalogModelKey:    candidate.CatalogModelKey,
	}
	s.withReleaseRead(func() {
		current, _ := s.autotuneCatalogSnapshot()
		if row, ok := current.Row(candidate.CatalogModelKey); ok {
			binding.CatalogRowStatus = row.RuntimeStatus
		}
		if eval := s.evaluateCatalogPreconditionsLocked(candidate, current); eval.decisionCode == "" {
			binding.ValidatedReleaseGeneration = s.artifactIdentitySets.generationLocked()
		}
	})
	return binding
}

func (s *Server) setModelAdmissionBindingLocked(providerID string, binding *pool.ModelAdmissionBinding, section *providerSection) {
	// A refresh that derives the binding already in place is not a
	// mutation: the section generation is not advanced (a route attempt
	// captured before a no-op heartbeat still compares equal) but the
	// session is re-stamped with the CURRENT section generation, which an
	// append for any of the provider's candidates has already advanced —
	// otherwise the stamp would fall behind the section and every later
	// route attempt would fail closed until the next real mutation.
	if current, ok := s.pool.Resolve(providerID, ""); ok {
		existing, bound := current.ModelAdmissionBinding()
		if (!bound && binding == nil) || (bound && binding != nil && existing == *binding) {
			s.pool.SetModelAdmissionBinding(providerID, binding, section.generation.Load())
			return
		}
	}
	generation := section.generation.Add(1)
	s.pool.SetModelAdmissionBinding(providerID, binding, generation)
}

// ---- drift predicates (R006 a, d)

// sessionDriftReason evaluates one decided candidate against the provider's
// live session: served model id, pinned hash_verified identity for a recorded
// admissible member (a), and — for settlement_capable — the receipt key (d).
func sessionDriftReason(provider pool.Provider, candidate ModelAdmissionEvent) (string, bool) {
	if !modelAdmissionStateDecided(candidate.State) {
		return "", false
	}
	if autotune.NormalizeModelID(provider.ModelID) != autotune.NormalizeModelID(candidate.CatalogRowModelID) {
		return modelAdmissionDriftRuntimeIdentity, true
	}
	if provider.HashStatus != pool.HashStatusVerified || provider.IdentityPin == nil {
		return modelAdmissionDriftRuntimeIdentity, true
	}
	if _, ok := sessionBoundMember(provider, candidate); !ok {
		return modelAdmissionDriftRuntimeIdentity, true
	}
	if candidate.State == "settlement_capable" && !sessionReceiptKeyPresent(provider) {
		return modelAdmissionDriftReceiptKeyUnavailable, true
	}
	return "", false
}

// sessionReceiptKeyPresent: the session presents its SPEC-022 receipt key —
// active, or staged as pending by the SPEC-015 publication grace (a fresh
// hello stages the key and the registry commits it later; routing gates the
// commit separately, R006(d) asks only whether the key is presented).
func sessionReceiptKeyPresent(provider pool.Provider) bool {
	return len(provider.ReceiptPubkey) == ed25519.PublicKeySize || len(provider.PendingReceiptPubkey) == ed25519.PublicKeySize
}

// sessionBoundMember is the recorded admissible member the session's PINNED
// verified identity names (R003(iv)): the candidate_row member for a
// primary-pinned session, the exact feed member (key, artifact id, pair)
// for a member-pinned one.
func sessionBoundMember(provider pool.Provider, candidate ModelAdmissionEvent) (ModelAdmissionCatalogMember, bool) {
	pin := provider.IdentityPin
	if pin == nil || provider.HashStatus != pool.HashStatusVerified {
		return ModelAdmissionCatalogMember{}, false
	}
	for _, member := range candidate.CatalogMembers {
		if pin.Primary {
			if member.Source == modelAdmissionMemberSourceCandidateRow &&
				member.HashAlgorithm == modelidentity.SnapshotManifestV1 &&
				provider.ModelHashAlgorithm == modelidentity.SnapshotManifestV1 &&
				member.Hash == strings.TrimSpace(provider.ModelHash) &&
				member.Hash == candidate.CatalogRowModelSHA256 {
				return member, true
			}
			continue
		}
		if member.Source == modelAdmissionMemberSourceArtifactFeed &&
			member.HashAlgorithm == pin.Member.HashAlgorithm &&
			member.Hash == pin.Member.Hash &&
			member.ArtifactID == pin.Member.ArtifactID &&
			candidate.CatalogModelKey == pin.Member.ModelKey &&
			provider.ArtifactIdentity != nil &&
			provider.ArtifactIdentity.Member == pin.Member {
			return member, true
		}
	}
	return ModelAdmissionCatalogMember{}, false
}

// appendDriftRevocationLocked appends `revoked` with one closed drift reason
// for a decided candidate (caller holds the section; the generation is
// incremented here, the binding refresh is the caller's).
func (s *Server) appendDriftRevocationLocked(ctx context.Context, candidate ModelAdmissionEvent, reason, evidence string, section *providerSection) bool {
	if _, ok := modelAdmissionDriftReasons[reason]; !ok || s.modelAdmissions == nil {
		return false
	}
	if !modelAdmissionStateDecided(candidate.State) {
		return false
	}
	revocation := modelAdmissionCoordinatorDecisionFromCurrent(candidate, modelAdmissionRevoked, reason, modelAdmissionDriftRevocationDomain, evidence, s.now())
	// A revocation binds no member and evaluated under no generation: the
	// decision-bound values belong to the event it supersedes.
	revocation.ArtifactFeedSHA256, revocation.ArtifactID, revocation.ArtifactHash, revocation.ArtifactHashAlgorithm = "", "", "", ""
	revocation.ArtifactFeedSignerKeyID, revocation.ArtifactCandidateCatalogSHA256, revocation.BoundMemberSource = "", "", ""
	revocation.EvaluatedReleaseGeneration = 0
	if _, err := s.modelAdmissions.AppendModelAdmissionDecision(ctx, revocation); err != nil {
		s.log.Warn().Err(err).
			Str("provider_id", candidate.ProviderID).
			Str("candidate_id", candidate.CandidateID).
			Str("reason_code", reason).
			Msg("model admission drift revocation failed")
		return false
	}
	section.generation.Add(1)
	s.log.Warn().
		Str("event", "model_admission_drift_revoked").
		Str("provider_id", candidate.ProviderID).
		Str("candidate_id", candidate.CandidateID).
		Str("previous_state", candidate.State).
		Str("reason_code", reason).
		Str("evidence", evidence).
		Msg("model admission revoked on drift")
	return true
}

// evaluateSessionDriftLocked applies (a)/(d) to the candidates the session
// is (or was) bound to, revoking before any binding is published.
func (s *Server) evaluateSessionDriftLocked(ctx context.Context, provider pool.Provider, candidateIDs []string, section *providerSection) {
	if s.modelAdmissions == nil {
		return
	}
	seen := map[string]struct{}{}
	for _, candidateID := range candidateIDs {
		if candidateID == "" {
			continue
		}
		if _, dup := seen[candidateID]; dup {
			continue
		}
		seen[candidateID] = struct{}{}
		candidate, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, provider.ProviderID, candidateID)
		if err != nil || !found {
			continue
		}
		if reason, drift := sessionDriftReason(provider, candidate); drift {
			s.appendDriftRevocationLocked(ctx, candidate, reason, "session_"+provider.AssignedID, section)
		}
	}
}

// bindModelAdmissionSessionAtHello runs after a hello (initial or
// replacement) installed the session: under the section it evaluates
// (a)/(d) against the candidate the prior binding named or the newly
// derived one, and only then publishes the binding.
func (s *Server) bindModelAdmissionSessionAtHello(providerID string, prior pool.Provider, hadPrior bool) {
	s.withProviderSection(providerID, func(section *providerSection) {
		s.helloSessionBindingLocked(providerID, prior, hadPrior, section)
	})
}

// helloSessionBindingLocked is bindModelAdmissionSessionAtHello
// for a caller already holding the provider's section (the registration
// path, which replaces the session under the same hold).
func (s *Server) helloSessionBindingLocked(providerID string, prior pool.Provider, hadPrior bool, section *providerSection) {
	if s.modelAdmissions == nil || s.pool == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), modelAdmissionRuntimeRevocationTimeout)
	defer cancel()
	provider, ok := s.pool.Resolve(providerID, "")
	if !ok {
		return
	}
	// (a)/(d) run against the candidate the prior binding named AND the
	// candidate the new session would bind to (a replacement hello that
	// changes the served model rebinds elsewhere), before either is published.
	var candidateIDs []string
	if hadPrior && prior.ModelAdmissionCandidateID != "" {
		candidateIDs = append(candidateIDs, prior.ModelAdmissionCandidateID)
	}
	if events, err := s.modelAdmissions.LatestModelAdmissionStatusesForProvider(ctx, providerID); err == nil {
		if candidates := bindableCandidates(events, provider.ModelID); len(candidates) == 1 {
			candidateIDs = append(candidateIDs, candidates[0].CandidateID)
		}
	}
	s.evaluateSessionDriftLocked(ctx, provider, candidateIDs, section)
	s.refreshModelAdmissionBindingLocked(ctx, providerID, section)
}

// evaluateModelAdmissionSessionOnHeartbeat applies (a)/(d) to the bound
// candidate after a heartbeat: a model change revokes the bound decided
// candidate and clears the binding (the registry already cleared it), an
// identity or receipt-key change revokes it, and the binding is refreshed.
func (s *Server) evaluateModelAdmissionSessionOnHeartbeat(provider pool.Provider, priorBinding pool.ModelAdmissionBinding, hadBinding bool) {
	s.withProviderSection(provider.ProviderID, func(section *providerSection) {
		s.heartbeatSessionEvaluationLocked(provider, priorBinding, hadBinding, section)
	})
}

// heartbeatSessionEvaluationLocked is the heartbeat (a)/(d)
// evaluation for a caller holding the section (the heartbeat handler, which
// applies the registry update under the same hold).
func (s *Server) heartbeatSessionEvaluationLocked(provider pool.Provider, priorBinding pool.ModelAdmissionBinding, hadBinding bool, section *providerSection) {
	if s.modelAdmissions == nil || s.pool == nil || !hadBinding {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), modelAdmissionRuntimeRevocationTimeout)
	defer cancel()
	current, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}
	s.evaluateSessionDriftLocked(ctx, current, []string{priorBinding.CandidateID}, section)
	s.refreshModelAdmissionBindingLocked(ctx, provider.ProviderID, section)
}

// clearModelAdmissionBindingOnDisconnect clears the binding when the session
// disconnects (not a durable transition): the candidate is unroutable until
// the next hello rebinds it under (a)/(d).
func (s *Server) clearModelAdmissionBindingOnDisconnect(providerID, assignedID string) {
	if s.pool == nil {
		return
	}
	s.withProviderSection(providerID, func(section *providerSection) {
		provider, ok := s.pool.Resolve(providerID, assignedID)
		if !ok || provider.ModelAdmissionCandidateID == "" {
			return
		}
		s.setModelAdmissionBindingLocked(providerID, nil, section)
	})
}

// ---- offer-time catalog match (R001 "Match")

type modelAdmissionCatalogMatch struct {
	State           string
	Reason          string
	CatalogModelKey string
	RowModelID      string
	RowModelSHA256  string
	ReleaseID       string
	CandidateSHA256 string
	SignerKeyID     string
	Members         []ModelAdmissionCatalogMember
}

type rawResolvedMember struct {
	member    ModelAdmissionCatalogMember
	modelKey  string
	modelID   string
	rowSHA256 string
	allowed   func(source string) bool
}

// matchModelAdmissionOffer resolves the offer's signed artifact hashes through
// the two SPEC-010-R007(b) paths against the CURRENT release, in the fixed
// order: (1) raw resolution, (2) key spanning, key disagreement, (3) the
// runtime-source admissibility filter, (4) match when one admissible member
// remains. Runs under the release read lock.
// intakeModelKeyForOffer is the SPEC-047 R009 intake resolution: the ONE
// catalog key whose row `model_sha256` (any runtime_status) or whose verified
// artifact in the release-bound identity set equals an offered pair. Two keys
// or an ambiguous row resolve nothing. It is recorded interest for SPEC-023
// §16.2(b) only — never an admission input.
func intakeModelKeyForOffer(current *autotune.Catalog, set *artifactidentity.Index, artifactHashes map[string]string) string {
	if current == nil || len(artifactHashes) == 0 {
		return ""
	}
	algorithms := make([]string, 0, len(artifactHashes))
	for algorithm := range artifactHashes {
		algorithms = append(algorithms, algorithm)
	}
	sort.Strings(algorithms)
	resolved := ""
	for _, algorithm := range algorithms {
		hash := strings.ToLower(strings.TrimSpace(artifactHashes[algorithm]))
		candidate := ""
		if algorithm == modelidentity.SnapshotManifestV1 {
			for _, key := range current.Keys() {
				row, _ := current.Row(key)
				if strings.TrimSpace(row.ModelSHA256) == hash {
					if candidate != "" {
						return ""
					}
					candidate = key
				}
			}
		}
		if candidate == "" && set != nil {
			if binding, ok := set.Resolve(algorithm, hash); ok {
				candidate = binding.Member.ModelKey
			}
		}
		if candidate == "" {
			continue
		}
		if resolved != "" && resolved != candidate {
			return ""
		}
		resolved = candidate
	}
	return resolved
}

func (s *Server) intakeModelKeyForOfferHashes(artifactHashes map[string]string) string {
	key := ""
	s.withReleaseRead(func() {
		current, _ := s.autotuneCatalogSnapshot()
		key = intakeModelKeyForOffer(current, s.usableIdentitySetLocked(current), artifactHashes)
	})
	return key
}

func (s *Server) matchModelAdmissionOffer(runtimeSource, assertedKey string, artifactHashes map[string]string) modelAdmissionCatalogMatch {
	var match modelAdmissionCatalogMatch
	s.withReleaseRead(func() {
		current, _ := s.autotuneCatalogSnapshot()
		match = matchOfferArtifactHashes(current, s.usableIdentitySetLocked(current), s.artifactIdentitySets.integrityFailed(), runtimeSource, assertedKey, artifactHashes)
	})
	return match
}

// usableIdentitySetLocked is the release's identity set when it is usable
// for artifact-derived authority: present and fresh (SPEC-023 §3.7.6 rules
// 4–5); a missing or stale set resolves nothing on the feed path. Caller
// holds the release read lock.
func (s *Server) usableIdentitySetLocked(catalog *autotune.Catalog) *artifactidentity.Index {
	if catalog == nil {
		return nil
	}
	set := s.artifactIdentitySetFor(catalog.SHA256)
	if set == nil || !set.Fresh(s.now()) {
		return nil
	}
	return set
}

func unmatched(reason string) modelAdmissionCatalogMatch {
	return modelAdmissionCatalogMatch{State: modelAdmissionCatalogUnmatched, Reason: reason}
}

func matchOfferArtifactHashes(current *autotune.Catalog, set *artifactidentity.Index, feedIntegrityFailed bool, runtimeSource, assertedKey string, artifactHashes map[string]string) modelAdmissionCatalogMatch {
	if current == nil || len(artifactHashes) == 0 {
		return unmatched(modelAdmissionMatchReasonNoArtifactMatch)
	}
	algorithms := make([]string, 0, len(artifactHashes))
	for algorithm := range artifactHashes {
		algorithms = append(algorithms, algorithm)
	}
	sort.Strings(algorithms)
	var resolved []rawResolvedMember
	feedPairOffered := false
	for _, algorithm := range algorithms {
		hash := strings.ToLower(strings.TrimSpace(artifactHashes[algorithm]))
		// (1) primary-row path: exactly one listed/recommendable row whose
		// model_sha256 is the offered snapshot-manifest pair.
		if algorithm == modelidentity.SnapshotManifestV1 {
			var rowKeys []string
			for _, key := range current.Keys() {
				row, _ := current.Row(key)
				if (row.RuntimeStatus == "listed" || row.RuntimeStatus == "recommendable") && strings.TrimSpace(row.ModelSHA256) == hash {
					rowKeys = append(rowKeys, key)
				}
			}
			if len(rowKeys) > 1 {
				return unmatched(modelAdmissionMatchReasonPrimaryAmbiguous)
			}
			if len(rowKeys) == 1 {
				row, _ := current.Row(rowKeys[0])
				resolved = append(resolved, rawResolvedMember{
					member:    ModelAdmissionCatalogMember{Source: modelAdmissionMemberSourceCandidateRow, HashAlgorithm: algorithm, Hash: hash},
					modelKey:  rowKeys[0],
					modelID:   autotune.NormalizeModelID(row.ModelID),
					rowSHA256: hash,
					allowed:   func(source string) bool { return source == modelAdmissionRuntimeSourceMLXCache },
				})
				continue
			}
		}
		// feed path: any other pair resolves in the current release's set.
		feedPairOffered = true
		if set == nil {
			continue
		}
		binding, ok := set.Resolve(algorithm, hash)
		if !ok {
			continue
		}
		row, rowOK := current.Row(binding.Member.ModelKey)
		if !rowOK {
			continue
		}
		member := binding.Member
		resolved = append(resolved, rawResolvedMember{
			member: ModelAdmissionCatalogMember{
				Source:                         modelAdmissionMemberSourceArtifactFeed,
				HashAlgorithm:                  member.HashAlgorithm,
				Hash:                           member.Hash,
				ArtifactID:                     member.ArtifactID,
				ArtifactFeedSHA256:             binding.Provenance.FeedSHA256,
				ArtifactFeedSignerKeyID:        binding.Provenance.SignerKeyID,
				ArtifactCandidateCatalogSHA256: binding.Provenance.CandidateCatalogSHA256,
			},
			modelKey:  member.ModelKey,
			modelID:   autotune.NormalizeModelID(row.ModelID),
			rowSHA256: strings.TrimSpace(row.ModelSHA256),
			allowed:   member.AllowsRuntimeSource,
		})
	}
	if len(resolved) == 0 {
		if feedPairOffered && feedIntegrityFailed {
			return unmatched(modelAdmissionMatchReasonFeedIntegrity)
		}
		return unmatched(modelAdmissionMatchReasonNoArtifactMatch)
	}
	// (2) raw resolved pairs spanning two keys match nothing, before any
	// admissibility filtering; a disagreeing asserted key matches nothing.
	key := resolved[0].modelKey
	for _, r := range resolved[1:] {
		if r.modelKey != key {
			return unmatched(modelAdmissionMatchReasonSpanKeys)
		}
	}
	if assertedKey = strings.ToLower(strings.TrimSpace(assertedKey)); assertedKey != "" && assertedKey != key {
		return unmatched(modelAdmissionMatchReasonKeyDisagrees)
	}
	// (3) admissibility filter: inadmissible members are not recorded.
	var members []ModelAdmissionCatalogMember
	for _, r := range resolved {
		if r.allowed(runtimeSource) {
			members = append(members, r.member)
		}
	}
	// (4)
	if len(members) == 0 {
		return unmatched(modelAdmissionMatchReasonSourceNotAllowed)
	}
	sort.Slice(members, func(i, j int) bool {
		if members[i].Source != members[j].Source {
			return members[i].Source < members[j].Source
		}
		if members[i].ArtifactID != members[j].ArtifactID {
			return members[i].ArtifactID < members[j].ArtifactID
		}
		return members[i].HashAlgorithm+members[i].Hash < members[j].HashAlgorithm+members[j].Hash
	})
	return modelAdmissionCatalogMatch{
		State:           modelAdmissionCatalogMatched,
		Reason:          modelAdmissionMatchReasonNone,
		CatalogModelKey: key,
		RowModelID:      resolved[0].modelID,
		RowModelSHA256:  resolved[0].rowSHA256,
		ReleaseID:       current.Version,
		CandidateSHA256: current.SHA256,
		SignerKeyID:     current.SignerKeyID,
		Members:         members,
	}
}

// applyModelAdmissionOfferCatalogMatch records the match on the offer event:
// the resolved key (null when unmatched — a provider assertion is never
// echoed as identity, R002 v0.1.5), the row tuple, the release provenance
// and the admissible member set.
func (s *Server) applyModelAdmissionOfferCatalogMatch(event ModelAdmissionEvent, body modelAdmissionOfferSubmitRequest) ModelAdmissionEvent {
	match := s.matchModelAdmissionOffer(body.RuntimeSource, body.CatalogModelKey, body.ArtifactHashes)
	event.RuntimeSource = body.RuntimeSource
	event.IntakeModelKey = s.intakeModelKeyForOfferHashes(body.ArtifactHashes)
	event.CatalogMatchState = match.State
	event.CatalogMatchReason = match.Reason
	event.CatalogModelKey = match.CatalogModelKey
	event.CatalogRowModelID = match.RowModelID
	event.CatalogRowModelSHA256 = match.RowModelSHA256
	event.CatalogReleaseID = match.ReleaseID
	event.CatalogCandidateSHA256 = match.CandidateSHA256
	event.CatalogSignerKeyID = match.SignerKeyID
	event.CatalogMembers = match.Members
	return event
}

// ---- R003 (i)–(iii) content evaluation (decision time and reload sweeps)

type catalogPreconditionResult struct {
	// decisionCode is the SPEC-047-R003 closed code, "" when every
	// precondition holds.
	decisionCode string
	// driftReason is the R006(b)/(c) reason a reload sweep appends for the
	// same failure, "" when nothing drifted.
	driftReason string
	// material is the trusted Tier-2 row material (composite proof of the
	// row binding and pricing key) when (iii) holds.
	material tier2.RouteSnapshotMaterial
	// members are the recorded members with CURRENT provenance (a re-stamp
	// changes provenance, never content).
	members []ModelAdmissionCatalogMember
}

// evaluateCatalogPreconditionsLocked re-resolves the RECORDED content of a
// catalog-matched candidate under the current release (caller holds the
// release read lock): every member still resolves (i), the row is
// recommendable and every member still allows the recorded runtime source
// (ii), and trusted Tier-2 material exists for the row (iii).
func (s *Server) evaluateCatalogPreconditionsLocked(candidate ModelAdmissionEvent, current *autotune.Catalog) catalogPreconditionResult {
	if candidate.CatalogMatchState != modelAdmissionCatalogMatched || candidate.CatalogModelKey == "" {
		return catalogPreconditionResult{decisionCode: "catalog_match_required"}
	}
	if current == nil {
		return catalogPreconditionResult{decisionCode: "catalog_match_stale", driftReason: modelAdmissionDriftRowChanged}
	}
	row, ok := current.Row(candidate.CatalogModelKey)
	if !ok || autotune.NormalizeModelID(row.ModelID) != autotune.NormalizeModelID(candidate.CatalogRowModelID) || strings.TrimSpace(row.ModelSHA256) != candidate.CatalogRowModelSHA256 {
		return catalogPreconditionResult{decisionCode: "catalog_match_stale", driftReason: modelAdmissionDriftRowChanged}
	}
	set := s.usableIdentitySetLocked(current)
	members := make([]ModelAdmissionCatalogMember, 0, len(candidate.CatalogMembers))
	sourceAllowed := true
	// (i) every recorded member still resolves by content.
	for _, member := range candidate.CatalogMembers {
		switch member.Source {
		case modelAdmissionMemberSourceCandidateRow:
			if member.HashAlgorithm != modelidentity.SnapshotManifestV1 || member.Hash != candidate.CatalogRowModelSHA256 {
				return catalogPreconditionResult{decisionCode: "catalog_match_stale", driftReason: modelAdmissionDriftRowChanged}
			}
			if candidate.RuntimeSource != modelAdmissionRuntimeSourceMLXCache {
				sourceAllowed = false
			}
			members = append(members, member)
		case modelAdmissionMemberSourceArtifactFeed:
			binding, ok := set.Resolve(member.HashAlgorithm, member.Hash)
			if !ok || binding.Member.ModelKey != candidate.CatalogModelKey || binding.Member.ArtifactID != member.ArtifactID {
				return catalogPreconditionResult{decisionCode: "catalog_match_stale", driftReason: modelAdmissionDriftArtifactFeedChanged}
			}
			if !binding.Member.AllowsRuntimeSource(candidate.RuntimeSource) {
				sourceAllowed = false
			}
			refreshed := member
			refreshed.ArtifactFeedSHA256 = binding.Provenance.FeedSHA256
			refreshed.ArtifactFeedSignerKeyID = binding.Provenance.SignerKeyID
			refreshed.ArtifactCandidateCatalogSHA256 = binding.Provenance.CandidateCatalogSHA256
			members = append(members, refreshed)
		default:
			return catalogPreconditionResult{decisionCode: "catalog_match_stale", driftReason: modelAdmissionDriftRowChanged}
		}
	}
	if len(members) == 0 {
		return catalogPreconditionResult{decisionCode: "catalog_match_stale", driftReason: modelAdmissionDriftRowChanged}
	}
	// (ii) the row is recommendable, then every member allows the source.
	if row.RuntimeStatus != "recommendable" {
		return catalogPreconditionResult{decisionCode: "catalog_row_not_recommendable", driftReason: modelAdmissionDriftRowIneligible, members: members}
	}
	if !sourceAllowed {
		return catalogPreconditionResult{decisionCode: "runtime_source_not_allowed", driftReason: modelAdmissionDriftRuntimeSourceDisallow, members: members}
	}
	material, ok := s.catalogRef().RouteSnapshotMaterial(row.ModelID, strings.TrimSpace(row.ModelSHA256))
	if !ok || material.HashStatus != pool.HashStatusVerified || material.ExpectedModelHash != candidate.CatalogRowModelSHA256 ||
		strings.TrimSpace(material.CatalogID) == "" || !validModelAdmissionSHA256Hex(material.CatalogBodyDigest) ||
		strings.TrimSpace(material.CatalogSignatureKeyID) == "" || !validModelAdmissionReceiptKeyFingerprint(material.CatalogSignaturePubkeyFingerprint) {
		return catalogPreconditionResult{decisionCode: "catalog_material_unavailable", driftReason: modelAdmissionDriftRowChanged, members: members}
	}
	return catalogPreconditionResult{material: material, members: members}
}

// ---- release sweeps (R006 b, c)

// afterReleasePublished runs the R006 sweeps over every catalog_priced /
// settlement_capable candidate after a release publication: each provider's
// section in turn, the recorded content re-evaluated under the new snapshot,
// drifted candidates revoked with the matching code, survivors' bindings
// stamped with the new generation. Never called under the release write lock.
func (s *Server) afterReleasePublished() {
	// Publish → re-verify every session against the new release → evaluate
	// drift and re-stamp survivors: one ordered sequence owned here. The
	// refresh advances the session epoch of every session whose identity
	// changed, so a route attempt captured before it fails closed at
	// compare-and-insert even before the sweep appends the revocation.
	if s.pool != nil {
		s.refreshSessionIdentities()
	}
	if s.modelAdmissions == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), modelAdmissionRuntimeRevocationTimeout)
	defer cancel()
	decided, err := s.modelAdmissions.LatestModelAdmissionStatusesInStates(ctx, []string{"catalog_priced", "settlement_capable"})
	if err != nil {
		s.log.Warn().Err(err).Msg("model admission release sweep: listing failed")
		return
	}
	byProvider := map[string][]ModelAdmissionEvent{}
	var providers []string
	for _, candidate := range decided {
		if _, seen := byProvider[candidate.ProviderID]; !seen {
			providers = append(providers, candidate.ProviderID)
		}
		byProvider[candidate.ProviderID] = append(byProvider[candidate.ProviderID], candidate)
	}
	sort.Strings(providers)
	for _, providerID := range providers {
		s.sweepProviderRelease(ctx, providerID, byProvider[providerID])
	}
}

func (s *Server) sweepProviderRelease(ctx context.Context, providerID string, candidates []ModelAdmissionEvent) {
	s.withProviderSection(providerID, func(section *providerSection) {
		for _, stale := range candidates {
			// Re-read under the section: the listing was taken outside it.
			candidate, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, providerID, stale.CandidateID)
			if err != nil || !found || !modelAdmissionStateDecided(candidate.State) {
				continue
			}
			var (
				eval       catalogPreconditionResult
				boundDrift bool
			)
			s.withReleaseRead(func() {
				current, _ := s.autotuneCatalogSnapshot()
				eval = s.evaluateCatalogPreconditionsLocked(candidate, current)
				// (c): the decision's bound Tier-2 identity must still be the
				// current material.
				if eval.decisionCode == "" &&
					(candidate.CatalogID != eval.material.CatalogID ||
						candidate.CatalogBodyDigest != eval.material.CatalogBodyDigest ||
						candidate.CatalogSignatureKeyID != eval.material.CatalogSignatureKeyID) {
					boundDrift = true
				}
			})
			switch {
			case eval.driftReason != "":
				s.appendDriftRevocationLocked(ctx, candidate, eval.driftReason, "release_sweep", section)
			case eval.decisionCode != "":
				// A decided candidate with no recorded match (a record that
				// predates v0.1.5) cannot be re-resolved under any release:
				// R006(c) requires re-evaluation, and the honest outcome is a
				// revocation (`catalog_row_changed`) — such a candidate could
				// never bind or route anyway; re-entry is a fresh signed offer.
				s.log.Warn().
					Str("event", "model_admission_legacy_record_revoked").
					Str("provider_id", providerID).
					Str("candidate_id", candidate.CandidateID).
					Str("admission_state", candidate.State).
					Msg("decided candidate without a recorded catalog match cannot be re-evaluated; revoked")
				s.appendDriftRevocationLocked(ctx, candidate, modelAdmissionDriftRowChanged, "release_sweep_legacy_record", section)
			case boundDrift:
				s.appendDriftRevocationLocked(ctx, candidate, modelAdmissionDriftRowChanged, "release_sweep_tier2_material", section)
			}
		}
		// R006(a) "refresh": the session's identity was re-verified against
		// the new release by afterReleasePublished before this sweep; the
		// bound decided candidate is evaluated against it here, under the
		// section.
		if provider, ok := s.pool.Resolve(providerID, ""); ok && provider.ModelAdmissionCandidateID != "" {
			s.evaluateSessionDriftLocked(ctx, provider, []string{provider.ModelAdmissionCandidateID}, section)
		}
		// Survivors: refresh the binding (row status + validated generation).
		s.refreshModelAdmissionBindingLocked(ctx, providerID, section)
	})
}
