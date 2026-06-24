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

// TestReleaseConstants pins the verifier release values. Bump this
// AND the constants in version.go together when cutting a new release;
// the pin guards against accidental version drift during a release PR.
//
// Current pin: v1.1.0 / SPEC-015 v0.3.3 (Entry 85 ship). v1.0.0 was
// the previous floor (Step 10 final acceptance, SPEC v0.2.4).
func TestReleaseConstants(t *testing.T) {
	if BinaryVersion != "1.1.0" {
		t.Fatalf("BinaryVersion = %q, want %q (v0.3 IMPL ship pin)", BinaryVersion, "1.1.0")
	}
	if MaxSPECVersion != "0.3.3" {
		t.Fatalf("MaxSPECVersion = %q, want %q (matches LOCKED SPEC-015 v0.3.3)", MaxSPECVersion, "0.3.3")
	}
}
