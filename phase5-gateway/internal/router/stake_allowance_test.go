package router

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

type allowanceHop struct {
	header http.Header
}

func allowanceCoordinator(t *testing.T, funding func(n int, r *http.Request) (int, http.Header, string)) (*http.Client, func() []allowanceHop) {
	t.Helper()
	var mu sync.Mutex
	var hops []allowanceHop
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		hops = append(hops, allowanceHop{header: r.Header.Clone()})
		n := len(hops)
		mu.Unlock()
		if r.Body != nil {
			_, _ = io.Copy(io.Discard, r.Body)
		}
		status, header, body := funding(n, r)
		return responseWithBody(status, header, body), nil
	})}
	return client, func() []allowanceHop {
		mu.Lock()
		defer mu.Unlock()
		return append([]allowanceHop(nil), hops...)
	}
}

func allowanceOKHeaders(funding, active string) http.Header {
	h := http.Header{"Content-Type": []string{"application/json"}}
	if funding != "" {
		h.Set(allowanceFundingHeader, funding)
	}
	if active != "" {
		h.Set(allowanceActiveHeader, active)
	}
	return h
}

func dailyTokensUsed(t *testing.T, h http.Handler, key string) float64 {
	t.Helper()
	resp := assertStatus(t, h, http.MethodGet, "/v1/usage", key, "", "1.2.3.4", http.StatusOK)
	return readQuota(t, resp)["daily_tokens_used"].(float64)
}

// SPEC-050-R007: the chat hop carries the allowance admission inputs, and an
// allowance-funded answer keeps the request off the paid daily quota without
// leaking the internal headers to the buyer.
func TestAllowanceFundedChatLeavesPaidQuotaUntouched(t *testing.T) {
	for _, tc := range []struct {
		funding  string
		wantUsed float64
	}{{"allowance", 0}, {"paid", 7}, {"", 7}} {
		t.Run("funding_"+tc.funding, func(t *testing.T) {
			client, hops := allowanceCoordinator(t, func(int, *http.Request) (int, http.Header, string) {
				return http.StatusOK, allowanceOKHeaders(tc.funding, "1"), retryChatSuccessBody
			})
			h, store, _, cfg := newRetryHarness(t, client, nil)
			key := createAccountAndKey(t, store, cfg, "acct_allow_"+tc.funding)
			resp := postChat(t, h, key, chatBody(false), map[string]string{
				allowanceRequiredHeader: "1", // a buyer copy never reaches the coordinator
			})
			if resp.Code != http.StatusOK {
				t.Fatalf("status %d body %s", resp.Code, resp.Body.String())
			}
			for name := range resp.Header() {
				if strings.HasPrefix(strings.ToLower(name), "x-macprovider-internal-allowance") {
					t.Fatalf("internal header %s leaked to the buyer", name)
				}
			}
			got := hops()
			if len(got) != 1 {
				t.Fatalf("hops = %d", len(got))
			}
			hop := got[0].header
			if hop.Get(allowanceModelHeader) != "llama" || hop.Get(allowanceOutputTokensHeader) != "20" ||
				hop.Get(allowanceInputTokensHeader) != strconv.FormatInt(promptCapTokens([]byte(chatBody(false))), 10) {
				t.Fatalf("allowance headers %v", hop)
			}
			if hop.Get(allowanceRequiredHeader) != "" {
				t.Fatal("buyer-supplied allowance-required header reached the coordinator")
			}
			if used := dailyTokensUsed(t, h, key); used != tc.wantUsed {
				t.Fatalf("daily_tokens_used=%v want %v", used, tc.wantUsed)
			}
		})
	}
}

