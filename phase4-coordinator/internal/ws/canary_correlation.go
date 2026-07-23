package ws

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/canarycorr"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// liveCorrelationEpoch is one in-flight FR-CAN23 multi-provider epoch for a model.
// Guarded by Server.canaryCorrMu.
type liveCorrelationEpoch struct {
	modelID        string
	fingerprint    string
	bankGeneration uint64
	epoch          *canarycorr.Epoch
	// Shared challenge re-dispatched to every snapshot member.
	probe        canaryBuiltProbe
	assignedByID map[string]string
	// recoveryEpochByID captures canary recovery epoch at Stage time so commit
	// can drop results invalidated by operator recovery.
	recoveryEpochByID map[string]uint64
	startedAt         time.Time
	deadline          time.Time
	// pendingShared marks snapshot members that still need a forced shared-fp probe.
	pendingShared map[string]struct{}
}

// sharedCanaryDispatch is a fingerprint-bound probe forced onto snapshot peers.
type sharedCanaryDispatch struct {
	modelID        string
	fingerprint    string
	bankGeneration uint64
	probe          canaryBuiltProbe
}

func canaryChallengeFingerprint(challenge config.CanaryChallengeConfig) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(challenge.Prompt) + "\n" + strings.TrimSpace(challenge.Expected)))
	return hex.EncodeToString(sum[:])
}

func mapCanaryFailClass(outcome canaryProbeOutcome, reason canaryFailReason) canarycorr.FailureClass {
	if outcome == canaryProbePass {
		return canarycorr.ClassPass
	}
	if outcome == canaryProbeSkip {
		return canarycorr.ClassNeutral
	}
	switch reason {
	case canaryFailNonce:
		return canarycorr.ClassNonceMismatch
	case canaryFailIncomplete:
		return canarycorr.ClassIncomplete
	case canaryFailRelay:
		return canarycorr.ClassRelayHard
	case canaryFailTTFT, canaryFailTPS:
		// Latency failures are not correctness failures for correlation suspicion.
		return canarycorr.ClassRelaySoft
	default:
		return canarycorr.ClassRelaySoft
	}
}

func (s *Server) canaryCorrelationWindow() time.Duration {
	// FR-CAN12-class bound: 1.5× canary interval + sweep cadence.
	return s.canaryInterval()*3/2 + s.canarySweepCadence()
}

func (s *Server) observedServingFor(p pool.Provider) bool {
	last := time.Time{}
	if p.LastBuyerSuccessAt != nil {
		last = *p.LastBuyerSuccessAt
	} else if s.pool != nil {
		last = s.pool.LastBuyerSuccessAt(p.ProviderID)
	}
	return canarycorr.HasRecentObservedServing(last, s.now(), canarycorr.ObservedServingWindow)
}

// shouldRouteThroughCorrelation reports whether this result must enter the
// FR-CAN23 staged path. Sole-provider models and non-correctness outcomes
// without an open epoch stay on the immediate RecordCanaryResult path.
func (s *Server) shouldRouteThroughCorrelation(provider pool.Provider, class canarycorr.FailureClass) bool {
	if s.pool == nil {
		return false
	}
	modelID := strings.TrimSpace(provider.ModelID)
	if modelID == "" {
		return false
	}
	s.canaryCorrMu.Lock()
	defer s.canaryCorrMu.Unlock()
	if s.canaryCorrByModel != nil {
		if _, open := s.canaryCorrByModel[strings.ToLower(modelID)]; open {
			return true
		}
	}
	if !canarycorr.CorrectnessFailure(class) {
		return false
	}
	return s.pool.BuyerServingCountForModel(modelID) >= 2
}

