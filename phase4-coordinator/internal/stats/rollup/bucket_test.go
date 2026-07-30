package rollup

import (
	"math/big"
	"testing"
)

// TestBucketBoundaries exercises every §6.2 v0.1.7 boundary
// across all four windows. Tests use big.Rat to mirror the
// NUMERIC(18,2) storage type the rollup compares against; a
// float-only test would miss the §F.2 invariant that bucket
// comparison uses the stored numeric value, NOT a string
// serialization.
func TestBucketBoundaries(t *testing.T) {
	type cell struct {
		dollars float64
		want    string
	}

	cases := map[string][]cell{
		"24h": {
			{0, "-"},
			{0.00, "-"},
			{0.005, "-"},
			{0.01, "$"},
			{4.99, "$"},
			{5.00, "$$"},
			{49.99, "$$"},
			{50.00, "$$$"},
			{1000000, "$$$"},
		},
		"7d": {
			{0, "-"},
			{0.01, "$"},
			{24.99, "$"},
			{25.00, "$$"},
			{249.99, "$$"},
			{250.00, "$$$"},
		},
		"30d": {
			{0, "-"},
			{0.01, "$"},
			{99.99, "$"},
			{100.00, "$$"},
			{999.99, "$$"},
			{1000.00, "$$$"},
		},
		"all": {
			{0, "-"},
			{0.01, "$"},
			{249.99, "$"},
			{250.00, "$$"},
			{4999.99, "$$"},
			{5000.00, "$$$"},
		},
	}

	for window, cells := range cases {
		for _, c := range cells {
			r := dollarsToRat(c.dollars)
			got, err := Bucket(window, r)
			if err != nil {
				t.Errorf("Bucket(%s, %v) err=%v", window, c.dollars, err)
				continue
			}
			if got != c.want {
				t.Errorf("Bucket(%s, %v) = %q, want %q", window, c.dollars, got, c.want)
			}
		}
	}
}

// TestBucketUnknownWindow — defensive: a malformed window
// string returns an error rather than silently falling back to
// a default bucket.
func TestBucketUnknownWindow(t *testing.T) {
	_, err := Bucket("99h", big.NewRat(5, 1))
	if err == nil {
		t.Fatal("Bucket with unknown window should error")
	}
}

// TestBucketNilTotal — nil input returns an error.
func TestBucketNilTotal(t *testing.T) {
	_, err := Bucket("24h", nil)
	if err == nil {
		t.Fatal("Bucket(nil) should error")
	}
}

// TestUsdFromCredits — verifies the formula
// `usd = credits * factor / 1e6`. Boundary cases at 0 and at
// the operator-default factor 1.0.
func TestUsdFromCredits(t *testing.T) {
	cases := []struct {
		credits int64
		factor  float64
		want    string // FloatString(2) of the result
	}{
		{0, 1.0, "0.00"},
		{1_000_000, 1.0, "1.00"},
		{500_000, 1.0, "0.50"},
		{52_000_000, 1.0, "52.00"},
		{1_000_000, 2.5, "2.50"},
		{1_000_000, 0.0, "0.00"},
	}
	for _, c := range cases {
		got := usdFromCredits(c.credits, c.factor)
		s := got.FloatString(2)
		if s != c.want {
			t.Errorf("usdFromCredits(%d, %v).FloatString(2) = %q, want %q", c.credits, c.factor, s, c.want)
		}
	}
}

// dollarsToRat converts a float to *big.Rat via cents (avoids
// float imprecision at NUMERIC(18,2) granularity).
func dollarsToRat(dollars float64) *big.Rat {
	cents := int64(dollars * 100)
	return big.NewRat(cents, 100)
}

// TestRoundToCentsBucketBoundaries — round-6 CODE r6 HIGH 1 fix:
// SPEC §6.2 says the bucket label MUST agree with the
// NUMERIC(18,2) value stored in the leaderboard table.
// `roundToCents` applies the same FloatString(2) rounding the
// SQL boundary applies, BEFORE bucketing. These cases would
// have failed in the pre-fix path (unrounded *big.Rat bucketed
// while storage rounded the same value into a different
// bucket).
func TestRoundToCentsBucketBoundaries(t *testing.T) {
	type cell struct {
		num, den int64
		window   string
		wantS    string
		wantB    string
	}
	cases := []cell{
		// $0.005 — half-cent → 0.01 → "$" (not "-")
		{5, 1000, "24h", "0.01", "$"},
		// $4.995 — half-cent → 5.00 → "$$" (not "$")
		{4995, 1000, "24h", "5.00", "$$"},
		// $49.995 — half-cent → 50.00 → "$$$" (not "$$")
		{49995, 1000, "24h", "50.00", "$$$"},
		// $0.004 — strictly below half-cent → 0.00 → "-"
		{4, 1000, "24h", "0.00", "-"},
		// $99.994 → 99.99 → "$" (30d threshold $100)
		{99994, 1000, "30d", "99.99", "$"},
		// $99.995 → 100.00 → "$$" (30d threshold $100)
		{99995, 1000, "30d", "100.00", "$$"},
	}
	for _, c := range cases {
		raw := big.NewRat(c.num, c.den)
		rounded := roundToCents(raw)
		gotS := rounded.FloatString(2)
		if gotS != c.wantS {
			t.Errorf("roundToCents(%d/%d).FloatString(2) = %q, want %q", c.num, c.den, gotS, c.wantS)
			continue
		}
		gotB, err := Bucket(c.window, rounded)
		if err != nil {
			t.Errorf("Bucket(%s, %s) err=%v", c.window, gotS, err)
			continue
		}
		if gotB != c.wantB {
			t.Errorf("Bucket(%s, roundToCents(%d/%d)=%s) = %q, want %q", c.window, c.num, c.den, gotS, gotB, c.wantB)
		}
	}
}

// TestRoundToCentsNil — nil input returns a safe zero *big.Rat.
func TestRoundToCentsNil(t *testing.T) {
	got := roundToCents(nil)
	if got == nil {
		t.Fatal("roundToCents(nil) returned nil; want zero *big.Rat")
	}
	if got.Sign() != 0 {
		t.Errorf("roundToCents(nil).Sign() = %d, want 0", got.Sign())
	}
}
