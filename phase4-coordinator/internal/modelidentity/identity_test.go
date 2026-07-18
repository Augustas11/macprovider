package modelidentity

import (
	"testing"
	"time"
)

func TestLegacyMissingAlgorithmAllowedRequiresFutureExplicitDeadline(t *testing.T) {
	now := time.Date(2026, 7, 18, 12, 0, 0, 0, time.UTC)
	for name, tc := range map[string]struct {
		deadline string
		want     bool
	}{
		"unset":   {"", false},
		"expired": {"2026-07-18T11:59:59Z", false},
		"equal":   {"2026-07-18T12:00:00Z", false},
		"future":  {"2026-07-18T12:00:01Z", true},
		"invalid": {"tomorrow", false},
	} {
		t.Run(name, func(t *testing.T) {
			if got := LegacyMissingAlgorithmAllowed(tc.deadline, now); got != tc.want {
				t.Fatalf("LegacyMissingAlgorithmAllowed(%q) = %v, want %v", tc.deadline, got, tc.want)
			}
		})
	}
}
