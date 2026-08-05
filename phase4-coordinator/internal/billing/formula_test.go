package billing

import "testing"

func TestRateFor_ExactMatch_Wins(t *testing.T) {
	rateA := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	rateD := RateCardEntry{PromptCreditsPerMtok: 300, CompletionCreditsPerMtok: 400}
	got := RateFor(map[string]RateCardEntry{"qwen3-32b": rateA, "default": rateD}, "qwen3-32b")
	if got != rateA {
		t.Fatalf("RateFor exact = %+v, want %+v", got, rateA)
	}
}

func TestRateFor_VerbatimWinsOverNormalized(t *testing.T) {
	rateExact := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	rateNorm := RateCardEntry{PromptCreditsPerMtok: 300, CompletionCreditsPerMtok: 400}
	got := RateFor(map[string]RateCardEntry{"mlx-community/Qwen3-32B-4bit": rateExact, "qwen3-32b": rateNorm}, "mlx-community/Qwen3-32B-4bit")
	if got != rateExact {
		t.Fatalf("RateFor verbatim = %+v, want %+v", got, rateExact)
	}
}

func TestRateFor_NormalizesMLXCommunityNamespace(t *testing.T) {
	rateA := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	got := RateFor(map[string]RateCardEntry{"qwen3-32b": rateA}, "mlx-community/Qwen3-32B-4bit")
	if got != rateA {
		t.Fatalf("RateFor normalized = %+v, want %+v", got, rateA)
	}
}

func TestRateFor_NormalizesQuantizationSuffix(t *testing.T) {
	rateL := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	got := RateFor(map[string]RateCardEntry{"meta-llama/llama-3.1-8b-instruct": rateL}, "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit")
	if got != rateL {
		t.Fatalf("RateFor llama normalized = %+v, want %+v", got, rateL)
	}
}

func TestRateFor_NormalizesCanonicalMetaLlamaNamespace(t *testing.T) {
	rateL := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	got := RateFor(map[string]RateCardEntry{"meta-llama/llama-3.1-8b-instruct": rateL}, "meta-llama/Llama-3.1-8B-Instruct-4bit")
	if got != rateL {
		t.Fatalf("RateFor canonical llama normalized = %+v, want %+v", got, rateL)
	}
}

func TestRateFor_NormalizesMXFP4Suffix(t *testing.T) {
	rateOss := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	got := RateFor(map[string]RateCardEntry{"openai/gpt-oss-20b": rateOss}, "mlx-community/gpt-oss-20b-MXFP4-Q8")
	if got != rateOss {
		t.Fatalf("RateFor gpt-oss normalized = %+v, want %+v", got, rateOss)
	}
}

func TestRateFor_NormalizesNemotronAliases(t *testing.T) {
	rateNemotron := RateCardEntry{PromptCreditsPerMtok: 117500, PromptCacheHitCreditsPerMtok: 29375, CompletionCreditsPerMtok: 235000}
	card := map[string]RateCardEntry{
		"nemotron-3-nano-30b-a3b": rateNemotron,
		"default":                 {PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000},
	}
	for _, model := range []string{
		"nemotron-3-nano-30b-a3b",
		"nvidia/nemotron-3-nano-30b-a3b",
		"mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
	} {
		got := RateFor(card, model)
		if got != rateNemotron {
			t.Fatalf("RateFor(%q) = %+v, want %+v", model, got, rateNemotron)
		}
	}
}

func TestRateFor_FallsBackToDefault(t *testing.T) {
	rateD := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	got := RateFor(map[string]RateCardEntry{"default": rateD}, "something-not-in-card")
	if got != rateD {
		t.Fatalf("RateFor default = %+v, want %+v", got, rateD)
	}
}

