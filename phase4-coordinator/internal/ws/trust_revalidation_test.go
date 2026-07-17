package ws

import (
	"context"
	"errors"
	"net"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/onboarding"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// stubTrustChecker records the admitted tuples passed to the batched sweep read
// and returns a configured untrusted subset (or an error). untrusted is keyed by
// hardware_identity_hash, so a test can mark a specific admitted tuple as having
// lost its trust root (issue #582 FIX B — the sweep is tuple-bound, not
// provider-wide).
type stubTrustChecker struct {
	untrusted map[string]struct{}
	err       error
	onCheck   func()
	calls     int
	gotTuples []onboarding.AdmittedTuple
}

func (s *stubTrustChecker) SessionsWithoutActiveTrust(_ context.Context, admitted []onboarding.AdmittedTuple) ([]onboarding.AdmittedTuple, error) {
	s.calls++
	s.gotTuples = append([]onboarding.AdmittedTuple(nil), admitted...)
	if s.onCheck != nil {
		s.onCheck()
	}
	if s.err != nil {
		return nil, s.err
	}
	var out []onboarding.AdmittedTuple
	for _, a := range admitted {
		if _, bad := s.untrusted[a.HardwareIdentityHash]; bad {
			out = append(out, a)
		}
	}
	return out, nil
}

// setAdmittedTuple stamps a harness provider with the admitted hardware tuple the
// hello gate would have captured, so the tuple-aware sweep considers it a gated
// session (issue #582 FIX B). The registry stores the provider pointer, so this
// mutation is visible to Snapshot.
func setAdmittedTuple(p *pool.Provider) {
	setAdmittedTupleValues(p, "hashA", "apple m4 max", 64)
}

func setAdmittedTupleValues(p *pool.Provider, hardwareIdentityHash, chipNormalized string, unifiedMemoryGB int) {
	p.AdmittedHardwareIdentityHash = hardwareIdentityHash
	p.AdmittedChipNormalized = chipNormalized
	p.AdmittedUnifiedMemoryGB = unifiedMemoryGB
}

// TestTrustRevalidationSweepEvictsInactiveTrust asserts the batched bounded sweep
// (issue #582 FIX A/B) drains an active session whose ADMITTED hardware tuple no
// longer has an active trust root, keeps a session whose tuple is still trusted,
// and fails OPEN (no eviction) on a transient DB error — all in a single batched
// read per tick, passing the admitted tuple (not just provider_id).
func TestTrustRevalidationSweepEvictsInactiveTrust(t *testing.T) {
	tests := []struct {
		name        string
		untrustsAll bool
		err         error
		wantDrained bool
	}{
		{name: "inactive tuple trust evicts", untrustsAll: true, wantDrained: true},
		{name: "active tuple trust keeps session", untrustsAll: false, wantDrained: false},
		{name: "db error fails open", err: errors.New("db blip"), wantDrained: false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			s, provider, _ := newEncryptedRelayHarness(t)
			setAdmittedTuple(provider)
			checker := &stubTrustChecker{err: tc.err}
			if tc.untrustsAll {
				checker.untrusted = map[string]struct{}{provider.AdmittedHardwareIdentityHash: {}}
			}
			s.providerTrust = checker

			s.runTrustRevalidationSweep()

			if checker.calls != 1 {
				t.Fatalf("SessionsWithoutActiveTrust calls = %d, want 1 (single batched read)", checker.calls)
			}
			if len(checker.gotTuples) != 1 ||
				checker.gotTuples[0].ProviderID != provider.ProviderID ||
				checker.gotTuples[0].HardwareIdentityHash != provider.AdmittedHardwareIdentityHash {
				t.Fatalf("batched read tuples = %+v, want one for provider %s / %s",
					checker.gotTuples, provider.ProviderID, provider.AdmittedHardwareIdentityHash)
			}
			resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
			if !ok {
				t.Fatal("provider missing from pool after sweep")
			}
			drained := resolved.State == pool.StateDraining
			if drained != tc.wantDrained {
				t.Fatalf("provider state = %q, wantDrained = %v", resolved.State, tc.wantDrained)
			}
		})
	}
}

