package buyer

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
)

const allowanceTestServiceToken = "allowance-test-service-token-0123456789"

type allowanceTestSource struct{ stakes []billing.AllowanceStake }

func (allowanceTestSource) Name() string { return "test_source" }

func (s allowanceTestSource) EarningStakes(context.Context, time.Time, time.Duration) ([]billing.AllowanceStake, error) {
	return s.stakes, nil
}

func newAllowanceHarness(t *testing.T, stakes ...billing.AllowanceStake) *econHarness {
	t.Helper()
	h, _ := newEconHarness(t, WithGatewayServiceToken(allowanceTestServiceToken), WithRequireGatewayContext(true))
	if _, err := h.db.Exec(`CREATE TABLE IF NOT EXISTS provider_ownership (provider_id TEXT PRIMARY KEY, github_user_id INTEGER NOT NULL)`); err != nil {
		t.Fatal(err)
	}
	policy := billing.AllowancePolicy{DailyBudgetCredits: 10_000_000, CreditsPerMALIBU: 1000, PerAccountDailyCapCredits: 1_000_000, MinStakeAge: time.Hour}
	if _, _, err := h.store.RefreshAllowanceDay(context.Background(), time.Now().UTC(), allowanceTestSource{stakes: stakes}, policy); err != nil {
		t.Fatal(err)
	}
	return h
}

func allowanceChat(h *econHarness, account, requestID string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(`{"model":"model-a","max_tokens":50,"messages":[{"role":"user","content":"hi"}]}`))
	req.RemoteAddr = "127.0.0.1:5555"
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+allowanceTestServiceToken)
	req.Header.Set("X-MacProvider-Account", account)
	req.Header.Set("X-Request-ID", requestID)
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	rec := httptest.NewRecorder()
	h.server.Handler().ServeHTTP(rec, req)
	return rec
}

func allowanceHeaders(outputTokens string, required bool) map[string]string {
	h := map[string]string{
		allowanceModelHeader:        "model-a",
		allowanceInputTokensHeader:  "100",
		allowanceOutputTokensHeader: outputTokens,
	}
	if required {
		h[allowanceRequiredHeader] = "1"
	}
	return h
}

