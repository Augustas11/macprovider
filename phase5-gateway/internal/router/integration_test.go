package router

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestStrangerKeyOpenAIChatUsageFlow(t *testing.T) {
	var forwardedRequestID string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		// SPEC-006 v0.9.1 / issue #211: the upstream Authorization
		// header is now hoisted out of the sticky-routing conditional
		// and set on every forward (alongside X-MacProvider-Account)
		// because the coordinator gates X-MacProvider-Account behind
		// internalBearerAuthorized. The value MUST be the gateway's
		// configured upstream coordinator bearer — NOT the buyer's
		// mp_-prefixed API key. This assertion guards that the
		// buyer's bearer is not silently exfiltrated upstream.
		got := r.Header.Get("Authorization")
		if strings.Contains(got, "mp_") {
			t.Fatalf("forwarded buyer auth header (mp_ key leaked)=%q", got)
		}
		if got != "Bearer service-token" {
			t.Fatalf("forwarded Authorization=%q, want %q", got, "Bearer service-token")
		}
		forwardedRequestID = r.Header.Get("X-Request-ID")
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_phase_e",
			"object":"chat.completion",
			"created":1780000000,
			"model":"llama",
			"usage":{"prompt_tokens":8,"completion_tokens":12,"total_tokens":20},
			"choices":[{"index":0,"message":{"role":"assistant","content":"hello"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{identity: auth.OAuthIdentity{
		ProviderUserID: "stranger-1",
		Email:          "stranger@example.test",
		Scopes:         []string{"read:user"},
	}}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))

	state, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound {
		t.Fatalf("oauth callback status=%d body=%s", resp.Code, resp.Body.String())
	}
	fullKey := findCookie(resp, "mp_new_api_key")
	if !strings.HasPrefix(fullKey, "mp_") {
		t.Fatalf("issued key=%q", fullKey)
	}

	chatResp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":32,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if chatResp.Code != http.StatusOK {
		t.Fatalf("chat status=%d body=%s", chatResp.Code, chatResp.Body.String())
	}
	if forwardedRequestID == "" {
		t.Fatalf("forwarded request id missing")
	}
	var chat map[string]any
	if err := json.Unmarshal(chatResp.Body.Bytes(), &chat); err != nil {
		t.Fatalf("chat json: %v", err)
	}
	if chat["object"] != "chat.completion" {
		t.Fatalf("chat object=%v", chat["object"])
	}

	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	if quota["daily_tokens_used"].(float64) != 20 {
		t.Fatalf("daily_tokens_used=%v want 20", quota["daily_tokens_used"])
	}
	if quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("daily_tokens_reserved=%v want 0", quota["daily_tokens_reserved"])
	}
}

func TestAccountPageDisplaysNewKeyOnce(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{ProviderUserID: "account-once", Scopes: []string{"read:user"}}})
	state, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound {
		t.Fatalf("oauth callback status=%d body=%s", resp.Code, resp.Body.String())
	}
	fullKey := findCookie(resp, "mp_new_api_key")
	if fullKey == "" {
		t.Fatalf("new key cookie missing")
	}
	for _, cookie := range resp.Result().Cookies() {
		if cookie.Name == "mp_new_api_key" && !cookie.Secure {
			t.Fatalf("mp_new_api_key cookie is not Secure")
		}
	}

	accountReq := httptest.NewRequest(http.MethodGet, "/account", nil)
	accountReq.AddCookie(&http.Cookie{Name: "mp_new_api_key", Value: fullKey, Path: "/account"})
	accountResp := httptest.NewRecorder()
	h.ServeHTTP(accountResp, accountReq)
	if accountResp.Code != http.StatusOK {
		t.Fatalf("account status=%d body=%s", accountResp.Code, accountResp.Body.String())
	}
	if !strings.Contains(accountResp.Body.String(), fullKey) {
		t.Fatalf("account page did not display key once")
	}

	refreshReq := httptest.NewRequest(http.MethodGet, "/account", nil)
	refreshResp := httptest.NewRecorder()
	h.ServeHTTP(refreshResp, refreshReq)
	if refreshResp.Code != http.StatusOK {
		t.Fatalf("refresh status=%d body=%s", refreshResp.Code, refreshResp.Body.String())
	}
	if strings.Contains(refreshResp.Body.String(), fullKey) || strings.Contains(refreshResp.Body.String(), "mp_") {
		t.Fatalf("refresh redisplayed key: %s", refreshResp.Body.String())
	}
}

