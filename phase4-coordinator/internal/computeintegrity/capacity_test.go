package computeintegrity

import "testing"

// AC-14: capacity.
func TestAC14_Capacity(t *testing.T) {
	t.Run("daily-canary and reference-forward-pass formulas", func(t *testing.T) {
		dc := DailyCanaries(100, 10, 1) // toy lower bound
		if dc != 1000 {
			t.Fatalf("daily canaries: want 1000, got %d", dc)
		}
		units := DailyReferenceForwardPassUnits(dc, 2, 4, 8, 16)
		if units != 1000*2*4*8*16 {
			t.Fatalf("reference forward-pass units mismatch: %d", units)
		}
	})

	t.Run("reference-refresh throughput must sustain >=2 fresh events per key within TTL", func(t *testing.T) {
		// 100 covered keys, 2 replicas, 24h TTL -> need >= 200/24 ~= 8.34 events/hour.
		if ReferenceRefreshThroughputSufficient(100, 2, 24, 8.0) {
			t.Fatal("8/h is below the required 8.34/h")
		}
		if !ReferenceRefreshThroughputSufficient(100, 2, 24, 9.0) {
			t.Fatal("9/h should be sufficient")
		}
	})

	t.Run("standby (single replica) never satisfies the two-active-reference precondition", func(t *testing.T) {
		if ReferenceRefreshThroughputSufficient(10, 1, 24, 1000.0) {
			t.Fatal("fewer than two active replicas must fail the throughput gate")
		}
	})

	t.Run("configured rates must meet the operator-approved SLOs", func(t *testing.T) {
		target := SLOTargets{TimeToOnboardMinutes: 60, TimeToQuarantineMinutes: 7 * 24 * 60, TimeToClearMinutes: 24 * 60}
		good := SLOTargets{TimeToOnboardMinutes: 45, TimeToQuarantineMinutes: 5 * 24 * 60, TimeToClearMinutes: 24 * 60}
		if !MeetsSLO(good, target) {
			t.Fatal("within-target latencies should meet the SLO")
		}
		bad := good
		bad.TimeToOnboardMinutes = 120
		if MeetsSLO(bad, target) {
			t.Fatal("onboard latency above target must fail the SLO")
		}
	})
}
