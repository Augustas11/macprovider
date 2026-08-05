package billing

import (
	"log/slog"
	"math"
	"strings"
)

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
	maxBillableTokens      = int64(10000000)
)

type BilledRow struct {
	GrossCredits              int64
	ProviderCredits           int64
	OperatorCredits           int64
	UsageSource               string
	FaultFlag                 string
	PromptTokens              *int64
	CachedPromptTokens        *int64
	CompletionTokens          *int64
	EstimatedCompTokens       *int64
	PromptRatePerMtok         int64
	PromptCacheHitRatePerMtok int64
	CompletionRatePerMtok     int64
	GlobalMultiplierPPM       int64
	ProviderShareBps          int64
}

func RateFor(rateCard map[string]RateCardEntry, model string) RateCardEntry {
	if rateCard != nil {
		if entry, ok := rateCard[model]; ok {
			return entry
		}
		normalized := NormalizeModelKey(model)
		if normalized != model {
			if entry, ok := rateCard[normalized]; ok {
				slog.Info("rate_card_normalized", "event", "rate_card_normalized", "requested", model, "normalized", normalized, "matched", normalized)
				return entry
			}
		}
		if entry, ok := rateCard["default"]; ok {
			if normalized != model {
				slog.Info("rate_card_normalized", "event", "rate_card_normalized", "requested", model, "normalized", normalized, "matched", "default")
			}
			return entry
		}
		if normalized != model {
			slog.Info("rate_card_normalized", "event", "rate_card_normalized", "requested", model, "normalized", normalized, "matched", "")
		}
	}
	return RateCardEntry{}
}

func NormalizeModelKey(model string) string {
	key := strings.ToLower(strings.TrimSpace(model))
	namespace := ""
	if slash := strings.IndexByte(key, '/'); slash >= 0 {
		namespace = key[:slash]
		if knownModelNamespace(namespace) {
			key = key[slash+1:]
		}
	}
	for _, suffix := range []string{"-mxfp4-q8", "-4bit", "-8bit"} {
		key = strings.TrimSuffix(key, suffix)
	}
	switch {
	case namespace == "meta-llama" && strings.HasPrefix(key, "llama-"):
		return "meta-llama/" + key
	// Magic-prefix collapses are namespace-scoped: only the empty /
	// mlx-community / canonical-vendor namespaces may rewrite into the
	// catalog key. Other known namespaces (qwen/, google/, …) must not
	// spoof openai/gpt-oss-20b (or meta-llama / nemotron) via body
	// prefix alone — that became load-bearing for routing in #900.
	case servedAliasNamespace(namespace, "meta-llama") && strings.HasPrefix(key, "meta-llama-"):
		return "meta-llama/" + strings.TrimPrefix(key, "meta-")
	case servedAliasNamespace(namespace, "nvidia") && strings.HasPrefix(key, "nvidia-nemotron-"):
		return strings.TrimPrefix(key, "nvidia-")
	case servedAliasNamespace(namespace, "openai") && strings.HasPrefix(key, "gpt-oss-"):
		return "openai/" + key
	default:
		return key
	}
}

// ModelsEquivalent reports whether two buyer/provider model identifiers
// refer to the same rate-card / catalog key after NormalizeModelKey.
// Routing uses this so catalog keys (e.g. openai/gpt-oss-20b) match the
// served HuggingFace ids (e.g. mlx-community/gpt-oss-20b-MXFP4-Q8)
// without registering duplicate provider identities (issue #900).
func ModelsEquivalent(a, b string) bool {
	if a == "" || b == "" {
		return false
	}
	if strings.EqualFold(a, b) {
		return true
	}
	na, nb := NormalizeModelKey(a), NormalizeModelKey(b)
	if na == "" || nb == "" {
		return false
	}
	return na == nb
}

// MatchesNormalizedKey reports whether model aligns with an already-
// computed NormalizeModelKey(query). Used by ModelKnown to avoid
// re-normalizing the buyer-supplied query on every seen-model scan.
func MatchesNormalizedKey(model, normalizedQuery string) bool {
	if model == "" || normalizedQuery == "" {
		return false
	}
	if strings.EqualFold(model, normalizedQuery) {
		return true
	}
	got := NormalizeModelKey(model)
	return got != "" && got == normalizedQuery
}

func knownModelNamespace(namespace string) bool {
	switch namespace {
	case "mlx-community", "openai", "google", "meta-llama", "nvidia", "qwen":
		return true
	default:
		return false
	}
}

// servedAliasNamespace is true when a magic-prefix rewrite may collapse
// into canonicalVendor's catalog key. Empty (no repo prefix) and
// mlx-community (typical served HF id) are the only non-canonical
// sources allowed; foreign known namespaces cannot spoof the alias.
func servedAliasNamespace(namespace, canonicalVendor string) bool {
	switch namespace {
	case "", "mlx-community", canonicalVendor:
		return true
	default:
		return false
	}
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
	return ComputeCreditsWithCache(promptTokens, nil, completionTokens, estimatedCompletionTokens, usageSource, faultFlag, rateEntry, multiplierPPM, providerShareBps)
}