// SPEC-050-R007: once the paid quota is spent, an account the coordinator
// reported an allowance for is forwarded as allowance-only; an account
// without one gets the usual 429 with no coordinator hop.
func TestPaidQuotaExhaustedFallsBackToAllowanceOnly(t *testing.T) {
	reservation := promptCapTokens([]byte(chatBody(false))) + 20
	client, hops := allowanceCoordinator(t, func(n int, r *http.Request) (int, http.Header, string) {
		if n == 1 {
			return http.StatusOK, allowanceOKHeaders("paid", "1"), retryChatSuccessBody
		}
		if n == 4 {
			// A different account with no allowance today.
			return http.StatusOK, allowanceOKHeaders("", "0"), retryChatSuccessBody
		}
		if r.Header.Get(allowanceRequiredHeader) != "1" {
			t.Errorf("hop %d without allowance-required", n)
		}
		if n == 2 {
			return http.StatusOK, allowanceOKHeaders("allowance", "1"), retryChatSuccessBody
		}
		h := markedNoProviderHeaders()
		h.Set(allowanceActiveHeader, "1")
		return http.StatusTooManyRequests, h, `{"error":{"code":"quota_exhausted","message":"Quota exhausted","type":"rate_limit_exceeded"}}`
	})
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Quotas.AccountDailyTokens = reservation + 3 // room for one request
		cfg.Retry503.Enabled = false
	})
	key := createAccountAndKey(t, store, cfg, "acct_allow_only")
	reqID := func(n int) map[string]string {
		return map[string]string{"X-Request-ID": "00000000-0000-4000-8000-00000000000" + strconv.Itoa(n)}
	}
	if resp := postChat(t, h, key, chatBody(false), reqID(1)); resp.Code != http.StatusOK {
		t.Fatalf("first status %d body %s", resp.Code, resp.Body.String())
	}
	if resp := postChat(t, h, key, chatBody(false), reqID(2)); resp.Code != http.StatusOK {
		t.Fatalf("allowance-only status %d body %s", resp.Code, resp.Body.String())
	}
	if used := dailyTokensUsed(t, h, key); used != 7 {
		t.Fatalf("daily_tokens_used=%v want 7: the allowance-only request must not draw the paid quota", used)
	}
	resp := postChat(t, h, key, chatBody(false), reqID(3))
	if resp.Code != http.StatusTooManyRequests || !strings.Contains(resp.Body.String(), "quota_exhausted") {
		t.Fatalf("refused allowance-only status %d body %s", resp.Code, resp.Body.String())
	}
	if len(hops()) != 3 {
		t.Fatalf("hops = %d", len(hops()))
	}

	// An account the coordinator never reported an allowance for is refused
	// locally, exactly as before.
	other := createAccountAndKey(t, store, cfg, "acct_no_allowance")
	if resp := postChat(t, h, other, chatBody(false), reqID(4)); resp.Code != http.StatusOK {
		t.Fatalf("other first %d", resp.Code)
	}
	before := len(hops())
	resp = postChat(t, h, other, chatBody(false), reqID(5))
	if resp.Code != http.StatusTooManyRequests || len(hops()) != before {
		t.Fatalf("account without an allowance: status %d, hops %d -> %d; want a local 429", resp.Code, before, len(hops()))
	}
}

func TestStakeProxyForwardsOnlyTheVerifiedPrincipal(t *testing.T) {
	var calls []creatorUpstreamCall
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		calls = append(calls, creatorUpstreamCall{method: r.Method, path: r.URL.Path, body: string(raw), header: r.Header.Clone()})
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Upstream-Only", "1")
		_, _ = w.Write([]byte(`{"object":"stake_events"}`))
	}))
	defer coordinator.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	key := createAccountAndKey(t, store, cfg, "acct_stake")
	if err := store.AddAccountIdentity(context.Background(), storage.AccountIdentity{
		AccountID: "acct_stake", Provider: "github", ProviderUserID: "4242", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/stake/lock", strings.NewReader(`{"amount_malibu":"1"}`))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Idempotency-Key", "lock-1")
	req.Header.Set(stakeAccountHeader, "acct_victim")
	req.Header.Set(stakeGitHubHeader, "1")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Header().Get("X-Upstream-Only") != "" || rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("status %d headers %v body %s", rec.Code, rec.Header(), rec.Body.String())
	}
	if len(calls) != 1 {
		t.Fatalf("calls = %d", len(calls))
	}
	call := calls[0]
	if call.method != http.MethodPost || call.path != "/internal/stake-allowance/lock" || call.body != `{"amount_malibu":"1"}` {
		t.Fatalf("call %+v", call)
	}
	if call.header.Get("Authorization") != "Bearer service-token" || call.header.Get("Idempotency-Key") != "lock-1" {
		t.Fatalf("call headers %v", call.header)
	}
	if got := call.header.Values(stakeAccountHeader); len(got) != 1 || got[0] != "acct_stake" {
		t.Fatalf("account %v", got)
	}
	if got := call.header.Values(stakeGitHubHeader); len(got) != 1 || got[0] != "4242" {
		t.Fatalf("github %v", got)
	}

	get := httptest.NewRequest(http.MethodGet, "/v1/stake", nil)
	get.Header.Set("Authorization", "Bearer "+key)
	rec = httptest.NewRecorder()
	h.ServeHTTP(rec, get)
	if rec.Code != http.StatusOK || calls[1].path != "/internal/stake-allowance/account" || calls[1].method != http.MethodGet {
		t.Fatalf("account view status %d call %+v", rec.Code, calls[len(calls)-1])
	}

	for name, mutate := range map[string]func(*http.Request){
		"demo":           func(r *http.Request) { r.Header.Set("X-Demo-Token", "x") },
		"wallet session": func(r *http.Request) { r.Header.Set("Authorization", "Bearer mps_session") },
	} {
		r := httptest.NewRequest(http.MethodPost, "/v1/stake/unlock", strings.NewReader(`{}`))
		r.Header.Set("Authorization", "Bearer "+key)
		mutate(r)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("%s status %d", name, rec.Code)
		}
	}
	for _, path := range []string{"/v1/stake/admit", "/v1/stake/../lock"} {
		r := httptest.NewRequest(http.MethodPost, path, strings.NewReader(`{}`))
		r.Header.Set("Authorization", "Bearer "+key)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		if rec.Code == http.StatusOK {
			t.Fatalf("%s reached the coordinator", path)
		}
	}
	if len(calls) != 2 {
		t.Fatalf("refused calls reached the coordinator: %d", len(calls))
	}
}

