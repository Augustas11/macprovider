package ws

import (
	"context"
	"strconv"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/autotune"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// trustRevalidationInterval bounds active-session trust drift. Admission
// authorizes trust BEFORE any durable mutation, but a trust root or autotune
// evidence row that expires MID-SESSION leaves an already-established session
// serving until it happens to reconnect. The hardware-trust lane evicts inactive
// admitted tuples; the strict autotune lane route-excludes stale/invalid evidence
// for capped sessions. 30s aligns with the canary sweep's 30s ceiling and keeps
// the bounded-staleness guarantee tight.
const trustRevalidationInterval = 30 * time.Second

// trustRevalidationSweepDeadlineCap bounds how long a single batched sweep read
// may run regardless of the tick interval. The sweep issues ONE DB round-trip
// per tick under a sweep-wide deadline of min(trustRevalidationInterval, this
// cap); a stalled read fails the whole tick OPEN (skip, no evictions) well
// before the next tick fires, so a slow database can never wedge the loop.
const trustRevalidationSweepDeadlineCap = 20 * time.Second

// trustSweepDegradedThreshold bounds the sweep's remaining fail-open (issue #582
// FIX C). A single transient sweep DB error is skipped (never mass-evicts on a
// blip), but this many CONSECUTIVE failures means the trust store has been
// unverifiable for ~N*interval and the ≤interval staleness bound no longer holds.
// At that point the coordinator raises a degraded trust-authority signal and
// quarantines established gated sessions (route-excludes them) rather than
// serving indefinitely on a trust store it cannot read. Kept small so the bound
// is tight (3 * 30s ≈ 90s worst case) while still absorbing brief blips.
const trustSweepDegradedThreshold = 3

type admittedProviderSession struct {
	tuple      onboarding.AdmittedTuple
	assignedID string
}

// runTrustRevalidationLoop is the periodic goroutine backing issue #582 FIX A/B.
// It is started only when the hardware-trust checker is wired (i.e. the
// admission trust join is enabled). Modeled on runSELivenessLoop / runCanaryLoop.
func (s *Server) runTrustRevalidationLoop() {
	ticker := time.NewTicker(trustRevalidationInterval)
	defer ticker.Stop()
	for range ticker.C {
		s.runTrustRevalidationSweep()
	}
}

// runTrustRevalidationSweep re-checks the bounded active-session trust lanes.
// The hardware lane checks every active provider session in ONE batched DB
// round-trip and evicts any whose ADMITTED hardware tuple is no longer backed by
// an active trust root (issue #582 FIX B). The strict autotune lane checks each
// capped live session's LatestVerified evidence under the same sweep deadline
// and route-excludes stale or tuple-mismatched sessions instead of evicting them.
//
// For hardware trust, the sweep snapshots active sessions, collects each
// session's admitted tuple (provider_id + hardware_identity_hash + chip + memory
// captured at the hello gate), classifies the whole set with a single
// SessionsWithoutActiveTrust read under a sweep-wide deadline, then evicts
// exactly the returned untrusted subset. Binding to the admitted tuple (not just
// provider_id) is what closes the multi-Mac gap: a second root B for the same
// provider_id can no longer keep a session admitted via root A alive after root
// A is revoked/expired.
//
// Fail-open, bounded (FIX C): a single transient DB error skips the tick — a
// query blip must never mass-evict the pool. But trustSweepFailures counts
// CONSECUTIVE failures; once it reaches trustSweepDegradedThreshold the sweep
// raises the degraded trust-authority signal and quarantines established gated
// sessions, so the fail-open can no longer run unbounded. A successful sweep
// resets the counter and clears the degraded signal.
func (s *Server) runTrustRevalidationSweep() {
	s.runAdmissionEvidenceRevalidationSweep()
	if s.providerTrust == nil {
		return
	}
	// Snapshot active sessions → one admitted tuple per distinct live session.
	// Only providers with a live session can be serving; skip the rest so a
	// disconnected-but-still-tracked entry costs no DB read. A session with no
	// captured hardware tuple (should not occur while the gate is enabled, since
	// admission requires verified evidence) is skipped rather than evicted, so an
	// edge entry is never dropped on a tuple we cannot check.
	var sessions []admittedProviderSession
	var tuples []onboarding.AdmittedTuple
	seen := make(map[string]struct{})
	for _, provider := range s.pool.Snapshot() {
		if _, ok := s.sessionFor(provider.ProviderID, provider.AssignedID); !ok {
			continue
		}
		if provider.AdmittedHardwareIdentityHash == "" {
			continue
		}
		key := provider.ProviderID + "\x00" + provider.AssignedID + "\x00" + provider.AdmittedHardwareIdentityHash
		if _, dup := seen[key]; dup {
			continue
		}
		seen[key] = struct{}{}
		tuple := onboarding.AdmittedTuple{
			ProviderID:           provider.ProviderID,
			HardwareIdentityHash: provider.AdmittedHardwareIdentityHash,
			ChipNormalized:       provider.AdmittedChipNormalized,
			UnifiedMemoryGB:      provider.AdmittedUnifiedMemoryGB,
		}
		sessions = append(sessions, admittedProviderSession{
			tuple:      tuple,
			assignedID: provider.AssignedID,
		})
		tuples = append(tuples, tuple)
	}
	if len(tuples) == 0 {
		return
	}
	// Single batched read under one sweep-wide deadline.
	deadline := trustRevalidationInterval
	if deadline > trustRevalidationSweepDeadlineCap {
		deadline = trustRevalidationSweepDeadlineCap
	}
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	untrusted, err := s.providerTrust.SessionsWithoutActiveTrust(ctx, tuples)
	cancel()
	if err != nil {
		s.trustSweepFailures++
		s.log.Warn().
			Err(err).
			Int("active_sessions", len(tuples)).
			Int("consecutive_failures", s.trustSweepFailures).
			Msg("hardware trust revalidation batch check failed; skipping evictions this tick")
		// FIX C: a single (or brief) failure fails open — skip. Only SUSTAINED
		// failure escalates to the degraded signal + bounded quarantine.
		if s.trustSweepFailures >= trustSweepDegradedThreshold {
			s.escalateTrustAuthorityDegraded(sessions)
		}
		return
	}
	// Success: clear any prior degraded state.
	if s.trustSweepFailures > 0 || s.trustAuthorityDegraded.Load() {
		s.log.Info().
			Int("prior_consecutive_failures", s.trustSweepFailures).
			Msg("hardware trust revalidation recovered; clearing degraded trust-authority signal")
		s.trustSweepFailures = 0
		s.trustAuthorityDegraded.Store(false)
	}
	sessionsByTuple := make(map[string][]admittedProviderSession, len(sessions))
	for _, session := range sessions {
		sessionsByTuple[admittedTupleKey(session.tuple)] = append(sessionsByTuple[admittedTupleKey(session.tuple)], session)
	}
	for _, tuple := range untrusted {
		s.log.Warn().
			Str("event", "hardware_trust_session_revalidation_evict").
			Str("provider_id", tuple.ProviderID).
			Str("hardware_identity_hash", tuple.HardwareIdentityHash).
			Str("reason", "no_active_trust_root_for_admitted_tuple").
			Msg("evicting active provider session: admitted hardware tuple no longer has an active trust root")
		for _, session := range sessionsByTuple[admittedTupleKey(tuple)] {
			s.disconnectAdmittedSessionForTrustRevalidation(session, "trust_revalidation")
		}
	}
}

func (s *Server) runAdmissionEvidenceRevalidationSweep() {
	if !s.cfg.ProofOfWeights.RequireAutotuneHelloGate || s.autotuneCatalog == nil || s.autotuneEvidence == nil || s.cfg.ProofOfWeights.AutotuneEvidenceTTLDays <= 0 {
		return
	}
	ttl := time.Duration(s.cfg.ProofOfWeights.AutotuneEvidenceTTLDays) * 24 * time.Hour
	deadline := trustRevalidationInterval
	if deadline > trustRevalidationSweepDeadlineCap {
		deadline = trustRevalidationSweepDeadlineCap
	}
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()

	for _, provider := range s.pool.Snapshot() {
		if provider.MaxAdmittedMinRAMGB <= 0 {
			continue
		}
		if _, ok := s.sessionFor(provider.ProviderID, provider.AssignedID); !ok {
			continue
		}
		stale, reason := s.admissionEvidenceStaleVerdict(ctx, provider, ttl)
		if !s.pool.SetAdmissionEvidenceStale(provider.ProviderID, provider.AssignedID, stale) {
			continue
		}
		logger := s.log.Info()
		message := "provider admission evidence revalidated"
		if stale {
			logger = s.log.Warn()
			message = "provider route-excluded by stale admission evidence"
		}
		logger.
			Str("event", EventProviderAdmissionEvidenceStale).
			Str("provider_id", provider.ProviderID).
			Str("assigned_id", provider.AssignedID).
			Str("model_id", provider.ModelID).
			Str("reason", reason).
			Bool("stale", stale).
			Int("max_admitted_min_ram_gb", provider.MaxAdmittedMinRAMGB).
			Msg(message)
	}
}

func (s *Server) admissionEvidenceStaleVerdict(ctx context.Context, provider pool.Provider, ttl time.Duration) (bool, string) {
	evidence, ok, err := s.autotuneEvidence.LatestVerified(ctx, provider.ProviderID, ttl)
	if err != nil {
		return true, "autotune_evidence_lookup_failed"
	}
	if !ok {
		return true, "autotune_evidence_expired"
	}
	if !providerHasAdmittedTuple(provider) {
		return true, "autotune_admitted_tuple_missing"
	}
	if !verifiedEvidenceMatchesAdmittedTuple(evidence, provider) {
		return true, "autotune_evidence_tuple_mismatch"
	}
	catalog := s.autotuneCatalogForProvider(provider)
	if catalog == nil {
		return true, "autotune_catalog_unavailable"
	}
	cap, err := autotune.ResolveMaxAdmission(catalog, evidence)
	if err != nil {
		return true, "autotune_evidence_invalid"
	}
	if cap.MinRAMGB < provider.MaxAdmittedMinRAMGB {
		return true, "autotune_evidence_ceiling_regressed"
	}
	return false, "autotune_evidence_current"
}

func verifiedEvidenceMatchesAdmittedTuple(evidence autotune.VerifiedEvidence, provider pool.Provider) bool {
	return evidence.HardwareIdentityHash == provider.AdmittedHardwareIdentityHash &&
		evidence.ChipNormalized == provider.AdmittedChipNormalized &&
		evidence.UnifiedMemoryGB == provider.AdmittedUnifiedMemoryGB
}

func providerHasAdmittedTuple(provider pool.Provider) bool {
	return provider.AdmittedHardwareIdentityHash != "" &&
		provider.AdmittedChipNormalized != "" &&
		provider.AdmittedUnifiedMemoryGB > 0
}

// escalateTrustAuthorityDegraded raises the degraded trust-authority signal and
// quarantines the established gated sessions after the sweep has failed
// trustSweepDegradedThreshold times in a row (issue #582 FIX C). Quarantine is a
// BOUNDED, route-excluding action — mark the session draining + send a drain
// frame so buyer routing stops selecting it — rather than a hard mass-eviction:
// the trust store is unverifiable, so the coordinator stops serving on unproven
// trust without violating FIX A's "never commit-then-refuse" (these sessions
// were already committed and are being drained, not refused). Idempotent: a
// session already draining is left alone, so repeated ticks past the threshold
// do not re-drain.
func (s *Server) escalateTrustAuthorityDegraded(sessions []admittedProviderSession) {
	first := s.trustAuthorityDegraded.CompareAndSwap(false, true)
	if first {
		s.log.Error().
			Int("consecutive_failures", s.trustSweepFailures).
			Int("gated_sessions", len(sessions)).
			Msg("hardware trust authority DEGRADED: sweep unverifiable past threshold; quarantining gated sessions")
	}
	for _, admitted := range sessions {
		provider, ok := s.pool.Resolve(admitted.tuple.ProviderID, admitted.assignedID)
		if !ok {
			continue
		}
		if !providerMatchesAdmittedTuple(provider, admitted.tuple) {
			continue
		}
		if provider.State == pool.StateDraining {
			continue
		}
		session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
		if !ok {
			continue
		}
		_ = session.send([]byte(`{"type":"drain"}`))
		s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
		s.log.Warn().
			Str("event", "hardware_trust_authority_degraded_quarantine").
			Str("provider_id", provider.ProviderID).
			Str("assigned_id", provider.AssignedID).
			Msg("quarantining gated session: trust authority unverifiable (route-excluded, draining)")
	}
}

func (s *Server) disconnectAdmittedSessionForTrustRevalidation(admitted admittedProviderSession, actor string) {
	provider, ok := s.pool.Resolve(admitted.tuple.ProviderID, admitted.assignedID)
	if !ok {
		return
	}
	if !providerMatchesAdmittedTuple(provider, admitted.tuple) {
		return
	}
	if provider.State == pool.StateDraining {
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		return
	}
	_ = session.send([]byte(`{"type":"drain"}`))
	s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
	s.log.Warn().
		Str("event", "hardware_trust_provider_evicted").
		Str("provider_id", provider.ProviderID).
		Str("assigned_id", provider.AssignedID).
		Str("actor", actor).
		Msg("draining provider session after hardware trust revocation")
	time.AfterFunc(200*time.Millisecond, func() {
		s.closeSession(session, CloseBanned, "hardware trust revoked for provider "+provider.ProviderID)
	})
}

func providerMatchesAdmittedTuple(provider pool.Provider, tuple onboarding.AdmittedTuple) bool {
	return provider.ProviderID == tuple.ProviderID &&
		provider.AdmittedHardwareIdentityHash == tuple.HardwareIdentityHash &&
		provider.AdmittedChipNormalized == tuple.ChipNormalized &&
		provider.AdmittedUnifiedMemoryGB == tuple.UnifiedMemoryGB
}

func admittedTupleKey(tuple onboarding.AdmittedTuple) string {
	return tuple.ProviderID + "\x00" + tuple.HardwareIdentityHash + "\x00" + tuple.ChipNormalized + "\x00" + strconv.Itoa(tuple.UnifiedMemoryGB)
}
