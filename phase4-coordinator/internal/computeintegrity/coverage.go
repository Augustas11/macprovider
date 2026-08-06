package computeintegrity

import "sort"

// FR-10 all-profile window coverage. An all-profile (__all_profiles__) window is a
// closed profile grid, not a blended aggregate: EVERY covered sampling profile must
// independently satisfy its own fresh sub-window before the aggregate is payable, and
// a fresh pass sequence on one profile MUST NOT authorize buyer traffic on an unprobed
// or stale sibling profile.

// CoveredProfileSetDigest returns the SHA-256 over the JCS-canonical, sorted covered-
// profile list (FR-4, FR-10). It is bound into an all-profile window and the
// request-start capture so settlement can verify the buyer profile is a member.
func CoveredProfileSetDigest(profiles []string) (string, error) {
	sorted := append([]string(nil), profiles...)
	sort.Strings(sorted)
	return jcsDigest(map[string]any{
		"type":     "compute_integrity_covered_profile_set_v1",
		"profiles": toAnySlice(sorted),
	})
}

// AllProfileGridSatisfied reports whether an all-profile window is payable: every
// covered profile must independently satisfy its sub-window (FR-10). satisfied maps
// each covered profile to whether its own sub-window is fresh+verified/warn. A missing
// or false entry for any covered profile fails the grid.
func AllProfileGridSatisfied(coveredProfiles []string, satisfied map[string]bool) bool {
	if len(coveredProfiles) == 0 {
		return false
	}
	for _, p := range coveredProfiles {
		if !satisfied[p] {
			return false
		}
	}
	return true
}

// RequestProfileCovered reports whether a buyer request's sampling profile is a member
// of the covered set with its own satisfied sub-window (FR-10, FR-11). For a
// per-profile window the profile must equal the covered profile; for an all-profile
// window it must be a member whose sub-window is satisfied.
func RequestProfileCovered(mode SamplingProfileCoverageMode, requestProfile string,
	coveredProfiles []string, satisfied map[string]bool) bool {
	switch mode {
	case CoveragePerProfile:
		return len(coveredProfiles) == 1 && coveredProfiles[0] == requestProfile && satisfied[requestProfile]
	case CoverageAllProfile:
		member := false
		for _, p := range coveredProfiles {
			if p == requestProfile {
				member = true
				break
			}
		}
		return member && AllProfileGridSatisfied(coveredProfiles, satisfied) && satisfied[requestProfile]
	}
	return false
}