func ComputeCreditsWithCache(
	promptTokens, cachedPromptTokens, completionTokens *int64,
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
		UsageSource:               usageSource,
		FaultFlag:                 faultFlag,
		PromptTokens:              promptTokens,
		CachedPromptTokens:        cachedPromptTokens,
		CompletionTokens:          completionTokens,
		EstimatedCompTokens:       estimatedCompletionTokens,
		PromptRatePerMtok:         rateEntry.PromptCreditsPerMtok,
		PromptCacheHitRatePerMtok: rateEntry.EffectivePromptCacheHitCreditsPerMtok(),
		CompletionRatePerMtok:     rateEntry.CompletionCreditsPerMtok,
		GlobalMultiplierPPM:       multiplierPPM,
		ProviderShareBps:          providerShareBps,
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
	cached := int64(0)
	if cachedPromptTokens != nil {
		cached = *cachedPromptTokens
	}
	completion, completionOK, clampedToEstimate := billableCompletion(row.UsageSource, completionTokens, estimatedCompletionTokens)
	if !completionOK {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	switch {
	case row.UsageSource == UsageByteEstimated:
	case clampedToEstimate:
		row.UsageSource = UsageByteEstimated
	default:
		row.UsageSource = UsageProviderReported
	}
	if invalidBillableTokenCount(prompt) || invalidBillableTokenCount(cached) || cached > prompt || invalidBillableTokenCount(completion) {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	uncached := prompt - cached
	uncachedPromptNumerator, ok := checkedMul(uncached, rateEntry.PromptCreditsPerMtok)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	cachedPromptNumerator, ok := checkedMul(cached, row.PromptCacheHitRatePerMtok)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	promptNumerator, ok := checkedAdd(uncachedPromptNumerator, cachedPromptNumerator)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	completionNumerator, ok := checkedMul(completion, rateEntry.CompletionCreditsPerMtok)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	baseNumerator, ok := checkedAdd(promptNumerator, completionNumerator)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	rateScaled, ok := checkedMul(baseNumerator, multiplierPPM)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	row.GrossCredits = RoundHalfEven(rateScaled, globalMultiplierDenom*tokensPerMillion)
	providerNumerator, ok := checkedMul(row.GrossCredits, providerShareBps)
	if !ok {
		row.FaultFlag = FaultNullUsageError
		row.UsageSource = UsageNullError
		return zeroCredits(row)
	}
	row.ProviderCredits = RoundHalfEven(providerNumerator, providerShareDenom)
	row.OperatorCredits = row.GrossCredits - row.ProviderCredits
	return row
}

func billableCompletion(usageSource string, completionTokens, estimatedCompletionTokens *int64) (int64, bool, bool) {
	if usageSource == UsageByteEstimated {
		if estimatedCompletionTokens == nil {
			return 0, true, false
		}
		estimate := *estimatedCompletionTokens
		if estimate < 0 {
			return 0, false, false
		}
		if completionTokens != nil {
			providerReported := *completionTokens
			if providerReported < 0 {
				return 0, false, false
			}
			if providerReported < estimate {
				return providerReported, true, false
			}
		}
		return estimate, true, false
	}
	if completionTokens == nil {
		if estimatedCompletionTokens == nil {
			return 0, true, false
		}
		return *estimatedCompletionTokens, true, true
	}
	providerReported := *completionTokens
	if providerReported < 0 {
		return 0, false, false
	}
	if estimatedCompletionTokens == nil {
		return providerReported, true, false
	}
	estimate := *estimatedCompletionTokens
	if estimate < 0 {
		return 0, false, false
	}
	if estimate < providerReported {
		return estimate, true, true
	}
	return providerReported, true, false
}

func invalidBillableTokenCount(v int64) bool {
	return v < 0 || v > maxBillableTokens
}

func checkedMul(a, b int64) (int64, bool) {
	if a < 0 || b < 0 {
		return 0, false
	}
	if a == 0 || b == 0 {
		return 0, true
	}
	if a > math.MaxInt64/b {
		return 0, false
	}
	return a * b, true
}

func checkedAdd(a, b int64) (int64, bool) {
	if a < 0 || b < 0 {
		return 0, false
	}
	if a > math.MaxInt64-b {
		return 0, false
	}
	return a + b, true
}

func zeroCredits(row BilledRow) BilledRow {
	row.GrossCredits = 0
	row.ProviderCredits = 0
	row.OperatorCredits = 0
	if row.FaultFlag == FaultNullUsageError {
		row.PromptTokens = nil
		row.CachedPromptTokens = nil
		row.CompletionTokens = nil
		row.EstimatedCompTokens = nil
	}
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
