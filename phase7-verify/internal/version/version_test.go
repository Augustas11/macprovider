package version

import (
	"regexp"
	"testing"
)

func TestConstants(t *testing.T) {
	tests := []struct {
		name    string
		value   string
		pattern string
	}{
		{
			name:    "binary version",
			value:   BinaryVersion,
			pattern: `^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$`,
		},
		{
			name:    "max spec version",
			value:   MaxSPECVersion,
			pattern: `^\d+\.\d+\.\d+$`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.value == "" {
				t.Fatal("version constant is empty")
			}
			if !regexp.MustCompile(tt.pattern).MatchString(tt.value) {
				t.Fatalf("version constant %q does not match %s", tt.value, tt.pattern)
			}
		})
	}
}

// TestStep1ExactConstants pins the exact Step 1 scaffold-stage values per the
// IMPL prompt. These constants change at Step 10 (final acceptance: BinaryVersion
// becomes 1.0.0; MaxSPECVersion bumps if SPEC-015 evolves). Any other change
// MUST be intentional and flagged in a SPEC-015 v0.2.x audit.
func TestStep1ExactConstants(t *testing.T) {
	if BinaryVersion != "0.1.0-step1-scaffold" {
		t.Fatalf("BinaryVersion = %q, want %q (Step 1 scaffold pin per BUILD prompt)", BinaryVersion, "0.1.0-step1-scaffold")
	}
	if MaxSPECVersion != "0.2.4" {
		t.Fatalf("MaxSPECVersion = %q, want %q (matches LOCKED SPEC-015 v0.2.4)", MaxSPECVersion, "0.2.4")
	}
}
