package billing

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math/big"
)

// rateTableJSON is the exact rate_card_json a ledger_config_snapshots row
// stores for cfg. InsertConfigSnapshot, ReloadBillingConfigV05 and
// RateTableDigest all go through it, so the digest an operator lane compares
// is the digest of the stored bytes (SPEC-005-R013).
func rateTableJSON(cfg RewardsConfig) ([]byte, error) {
	return json.Marshal(cfg.RateCard)
}

// RateTableDigest is the lowercase hex sha256 of the rate_card_json bytes a
// billing config snapshot stores for cfg.
func RateTableDigest(cfg RewardsConfig) (string, error) {
	raw, err := rateTableJSON(cfg)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:]), nil
}

// RateKeyFor resolves model exactly as RateFor does (exact key, then the
// normalized key, then "default") and also returns the row key it matched,
// "" when nothing matched. It does not log. A test pins it to RateFor.
func RateKeyFor(rateCard map[string]RateCardEntry, model string) (string, RateCardEntry) {
	if rateCard == nil {
		return "", RateCardEntry{}
	}
	if entry, ok := rateCard[model]; ok {
		return model, entry
	}
	if normalized := NormalizeModelKey(model); normalized != model {
		if entry, ok := rateCard[normalized]; ok {
			return normalized, entry
		}
	}
	if entry, ok := rateCard["default"]; ok {
		return "default", entry
	}
	return "", RateCardEntry{}
}

// ErrWholesaleGrossOverflow fails a wholesale statement closed when a gross
// credit or token total does not fit in int64.
var ErrWholesaleGrossOverflow = errors.New("wholesale statement total exceeds int64")

// ErrWholesaleGrossNegative fails a wholesale statement closed on a negative
// token total, rate or multiplier; the list-price formula is only defined for
// non-negative inputs.
var ErrWholesaleGrossNegative = errors.New("wholesale gross input is negative")

// WholesaleGross is the list-price gross of an aggregate: the exact
// ComputeCredits numerator (prompt×prompt_rate + completion×completion_rate)
// ×multiplier, rounded half-even by 1e6×1e6 like RoundHalfEven, computed in
// arbitrary precision. Unlike ComputeCredits it applies no per-request
// maxBillableTokens cap and never zeroes on int64 overflow — both are
// request-scoped guards; an aggregate above them is still owed. A result
// that does not fit in int64 is an error.
func WholesaleGross(prompt, completion *big.Int, rate RateCardEntry, multiplierPPM int64) (int64, error) {
	if prompt == nil {
		prompt = new(big.Int)
	}
	if completion == nil {
		completion = new(big.Int)
	}
	if prompt.Sign() < 0 || completion.Sign() < 0 || rate.PromptCreditsPerMtok < 0 || rate.CompletionCreditsPerMtok < 0 || multiplierPPM < 0 {
		return 0, ErrWholesaleGrossNegative
	}
	numerator := new(big.Int).Mul(prompt, big.NewInt(rate.PromptCreditsPerMtok))
	numerator.Add(numerator, new(big.Int).Mul(completion, big.NewInt(rate.CompletionCreditsPerMtok)))
	numerator.Mul(numerator, big.NewInt(multiplierPPM))
	denominator := new(big.Int).Mul(big.NewInt(globalMultiplierDenom), big.NewInt(tokensPerMillion))
	quotient, remainder := new(big.Int).QuoRem(numerator, denominator, new(big.Int))
	switch new(big.Int).Lsh(remainder, 1).Cmp(denominator) {
	case 1:
		quotient.Add(quotient, big.NewInt(1))
	case 0:
		if quotient.Bit(0) == 1 {
			quotient.Add(quotient, big.NewInt(1))
		}
	}
	if !quotient.IsInt64() {
		return 0, ErrWholesaleGrossOverflow
	}
	return quotient.Int64(), nil
}
