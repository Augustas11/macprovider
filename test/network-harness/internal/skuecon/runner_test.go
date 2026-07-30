package skuecon

import (
	"context"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-network-harness/internal/scenario"
)

func TestAggregateViabilityCountsEligibleWithRateCardEntry(t *testing.T) {
	got := AggregateViability([]simulateCandidate{
		{Model: "ineligible", Eligible: false, CompletionRateUSDPerMillionTokens: 1.0, RawScore: 100},
		{Model: "eligible-a", Eligible: true, CompletionRateUSDPerMillionTokens: 0.235, RawScore: 50},
		{Model: "eligible-b", Eligible: true, CompletionRateUSDPerMillionTokens: 0.160, RawScore: 80},
	}, "at_least_one_eligible_row")

	if got.EligibleRowCount != 2 {
		t.Fatalf("eligible count=%d, want 2", got.EligibleRowCount)
	}
	if got.BestRow == nil || got.BestRow.Model != "eligible-b" {
		t.Fatalf("best row=%+v, want highest raw_score eligible row", got.BestRow)
	}
	if got.BestByScore == nil || got.BestByScore.Model != "ineligible" {
		t.Fatalf("best_by_score=%+v, want highest-scoring ineligible row", got.BestByScore)
	}
	if got.DeltaVsExpected != "meets_expected" {
		t.Fatalf("delta=%q, want meets_expected", got.DeltaVsExpected)
	}
}

func TestAggregateViabilityOmitsBestByScoreWhenSameAsBestRow(t *testing.T) {
	got := AggregateViability([]simulateCandidate{
		{Model: "eligible-a", Eligible: true, CompletionRateUSDPerMillionTokens: 0.235, RawScore: 80},
		{Model: "eligible-b", Eligible: true, CompletionRateUSDPerMillionTokens: 0.160, RawScore: 50},
	}, "at_least_one_eligible_row")

	if got.BestRow == nil || got.BestRow.Model != "eligible-a" {
		t.Fatalf("best row=%+v, want highest raw_score eligible", got.BestRow)
	}
	if got.BestByScore != nil {
		t.Fatalf("best_by_score=%+v, want nil when top scorer is eligible", got.BestByScore)
	}
}

func TestAggregateViabilityBestRowNilWhenNoneEligible(t *testing.T) {
	got := AggregateViability([]simulateCandidate{
		{Model: "blocked-a", Eligible: false, CompletionRateUSDPerMillionTokens: 0.10, RawScore: 10},
		{Model: "blocked-b", Eligible: false, CompletionRateUSDPerMillionTokens: 0.05, RawScore: 5},
	}, "at_least_one_eligible_row")

	if got.BestRow != nil {
		t.Fatalf("best_row=%+v, want nil when no eligible candidate exists", got.BestRow)
	}
	if got.BestByScore == nil || got.BestByScore.Model != "blocked-a" {
		t.Fatalf("best_by_score=%+v, want highest-scoring ineligible surfaced", got.BestByScore)
	}
	if got.DeltaVsExpected != "record_would_fail_phase_c" {
		t.Fatalf("delta=%q, want record_would_fail_phase_c", got.DeltaVsExpected)
	}
}

func TestClassifyI5PassesEligibleAndDonor(t *testing.T) {
	tests := []struct {
		name             string
		expected         string
		eligible         int
		recommendedModel string
		want             string
	}{
		{name: "eligible expected passes", expected: "at_least_one_eligible_row", eligible: 1, recommendedModel: "qwen3-coder", want: "pass"},
		{name: "eligible expected zero records", expected: "at_least_one_eligible_row", eligible: 0, recommendedModel: "", want: "record"},
		{name: "eligible expected fails without recommendation", expected: "at_least_one_eligible_row", eligible: 2, recommendedModel: "", want: "fail"},
		{name: "donor ram expected passes with zero eligible", expected: "donor_only_by_ram", eligible: 0, recommendedModel: "", want: "pass"},
		{name: "donor ram expected records when misclassified", expected: "donor_only_by_ram", eligible: 1, recommendedModel: "qwen3-coder", want: "record"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ClassifyI5(tt.expected, tt.eligible, tt.recommendedModel); got != tt.want {
				t.Fatalf("ClassifyI5(%q,%d,%q)=%q, want %q", tt.expected, tt.eligible, tt.recommendedModel, got, tt.want)
			}
		})
	}
}

func TestClassifyI5RecordsMisclassifiedRows(t *testing.T) {
	if got := ClassifyI5("donor_only_by_ram", 2, "qwen3-coder-30b-a3b-instruct"); got != "record" {
		t.Fatalf("misclassified donor row=%q, want record", got)
	}
}

