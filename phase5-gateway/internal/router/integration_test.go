package router

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
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
		if got := r.Header.Get("Authorization"); got != "" {
			t.Fatalf("forwarded buyer auth header=%q", got)
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
		cfg.Quotas.AccountDailyTokens = 50
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
		cfg.Quotas.DemoDailyTokensPerIP = 10
		cfg.Limits.DemoMaxTokensPerRequest = 10
	}, WithHTTPClient(client))
	demo := issueDemoToken(t, h, "1.2.3.4")
	body := `{"model":"llama","max_tokens":8,"messages":[{"role":"user","content":"hi"}]}`
	first := postChat(t, h, "", body, map[string]string{"X-Demo-Token": demo, "X-Real-IP": "1.2.3.4"})
	if first.Code != http.StatusOK {
		t.Fatalf("first demo status=%d body=%s", first.Code, first.Body.String())
	}
	second := postChat(t, h, "", body, map[string]string{"X-Demo-Token": demo, "X-Real-IP": "1.2.3.4"})
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
		go func() { done <- postChat(t, h, key, body, nil) }()
	}
	for i := 0; i < 2; i++ {
		select {
		case <-entered:
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for upstream request")
		}
	}
	third := postChat(t, h, key, body, nil)
	if third.Code != http.StatusTooManyRequests {
		t.Fatalf("third status=%d body=%s", third.Code, third.Body.String())
	}
	assertErrorCode(t, third.Body.String(), "account_concurrency_exceeded")
	close(release)
	for i := 0; i < 2; i++ {
		resp := <-done
		if resp.Code != http.StatusOK {
			t.Fatalf("in-flight response status=%d body=%s", resp.Code, resp.Body.String())
		}
	}
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
	assertErrorCode(t, resp.Body.String(), "provider_unavailable")
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

	postAdminJSON(t, h, "/admin/kill-switch", `{"demo_only":true}`)
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

// TestOAuthMintActionRejectsUnknownActions guards against the action cookie
// being a footgun for future contributors who add new action values without
// validating them. Unknown actions must 400 at /auth/github/start, never
// reach the callback.
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