func TestCrossAccountKeyRevocationRejected(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	keyA := createAccountAndKey(t, store, cfg, "acct_revoke_a")
	keyB := createAccountAndKey(t, store, cfg, "acct_revoke_b")
	keysB, err := store.ListAPIKeys(context.Background(), "acct_revoke_b")
	if err != nil {
		t.Fatalf("ListAPIKeys B: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/auth/api-keys/"+keysB[0].KeyID+"/revoke", nil)
	req.Header.Set("Authorization", "Bearer "+keyA)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusNotFound {
		t.Fatalf("cross revoke status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertStatus(t, h, http.MethodGet, "/v1/models", keyB, "", "1.2.3.4", http.StatusOK)
}

func TestQuotaExhaustionReturns429(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_quota",
			"object":"chat.completion",
			"usage":{"prompt_tokens":10,"completion_tokens":30,"total_tokens":40},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.AccountDailyTokens = 130
		cfg.Limits.MaxTokensPerRequest = 50
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_quota_exhaust")

	first := postChat(t, h, fullKey, `{"model":"llama","max_tokens":40,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if first.Code != http.StatusOK {
		t.Fatalf("first status=%d body=%s", first.Code, first.Body.String())
	}
	second := postChat(t, h, fullKey, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"again"}]}`, nil)
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second status=%d body=%s", second.Code, second.Body.String())
	}
	assertErrorCode(t, second.Body.String(), "quota_exhausted")
	if second.Header().Get("X-RateLimit-Reset") == "" {
		t.Fatalf("X-RateLimit-Reset missing")
	}
}

func TestDemoChatQuotaExhaustionIsSeparateFromAccountQuota(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_demo_quota",
			"object":"chat.completion",
			"usage":{"prompt_tokens":4,"completion_tokens":4,"total_tokens":8},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.DemoDailyTokensPerIP = 95
		cfg.Limits.DemoMaxTokensPerRequest = 10
	}, WithHTTPClient(client))
	demo := issueDemoToken(t, h, "1.2.3.4")
	body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	demoHeaders := map[string]string{"X-Demo-Token": demo, "X-Real-IP": "1.2.3.4"}
	first := postChat(t, h, "", body, distinctRequestID(demoHeaders))
	if first.Code != http.StatusOK {
		t.Fatalf("first demo status=%d body=%s", first.Code, first.Body.String())
	}
	second := postChat(t, h, "", body, distinctRequestID(demoHeaders))
	if second.Code != http.StatusTooManyRequests {
		t.Fatalf("second demo status=%d body=%s", second.Code, second.Body.String())
	}
	assertErrorCode(t, second.Body.String(), "quota_exhausted")

	key := createAccountAndKey(t, store, cfg, "acct_demo_quota_separate")
	account := postChat(t, h, key, body, nil)
	if account.Code != http.StatusOK {
		t.Fatalf("account status=%d body=%s", account.Code, account.Body.String())
	}
}

