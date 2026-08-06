package computeintegrity

import "testing"

// AC-11: sampling-profile coverage.
func TestAC11_SamplingProfileCoverage(t *testing.T) {
	t.Run("settlement denies a covered paid request whose profile is not covered", func(t *testing.T) {
		c := payableCapture()
		c.RequestSamplingProfileCovered = false
		if d := Evaluate(c); d.Payable || d.Reason != ReasonUncoveredProfile {
			t.Fatalf("uncovered profile must deny with uncovered_profile, got %+v", d)
		}
	})

	t.Run("all-profile grid: a fresh sibling does not authorize an unprobed profile", func(t *testing.T) {
		covered := []string{"temp-0.2", "temp-0.7", "temp-1.0"}
		satisfied := map[string]bool{"temp-0.2": true, "temp-0.7": true, "temp-1.0": false}
		if AllProfileGridSatisfied(covered, satisfied) {
			t.Fatal("grid must fail when any covered profile is unsatisfied")
		}
		// A buyer request on the stale sibling is not covered even though others pass.
		if RequestProfileCovered(CoverageAllProfile, "temp-1.0", covered, satisfied) {
			t.Fatal("stale sibling profile must not be covered")
		}
		// A buyer request on a satisfied profile is still not covered until the WHOLE
		// grid is satisfied (closed grid, not per-profile authorization).
		if RequestProfileCovered(CoverageAllProfile, "temp-0.2", covered, satisfied) {
			t.Fatal("all-profile grid must be fully satisfied before any member is payable")
		}
	})

	t.Run("all-profile grid fully satisfied authorizes a member", func(t *testing.T) {
		covered := []string{"temp-0.2", "temp-0.7"}
		satisfied := map[string]bool{"temp-0.2": true, "temp-0.7": true}
		if !RequestProfileCovered(CoverageAllProfile, "temp-0.7", covered, satisfied) {
			t.Fatal("a member of a fully-satisfied grid must be covered")
		}
	})

	t.Run("per-profile coverage requires an exact profile match", func(t *testing.T) {
		if RequestProfileCovered(CoveragePerProfile, "temp-1.0", []string{"temp-0.7"}, map[string]bool{"temp-0.7": true}) {
			t.Fatal("per-profile coverage must not authorize a different profile")
		}
	})

	t.Run("covered-profile-set digest is deterministic and order-independent", func(t *testing.T) {
		a, err := CoveredProfileSetDigest([]string{"temp-0.7", "temp-0.2"})
		if err != nil {
			t.Fatal(err)
		}
		b, _ := CoveredProfileSetDigest([]string{"temp-0.2", "temp-0.7"})
		if a != b {
			t.Fatal("covered-profile-set digest must be order-independent")
		}
	})
}
