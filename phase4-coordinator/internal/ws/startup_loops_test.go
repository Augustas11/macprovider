package ws

import (
	"testing"
	"time"
)

// awaitStartupSnapshots blocks until the snapshot loops NewServer starts have
// finished their immediate first build. Each first build reads s.now on its
// own goroutine; the next read is one cadence (15 minutes) later. A test that
// reassigns s.now, or mutates the variable its WithNow closure returns, must
// call this first: observing the snapshot under its mutex orders the loop's
// clock read before the test's write (#1996).
func awaitStartupSnapshots(t testing.TB, s *Server) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		intakeBuilt := s.modelAdmissions == nil
		if !intakeBuilt {
			s.modelAdmissionIntakeMu.RLock()
			intakeBuilt = s.modelAdmissionIntake != nil
			s.modelAdmissionIntakeMu.RUnlock()
		}
		poolProvenBuilt := s.poolProven == nil || s.probeEvidence == nil
		if !poolProvenBuilt {
			s.modelAdmissionPPMu.RLock()
			poolProvenBuilt = s.modelAdmissionPPSnap != nil
			s.modelAdmissionPPMu.RUnlock()
		}
		if intakeBuilt && poolProvenBuilt {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("startup snapshot builds did not finish: intake=%v pool_proven=%v", intakeBuilt, poolProvenBuilt)
		}
		time.Sleep(time.Millisecond)
	}
}

// wireRewardsTrust sets the rewards-trust store after NewServer has returned,
// so the server never starts its 30s trust revalidation loop. Test servers are
// never stopped: a loop started through WithProviderRewardsTrustTierStore
// would keep reading the package-level rewardsTrust* timeouts that
// TestRewardsTrustReconciliationSweepDeadlineDemotesUnresolvedTrustedProviders
// overrides, which is a race (#1996). Tests call the sweep directly.
func wireRewardsTrust(s *Server, store ProviderRewardsTrustTierStore) *Server {
	s.rewardsTrust = store
	return s
}