func TestAccountConcurrencyCap(t *testing.T) {
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		entered <- struct{}{}
		<-release
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_concurrency",
			"object":"chat.completion",
			"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.AccountConcurrency = 2
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_concurrency_cap")
	body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	done := make(chan *httptest.ResponseRecorder, 2)
	for i := 0; i < 2; i++ {
		go func() { done <- postChat(t, h, key, body, distinctRequestID(nil)) }()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for upstream request")
		}
	}
	third := postChat(t, h, key, body, distinctRequestID(nil))
	if third.Code != http.StatusTooManyRequests {
		t.Fatalf("third status=%d body=%s", third.Code, third.Body.String())
	}
	assertErrorCode(t, third.Body.String(), "account_concurrency_exceeded")
	// Issue #190: 429 must carry OpenAI-compatible concurrency
	// rate-limit headers so SDKs can self-pace.
	assertConcurrencyRejectHeaders(t, third, 2)
	// Issue #190 R1 security HIGH: per-tenant headers must not
	// be cacheable.
	assertNoStoreCacheHeaders(t, third)
	close(release)
	for i := 0; i < 2; i++ {
		resp := <-done
		if resp.Code != http.StatusOK {
			t.Fatalf("in-flight response status=%d body=%s", resp.Code, resp.Body.String())
		}
		// Issue #190: admitted 2xx responses must also carry
		// X-RateLimit-Limit-Requests so SDKs know the cap before
		// they hit it.
		if got := resp.Header().Get("X-RateLimit-Limit-Requests"); got != "2" {
			t.Errorf("admitted response X-RateLimit-Limit-Requests=%q want 2", got)
		}
		if got := resp.Header().Get("Retry-After"); got != "" {
			t.Errorf("admitted response carries Retry-After=%q (must be unset)", got)
		}
	}
}

func TestAccountRequestRateLimitRejectsBurstBeforeUpstream(t *testing.T) {
	now := fixedNow()
	upstreamHits := make(chan struct{}, 4)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits <- struct{}{}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_request_rate",
			"object":"chat.completion",
			"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.AccountConcurrency = 10
		cfg.Quotas.AccountRequestRatePerSecond = 2
	}, WithNow(func() time.Time { return now }), WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_request_rate_burst")
	body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`

	for i := 0; i < 2; i++ {
		resp := postChat(t, h, key, body, distinctRequestID(nil))
		if resp.Code != http.StatusOK {
			t.Fatalf("admitted request %d status=%d body=%s", i, resp.Code, resp.Body.String())
		}
	}
	beforeReject := gatewaySettlementSnapshot(t, dbPath, "acct_request_rate_burst")
	third := postChat(t, h, key, body, distinctRequestID(nil))
	if third.Code != http.StatusTooManyRequests {
		t.Fatalf("third request status=%d body=%s, want 429", third.Code, third.Body.String())
	}
	assertErrorCode(t, third.Body.String(), "account_request_rate_exceeded")
	assertConcurrencyRejectHeaders(t, third, 2)
	if got := len(upstreamHits); got != 2 {
		t.Fatalf("upstream hits after rate rejection=%d want 2", got)
	}
	afterReject := gatewaySettlementSnapshot(t, dbPath, "acct_request_rate_burst")
	if afterReject != beforeReject {
		t.Fatalf("rate rejection changed settlement state: before=%+v after=%+v", beforeReject, afterReject)
	}

	now = now.Add(time.Second)
	fourth := postChat(t, h, key, body, distinctRequestID(nil))
	if fourth.Code != http.StatusOK {
		t.Fatalf("request after refill status=%d body=%s", fourth.Code, fourth.Body.String())
	}
	if got := len(upstreamHits); got != 3 {
		t.Fatalf("upstream hits after refill=%d want 3", got)
	}
}

func TestRunawayBuyerBurstGetsQuick429sAtGateway(t *testing.T) {
	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		entered <- struct{}{}
		<-release
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_runaway",
			"object":"chat.completion",
			"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.AccountConcurrency = 1
		cfg.Quotas.AccountRequestRatePerSecond = 100
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, store, cfg, "acct_runaway_burst")
	body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`

	done := make(chan *httptest.ResponseRecorder, 1)
	go func() { done <- postChat(t, h, key, body, distinctRequestID(nil)) }()
	select {
	case <-entered:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first upstream request")
	}

	for i := 0; i < 19; i++ {
		resp := postChat(t, h, key, body, distinctRequestID(nil))
		if resp.Code != http.StatusTooManyRequests {
			t.Fatalf("burst request %d status=%d body=%s, want 429", i+2, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "account_concurrency_exceeded")
		assertConcurrencyRejectHeaders(t, resp, 1)
	}

	close(release)
	first := <-done
	if first.Code != http.StatusOK {
		t.Fatalf("first in-flight response status=%d body=%s", first.Code, first.Body.String())
	}
}