func TestModelsEquivalent_CatalogKeyMatchesServedHFID(t *testing.T) {
	cases := []struct {
		a, b string
		want bool
	}{
		{"openai/gpt-oss-20b", "mlx-community/gpt-oss-20b-MXFP4-Q8", true},
		{"mlx-community/gpt-oss-20b-MXFP4-Q8", "openai/gpt-oss-20b", true},
		{"OPENAI/GPT-OSS-20B", "mlx-community/gpt-oss-20b-MXFP4-Q8", true},
		{"openai/gpt-oss-20b", "openai/gpt-oss-20b", true},
		{"openai/gpt-oss-20b", "mlx-community/Qwen3-32B-4bit", false},
		{"", "openai/gpt-oss-20b", false},
		{"openai/gpt-oss-20b", "", false},
		{"", "", false},
		{"qwen3-32b", "mlx-community/Qwen3-32B-4bit", true},
		// Foreign known namespaces must not spoof catalog vendors (#900 audit).
		{"qwen/gpt-oss-20b", "openai/gpt-oss-20b", false},
		{"google/gpt-oss-20b", "openai/gpt-oss-20b", false},
		{"qwen/meta-llama-3.1-8b-instruct-4bit", "meta-llama/Llama-3.1-8B-Instruct-4bit", false},
		{"qwen/nvidia-nemotron-3-nano-30b-a3b", "nvidia/nemotron-3-nano-30b-a3b", false},
		{"openai/nvidia-nemotron-3-nano-30b-a3b", "nvidia/nemotron-3-nano-30b-a3b", false},
	}
	for _, tc := range cases {
		if got := ModelsEquivalent(tc.a, tc.b); got != tc.want {
			t.Fatalf("ModelsEquivalent(%q, %q) = %v, want %v", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestRateFor_UnknownNamespaceDoesNotNormalizeToKnownModel(t *testing.T) {
	rateA := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	rateD := RateCardEntry{PromptCreditsPerMtok: 300, CompletionCreditsPerMtok: 400}
	got := RateFor(map[string]RateCardEntry{"qwen3-32b": rateA, "default": rateD}, "other/Qwen3-32B-4bit")
	if got != rateD {
		t.Fatalf("RateFor unknown namespace = %+v, want default %+v", got, rateD)
	}
}

func TestRateFor_NoDefault_ReturnsZero(t *testing.T) {
	rateA := RateCardEntry{PromptCreditsPerMtok: 100, CompletionCreditsPerMtok: 200}
	got := RateFor(map[string]RateCardEntry{"qwen3-32b": rateA}, "something-else")
	if got != (RateCardEntry{}) {
		t.Fatalf("RateFor no default = %+v, want zero", got)
	}
}

func TestRateFor_EmptyCard_ReturnsZero(t *testing.T) {
	got := RateFor(map[string]RateCardEntry{}, "anything")
	if got != (RateCardEntry{}) {
		t.Fatalf("RateFor empty = %+v, want zero", got)
	}
}

func TestRateFor_NilCard_ReturnsZero(t *testing.T) {
	got := RateFor(nil, "anything")
	if got != (RateCardEntry{}) {
		t.Fatalf("RateFor nil = %+v, want zero", got)
	}
}

func TestComputeCredits_WorkedExamples(t *testing.T) {
	rate7B := RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000}
	defaultRate := RateCardEntry{PromptCreditsPerMtok: 500000, CompletionCreditsPerMtok: 1000000}
	p1000, c2000, c500 := int64(1000), int64(2000), int64(500)

	row := ComputeCredits(&p1000, &c2000, nil, UsageProviderReported, FaultNone, rate7B, 1000000, 9000)
	if row.GrossCredits != 5000 || row.ProviderCredits != 4500 || row.OperatorCredits != 500 {
		t.Fatalf("200 credits = %+v", row)
	}

	row = ComputeCredits(&p1000, nil, nil, UsageProviderReported, FaultNone, rate7B, 1000000, 9000)
	if row.GrossCredits != 1000 || row.ProviderCredits != 900 || row.OperatorCredits != 100 {
		t.Fatalf("502 prompt-only credits = %+v", row)
	}

	row = ComputeCredits(nil, nil, nil, UsageNullError, FaultNone, rate7B, 1000000, 9000)
	if row.GrossCredits != 0 || row.ProviderCredits != 0 || row.OperatorCredits != 0 || row.FaultFlag != FaultNullUsageError {
		t.Fatalf("null error credits = %+v", row)
	}

	row = ComputeCredits(&p1000, &c500, nil, UsageProviderReported, FaultNone, defaultRate, 1000000, 9000)
	if row.GrossCredits != 1000 || row.ProviderCredits != 900 || row.OperatorCredits != 100 {
		t.Fatalf("default-rate credits = %+v", row)
	}
}

func TestComputeCreditsWithCachePricesOnlyCachedPromptAtCacheRate(t *testing.T) {
	rate := RateCardEntry{
		PromptCreditsPerMtok:         1000000,
		PromptCacheHitCreditsPerMtok: 250000,
		CompletionCreditsPerMtok:     2000000,
	}
	prompt, cached, completion := int64(1000), int64(400), int64(100)
	row := ComputeCreditsWithCache(&prompt, &cached, &completion, nil, UsageProviderReported, FaultNone, rate, 1000000, 9000)
	if row.GrossCredits != 900 || row.ProviderCredits != 810 || row.OperatorCredits != 90 {
		t.Fatalf("cache-priced row = %+v, want gross/provider/operator 900/810/90", row)
	}
	if row.CachedPromptTokens == nil || *row.CachedPromptTokens != cached || row.PromptCacheHitRatePerMtok != 250000 {
		t.Fatalf("cache fields = %+v, want cached tokens and rate preserved", row)
	}
}

func TestComputeCreditsWithCacheRejectsCachedPromptAbovePrompt(t *testing.T) {
	rate := RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000}
	prompt, cached, completion := int64(100), int64(101), int64(1)
	row := ComputeCreditsWithCache(&prompt, &cached, &completion, nil, UsageProviderReported, FaultNone, rate, 1000000, 9000)
	if row.GrossCredits != 0 || row.ProviderCredits != 0 || row.OperatorCredits != 0 || row.FaultFlag != FaultNullUsageError || row.CachedPromptTokens != nil {
		t.Fatalf("invalid cached row = %+v, want null-error zero row", row)
	}
}

func TestComputeCredits_InvalidTokenCountsZeroAndFlag(t *testing.T) {
	rate := RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000}
	negative := int64(-1)
	row := ComputeCredits(&negative, nil, nil, UsageProviderReported, FaultNone, rate, 1000000, 9000)
	if row.GrossCredits != 0 || row.ProviderCredits != 0 || row.OperatorCredits != 0 || row.FaultFlag != FaultNullUsageError {
		t.Fatalf("negative token row = %+v", row)
	}
	tooLarge := maxBillableTokens + 1
	row = ComputeCredits(nil, &tooLarge, nil, UsageProviderReported, FaultNone, rate, 1000000, 9000)
	if row.GrossCredits != 0 || row.ProviderCredits != 0 || row.OperatorCredits != 0 || row.FaultFlag != FaultNullUsageError {
		t.Fatalf("too-large token row = %+v", row)
	}
}

func TestRoundHalfEven(t *testing.T) {
	cases := []struct {
		n, d int64
		want int64
	}{
		{5, 10, 0},
		{15, 10, 2},
		{4, 10, 0},
		{6, 10, 1},
	}
	for _, tc := range cases {
		if got := RoundHalfEven(tc.n, tc.d); got != tc.want {
			t.Fatalf("RoundHalfEven(%d,%d)=%d want %d", tc.n, tc.d, got, tc.want)
		}
	}
}

func TestParseMultiplierPPM(t *testing.T) {
	for _, tc := range []struct {
		in   float64
		want int64
	}{{1.0, 1000000}, {0.5, 500000}, {2.0, 2000000}} {
		if got := ParseMultiplierPPM(tc.in); got != tc.want {
			t.Fatalf("ParseMultiplierPPM(%v)=%d want %d", tc.in, got, tc.want)
		}
	}
}

func TestParseShareBps(t *testing.T) {
	for _, tc := range []struct {
		in   float64
		want int64
	}{{0.90, 9000}, {1.0, 10000}, {0.0, 0}} {
		if got := ParseShareBps(tc.in); got != tc.want {
			t.Fatalf("ParseShareBps(%v)=%d want %d", tc.in, got, tc.want)
		}
	}
}
