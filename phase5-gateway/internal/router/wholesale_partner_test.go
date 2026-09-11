package router

import (
	"io"
	"net/http"
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
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
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

func TestPublicNoProviderStays503(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if got := r.Header.Get(wholesaleInternalHeader); got != "" {
			t.Fatalf("public traffic leaked wholesale header %q", got)
		}
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
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

func TestWholesaleStreamInjectsUsageAndKeepalive(t *testing.T) {
	prev := wholesaleKeepaliveInterval
	wholesaleKeepaliveInterval = 15 * time.Millisecond
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
}