func ledgerRowsFor(t *testing.T, h *econHarness, account, external string) int {
	t.Helper()
	var n int
	if err := h.db.QueryRow(`SELECT COUNT(*) FROM ledger_request_credits WHERE request_id IN (SELECT request_id FROM request_log WHERE account_id = ? AND external_request_id = ?)`, account, external).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

// SPEC-050-R007/R008/R009 on the coordinator chat hop.
func TestCoordinatorAllowanceAdmissionFundsAndSplits(t *testing.T) {
	h := newAllowanceHarness(t, billing.AllowanceStake{AccountID: "acct_allow", Units: 100 * billing.AllowanceUnitsPerMALIBU}) // 100,000 credits
	ctx := context.Background()

	rec := allowanceChat(h, "acct_allow", "ext-1", allowanceHeaders("50", false))
	if rec.Code != http.StatusOK {
		t.Fatalf("status %d body %s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get(allowanceFundingHeader) != billing.AllowanceFundingAllowance || rec.Header().Get(allowanceActiveHeader) != "1" {
		t.Fatalf("funding headers %v", rec.Header())
	}
	status, err := h.store.AllowanceStatusFor(ctx, "acct_allow", time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	var gross, providerCredits int64
	if err := h.db.QueryRow(`SELECT gross_credits, provider_credits FROM ledger_request_credits WHERE request_id IN (SELECT request_id FROM request_log WHERE external_request_id = 'ext-1')`).Scan(&gross, &providerCredits); err != nil {
		t.Fatal(err)
	}
	if gross <= 0 || providerCredits <= 0 || status.SpentCredits != gross || status.HeldCredits != 0 {
		t.Fatalf("status %+v gross %d provider %d: the allowance spends the gross and the provider is still credited", status, gross, providerCredits)
	}
	var splitAllowance int64
	if err := h.db.QueryRow(`SELECT allowance_credits FROM allowance_request_splits WHERE external_request_id = 'ext-1'`).Scan(&splitAllowance); err != nil || splitAllowance != gross {
		t.Fatalf("split %d err %v", splitAllowance, err)
	}

	// A request without the allowance headers is untouched.
	rec = allowanceChat(h, "acct_allow", "ext-plain", nil)
	if rec.Code != http.StatusOK || rec.Header().Get(allowanceFundingHeader) != "" {
		t.Fatalf("plain request status %d headers %v", rec.Code, rec.Header())
	}

	// Paid quota exhausted and the allowance cannot cover the bound: refused
	// before any provider runs, even with overage on.
	rec = allowanceChat(h, "acct_allow", "ext-big", allowanceHeaders("900000000", true))
	if rec.Code != http.StatusTooManyRequests || !strings.Contains(rec.Body.String(), "quota_exhausted") {
		t.Fatalf("required status %d body %s", rec.Code, rec.Body.String())
	}
	if n := ledgerRowsFor(t, h, "acct_allow", "ext-big"); n != 0 {
		t.Fatalf("refused request dispatched %d attempts", n)
	}
	// Overage off: a request the allowance cannot cover is refused.
	if err := h.store.SetAllowanceOverage(ctx, "acct_allow", false, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	rec = allowanceChat(h, "acct_allow", "ext-over", allowanceHeaders("900000000", false))
	if rec.Code != http.StatusTooManyRequests || !strings.Contains(rec.Body.String(), "allowance_exhausted") || rec.Header().Get("X-RateLimit-Reset") == "" ||
		rec.Header().Get(settlementNoPriorDispatchHeader) != "1" {
		t.Fatalf("overage-off status %d headers %v body %s", rec.Code, rec.Header(), rec.Body.String())
	}
	if n := ledgerRowsFor(t, h, "acct_allow", "ext-over"); n != 0 {
		t.Fatalf("refused request dispatched %d attempts", n)
	}
}

// SPEC-050-R010: an allowance request served by the staker's own provider is
// written rewards-excluded; one served by an unrelated provider is not, and
// both providers keep their credit.
func TestAllowanceOwnedProviderExcludedBeforeDispatch(t *testing.T) {
	h := newAllowanceHarness(t,
		billing.AllowanceStake{AccountID: "acct_self", GitHubUserID: 7, Units: 100 * billing.AllowanceUnitsPerMALIBU},
		billing.AllowanceStake{AccountID: "acct_clean", GitHubUserID: 8, Units: 100 * billing.AllowanceUnitsPerMALIBU},
	)
	for _, stmt := range []string{
		`CREATE TABLE IF NOT EXISTS provider_ownership (provider_id TEXT PRIMARY KEY, github_user_id INTEGER NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS provider_payout_addresses (provider_id TEXT NOT NULL, chain TEXT NOT NULL, address TEXT NOT NULL)`,
		`CREATE TABLE IF NOT EXISTS referral_issuers (issuer_id TEXT PRIMARY KEY, code_type TEXT NOT NULL, provider_id TEXT)`,
		`CREATE TABLE IF NOT EXISTS referral_redemptions (campaign TEXT NOT NULL, provider_id TEXT NOT NULL, issuer_id TEXT NOT NULL)`,
		`INSERT INTO provider_ownership VALUES ('p1', 7), ('p_clean', 8)`,
	} {
		if _, err := h.db.Exec(stmt); err != nil {
			t.Fatal(err)
		}
	}
	WithBuyerOwnershipLookup(h.store.BuyerOwnedProviders)(h.server)
	for account, want := range map[string]int{"acct_self": 1, "acct_clean": 0} {
		external := "ext-" + account
		rec := allowanceChat(h, account, external, allowanceHeaders("50", false))
		if account == "acct_self" {
			if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "no_provider_available") || ledgerRowsFor(t, h, account, external) != 0 {
				t.Fatalf("own route was dispatched or billed: %d %s", rec.Code, rec.Body.String())
			}
			continue
		}
		if rec.Code != http.StatusOK || rec.Header().Get(allowanceFundingHeader) != billing.AllowanceFundingAllowance {
			t.Fatalf("%s status %d headers %v", account, rec.Code, rec.Header())
		}
		var excluded int
		var providerCredits int64
		if err := h.db.QueryRow(`SELECT rewards_excluded, provider_credits FROM ledger_request_credits WHERE request_id IN (SELECT request_id FROM request_log WHERE account_id = ? AND external_request_id = ?)`, account, external).Scan(&excluded, &providerCredits); err != nil {
			t.Fatal(err)
		}
		if excluded != want || providerCredits <= 0 {
			t.Fatalf("%s rewards_excluded=%d provider_credits=%d, want excluded=%d and a paid provider", account, excluded, providerCredits, want)
		}
		var splitExcluded int
		if err := h.db.QueryRow(`SELECT rewards_excluded FROM allowance_request_splits WHERE external_request_id = ?`, external).Scan(&splitExcluded); err != nil || splitExcluded != want {
			t.Fatalf("%s split rewards_excluded=%d err=%v", account, splitExcluded, err)
		}
	}
}

// SPEC-050-R014: an allowance-only request (gateway paid quota spent) whose
// admission cannot run is refused before dispatch, never served unfunded.
func TestAllowanceOnlyRequestFailsClosed(t *testing.T) {
	h := newAllowanceHarness(t, billing.AllowanceStake{AccountID: "acct_req", GitHubUserID: 7, Units: 100 * billing.AllowanceUnitsPerMALIBU})
	for name, headers := range map[string]map[string]string{
		"missing model":   {allowanceRequiredHeader: "1", allowanceInputTokensHeader: "10", allowanceOutputTokensHeader: "10"},
		"bad token count": {allowanceRequiredHeader: "1", allowanceModelHeader: "model-a", allowanceInputTokensHeader: "-1", allowanceOutputTokensHeader: "10"},
	} {
		external := "ext-" + strings.ReplaceAll(name, " ", "-")
		rec := allowanceChat(h, "acct_req", external, headers)
		if rec.Code != http.StatusServiceUnavailable || !strings.Contains(rec.Body.String(), "allowance_unavailable") {
			t.Fatalf("%s: status %d body %s", name, rec.Code, rec.Body.String())
		}
		if n := ledgerRowsFor(t, h, "acct_req", external); n != 0 {
			t.Fatalf("%s: refused request dispatched %d attempts", name, n)
		}
	}
	// Without the required marker the same malformed headers are ignored
	// and the request is paid as before.
	rec := allowanceChat(h, "acct_req", "ext-ignored", map[string]string{allowanceInputTokensHeader: "10"})
	if rec.Code != http.StatusOK || rec.Header().Get(allowanceFundingHeader) != "" {
		t.Fatalf("plain request status %d headers %v", rec.Code, rec.Header())
	}
}
