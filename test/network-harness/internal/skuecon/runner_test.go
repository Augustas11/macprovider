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

func TestAggregateViabilityCountsEligiblePaidRows(t *testing.T) {
	got := AggregateViability([]simulateCandidate{
		{Model: "donor", Eligible: true, ExpectedNetUSDPerHour: 0.0049},
		{Model: "paid", Eligible: true, ExpectedNetUSDPerHour: 0.0050},
		{Model: "ineligible", Eligible: false, ExpectedNetUSDPerHour: 1.0},
	}, "at_least_one_paid_row")

	if got.EligibleRowCount != 1 {
		t.Fatalf("eligible count=%d, want 1", got.EligibleRowCount)
	}
	if got.EligibleEarningRowCount != 2 {
		t.Fatalf("eligible earning count=%d, want 2", got.EligibleEarningRowCount)
	}
	if got.BestRow == nil || got.BestRow.Model != "paid" {
		t.Fatalf("best row=%+v, want highest-earning ELIGIBLE row", got.BestRow)
	}
	if got.BestByEarnings == nil || got.BestByEarnings.Model != "ineligible" {
		t.Fatalf("best_by_earnings=%+v, want highest-net ineligible row to surface for phase-B triage", got.BestByEarnings)
	}
	if got.DeltaVsExpected != "meets_expected" {
		t.Fatalf("delta=%q, want meets_expected", got.DeltaVsExpected)
	}
}

func TestAggregateViabilityCountsStarterRowsForEarningExpectation(t *testing.T) {
	got := AggregateViability([]simulateCandidate{
		{Model: "starter", Eligible: true, ExpectedNetUSDPerHour: 0.0049},
		{Model: "zero", Eligible: true, ExpectedNetUSDPerHour: 0},
	}, "at_least_one_earning_row")

	if got.EligibleRowCount != 0 {
		t.Fatalf("eligible paid count=%d, want 0", got.EligibleRowCount)
	}
	if got.EligibleEarningRowCount != 1 {
		t.Fatalf("eligible earning count=%d, want 1", got.EligibleEarningRowCount)
	}
	if got.DeltaVsExpected != "meets_expected_starter" {
		t.Fatalf("delta=%q, want meets_expected_starter", got.DeltaVsExpected)
	}
}

func TestAggregateViabilityOmitsBestByEarningsWhenSameAsBestRow(t *testing.T) {
	// When the highest-net candidate is also eligible, BestByEarnings is
	// redundant with BestRow and must be omitted (json:omitempty). Keeps
	// the artifact tight for the common case.
	got := AggregateViability([]simulateCandidate{
		{Model: "paid-a", Eligible: true, ExpectedNetUSDPerHour: 0.0100},
		{Model: "paid-b", Eligible: true, ExpectedNetUSDPerHour: 0.0060},
	}, "at_least_one_paid_row")

	if got.BestRow == nil || got.BestRow.Model != "paid-a" {
		t.Fatalf("best row=%+v, want highest-net eligible (paid-a)", got.BestRow)
	}
	if got.BestByEarnings != nil {
		t.Fatalf("best_by_earnings=%+v, want nil when same model as best_row", got.BestByEarnings)
	}
}

func TestAggregateViabilityBestRowNilWhenNoneEligible(t *testing.T) {
	// If every candidate is ineligible (all runtime_status=blocked, or all
	// benchmark-gated), best_row must be nil — never falsely present a
	// non-recommendable row as the "best" one. best_by_earnings still
	// surfaces the highest-net ineligible candidate for phase-B triage.
	got := AggregateViability([]simulateCandidate{
		{Model: "blocked-a", Eligible: false, ExpectedNetUSDPerHour: 0.10},
		{Model: "blocked-b", Eligible: false, ExpectedNetUSDPerHour: 0.05},
	}, "at_least_one_paid_row")

	if got.BestRow != nil {
		t.Fatalf("best_row=%+v, want nil when no eligible candidate exists", got.BestRow)
	}
	if got.BestByEarnings == nil || got.BestByEarnings.Model != "blocked-a" {
		t.Fatalf("best_by_earnings=%+v, want highest-net ineligible surfaced", got.BestByEarnings)
	}
	if got.DeltaVsExpected != "record_would_fail_phase_c" {
		t.Fatalf("delta=%q, want record_would_fail_phase_c", got.DeltaVsExpected)
	}
}

func TestI5OutcomeClassifier(t *testing.T) {
	tests := []struct {
		name               string
		expected           string
		paid               int
		earning            int
		want               string
		recommendedModel   string
		recommendationTier string
	}{
		{name: "paid expected zero fails", expected: "at_least_one_paid_row", paid: 0, earning: 1, want: "fail", recommendedModel: "starter", recommendationTier: "starter"},
		{name: "paid expected one passes with paid recommendation", expected: "at_least_one_paid_row", paid: 1, earning: 1, want: "pass", recommendedModel: "paid", recommendationTier: "paid"},
		{name: "paid expected many fails without paid recommendation", expected: "at_least_one_paid_row", paid: 3, earning: 3, want: "fail", recommendedModel: "starter", recommendationTier: "starter"},
		{name: "earning expected zero fails", expected: "at_least_one_earning_row", paid: 0, earning: 0, want: "fail", recommendedModel: "", recommendationTier: "donor"},
		{name: "earning expected starter passes", expected: "at_least_one_earning_row", paid: 0, earning: 1, want: "pass", recommendedModel: "starter", recommendationTier: "starter"},
		{name: "earning expected paid also passes", expected: "at_least_one_earning_row", paid: 1, earning: 1, want: "pass", recommendedModel: "paid", recommendationTier: "paid"},
		{name: "donor exemption passes", expected: "donor_only_by_design", paid: 0, earning: 0, want: "pass", recommendedModel: "", recommendationTier: "donor"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ClassifyI5(tt.expected, tt.paid, tt.earning, tt.recommendedModel, tt.recommendationTier); got != tt.want {
				t.Fatalf("ClassifyI5(%q,%d,%d,%q,%q)=%q, want %q", tt.expected, tt.paid, tt.earning, tt.recommendedModel, tt.recommendationTier, got, tt.want)
			}
		})
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
	// SEC-H-1 (r3 security audit): a 3xx from the pinned coordinator must
	// NOT cause a follow-up fetch to an attacker-controlled host. Replicate
	// the runner's default client construction verbatim and confirm the
	// redirect surfaces as a 3xx status the caller then rejects.
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
		Expected:      "at_least_one_paid_row",
	}
	check := I5Check(row, 0, 0, "fail")

	if check.Passed {
		t.Fatal("failed I5 must fail the hard-invariant result")
	}
	if check.Status != "fail" {
		t.Fatalf("status=%q, want fail", check.Status)
	}
	if !strings.Contains(check.Detail, "eligible_row_count=0") {
		t.Fatalf("detail=%q, want eligible count evidence", check.Detail)
	}
	if !strings.Contains(check.Detail, "eligible_earning_row_count=0") {
		t.Fatalf("detail=%q, want eligible earning count evidence", check.Detail)
	}
}