func TestTrustRevalidationSweepDoesNotDrainReplacementSession(t *testing.T) {
	s, provider, _ := newEncryptedRelayHarness(t)
	setAdmittedTupleValues(provider, "hashA", "apple m4 max", 64)

	replaced := false
	checker := &stubTrustChecker{
		untrusted: map[string]struct{}{"hashA": {}},
		onCheck: func() {
			replaced = true
			serverConn, providerConn := net.Pipe()
			t.Cleanup(func() {
				_ = providerConn.Close()
				_ = serverConn.Close()
			})
			replacement := *provider
			replacement.AssignedID = "s2"
			replacement.State = pool.StateReady
			setAdmittedTupleValues(&replacement, "hashB", "apple m4 max", 64)
			s.pool.Register(&replacement, serverConn)
			session := newProviderSession(replacement.ProviderID, replacement.AssignedID, serverConn, 4)
			s.sessions.Store(sessionKey(replacement.ProviderID, replacement.AssignedID), session)
			go session.runWriter()
		},
	}
	s.providerTrust = checker

	s.runTrustRevalidationSweep()

	if !replaced {
		t.Fatal("test did not replace the session during the trust sweep")
	}
	if _, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID); ok {
		t.Fatal("old assigned session still resolves after replacement")
	}
	resolved, ok := s.pool.Resolve(provider.ProviderID, "s2")
	if !ok {
		t.Fatal("replacement session missing from pool")
	}
	if resolved.AdmittedHardwareIdentityHash != "hashB" {
		t.Fatalf("replacement admitted hash = %q, want hashB", resolved.AdmittedHardwareIdentityHash)
	}
	if resolved.State == pool.StateDraining {
		t.Fatal("replacement session was drained by stale untrusted result for root A")
	}
}

// TestTrustRevalidationSweepSkipsUngatedProviders confirms a provider with no
// live session, and a live session with no captured admitted tuple, are both
// left out of the batched trust read (the former avoids needless DB work; the
// latter is never dropped on a tuple the sweep cannot check).
func TestTrustRevalidationSweepSkipsUngatedProviders(t *testing.T) {
	t.Run("no live session", func(t *testing.T) {
		s, provider, _ := newEncryptedRelayHarness(t)
		setAdmittedTuple(provider)
		s.sessions.Delete(sessionKey(provider.ProviderID, provider.AssignedID))
		checker := &stubTrustChecker{untrusted: map[string]struct{}{"hashA": {}}}
		s.providerTrust = checker

		s.runTrustRevalidationSweep()

		if checker.calls != 0 {
			t.Fatalf("SessionsWithoutActiveTrust calls = %d, want 0 (no live session)", checker.calls)
		}
	})
	t.Run("no admitted tuple", func(t *testing.T) {
		s, _, _ := newEncryptedRelayHarness(t)
		// Leave AdmittedHardwareIdentityHash empty.
		checker := &stubTrustChecker{}
		s.providerTrust = checker

		s.runTrustRevalidationSweep()

		if checker.calls != 0 {
			t.Fatalf("SessionsWithoutActiveTrust calls = %d, want 0 (no admitted tuple to check)", checker.calls)
		}
	})
}