// takeSharedCanaryDispatch returns and clears a forced shared-fingerprint probe
// for providerID, if any.
func (s *Server) takeSharedCanaryDispatch(providerID string) (sharedCanaryDispatch, bool) {
	s.canaryCorrMu.Lock()
	defer s.canaryCorrMu.Unlock()
	if s.canarySharedDispatch == nil {
		return sharedCanaryDispatch{}, false
	}
	d, ok := s.canarySharedDispatch[providerID]
	if !ok {
		return sharedCanaryDispatch{}, false
	}
	delete(s.canarySharedDispatch, providerID)
	return d, true
}

// requeueSharedCanaryDispatch restores a forced probe after a skip so the peer
// still receives the shared fingerprint (or the FR-CAN12 window resolves).
func (s *Server) requeueSharedCanaryDispatch(providerID string, d sharedCanaryDispatch) {
	if strings.TrimSpace(providerID) == "" {
		return
	}
	s.canaryCorrMu.Lock()
	defer s.canaryCorrMu.Unlock()
	if s.canarySharedDispatch == nil {
		s.canarySharedDispatch = make(map[string]sharedCanaryDispatch)
	}
	s.canarySharedDispatch[providerID] = d
	s.canaryDue.Store(providerID, s.now())
}

// expireCanaryCorrelationWindows resolves any open epochs past their FR-CAN12
// deadline with AllowIncomplete. Called at the start of each canary sweep.
func (s *Server) expireCanaryCorrelationWindows() {
	now := s.now()
	type due struct {
		modelKey string
		live     *liveCorrelationEpoch
	}
	var expired []due
	s.canaryCorrMu.Lock()
	for key, live := range s.canaryCorrByModel {
		if live != nil && !live.deadline.IsZero() && !now.Before(live.deadline) {
			// Drop forced shared dispatches so peers do not re-enter a dead epoch.
			for id := range live.pendingShared {
				delete(s.canarySharedDispatch, id)
			}
			for id := range live.assignedByID {
				delete(s.canarySharedDispatch, id)
			}
			expired = append(expired, due{modelKey: key, live: live})
			delete(s.canaryCorrByModel, key)
		}
	}
	s.canaryCorrMu.Unlock()
	for _, item := range expired {
		s.resolveAndApplyCorrelation(item.live, true /* allowIncomplete */)
	}
}

// providerInOpenCorrelation reports whether providerID is a member of any open
// FR-CAN23 epoch snapshot (staged or pending). Such members must not take the
// immediate sanction path until the epoch resolves.
func (s *Server) providerInOpenCorrelation(providerID string) bool {
	s.canaryCorrMu.Lock()
	defer s.canaryCorrMu.Unlock()
	for _, live := range s.canaryCorrByModel {
		if live == nil || live.epoch == nil {
			continue
		}
		if _, ok := live.epoch.Snapshot[providerID]; ok {
			return true
		}
		if _, ok := live.assignedByID[providerID]; ok {
			return true
		}
		if _, ok := live.pendingShared[providerID]; ok {
			return true
		}
	}
	return false
}