// Issue #190 R1 security HIGH helper: confirm chat responses are
// non-cacheable so per-tenant headers cannot leak via a shared
// CDN/proxy cache.
func assertNoStoreCacheHeaders(t *testing.T, resp *httptest.ResponseRecorder) {
	t.Helper()
	if got := resp.Header().Get("Cache-Control"); !strings.Contains(got, "no-store") {
		t.Errorf("Cache-Control=%q must contain no-store", got)
	}
	// Vary may be a single comma-joined value or multiple Add-ed
	// values; check both representations.
	varyJoined := strings.Join(resp.Header().Values("Vary"), ", ")
	if !strings.Contains(varyJoined, "Authorization") {
		t.Errorf("Vary=%q must contain Authorization", varyJoined)
	}
	if !strings.Contains(varyJoined, "X-Api-Key") {
		t.Errorf("Vary=%q must contain X-Api-Key", varyJoined)
	}
	if !strings.Contains(varyJoined, "X-Demo-Token") {
		t.Errorf("Vary=%q must contain X-Demo-Token", varyJoined)
	}
}

// Issue #190 helper: verify the 429 concurrency-reject path emits
// every header an OpenAI-compatible SDK looks for.
func assertConcurrencyRejectHeaders(t *testing.T, resp *httptest.ResponseRecorder, wantLimit int) {
	t.Helper()
	wantLimitStr := strconv.Itoa(wantLimit)
	if got := resp.Header().Get("X-RateLimit-Limit-Requests"); got != wantLimitStr {
		t.Errorf("X-RateLimit-Limit-Requests=%q want %s", got, wantLimitStr)
	}
	if got := resp.Header().Get("X-RateLimit-Remaining-Requests"); got != "0" {
		t.Errorf("X-RateLimit-Remaining-Requests=%q want 0", got)
	}
	resetStr := resp.Header().Get("X-RateLimit-Reset-Requests")
	if resetStr == "" {
		t.Errorf("X-RateLimit-Reset-Requests missing on 429")
	} else if reset, err := strconv.ParseInt(resetStr, 10, 64); err != nil {
		t.Errorf("X-RateLimit-Reset-Requests=%q not parsable: %v", resetStr, err)
	} else if reset <= 0 {
		t.Errorf("X-RateLimit-Reset-Requests=%d must be positive unix seconds", reset)
	}
	retryAfterStr := resp.Header().Get("Retry-After")
	if retryAfterStr == "" {
		t.Errorf("Retry-After missing on 429")
	} else if retryAfter, err := strconv.Atoi(retryAfterStr); err != nil {
		t.Errorf("Retry-After=%q not parsable: %v", retryAfterStr, err)
	} else if retryAfter < 1 || retryAfter > 60 {
		t.Errorf("Retry-After=%d outside [1, 60]", retryAfter)
	}
	// Round-2 sweep rule: a path that sets a positive Retry-After MUST
	// stamp retryable=true in the body — otherwise a buyer honoring one
	// signal and a buyer honoring the other reach opposite conclusions.
	assertBodyRetryable(t, resp.Body.String(), true)
}

