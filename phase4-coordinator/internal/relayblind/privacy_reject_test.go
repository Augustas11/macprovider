package relayblind

import (
	"regexp"
	"testing"
)

// SPEC-049-R030: every reason is a short closed token, and anything else is
// folded to "other" before it can become a log field or metric label.
func TestPrivacyRejectReasonsAreClosed(t *testing.T) {
	token := regexp.MustCompile(`^[a-z_]{1,40}$`)
	reasons := PrivacyRejectReasons()
	if len(reasons) != 31 {
		t.Fatalf("reason set size = %d, want 31", len(reasons))
	}
	for _, reason := range reasons {
		if !token.MatchString(reason) {
			t.Fatalf("reason %q is not a closed token", reason)
		}
		if NormalizePrivacyRejectReason(reason) != reason {
			t.Fatalf("known reason %q was renamed", reason)
		}
	}
	for _, raw := range []string{"", "provider-123", "posture_expired ", "POSTURE_EXPIRED", "x\nreason=forged"} {
		if got := NormalizePrivacyRejectReason(raw); got != PrivacyRejectOther {
			t.Fatalf("NormalizePrivacyRejectReason(%q) = %q, want other", raw, got)
		}
	}
	for _, phase := range []string{PrivacyRejectPhaseReservation, PrivacyRejectPhaseConsume, PrivacyRejectPhaseDispatch} {
		if !PrivacyRejectPhaseKnown(phase) {
			t.Fatalf("phase %q unknown", phase)
		}
	}
	if PrivacyRejectPhaseKnown("chat") {
		t.Fatal("unexpected phase accepted")
	}
}