// applyCanaryViaCorrelation stages the result into the model epoch and resolves
// when complete (or when the caller already expired the window).
func (s *Server) applyCanaryViaCorrelation(provider pool.Provider, attempt canaryAttemptResult, class canarycorr.FailureClass, recoveryEpoch uint64) bool {
	modelID := strings.TrimSpace(provider.ModelID)
	if modelID == "" || s.pool == nil {
		return s.applyCanaryImmediate(provider, attempt, recoveryEpoch)
	}
	modelKey := strings.ToLower(modelID)
	fp := canaryChallengeFingerprint(attempt.challenge)
	if fp == "" {
		return s.applyCanaryImmediate(provider, attempt, recoveryEpoch)
	}

	s.canaryCorrMu.Lock()
	if s.canaryCorrByModel == nil {
		s.canaryCorrByModel = make(map[string]*liveCorrelationEpoch)
	}
	if s.canarySharedDispatch == nil {
		s.canarySharedDispatch = make(map[string]sharedCanaryDispatch)
	}
	if s.canaryBankGeneration == 0 {
		s.canaryBankGeneration = 1
	}

	live := s.canaryCorrByModel[modelKey]
	if live == nil {
		// Only correctness failures open a new epoch (design: stage shared-fp fails).
		if !canarycorr.CorrectnessFailure(class) {
			s.canaryCorrMu.Unlock()
			return s.applyCanaryImmediate(provider, attempt, recoveryEpoch)
		}
		snapshot := s.pool.BuyerServingProviderIDsForModel(modelID)
		// Ensure the failing provider is in the snapshot even if predicate races.
		found := false
		for _, id := range snapshot {
			if id == provider.ProviderID {
				found = true
				break
			}
		}
		if !found {
			snapshot = append(snapshot, provider.ProviderID)
		}
		if len(snapshot) < 2 {
			s.canaryCorrMu.Unlock()
			return s.applyCanaryImmediate(provider, attempt, recoveryEpoch)
		}
		s.canaryBankGeneration++
		bankGen := s.canaryBankGeneration
		ep, err := canarycorr.NewEpoch(modelID, fp, bankGen, snapshot)
		if err != nil {
			s.canaryCorrMu.Unlock()
			s.log.Warn().Err(err).Str("model_id", modelID).Msg("canary correlation epoch open failed; applying immediately")
			return s.applyCanaryImmediate(provider, attempt, recoveryEpoch)
		}
		now := s.now()
		live = &liveCorrelationEpoch{
			modelID:           modelID,
			fingerprint:       fp,
			bankGeneration:    bankGen,
			epoch:             ep,
			probe:             attempt.probe,
			assignedByID:      map[string]string{provider.ProviderID: provider.AssignedID},
			recoveryEpochByID: map[string]uint64{provider.ProviderID: recoveryEpoch},
			startedAt:         now,
			deadline:          now.Add(s.canaryCorrelationWindow()),
			pendingShared:     make(map[string]struct{}),
		}
		for _, id := range snapshot {
			if id == provider.ProviderID {
				continue
			}
			live.pendingShared[id] = struct{}{}
			s.canarySharedDispatch[id] = sharedCanaryDispatch{
				modelID:        modelID,
				fingerprint:    fp,
				bankGeneration: bankGen,
				probe:          attempt.probe,
			}
			// Force peer due immediately for shared-fingerprint re-dispatch.
			s.canaryDue.Store(id, now)
		}
		s.canaryCorrByModel[modelKey] = live
	}

	// Fingerprint/generation must match the open epoch. Snapshot members of an
	// open epoch NEVER take the immediate path (would break unapplied-until-resolve).
	if live.fingerprint != fp || (attempt.sharedBankGen != 0 && attempt.sharedBankGen != live.bankGeneration) {
		s.canaryCorrMu.Unlock()
		s.log.Info().
			Str("provider_id", provider.ProviderID).
			Str("model_id", modelID).
			Msg("canary result fenced from open correlation epoch (fingerprint/generation mismatch); discarded until shared re-dispatch or window")
		// Keep due after deadline so the forced shared probe (if any) or window wins.
		s.canaryDue.Store(provider.ProviderID, live.deadline.Add(time.Millisecond))
		return true
	}

	live.assignedByID[provider.ProviderID] = provider.AssignedID
	if live.recoveryEpochByID == nil {
		live.recoveryEpochByID = make(map[string]uint64)
	}
	live.recoveryEpochByID[provider.ProviderID] = recoveryEpoch
	delete(live.pendingShared, provider.ProviderID)
	delete(s.canarySharedDispatch, provider.ProviderID)

	buyerServing := s.canaryBuyerServing(provider)
	staged := canarycorr.StagedResult{
		ProviderID:      provider.ProviderID,
		AssignedID:      provider.AssignedID,
		ModelID:         modelID,
		Fingerprint:     live.fingerprint,
		BankGeneration:  live.bankGeneration,
		Class:           class,
		BuyerServing:    buyerServing,
		ObservedServing: s.observedServingFor(provider),
	}
	if err := live.epoch.Stage(staged); err != nil {
		// Already staged (re-probe before resolve): hold until deadline, no apply.
		deadline := live.deadline
		s.canaryCorrMu.Unlock()
		s.log.Info().Err(err).Str("provider_id", provider.ProviderID).Msg("canary correlation stage skipped (already staged or fenced); holding until epoch resolve")
		if !deadline.IsZero() {
			s.canaryDue.Store(provider.ProviderID, deadline.Add(time.Millisecond))
		}
		return true
	}

	complete := live.epoch.StagedCount() >= live.epoch.N()
	var toResolve *liveCorrelationEpoch
	if complete {
		toResolve = live
		delete(s.canaryCorrByModel, modelKey)
		for id := range live.pendingShared {
			delete(s.canarySharedDispatch, id)
		}
		for id := range live.assignedByID {
			delete(s.canarySharedDispatch, id)
		}
	}
	deadline := live.deadline
	stagedCount := live.epoch.StagedCount()
	snapshotN := live.epoch.N()
	s.canaryCorrMu.Unlock()

	if toResolve != nil {
		return s.resolveAndApplyCorrelation(toResolve, false)
	}
	// Hold re-probe until after FR-CAN12 window so counters stay unapplied.
	if !deadline.IsZero() {
		s.canaryDue.Store(provider.ProviderID, deadline.Add(time.Millisecond))
	}
	s.log.Info().
		Str("provider_id", provider.ProviderID).
		Str("model_id", modelID).
		Str("event", "canary_correlation_staged").
		Str("class", string(class)).
		Int("staged", stagedCount).
		Int("snapshot_n", snapshotN).
		Msg("canary result staged for FR-CAN23 correlation epoch")
	return true
}