// SPEC-050-R014: an allowance-only request the coordinator did not fund (a
// coordinator without SPEC-050) is charged to the paid quota, and the gateway
// stops forwarding allowance-only requests for that account.
func TestUnfundedAllowanceOnlyRequestIsChargedToPaidQuota(t *testing.T) {
	reservation := promptCapTokens([]byte(chatBody(false))) + 20
	client, hops := allowanceCoordinator(t, func(n int, r *http.Request) (int, http.Header, string) {
		if n == 1 {
			return http.StatusOK, allowanceOKHeaders("paid", "1"), retryChatSuccessBody
		}
		// A coordinator that ignores the allowance headers.
		return http.StatusOK, allowanceOKHeaders("", ""), retryChatSuccessBody
	})
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Quotas.AccountDailyTokens = reservation + 3
		cfg.Retry503.Enabled = false
	})
	key := createAccountAndKey(t, store, cfg, "acct_unfunded")
	reqID := func(n int) map[string]string {
		return map[string]string{"X-Request-ID": "00000000-0000-4000-8000-00000000010" + strconv.Itoa(n)}
	}
	for i := 1; i <= 2; i++ {
		if resp := postChat(t, h, key, chatBody(false), reqID(i)); resp.Code != http.StatusOK {
			t.Fatalf("request %d status %d body %s", i, resp.Code, resp.Body.String())
		}
	}
	if used := dailyTokensUsed(t, h, key); used != 14 {
		t.Fatalf("daily_tokens_used=%v, want 14: the unfunded allowance-only request is charged to the paid quota", used)
	}
	before := len(hops())
	if resp := postChat(t, h, key, chatBody(false), reqID(3)); resp.Code != http.StatusTooManyRequests || len(hops()) != before {
		t.Fatalf("after an unfunded allowance-only request: status %d hops %d -> %d; want a local 429", resp.Code, before, len(hops()))
	}
}

// SPEC-050-R008: a journaled settlement re-driven after a crash keeps the
// coordinator-confirmed allowance funding, on both recovery rungs, so the
// allowance usage never lands on the paid quota.
func TestJournalRecoveryKeepsAllowanceFunding(t *testing.T) {
	for _, refunded := range []bool{false, true} {
		srv, store, _, jnl, _ := newJournalHarness(t, nil)
		account := "acct_journal_allow"
		if refunded {
			account += "_refunded"
		}
		seedJournalReservation(t, store, account, "req-allow", 100)
		if refunded {
			if err := store.RefundReservation(context.Background(), account, "req-allow", fixedNow().Unix()); err != nil {
				t.Fatal(err)
			}
		}
		rec := journalSettleEffect(account, "req-allow")
		rec.FundingSource = storage.FundingSourceAllowance
		if err := jnl.WriteEffect(rec); err != nil {
			t.Fatal(err)
		}
		if _, err := srv.RecoverSettlementJournal(context.Background(), 0); err != nil {
			t.Fatal(err)
		}
		used, reserved, err := store.DailyUsage(context.Background(), account, journalTestWindow)
		if err != nil || used != 0 || reserved != 0 {
			t.Fatalf("refunded=%v used=%d reserved=%d err=%v: recovered allowance usage must leave the paid quota", refunded, used, reserved, err)
		}
	}
}

// A negative in-memory answer never hides an allowance another gateway
// instance (or a later response) recorded in the shared table.
func TestAllowanceDayLookupIsNotBlockedByANegativeAnswer(t *testing.T) {
	reservation := promptCapTokens([]byte(chatBody(false))) + 20
	client, hops := allowanceCoordinator(t, func(n int, r *http.Request) (int, http.Header, string) {
		if n == 1 {
			return http.StatusOK, allowanceOKHeaders("paid", "0"), retryChatSuccessBody
		}
		if r.Header.Get(allowanceRequiredHeader) != "1" || r.Header.Get(allowanceDayHeader) == "" {
			t.Errorf("hop %d headers %v", n, r.Header)
		}
		return http.StatusOK, allowanceOKHeaders("allowance", "1"), retryChatSuccessBody
	})
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Quotas.AccountDailyTokens = reservation + 3
		cfg.Retry503.Enabled = false
	})
	key := createAccountAndKey(t, store, cfg, "acct_shared_day")
	if resp := postChat(t, h, key, chatBody(false), map[string]string{"X-Request-ID": "00000000-0000-4000-8000-000000000201"}); resp.Code != http.StatusOK {
		t.Fatalf("first status %d", resp.Code)
	}
	// Another gateway instance learned of today's allowance.
	if err := store.NoteAllowanceDay(context.Background(), "acct_shared_day", fixedNow().UTC().Format("2006-01-02"), true, fixedNow()); err != nil {
		t.Fatal(err)
	}
	if resp := postChat(t, h, key, chatBody(false), map[string]string{"X-Request-ID": "00000000-0000-4000-8000-000000000202"}); resp.Code != http.StatusOK {
		t.Fatalf("allowance-only status %d body %s", resp.Code, resp.Body.String())
	}
	if len(hops()) != 2 {
		t.Fatalf("hops %d", len(hops()))
	}
}