// Regression: M1-8 / PERF-6. Demo requests must respect a concurrency cap.
// Pre-fix the router skipped AcquireConcurrency for demo subjects, so 3+
// parallel demo requests from a single IP could saturate the MLX-serialized
// pool for up to CoordinatorTimeout — an accidental DoS against paying
// buyers. The cap is keyed on subject.AccountID = "demo:<ip>" with IPv6
// normalized to /64.
func TestDemoConcurrencyCap(t *testing.T) {
	entered := make(chan struct{}, 2)
	release := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		entered <- struct{}{}
		<-release
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_demo_concurrency",
			"object":"chat.completion",
			"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.DemoConcurrency = 2
		// Keep daily-token budget high enough that 3 requests don't hit
		// quota_exhausted (which is checked before concurrency).
		cfg.Quotas.DemoDailyTokensPerIP = 1_000_000
		cfg.Limits.DemoMaxTokensPerRequest = 1_000
	}, WithHTTPClient(client))
	demo := issueDemoToken(t, h, "1.2.3.4")
	body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	headers := map[string]string{"X-Demo-Token": demo, "X-Real-IP": "1.2.3.4"}

	done := make(chan *httptest.ResponseRecorder, 2)
	for i := 0; i < 2; i++ {
		go func() { done <- postChat(t, h, "", body, distinctRequestID(headers)) }()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for upstream demo request to enter")
		}
	}
	third := postChat(t, h, "", body, distinctRequestID(headers))
	if third.Code != http.StatusTooManyRequests {
		t.Fatalf("third demo request status=%d body=%s, want 429", third.Code, third.Body.String())
	}
	assertErrorCode(t, third.Body.String(), "demo_concurrency_exceeded")
	// Issue #190: demo path must carry the same headers as the
	// authenticated path.
	assertConcurrencyRejectHeaders(t, third, 2)
	close(release)
	for i := 0; i < 2; i++ {
		resp := <-done
		if resp.Code != http.StatusOK {
			t.Fatalf("in-flight demo response status=%d body=%s", resp.Code, resp.Body.String())
		}
	}
}

func TestCoordinator503PassthroughPreservesPreflightRejected(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		body := `{"error":{"code":"preflight_rejected","message":"Provider rejected preflight","param":null,"type":"service_unavailable"}}`
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_preflight_passthrough")
	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":80,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "preflight_rejected")
}

func TestProviderUnavailableReturns503AndRefunds(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusServiceUnavailable, nil, ""), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_provider_unavailable")
	resp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":80,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "no_provider_available")
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usageResp)
	if quota["daily_tokens_used"].(float64) != 0 || quota["daily_tokens_reserved"].(float64) != 0 {
		t.Fatalf("quota after 503=%v", quota)
	}
}

func TestModelsCoordinatorUnavailableReturns503(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(&http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("coordinator down")
	})}))
	key := createAccountAndKey(t, store, cfg, "acct_models_unavailable")
	resp := assertStatus(t, h, http.MethodGet, "/v1/models", key, "", "1.2.3.4", http.StatusServiceUnavailable)
	assertErrorCode(t, resp.Body.String(), "coordinator_unavailable")
}

func TestCapacityTierOneClosesSignupButExistingKeyWorks(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_capacity",
			"object":"chat.completion",
			"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{identity: auth.OAuthIdentity{
		ProviderUserID: "new-after-tier",
		Scopes:         []string{"read:user"},
	}}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_existing_capacity")

	postAdminJSON(t, h, "/admin/capacity-signal", `{"signal":"projected_cost","value":80,"threshold":80,"firing":true}`)
	state, cookie := startOAuth(t, h, "https://api.streamvc.live/auth/github/callback")
	req := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	req.AddCookie(cookie)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("signup status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "capacity_signup_closed")

	chatResp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if chatResp.Code != http.StatusOK {
		t.Fatalf("existing key chat status=%d body=%s", chatResp.Code, chatResp.Body.String())
	}
}

