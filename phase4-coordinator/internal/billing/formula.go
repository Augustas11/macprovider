package billing

import "math"

const (
	UsageProviderReported = "provider_reported"
	UsageByteEstimated    = "byte_estimated"
	UsageNullError        = "null_error"

	FaultNone              = "none"
	FaultBreakerQualifying = "breaker_qualifying"
	FaultNullUsageError    = "null_usage_error"
	globalMultiplierDenom  = int64(1000000)
	tokensPerMillion       = int64(1000000)
	providerShareDenom     = int64(10000)
)

type BilledRow struct {
	GrossCredits          int64
	ProviderCredits       int64
	OperatorCredits       int64
	UsageSource           string
	FaultFlag             string
	PromptTokens          *int64
	CompletionTokens      *int64
	EstimatedCompTokens   *int64
	PromptRatePerMtok     int64
	CompletionRatePerMtok int64
	GlobalMultiplierPPM   int64
	ProviderShareBps      int64
}

func RateFor(rateCard map[string]RateCardEntry, model string) RateCardEntry {
	if rateCard != nil {
		if entry, ok := rateCard[model]; ok {
			return entry
		}
		if entry, ok := rateCard["default"]; ok {
			return entry
		}
	}
	return RateCardEntry{}
}

func ParseMultiplierPPM(v float64) int64 {
	return int64(math.Round(v * float64(globalMultiplierDenom)))
}

func ParseShareBps(v float64) int64 {
	return int64(math.Round(v * float64(providerShareDenom)))
}

func RoundHalfEven(numerator, denominator int64) int64 {
	if denominator <= 0 {
		return 0
	}
	q := numerator / denominator
	r := numerator % denominator
	if r < 0 {
		r = -r
	}
	twice := r * 2
	switch {
	case twice < denominator:
		return q
	case twice > denominator:
		if numerator >= 0 {
			return q + 1
		}
		return q - 1
	default:
		if q%2 == 0 {
			return q
		}
		if numerator >= 0 {
			return q + 1
		}
		return q - 1
	}
}

// ComputeCredits applies SPEC-005 §5.3 and §6 to one provider-reached
// request attempt. The 503 provider-not-reached path writes request_log only;
// callers must not call ComputeCredits for that path.
func ComputeCredits(
	promptTokens, completionTokens *int64,
	estimatedCompletionTokens *int64,
	usageSource string,
	faultFlag string,
	rateEntry RateCardEntry,
	multiplierPPM int64,
	providerShareBps int64,
) BilledRow {
	if usageSource == "" {
		usageSource = UsageProviderReported
	}
	if faultFlag == "" {
		faultFlag = FaultNone
	}
	row := BilledRow{
		UsageSource:           usageSource,
		FaultFlag:             faultFlag,
		PromptTokens:          promptTokens,
		CompletionTokens:      completionTokens,
		EstimatedCompTokens:   estimatedCompletionTokens,
		PromptRatePerMtok:     rateEntry.PromptCreditsPerMtok,
		CompletionRatePerMtok: rateEntry.CompletionCreditsPerMtok,
		GlobalMultiplierPPM:   multiplierPPM,
		ProviderShareBps:      providerShareBps,
	}
	if row.FaultFlag == FaultBreakerQualifying {
		return row
	}
	if row.UsageSource == UsageNullError {
		row.FaultFlag = FaultNullUsageError
		return row
	}
	prompt := int64(0)
	if promptTokens != nil {
		prompt = *promptTokens
	}
	completion := int64(0)
	switch row.UsageSource {
	case UsageByteEstimated:
		if estimatedCompletionTokens != nil {
			completion = *estimatedCompletionTokens
		}
	default:
		row.UsageSource = UsageProviderReported
		if completionTokens != nil {
			completion = *completionTokens
		}
	}
	baseNumerator := prompt*rateEntry.PromptCreditsPerMtok + completion*rateEntry.CompletionCreditsPerMtok
	rateScaled := baseNumerator * multiplierPPM
	row.GrossCredits = RoundHalfEven(rateScaled, globalMultiplierDenom*tokensPerMillion)
	row.ProviderCredits = RoundHalfEven(row.GrossCredits*providerShareBps, providerShareDenom)
	row.OperatorCredits = row.GrossCredits - row.ProviderCredits
	return row
}

func usageFor(errorCode string, estimatedCompletionTokens *int64) string {
	switch errorCode {
	case "error_model_not_loaded", "error_context_exceeded", "error_queue_full", "error_internal":
		return UsageNullError
	}
	if estimatedCompletionTokens != nil {
		return UsageByteEstimated
	}
	return UsageProviderReported
}