func (s *Server) resolveAndApplyCorrelation(live *liveCorrelationEpoch, allowIncomplete bool) bool {
	if live == nil || live.epoch == nil {
		return false
	}
	out, err := live.epoch.Resolve(s.now(), canarycorr.ResolveOptions{AllowIncomplete: allowIncomplete})
	if err != nil {
		s.log.Warn().Err(err).Str("model_id", live.modelID).Msg("canary correlation resolve failed")
		return false
	}
	if out.Suspicious {
		if out.Alert != nil {
			s.log.Warn().
				Str("event", "canary_correlated_fault").
				Str("model_id", out.Alert.ModelID).
				Str("fingerprint", out.Alert.Fingerprint).
				Uint64("bank_generation", out.Alert.BankGeneration).
				Int("snapshot_n", out.Alert.SnapshotN).
				Int("failing_count", out.Alert.FailingCount).
				Bool("discarded", out.Alert.Discarded).
				Str("reason", out.Alert.Reason).
				Msg("FR-CAN23/FR-CAN29a correlated canary majority — staged results discarded; no sanctions applied")
		}
		return true
	}
	applied := false
	for _, c := range out.Commits {
		assigned := c.AssignedID
		if assigned == "" {
			assigned = live.assignedByID[c.ProviderID]
		}
		// Drop commits invalidated by operator recovery between stage and resolve.
		if stagedEpoch, ok := live.recoveryEpochByID[c.ProviderID]; ok {
			s.canaryRecoveryMu.RLock()
			cur := s.canaryEpoch(c.ProviderID).Load()
			s.canaryRecoveryMu.RUnlock()
			if cur != stagedEpoch {
				s.log.Info().
					Str("provider_id", c.ProviderID).
					Msg("discarding canary correlation commit invalidated by operator recovery")
				continue
			}
		}
		switch {
		case c.ApplyPass:
			if s.applyCanaryRecord(c.ProviderID, assigned, true, canaryAttemptResult{outcome: canaryProbePass}, false) {
				applied = true
			}
		case c.ApplyFailure:
			// FloorHeld: accrue fail counter but force FR-CAN23 residual floor
			// (suppress tier sanction even if ghost BuyerServing peers exist).
			attempt := canaryAttemptResult{
				outcome: canaryProbeFail,
				metrics: canaryProbeMetrics{FailReason: classToFailReason(c.Class)},
			}
			if s.applyCanaryRecord(c.ProviderID, assigned, false, attempt, c.FloorHeld) {
				applied = true
			}
		}
	}
	return applied
}

