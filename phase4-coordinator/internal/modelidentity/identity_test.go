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

func TestValidSHA256RequiresExactWireShape(t *testing.T) {
	valid := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	for name, value := range map[string]string{
		"exact":            valid,
		"leading space":    " " + valid,
		"trailing newline": valid + "\n",
		"uppercase":        "0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
		"short":            valid[:63],
	} {
		t.Run(name, func(t *testing.T) {
			want := name == "exact"
			if got := ValidSHA256(value); got != want {
				t.Fatalf("ValidSHA256(%q) = %v, want %v", value, got, want)
			}
		})
	}
}