// TestFixANoCommitThenRefuse is the FIX A race test (issue #582): a provider
// whose trust is revoked AFTER the hello gate passes but BEFORE registration is
// STILL admitted (session delivered, no refusal, and registration never consults
// the trust checker) — the minted token is never stranded. The bounded sweep then
// evicts the committed session. This proves the deadlock-causing commit-then-refuse
// re-check is gone and the residual TOCTOU is covered by eviction, not refusal.
func TestFixANoCommitThenRefuse(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()

	s := NewServer(config.Default(), pool.NewRegistry(nil), zerolog.Nop())
	// A checker that reports the admitted tuple untrusted (trust revoked between
	// gate and register). Registration must ignore it; the sweep must act on it.
	checker := &stubTrustChecker{untrusted: map[string]struct{}{"hashA": {}}}
	s.providerTrust = checker

	entry := &pool.Provider{
		ProviderID:                   "p1",
		AssignedID:                   "s1",
		ModelID:                      "model-a",
		Tier:                         pool.TierProvisional,
		InferencePath:                pool.InferencePathWSTunneled,
		State:                        pool.StateReady,
		SlotsFree:                    1,
		SlotsTotal:                   1,
		MaxConcurrency:               1,
		AdmittedHardwareIdentityHash: "hashA",
		AdmittedChipNormalized:       "apple m4 max",
		AdmittedUnifiedMemoryGB:      64,
	}

	session, refusal := s.registerProviderSession(serverConn, entry)
	if session == nil {
		t.Fatalf("registration refused (refusal=%q); FIX A requires admit despite revoked trust (no commit-then-refuse)", refusal)
	}
	if checker.calls != 0 {
		t.Fatalf("registration consulted the trust checker %d times; want 0 (no post-commit re-check)", checker.calls)
	}

	// The bounded sweep is the backstop: it evicts the committed session.
	s.runTrustRevalidationSweep()
	if checker.calls != 1 {
		t.Fatalf("sweep issued %d batched reads, want 1", checker.calls)
	}
	resolved, ok := s.pool.Resolve("p1", "s1")
	if !ok {
		t.Fatal("provider missing from pool after sweep")
	}
	if resolved.State != pool.StateDraining {
		t.Fatalf("committed session state = %q after sweep, want draining (evicted, not refused)", resolved.State)
	}
}

// TestTrustSweepFailOpenBounded covers FIX C (issue #582): a single transient
// sweep DB error fails open (no degrade, no quarantine), but sustained failure
// escalates to the degraded trust-authority signal and quarantines the gated
// session after trustSweepDegradedThreshold consecutive failures. A subsequent
// successful sweep clears the degraded signal.
func TestTrustSweepFailOpenBounded(t *testing.T) {
	s, provider, _ := newEncryptedRelayHarness(t)
	setAdmittedTuple(provider)
	checker := &stubTrustChecker{err: errors.New("trust store unreachable")}
	s.providerTrust = checker

	// Single failure → fail open.
	s.runTrustRevalidationSweep()
	if s.trustAuthorityDegraded.Load() {
		t.Fatal("trust authority degraded after a single failure; want fail-open")
	}
	if resolved, _ := s.pool.Resolve(provider.ProviderID, provider.AssignedID); resolved.State == pool.StateDraining {
		t.Fatal("gated session quarantined after a single failure; want fail-open")
	}

	// Sustained failure → escalate exactly at the threshold.
	for i := 1; i < trustSweepDegradedThreshold; i++ {
		s.runTrustRevalidationSweep()
	}
	if !s.trustAuthorityDegraded.Load() {
		t.Fatalf("trust authority not degraded after %d consecutive failures", trustSweepDegradedThreshold)
	}
	resolved, ok := s.pool.Resolve(provider.ProviderID, provider.AssignedID)
	if !ok {
		t.Fatal("provider missing from pool after escalation")
	}
	if resolved.State != pool.StateDraining {
		t.Fatalf("gated session state = %q after escalation, want draining (quarantined)", resolved.State)
	}

	// Recovery: a successful sweep clears the degraded signal.
	checker.err = nil
	s.runTrustRevalidationSweep()
	if s.trustAuthorityDegraded.Load() {
		t.Fatal("trust authority still degraded after a successful sweep; want cleared")
	}
	if s.trustSweepFailures != 0 {
		t.Fatalf("consecutive failure counter = %d after recovery, want 0", s.trustSweepFailures)
	}
}