func classToFailReason(class canarycorr.FailureClass) canaryFailReason {
	switch class {
	case canarycorr.ClassNonceMismatch:
		return canaryFailNonce
	case canarycorr.ClassIncomplete:
		return canaryFailIncomplete
	case canarycorr.ClassRelayHard:
		return canaryFailRelay
	default:
		return canaryFailNone
	}
}

// applyCanaryRecord is the shared sanction application used by immediate and
// correlation commit paths. recoveryFenced is handled by callers before invoke.
// Returns false when the result was not current (stale session).
func (s *Server) applyCanaryRecord(providerID, assignedID string, passed bool, attempt canaryAttemptResult, corrFloorHeld bool) bool {
	checkedAt := s.now()
	var result pool.CanaryResult
	if corrFloorHeld && !passed {
		result = s.pool.RecordCanaryResultForceFloorHeld(providerID, assignedID, passed, checkedAt, s.canaryFailureThreshold())
	} else {
		result = s.pool.RecordCanaryResult(providerID, assignedID, passed, checkedAt, s.canaryFailureThreshold())
	}
	if !result.Current {
		return false
	}
	s.enforceNextCanary.Delete(providerID)
	if passed {
		if result.SanctionCleared {
			_ = s.deleteCanarySanction(providerID)
		}
		if result.Count == 0 {
			s.log.Debug().Str("provider_id", providerID).Msg("provider canary passed")
		}
		return true
	}
	event := s.log.Warn().
		Str("provider_id", providerID).
		Int("canary_fail_count", result.Count).
		Int("canary_failure_threshold", result.Threshold)
	if attempt.metrics.FailReason != canaryFailNone {
		event = event.Str("canary_fail_reason", string(attempt.metrics.FailReason))
	}
	if result.Tripped != pool.CanaryTripNone {
		event = event.Str("canary_trip", string(result.Tripped))
	}
	if corrFloorHeld && result.Tripped == pool.CanaryTripNone {
		event = event.Bool("canary_corr_floor_held", true)
	}
	if attempt.modelClassBank && attempt.metrics.LatencyGated {
		event = event.
			Int("canary_ttft_ms", attempt.metrics.TTFTMS).
			Float64("canary_sustained_tps", attempt.metrics.SustainedTPS)
	}
	event.Msg("provider canary failed")
	switch result.Tripped {
	case pool.CanaryTripUnavailable:
		if result.Tier == pool.TierProvisional && s.admission != nil {
			s.admission.Reject(providerID, "canary failures")
		}
		if session, ok := s.sessionFor(providerID, assignedID); ok {
			s.closeSession(session, CloseBanned, "canary_failed")
		}
	case pool.CanaryTripDegraded:
		s.saveCanarySanction(pool.CanarySanctionSnapshot{
			ProviderID:    providerID,
			FailCount:     result.Count,
			LastCheckedAt: &checkedAt,
			LastFailedAt:  &checkedAt,
		})
		s.log.Warn().Str("provider_id", providerID).Msg("provider held degraded after canary threshold")
	case pool.CanaryTripFloorHeld:
		s.log.Warn().
			Str("provider_id", providerID).
			Str("event", "canary_floor_held").
			Int("canary_fail_count", result.Count).
			Int("canary_failure_threshold", result.Threshold).
			Bool("pool_redundancy_low", true).
			Msg("sole buyer-serving provider for model failed canary threshold; spared to preserve availability (SPEC-031 FR-CAN22) — operator investigation required")
	}
	return true
}

