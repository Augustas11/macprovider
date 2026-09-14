package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func TestWholesaleNoProviderBecomes429(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if got := r.Header.Get(wholesaleInternalHeader); got != "1" {
			t.Fatalf("wholesale header=%q want 1", got)
		}
		return responseWithBody(http.StatusServiceUnavailable, markedNoProviderHeaders(), noProviderBody()), nil
	})}
	accountID := "acct_wholesale_or"
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Auth.WholesaleAccountIDs = []string{accountID}
	})
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	resp := postChat(t, h, fullKey, chatBody(false), nil)
	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "no_provider_available")
	if got := resp.Header().Get("Retry-After"); got != "1" {
		t.Fatalf("Retry-After=%q want 1", got)
	}
}

func TestWholesaleUnmarkedNoProviderSettlesInsteadOf429(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if got := r.Header.Get(wholesaleInternalHeader); got != "1" {
			t.Fatalf("wholesale header=%q want 1", got)
		}
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
	})}
	accountID := "acct_wholesale_unmarked_or"
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Auth.WholesaleAccountIDs = []string{accountID}
		cfg.Retry503.Enabled = false
	})
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used == 0 {
		t.Fatalf("daily_tokens_used=0 — unmarked no_provider_available must charge the estimate")
	}
}

func TestPublicNoProviderStays503(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if got := r.Header.Get(wholesaleInternalHeader); got != "" {
			t.Fatalf("public traffic leaked wholesale header %q", got)
		}
		return responseWithBody(http.StatusServiceUnavailable, markedNoProviderHeaders(), noProviderBody()), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_public_or")
	resp := postChat(t, h, fullKey, chatBody(false), nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "no_provider_available")
}

func TestWholesaleQuotaIsNotCappedAtPublicDailyLimit(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	accountID := "acct_wholesale_quota"
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Quotas.AccountDailyTokens = 1
		cfg.Auth.WholesaleAccountIDs = []string{accountID}
	})
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	resp := postChat(t, h, fullKey, chatBody(false), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
}

func TestWholesaleConcurrencyOverrideDoesNotThrottlePublicAccounts(t *testing.T) {
	entered := make(chan string, 2)
	release := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		entered <- r.Header.Get(wholesaleInternalHeader)
		<-release
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	wholesaleAccountID := "acct_wholesale_concurrency"
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Auth.WholesaleAccountIDs = []string{wholesaleAccountID}
		cfg.Quotas.AccountConcurrency = 8
		cfg.Quotas.WholesaleAccountConcurrency = 1
		cfg.Quotas.AccountRequestRatePerSecond = 100
	})
	wholesaleKey := createAccountAndKey(t, store, cfg, wholesaleAccountID)
	publicKey := createAccountAndKey(t, store, cfg, "acct_public_concurrency")
	body := chatBody(false)

	done := make(chan *httptest.ResponseRecorder, 2)
	go func() { done <- postChat(t, h, wholesaleKey, body, distinctRequestID(nil)) }()
	select {
	case marker := <-entered:
		if marker != "1" {
			t.Fatalf("first request wholesale marker=%q want 1", marker)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for first wholesale request")
	}

	rejected := postChat(t, h, wholesaleKey, body, distinctRequestID(nil))
	if rejected.Code != http.StatusTooManyRequests {
		t.Fatalf("second wholesale status=%d body=%s", rejected.Code, rejected.Body.String())
	}
	assertErrorCode(t, rejected.Body.String(), "account_concurrency_exceeded")
	assertConcurrencyRejectHeaders(t, rejected, 1)

	go func() { done <- postChat(t, h, publicKey, body, distinctRequestID(nil)) }()
	select {
	case marker := <-entered:
		if marker != "" {
			t.Fatalf("public request wholesale marker=%q want empty", marker)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("public account was throttled by wholesale override")
	}

	close(release)
	for i := 0; i < 2; i++ {
		resp := <-done
		if resp.Code != http.StatusOK {
			t.Fatalf("in-flight response status=%d body=%s", resp.Code, resp.Body.String())
		}
	}
}

func TestWholesaleStreamInjectsUsageAndKeepalive(t *testing.T) {
	prev := wholesaleKeepaliveInterval
	wholesaleKeepaliveInterval = time.Hour
	t.Cleanup(func() { wholesaleKeepaliveInterval = prev })

	pr, pw := io.Pipe()
	go func() {
		defer pw.Close()
		time.Sleep(40 * time.Millisecond)
		_, _ = io.WriteString(pw, "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n")
	}()
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}},
			Body:       pr,
		}, nil
	})}
	accountID := "acct_wholesale_stream"
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Auth.WholesaleAccountIDs = []string{accountID}
		cfg.Retry503.Enabled = false
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, accountID)
	resp := postChat(t, h, fullKey, chatBody(true), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	body := resp.Body.String()
	if !strings.Contains(body, `"usage"`) {
		t.Fatalf("wholesale stream missing usage chunk: %s", body)
	}
	if !strings.Contains(body, "data: [DONE]") {
		t.Fatalf("wholesale stream missing [DONE]: %s", body)
	}
	if !strings.Contains(body, ": keepalive") {
		t.Fatalf("wholesale stream missing keepalive comment: %s", body)
	}
	if keepaliveIndex, dataIndex := strings.Index(body, ": keepalive"), strings.Index(body, `data: {"choices"`); keepaliveIndex < 0 || dataIndex < 0 || keepaliveIndex > dataIndex {
		t.Fatalf("keepalive was not emitted before provider data: %s", body)
	}
}
