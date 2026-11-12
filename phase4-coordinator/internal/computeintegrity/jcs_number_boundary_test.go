package computeintegrity

import "testing"

// Issue #2312: same int64 boundary as internal/jcs.
func TestCanonicalJSONNumberInt64Boundary(t *testing.T) {
	cases := []struct{ in, want string }{
		{"9223372036854775807", "9223372036854775807"},
		{"9223372036854775808", "9223372036854776000"},
		{"9.223372036854775808e18", "9223372036854776000"},
		{"9223372036854777856", "9223372036854778000"},
		{"-9223372036854775808", "-9223372036854775808"},
		{"-9223372036854775809", "-9223372036854775808"},
		{"9007199254740993", "9007199254740993"},
		{"1.5", "1.5"},
	}
	for _, tc := range cases {
		got, err := canonicalJSONNumber(tc.in)
		if err != nil {
			t.Fatalf("canonicalJSONNumber(%s): %v", tc.in, err)
		}
		if got != tc.want {
			t.Errorf("canonicalJSONNumber(%s) = %s, want %s", tc.in, got, tc.want)
		}
	}
}