func TestCapacityTierTwoHalvesQuotaAndTierThreePauses(t *testing.T) {
	current := fixedNow()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_capacity_tiers",
			"object":"chat.completion",
			"usage":{"prompt_tokens":10,"completion_tokens":10,"total_tokens":20},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Quotas.AccountDailyTokens = 100
	}, WithHTTPClient(client), WithNow(func() time.Time { return current }))
	key := createAccountAndKey(t, store, cfg, "acct_capacity_tiers")

	postAdminJSON(t, h, "/admin/capacity-signal", `{"signal":"projected_cost","value":80,"threshold":80,"firing":true}`)
	current = current.Add(8 * 24 * time.Hour)
	eval := postAdminJSON(t, h, "/admin/capacity-tier/evaluate", `{}`)
	var evalBody map[string]any
	if err := json.Unmarshal(eval.Body.Bytes(), &evalBody); err != nil {
		t.Fatalf("eval json: %v", err)
	}
	if evalBody["new_tier"].(float64) != 2 {
		t.Fatalf("eval body=%v", evalBody)
	}
	usage := assertStatus(t, h, http.MethodGet, "/v1/usage", key, "", "1.2.3.4", http.StatusOK)
	quota := readQuota(t, usage)
	if quota["daily_tokens_limit"].(float64) != 50 {
		t.Fatalf("tier2 quota=%v", quota)
	}

	postAdminJSON(t, h, "/admin/capacity-signal", `{"signal":"monthly_cost","value":600,"threshold":500,"firing":true}`)
	paused := postChat(t, h, key, `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if paused.Code != http.StatusServiceUnavailable {
		t.Fatalf("tier3 paused status=%d body=%s", paused.Code, paused.Body.String())
	}
	assertErrorCode(t, paused.Body.String(), "public_api_paused")
}

func TestDemoOnlyKillSwitchPausesDemoOnly(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{
			"id":"chatcmpl_demo_switch",
			"object":"chat.completion",
			"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2},
			"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]
		}`), nil
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.KillSwitch.DemoOnly = true
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	demoReq := httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	demoResp := httptest.NewRecorder()
	h.ServeHTTP(demoResp, demoReq)
	if demoResp.Code != http.StatusServiceUnavailable {
		t.Fatalf("demo status=%d body=%s", demoResp.Code, demoResp.Body.String())
	}
	assertErrorCode(t, demoResp.Body.String(), "demo_paused")

	fullKey := createAccountAndKey(t, store, cfg, "acct_demo_switch")
	chatResp := postChat(t, h, fullKey, `{"model":"llama","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if chatResp.Code != http.StatusOK {
		t.Fatalf("authenticated status=%d body=%s", chatResp.Code, chatResp.Body.String())
	}
}

func TestDemoOnlyKillSwitchPausesPlaygroundFeedback(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, nil)
	demoToken := issueDemoToken(t, h, "1.2.3.4")

	postAdminJSON(t, h, "/admin/kill-switch", `{"demo_only":true,"version":0}`)
	resp := postFeedback(t, h, "", demoToken, `{"rating":4,"scope":"playground"}`)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("feedback status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "demo_paused")
}

func TestClientIPDetectionRejectsForgedXFF(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	req.Header.Set("X-Real-IP", "1.2.3.4")
	req.Header.Set("X-Forwarded-For", "9.9.9.9")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusCreated {
		t.Fatalf("demo status=%d body=%s", resp.Code, resp.Body.String())
	}
	var body struct {
		DemoToken string `json:"demo_token"`
	}
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("demo json: %v", err)
	}
	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.Header.Set("X-Demo-Token", body.DemoToken)
	req.Header.Set("X-Real-IP", "1.2.3.4")
	req.Header.Set("X-Forwarded-For", "9.9.9.9")
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("real ip auth status=%d body=%s", resp.Code, resp.Body.String())
	}

	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.RemoteAddr = "5.6.7.8:1234"
	req.Header.Set("X-Demo-Token", body.DemoToken)
	req.Header.Set("X-Real-IP", "1.2.3.4")
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("forged x-real-ip auth status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "invalid_demo_token")

	req = httptest.NewRequest(http.MethodGet, "/v1/models", nil)
	req.RemoteAddr = "5.6.7.8:1234"
	req.Header.Set("X-Demo-Token", body.DemoToken)
	req.Header.Set("X-Forwarded-For", "1.2.3.4")
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusUnauthorized {
		t.Fatalf("forged xff auth status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "invalid_demo_token")

	req = httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	req.RemoteAddr = "5.6.7.8:5678"
	resp = httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusCreated {
		t.Fatalf("remote addr demo status=%d body=%s", resp.Code, resp.Body.String())
	}
}

// TestOAuthMintActionIssuesFreshKeyForExistingAccount exercises the
// `?action=mint` flow added so the /account page's "sign in again to mint a
// new one" copy is actually truthful for existing accounts. Without the
// action, the existing-account branch of handleGitHubCallback issues no key
// — which is what dropped us into the chicken-and-egg state where a user
// who lost their key had no in-product path to recover.
func TestOAuthMintActionIssuesFreshKeyForExistingAccount(t *testing.T) {
	identity := auth.OAuthIdentity{ProviderUserID: "mint-acct", Scopes: []string{"read:user"}}
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: identity})

	signupKey := completeOAuth(t, h, "", "https://api.streamvc.live/auth/github/callback")
	if !strings.HasPrefix(signupKey, "mp_") {
		t.Fatalf("signup key=%q", signupKey)
	}

	noActionKey := completeOAuth(t, h, "", "https://api.streamvc.live/auth/github/callback")
	if noActionKey != "" {
		t.Fatalf("existing-account login without action must NOT issue a key; got %q", noActionKey)
	}

	mintedKey := completeOAuth(t, h, "mint", "https://api.streamvc.live/auth/github/callback")
	if !strings.HasPrefix(mintedKey, "mp_") {
		t.Fatalf("mint-action key=%q", mintedKey)
	}
	if mintedKey == signupKey {
		t.Fatalf("mint must issue a fresh key, got same as signup: %q", mintedKey)
	}

	// We verify the minted key authenticates by hitting a bearer-protected
	// endpoint and asserting we DON'T get 401. The downstream resource
	// (coordinator) is intentionally not mocked here — any 5xx from the
	// downstream is still proof the bearer lookup succeeded.
	chatResp := postChat(t, h, mintedKey, `{"model":"llama","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if chatResp.Code == http.StatusUnauthorized {
		t.Fatalf("minted key did not authenticate; chat status=401 body=%s", chatResp.Body.String())
	}
}

