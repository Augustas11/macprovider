package ws

import (
	"bytes"
	"context"
	"encoding/json"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type modelAdmissionAuthorityExtension struct {
	OfferIdentitySHA256       string                             `json:"offer_identity_sha256,omitempty"`
	RuntimeSource             string                             `json:"runtime_source,omitempty"`
	ExpectedCurrentEventID    string                             `json:"expected_current_event_id,omitempty"`
	ArtifactAdmissionEvidence *billing.ArtifactAdmissionEvidence `json:"artifact_admission,omitempty"`
}

func modelAdmissionAuthorityJSON(event ModelAdmissionEvent) string {
	raw, _ := json.Marshal(modelAdmissionAuthorityExtension{RuntimeSource: event.RuntimeSource, OfferIdentitySHA256: event.OfferIdentitySHA256, ExpectedCurrentEventID: event.ExpectedCurrentEventID, ArtifactAdmissionEvidence: event.ArtifactAdmissionEvidence})
	return string(raw)
}

// ModelAdmissionAuthorityResolver is supplied by the coordinator's verified
// feed/effective-billing owner. A provider-supplied assertion never implements it.
type ModelAdmissionAuthorityResolver func(context.Context, pool.Provider, ModelAdmissionEvent) (ModelAdmissionEvent, error)

// PreparedModelAdmissionAuthority contains coordinator-owned evidence and a pin
// factory. It is never decoded from a provider request or persisted as a closure.
type PreparedModelAdmissionAuthority struct {
	Event  ModelAdmissionEvent
	TryPin ModelAdmissionCommitGuard
}
type ModelAdmissionAuthorityPreparer func(context.Context, pool.Provider, ModelAdmissionEvent) (PreparedModelAdmissionAuthority, error)

func (s *Server) SetModelAdmissionAuthority(resolve ModelAdmissionAuthorityResolver, prepares ...ModelAdmissionAuthorityPreparer) error {
	s.modelAdmissionAuthorityMu.Lock()
	defer s.modelAdmissionAuthorityMu.Unlock()
	s.modelAdmissionAuthorityGeneration++
	s.modelAdmissionAuthority = resolve
	s.modelAdmissionPrepare = nil
	if resolve == nil {
		return nil
	}
	if len(prepares) != 1 || prepares[0] == nil {
		return errModelAdmissionAuthorityUnavailable
	}
	s.modelAdmissionPrepare = prepares[0]
	return nil
}
func (s *Server) admissionAuthorityResolver() ModelAdmissionAuthorityResolver {
	s.modelAdmissionAuthorityMu.RLock()
	defer s.modelAdmissionAuthorityMu.RUnlock()
	return s.modelAdmissionAuthority
}
func (s *Server) prepareAdmission(ctx context.Context, p pool.Provider, current ModelAdmissionEvent) (PreparedModelAdmissionAuthority, uint64, error) {
	s.modelAdmissionAuthorityMu.RLock()
	prepare, generation := s.modelAdmissionPrepare, s.modelAdmissionAuthorityGeneration
	s.modelAdmissionAuthorityMu.RUnlock()
	if prepare == nil {
		return PreparedModelAdmissionAuthority{}, generation, errModelAdmissionAuthorityUnavailable
	}
	prepared, err := prepare(ctx, p, current)
	if err == nil && (prepared.TryPin == nil || prepared.Event.ArtifactAdmissionEvidence == nil) {
		err = errModelAdmissionAuthorityUnavailable
	}
	return prepared, generation, err
}

func sameAdmissionProvider(a, b pool.Provider) bool {
	return a.ProviderID == b.ProviderID && a.AssignedID == b.AssignedID && a.ModelID == b.ModelID && a.ModelHash == b.ModelHash &&
		a.ExpectedModelHash == b.ExpectedModelHash && a.ModelHashAlgorithm == b.ModelHashAlgorithm && a.CatalogAdmissionMode == b.CatalogAdmissionMode &&
		a.CatalogPolicyVersion == b.CatalogPolicyVersion && a.CandidateCatalogSHA256 == b.CandidateCatalogSHA256 && a.CatalogReleaseID == b.CatalogReleaseID &&
		a.CatalogSignerKeyID == b.CatalogSignerKeyID && a.CandidateRowIdentity == b.CandidateRowIdentity && bytes.Equal(a.ReceiptPubkey, b.ReceiptPubkey)
}

func (s *Server) pinAdmission(ctx context.Context, p pool.Provider, prepared PreparedModelAdmissionAuthority, generation uint64) (func(), error) {
	var releases []func()
	release := func() {
		for i := len(releases) - 1; i >= 0; i-- {
			releases[i]()
		}
	}
	fail := func() (func(), error) { release(); return nil, errModelAdmissionAuthorityUnavailable }
	if !s.modelAdmissionAuthorityMu.TryRLock() {
		return fail()
	}
	releases = append(releases, s.modelAdmissionAuthorityMu.RUnlock)
	if generation != s.modelAdmissionAuthorityGeneration || s.modelAdmissionPrepare == nil {
		return fail()
	}
	if !s.sessionPublicationMu.TryRLock() {
		return fail()
	}
	releases = append(releases, s.sessionPublicationMu.RUnlock)
	session, ok := s.storedSessionFor(p.ProviderID, p.AssignedID)
	if !ok || session.providerID != p.ProviderID || session.assignedID != p.AssignedID || !session.writeMu.TryLock() {
		return fail()
	}
	releases = append(releases, session.writeMu.Unlock)
	if session.closing || session.closed {
		return fail()
	}
	live, sanctioned, unlock, ok := s.pool.TryPinModelAdmissionProvider(p.ProviderID, p.AssignedID)
	if !ok {
		return fail()
	}
	releases = append(releases, unlock)
	if sanctioned || !sameAdmissionProvider(p, live) || !live.IsWSTunneled() ||
		(live.State != pool.StateReady && live.State != pool.StateBusy) || len(live.PendingReceiptPubkey) > 0 ||
		live.AuthState == pool.AuthBearerlessDuplicate || live.AuthState == pool.AuthSelfMinted ||
		live.BenchmarkQuarantined || live.AdmissionCeilingExcluded || live.AdmissionEvidenceStale || live.AdmissionSandboxed {
		return fail()
	}
	unlock, err := prepared.TryPin()
	if err != nil {
		return fail()
	}
	releases = append(releases, unlock)
	if ctx.Err() != nil || artifactDecisionExpired(prepared.Event, s.now()) {
		return fail()
	}
	return release, nil
}

func (s *Server) promoteModelAdmission(ctx context.Context, current ModelAdmissionEvent, probedProvider pool.Provider, probeAt time.Time) ModelAdmissionEvent {
	store, guarded := s.modelAdmissions.(guardedModelAdmissionStore)
	if !guarded || (current.State != "network_admitted_unsettled" && current.State != "catalog_priced") {
		return current
	}
	for _, state := range []string{"catalog_priced", "settlement_capable"} {
		if state == current.State {
			continue
		}
		provider, ok := s.modelAdmissionSyntheticProbeProvider(current.ProviderID)
		if !ok || !sameAdmissionProvider(provider, probedProvider) {
			return current
		}
		prepared, generation, err := s.prepareAdmission(ctx, provider, current)
		if err != nil {
			return current
		}
		authority := prepared.Event
		authority.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS = probeAt.Add(10 * time.Minute).UnixMilli()
		decision := modelAdmissionCoordinatorDecisionFromCurrent(current, state, "primary_artifact_authority_verified", "macprovider.model_admission.primary_artifact.v1", modelAdmissionAuthorityJSON(authority), s.now())
		decision.CatalogModelKey = authority.CatalogModelKey
		decision.CatalogID = authority.CatalogID
		decision.CatalogBodyDigest = authority.CatalogBodyDigest
		decision.CatalogSignatureKeyID = authority.CatalogSignatureKeyID
		decision.CatalogSignaturePubkeyFingerprint = authority.CatalogSignaturePubkeyFingerprint
		decision.ExpectedCatalogModelHash = authority.ExpectedCatalogModelHash
		decision.ExpectedCatalogModelHashAlgorithm = authority.ExpectedCatalogModelHashAlgorithm
		decision.ArtifactAdmissionEvidence = authority.ArtifactAdmissionEvidence
		prepared.Event = decision
		expiry := time.UnixMilli(min(decision.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS, decision.ArtifactAdmissionEvidence.AuthorityExpiresAtUnixMS))
		budget := min(250*time.Millisecond, expiry.Sub(s.now()))
		commitCtx, cancel := context.WithTimeout(ctx, budget)
		stored, err := store.AppendGuardedModelAdmissionDecision(commitCtx, decision, func() (func(), error) { return s.pinAdmission(commitCtx, provider, prepared, generation) })
		cancel()
		if err != nil {
			return current
		}
		current = stored
	}
	return current
}

// ModelAdmissionAuthorityRevocation makes a CAS-protected demotion when a
// current route-time authority check fails. In-flight snapshots stay immutable.
func ModelAdmissionAuthorityRevocation(current ModelAdmissionEvent, now time.Time) ModelAdmissionEvent {
	return modelAdmissionCoordinatorDecisionFromCurrent(current, "revoked", "artifact_authority_drift", "macprovider.model_admission.authority_drift.v1", current.CoordinatorEventID, now)
}

func cloneModelAdmissionEvent(event ModelAdmissionEvent) ModelAdmissionEvent {
	if event.ArtifactAdmissionEvidence != nil {
		evidence := *event.ArtifactAdmissionEvidence
		event.ArtifactAdmissionEvidence = &evidence
	}
	return event
}

// refreshArtifactAdmissionStatus prevents a persisted capability from being
// presented as current after its probe, session, feed, or rate authority changes.
func (s *Server) refreshArtifactAdmissionStatus(ctx context.Context, selected ModelAdmissionEvent) (ModelAdmissionEvent, error) {
	for attempt := 0; attempt < 2; attempt++ {
		current, found, err := s.modelAdmissions.LatestModelAdmissionStatus(ctx, selected.ProviderID, selected.CandidateID)
		if err != nil {
			return ModelAdmissionEvent{}, err
		}
		if !found {
			return ModelAdmissionEvent{}, errModelAdmissionAuthorityUnavailable
		}
		store, guarded := s.modelAdmissions.(guardedModelAdmissionStore)
		if !guarded {
			if artifactPositive(current) {
				return ModelAdmissionEvent{}, errModelAdmissionAuthorityUnavailable
			}
			return current, nil
		}
		var prepared PreparedModelAdmissionAuthority
		var provider pool.Provider
		var generation uint64
		if artifactPositive(current) {
			var live bool
			provider, live = s.modelAdmissionSyntheticProbeProvider(current.ProviderID)
			if !live {
				err = errModelAdmissionAuthorityUnavailable
			} else {
				prepared, generation, err = s.prepareAdmission(ctx, provider, current)
			}
			if err == nil {
				actual := prepared.Event
				actual.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS = current.ArtifactAdmissionEvidence.ProbeExpiresAtUnixMS
				if *actual.ArtifactAdmissionEvidence != *current.ArtifactAdmissionEvidence || actual.CatalogBodyDigest != current.CatalogBodyDigest || actual.CatalogID != current.CatalogID || actual.CatalogSignatureKeyID != current.CatalogSignatureKeyID || actual.CatalogSignaturePubkeyFingerprint != current.CatalogSignaturePubkeyFingerprint {
					err = errModelAdmissionAuthorityUnavailable
				}
				prepared.Event = current
			}
			if err != nil || artifactDecisionExpired(current, s.now()) {
				if _, revokeErr := s.modelAdmissions.AppendModelAdmissionDecision(ctx, ModelAdmissionAuthorityRevocation(current, s.now())); revokeErr != nil && attempt == 1 {
					return ModelAdmissionEvent{}, revokeErr
				}
				continue
			}
		}
		observed, err := store.ObserveModelAdmission(ctx, current.ProviderID, current.CandidateID, func(latest ModelAdmissionEvent) (func(), error) {
			if latest.CoordinatorEventID != current.CoordinatorEventID {
				return nil, errModelAdmissionReplayConflict
			}
			if !artifactPositive(latest) {
				return nil, nil
			}
			return s.pinAdmission(ctx, provider, prepared, generation)
		})
		if err == nil && !artifactDecisionExpired(observed, s.now()) {
			return observed, nil
		}
	}
	return ModelAdmissionEvent{}, errModelAdmissionAuthorityUnavailable
}
