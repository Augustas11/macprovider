package jcs

import (
	"encoding/json"
	"testing"
)

// Issue #2312: float64(math.MaxInt64) rounds up to 2^63, so an inclusive
// MaxInt64 bound let 2^63 reach int64(f), whose result is
// implementation-defined. Integral values in [-2^63, 2^63) print as exact
// integers; values outside use the RFC 8785 double form.
func TestCanonicalJSONNumberInt64Boundary(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		// In range: unchanged by the fix.
		{"0", "0"},
		{"-0", "0"},
		{"1", "1"},
		{"-42", "-42"},
		{"1.5", "1.5"},
		{"1e3", "1000"},
		{"1.0", "1"},
		{"9223372036854775807", "9223372036854775807"},   // 2^63-1
		{"-9223372036854775808", "-9223372036854775808"}, // -2^63
		{"-9.223372036854775808e18", "-9223372036854775808"},
		// -2^63-1 parses to the double -2^63, which is in range.
		{"-9223372036854775809", "-9223372036854775808"},
		// Profile pin: int64 integers above 2^53 stay exact (SPEC-015 §3.1,
		// SPEC-040 int64 integer fields); a fractional spelling is a double.
		{"9007199254740993", "9007199254740993"},
		{"9007199254740993.0", "9007199254740992"},
		// At or above 2^63: RFC 8785 double form, never int64(f).
		{"9223372036854775808", "9223372036854776000"}, // 2^63
		{"9.223372036854775808e18", "9223372036854776000"},
		{"9223372036854777856", "9223372036854778000"}, // 2^63+1024
		{"18446744073709551616", "18446744073709552000"},
		{"-9223372036854777856", "-9223372036854778000"},
		{"1e21", "1e+21"},
		{"-1e21", "-1e+21"},
	}
	for _, tc := range cases {
		got, err := CanonicalJSON(json.Number(tc.in))
		if err != nil {
			t.Fatalf("CanonicalJSON(%s): %v", tc.in, err)
		}
		if string(got) != tc.want {
			t.Errorf("CanonicalJSON(%s) = %s, want %s", tc.in, got, tc.want)
		}
	}
}