// TestOAuthMintActionRejectsUnknownActions guards against the action
// surface becoming a footgun for future contributors who add new action
// values without validating them. Unknown actions must 400 at
// /auth/github/start, never reach the callback.
func TestOAuthMintActionRejectsUnknownActions(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	req := httptest.NewRequest(http.MethodGet, "/auth/github/start?action=delete&redirect_uri="+url.QueryEscape("https://api.streamvc.live/auth/github/callback"), nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("unknown action status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "oauth_action_unknown") {
		t.Fatalf("expected oauth_action_unknown in body, got %s", resp.Body.String())
	}
}

// TestOAuthMintActionRejectsUnknownRedirectURI defends against an attacker
// who tricks the victim into following /auth/github/start with a tampered
// redirect_uri AND action=mint. The redirect_uri allowlist gate must fire
// before the action is persisted; even with action=mint set, an
// off-allowlist redirect_uri returns 400 and no state row is created.
func TestOAuthMintActionRejectsUnknownRedirectURI(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	startURL := "/auth/github/start?action=mint&redirect_uri=" + url.QueryEscape("https://evil.example/callback")
	req := httptest.NewRequest(http.MethodGet, startURL, nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("tampered redirect_uri status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), "oauth_callback_not_allowed") {
		t.Fatalf("expected oauth_callback_not_allowed in body, got %s", resp.Body.String())
	}
}

// TestOAuthMintActionDoesNotSetCookie locks in the design that the action
// is bound to the OAuthState row, NOT to a sibling cookie. The cookie shape
// (mp_oauth_action) was prototyped during PR #2 review and rejected because
// it leaked across parallel flows, persisted across early callback errors,
// and could be CSRF-planted to taint a later normal login. Any reintroduction
// of an action cookie will fail this test.
func TestOAuthMintActionDoesNotSetCookie(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{
		ProviderUserID: "no-action-cookie", Scopes: []string{"read:user"},
	}})
	startURL := "/auth/github/start?action=mint&redirect_uri=" + url.QueryEscape("https://api.streamvc.live/auth/github/callback")
	req := httptest.NewRequest(http.MethodGet, startURL, nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusFound {
		t.Fatalf("mint start status=%d body=%s", resp.Code, resp.Body.String())
	}
	for _, c := range resp.Result().Cookies() {
		if c.Name == "mp_oauth_action" {
			t.Fatalf("mp_oauth_action cookie must not be set; got value=%q", c.Value)
		}
	}
}

// TestOAuthMintActionIsBoundToStateAcrossInterleavedFlows reproduces the
// parallel-flow attack the cookie-based design was vulnerable to: tab A
// starts a mint flow, tab B starts a normal flow, tab A's callback fails
// (state replay / expiry), tab B's callback succeeds. Under the cookie
// design, tab A's `mp_oauth_action` cookie would survive and cause tab B
// to mint a key. Under the state-bound design, each flow's action is
// pinned to its own state row, so tab B's normal flow must NOT mint.
func TestOAuthMintActionIsBoundToStateAcrossInterleavedFlows(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{identity: auth.OAuthIdentity{
		ProviderUserID: "interleave-acct", Scopes: []string{"read:user"},
	}})

	signupKey := completeOAuth(t, h, "", "https://api.streamvc.live/auth/github/callback")
	if !strings.HasPrefix(signupKey, "mp_") {
		t.Fatalf("signup key=%q", signupKey)
	}

	// Tab A: start mint flow but never complete callback.
	mintStartReq := httptest.NewRequest(http.MethodGet, "/auth/github/start?action=mint&redirect_uri="+url.QueryEscape("https://api.streamvc.live/auth/github/callback"), nil)
	mintStartResp := httptest.NewRecorder()
	h.ServeHTTP(mintStartResp, mintStartReq)
	if mintStartResp.Code != http.StatusFound {
		t.Fatalf("tab A start status=%d body=%s", mintStartResp.Code, mintStartResp.Body.String())
	}

	// Tab B: start normal flow + complete it. Under cookie design, the
	// dangling action cookie from tab A would cause tab B to mint.
	plainKey := completeOAuth(t, h, "", "https://api.streamvc.live/auth/github/callback")
	if plainKey != "" {
		t.Fatalf("tab B normal flow must not mint when tab A's mint state is pending; got key=%q", plainKey)
	}
}

