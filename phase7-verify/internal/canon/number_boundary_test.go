package canon

import (
	"encoding/json"
	"testing"

	"github.com/augstar/macprovider/phase7-verify/internal/jcs"
)

// Issue #2312: float64(math.MaxInt64) rounds up to 2^63, so the integral
// check must be half-open or int64(2^63) overflows.
func TestJCSValueInt64Boundary(t *testing.T) {
	cases := []struct {
		in   any
		want string
	}{
		{json.Number("9223372036854775807"), "9223372036854775807"},
		{json.Number("9223372036854775808"), "9223372036854776000"},
		{json.Number("9.223372036854775808e18"), "9223372036854776000"},
		{json.Number("9223372036854777856"), "9223372036854778000"},
		{json.Number("-9223372036854775808"), "-9223372036854775808"},
		{json.Number("-9.223372036854775808e18"), "-9223372036854775808"},
		{json.Number("-9223372036854775809"), "-9223372036854775808"},
		{json.Number("1.5"), "1.5"},
		{float64(1 << 63), "9223372036854776000"},
		{float64(-1 << 63), "-9223372036854775808"},
		{float64(42), "42"},
	}
	for _, tc := range cases {
		got, err := jcs.Canonicalize(jcsValue(tc.in))
		if err != nil {
			t.Fatalf("Canonicalize(%v): %v", tc.in, err)
		}
		if string(got) != tc.want {
			t.Errorf("Canonicalize(%v) = %s, want %s", tc.in, got, tc.want)
		}
	}
}
