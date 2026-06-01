package billing

import "testing"

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
