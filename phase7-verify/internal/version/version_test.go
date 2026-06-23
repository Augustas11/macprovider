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

// TestStep10FinalConstants pins the exact Step 10 final-acceptance values per
// the IMPL prompt. BinaryVersion is the verifier release version; MaxSPECVersion
// stays pinned to the locked SPEC-015 v0.2.4 compatibility ceiling.
func TestStep10FinalConstants(t *testing.T) {
	if BinaryVersion != "1.0.0" {
		t.Fatalf("BinaryVersion = %q, want %q (Step 10 final acceptance pin per BUILD prompt)", BinaryVersion, "1.0.0")
	}
	if MaxSPECVersion != "0.2.4" {
		t.Fatalf("MaxSPECVersion = %q, want %q (matches LOCKED SPEC-015 v0.2.4)", MaxSPECVersion, "0.2.4")
	}
}
