package rollup

import (
	"fmt"
	"math/big"
)

// Bucket returns the §6.2 v0.1.7 bucket label for a provider's
// total earnings ($work + $rewards) over the given window.
//
// Bracket notation `[a, b)` means a inclusive, b exclusive.
// Comparison uses the underlying NUMERIC(18,2) value (modeled
// here as *big.Rat to avoid float drift).
//
// Window must be one of {"24h", "7d", "30d", "all"}.
//
//	24h: < $0.01 → "-",  [0.01,5)   → "$", [5,50)   → "$$", ≥50   → "$$$"
//	7d:  < $0.01 → "-",  [0.01,25)  → "$", [25,250) → "$$", ≥250  → "$$$"
//	30d: < $0.01 → "-",  [0.01,100) → "$", [100,1000)→ "$$", ≥1000 → "$$$"
//	all: < $0.01 → "-",  [0.01,250) → "$", [250,5000)→ "$$", ≥5000 → "$$$"
//
// Bucket of an unknown window returns an error rather than a
// silent fallback.
func Bucket(window string, totalUSD *big.Rat) (string, error) {
	if totalUSD == nil {
		return "", fmt.Errorf("rollup: Bucket totalUSD must not be nil")
	}
	t, ok := thresholdsForWindow(window)
	if !ok {
		return "", fmt.Errorf("rollup: Bucket unknown window %q", window)
	}
	zeroFloor := big.NewRat(1, 100) // $0.01
	if totalUSD.Cmp(zeroFloor) < 0 {
		return "-", nil
	}
	if totalUSD.Cmp(t.dollar) < 0 {
		return "$", nil
	}
	if totalUSD.Cmp(t.dollarDollar) < 0 {
		return "$$", nil
	}
	return "$$$", nil
}

type bucketThresholds struct {
	// dollar is the EXCLUSIVE upper bound of the "$" bucket.
	dollar *big.Rat
	// dollarDollar is the EXCLUSIVE upper bound of the "$$"
	// bucket; values ≥ this fall into "$$$".
	dollarDollar *big.Rat
}

func thresholdsForWindow(window string) (bucketThresholds, bool) {
	switch window {
	case "24h":
		return bucketThresholds{
			dollar:       big.NewRat(5, 1),
			dollarDollar: big.NewRat(50, 1),
		}, true
	case "7d":
		return bucketThresholds{
			dollar:       big.NewRat(25, 1),
			dollarDollar: big.NewRat(250, 1),
		}, true
	case "30d":
		return bucketThresholds{
			dollar:       big.NewRat(100, 1),
			dollarDollar: big.NewRat(1000, 1),
		}, true
	case "all":
		return bucketThresholds{
			dollar:       big.NewRat(250, 1),
			dollarDollar: big.NewRat(5000, 1),
		}, true
	}
	return bucketThresholds{}, false
}

// usdFromCredits converts SPEC-005 v0.3 INTEGER provider_credits
// to a NUMERIC(18,2)-shaped *big.Rat USD value per the operator
// config knob. SPEC-016 v0.1.19 has not normatively pinned the
// conversion; SPEC-017 v0.1 IMPL exposes UsdPerMillionCredits as
// a single tunable factor: usd = credits * factor / 1_000_000.
//
// The result is rounded to 2 decimals (banker's rounding in
// big.Rat is not supported directly; we use the SetString /
// FloatString discipline at the SQL boundary).
func usdFromCredits(credits int64, factor float64) *big.Rat {
	// credits * factor / 1e6
	creditRat := big.NewRat(credits, 1)
	factorRat := new(big.Rat).SetFloat64(factor)
	if factorRat == nil {
		// NaN/Inf — guard with zero. Validate() above prevents
		// negative; positive infinity is the only NaN risk.
		factorRat = big.NewRat(0, 1)
	}
	per := big.NewRat(1, 1_000_000)
	return new(big.Rat).Mul(new(big.Rat).Mul(creditRat, factorRat), per)
}
