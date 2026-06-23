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