// completeOAuth runs one full /auth/github/start → /auth/github/callback
// round-trip with an optional action and returns the value of the
// mp_new_api_key cookie (empty if not set).
func completeOAuth(t *testing.T, h http.Handler, action, redirectURI string) string {
	t.Helper()
	startPath := "/auth/github/start?redirect_uri=" + url.QueryEscape(redirectURI)
	if action != "" {
		startPath += "&action=" + url.QueryEscape(action)
	}
	startReq := httptest.NewRequest(http.MethodGet, startPath, nil)
	startResp := httptest.NewRecorder()
	h.ServeHTTP(startResp, startReq)
	if startResp.Code != http.StatusFound {
		t.Fatalf("start status=%d body=%s", startResp.Code, startResp.Body.String())
	}
	location, err := url.Parse(startResp.Header().Get("Location"))
	if err != nil {
		t.Fatalf("parse location: %v", err)
	}
	state := location.Query().Get("state")
	if state == "" {
		t.Fatalf("state missing in %s", location.String())
	}

	callbackReq := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	for _, c := range startResp.Result().Cookies() {
		callbackReq.AddCookie(c)
	}
	callbackResp := httptest.NewRecorder()
	h.ServeHTTP(callbackResp, callbackReq)
	if callbackResp.Code != http.StatusFound {
		t.Fatalf("callback status=%d body=%s", callbackResp.Code, callbackResp.Body.String())
	}
	return findCookie(callbackResp, "mp_new_api_key")
}

func TestPublicEndpointAllowlistDoesNotExposeCoordinatorInternals(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(noopClient()))
	for _, path := range []string{"/admin/foo", "/poolz", "/ws/provider"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		body, _ := io.ReadAll(resp.Result().Body)
		if resp.Code == http.StatusOK {
			t.Fatalf("%s unexpectedly returned 200 body=%s", path, string(body))
		}
		for _, forbidden := range []string{"provider_id", "assigned_id", "endpoint_url", "operator_identity"} {
			if strings.Contains(string(body), forbidden) {
				t.Fatalf("%s leaked %s in body=%s", path, forbidden, string(body))
			}
		}
	}
}