func TestSummaryLineFormatsPerTokenRate(t *testing.T) {
	eligible := SummaryLine(scenario.HardwareMatrixRow{
		Label:         "m4-64gb",
		BandwidthTier: "C",
		Expected:      "at_least_one_eligible_row",
	}, []simulateCandidate{
		{Model: "qwen3-coder-30b-a3b-instruct", Eligible: true, CompletionRateUSDPerMillionTokens: 0.235, RawScore: 100},
	}, "pass")
	if !strings.Contains(eligible, "eligible=1/1") {
		t.Fatalf("summary=%q, want eligible count", eligible)
	}
	if !strings.Contains(eligible, "best_completion_rate=$0.235/M") {
		t.Fatalf("summary=%q, want per-token completion rate", eligible)
	}

	donor := SummaryLine(scenario.HardwareMatrixRow{
		Label:         "m1-8gb",
		BandwidthTier: "C",
		Expected:      "donor_only_by_ram",
	}, []simulateCandidate{
		{Model: "blocked", Eligible: false, CompletionRateUSDPerMillionTokens: 0.235, RawScore: 100},
	}, "pass")
	if !strings.Contains(donor, "eligible=0/1") {
		t.Fatalf("summary=%q, want zero eligible", donor)
	}
	if !strings.Contains(donor, "no catalog fit") {
		t.Fatalf("summary=%q, want donor-only wording", donor)
	}
}

func TestSanitizedEnvDropsCredsForCLIChildren(t *testing.T) {
	t.Setenv("BUYER_TOKEN", "should-not-leak")
	t.Setenv("OPERATOR_TOKEN", "should-not-leak")
	t.Setenv("GH_TOKEN", "should-not-leak")
	t.Setenv("PATH", "/usr/bin:/bin")
	t.Setenv("HOME", "/tmp/test-home")

	env := sanitizedEnv("/tmp/isolated-home")

	joined := strings.Join(env, "\n")
	for _, forbidden := range []string{"BUYER_TOKEN", "OPERATOR_TOKEN", "GH_TOKEN", "should-not-leak"} {
		if strings.Contains(joined, forbidden) {
			t.Fatalf("sanitizedEnv leaked %q: %v", forbidden, env)
		}
	}
	var sawPath, sawHome bool
	for _, kv := range env {
		if kv == "PATH=/usr/bin:/bin" {
			sawPath = true
		}
		if kv == "HOME=/tmp/isolated-home" {
			sawHome = true
		}
	}
	if !sawPath {
		t.Fatalf("sanitizedEnv missing PATH: %v", env)
	}
	if !sawHome {
		t.Fatalf("sanitizedEnv missing HOME: %v", env)
	}
	if len(env) != 2 {
		t.Fatalf("sanitizedEnv should contain exactly PATH and HOME, got %d entries: %v", len(env), env)
	}
}

func TestSanitizedEnvOmitsUnsetKeys(t *testing.T) {
	os.Unsetenv("PATH")
	os.Unsetenv("HOME")
	t.Setenv("BUYER_TOKEN", "should-not-leak")

	env := sanitizedEnv("")
	if len(env) != 0 {
		t.Fatalf("sanitizedEnv should be empty when PATH and isolated HOME are unset, got %v", env)
	}
}

func TestRateCardClientRefusesRedirects(t *testing.T) {
	client := &http.Client{
		Timeout: 5 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}

	var followedURL string
	attackerServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		followedURL = r.URL.String()
		_, _ = w.Write([]byte("attacker payload"))
	}))
	defer attackerServer.Close()

	redirectServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, attackerServer.URL, http.StatusFound)
	}))
	defer redirectServer.Close()

	req, err := http.NewRequestWithContext(context.Background(), http.MethodGet, redirectServer.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := client.Do(req)
	if err != nil {
		t.Fatalf("Do err: %v", err)
	}
	defer resp.Body.Close()

	if followedURL != "" {
		t.Fatalf("client followed redirect to %q; should have stopped at 302", followedURL)
	}
	if resp.StatusCode != http.StatusFound {
		t.Fatalf("status=%d, want 302", resp.StatusCode)
	}
}

func TestI5FailFailsHardInvariantResult(t *testing.T) {
	row := scenario.HardwareMatrixRow{
		Label:         "m4-32gb",
		BandwidthTier: "C",
		Expected:      "at_least_one_eligible_row",
	}
	check := I5Check(row, 0, "fail")

	if check.Passed {
		t.Fatal("failed I5 must fail the hard-invariant result")
	}
	if check.Status != "fail" {
		t.Fatalf("status=%q, want fail", check.Status)
	}
	if !strings.Contains(check.Detail, "eligible_row_count=0") {
		t.Fatalf("detail=%q, want eligible count evidence", check.Detail)
	}
}
