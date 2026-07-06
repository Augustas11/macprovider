package router

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

const retryChatSuccessBody = `{"id":"chatcmpl_retry","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`

func TestGatewayCoord503RetryRecoversAfterTwoNoProviderResponses(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls <= 2 {
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_recovered")

	resp := postChat(t, h, fullKey, chatBody(false), map[string]string{
		"X-Request-ID": "11111111-1111-4111-8111-111111111111",
	})

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 3 {
		t.Fatalf("coordinator calls=%d want 3", calls)
	}
	assertRetryLogCounts(t, logs.String(), 2, 1, 0)
	assertRetryMetricsContain(t, h,
		`gateway_coord_503_retry_recovered_total{request_id_class="client_supplied"} 1`,
		`gateway_coord_503_retry_recovered_total{request_id_class="gateway_generated"} 0`,
		`gateway_coord_503_retry_exhausted_total 0`,
		`gateway_coord_503_retry_backoff_ms_bucket{le="100"} 1`,
		`gateway_coord_503_retry_backoff_ms_bucket{le="+Inf"} 1`,
	)
}

func TestGatewayCoord503RetryExhaustsNoProviderResponses(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_exhausted")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "no_provider_available")
	if calls != 3 {
		t.Fatalf("coordinator calls=%d want 3", calls)
	}
	assertRetryLogCounts(t, logs.String(), 2, 0, 1)
	assertRetryMetricsContain(t, h,
		`gateway_coord_503_retry_recovered_total{request_id_class="client_supplied"} 0`,
		`gateway_coord_503_retry_recovered_total{request_id_class="gateway_generated"} 0`,
		`gateway_coord_503_retry_exhausted_total 1`,
		`gateway_coord_503_retry_backoff_ms_bucket{le="100"} 1`,
		`gateway_coord_503_retry_backoff_ms_bucket{le="+Inf"} 1`,
	)
}

func TestCapacityRejection503EchoesRequestIDAndSettlesAfterRetryExhaustion(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, http.Header{
			"Content-Type": []string{"application/json"},
			"X-Request-ID": []string{"99999999-9999-4999-8999-999999999999"},
		}, noProviderBody()), nil
	})}
	h, store, dbPath, cfg := newRetryHarness(t, client, nil)
	accountID := "acct_retry_exhausted_settled"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	requestID := "33333333-3333-4333-8333-333333333333"
	resp := postChat(t, h, fullKey, chatBody(false), map[string]string{"X-Request-ID": requestID})

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 3 {
		t.Fatalf("coordinator calls=%d want 3", calls)
	}
	values := resp.Header().Values("X-Request-ID")
	if len(values) != 1 || values[0] != requestID {
		t.Fatalf("response X-Request-ID values=%q, want only gateway request id %q", values, requestID)
	}
	outcome, source, completion, prompt := usageEventOutcomeAndTokens(t, dbPath, accountID)
	if outcome != "no_provider_available" || source != "gateway_estimated" || completion != 0 || prompt <= 0 {
		t.Fatalf("usage row outcome/source/completion/prompt = %s/%s/%d/%d, want no_provider_available/gateway_estimated/0/>0", outcome, source, completion, prompt)
	}
}

func TestCoordinatorSuppliedRetryExhaustedHeaderDoesNotSettle(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusServiceUnavailable, http.Header{
			"Content-Type":                          []string{"application/json"},
			"X-MacProvider-Gateway-Retry-Exhausted": []string{"true"},
		}, noProviderBody()), nil
	})}
	h, store, dbPath, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Retry503.Enabled = false
	})
	accountID := "acct_retry_exhausted_header_spoof"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertNoUsageEventsForAccount(t, dbPath, accountID)
}

func TestGatewayCoord503RetryExhaustedEmptyBodyRefunds(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, nil, ""), nil
	})}
	h, store, dbPath, cfg := newRetryHarness(t, client, nil)
	accountID := "acct_retry_exhausted_empty_body"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 3 {
		t.Fatalf("coordinator calls=%d want 3", calls)
	}
	assertErrorCode(t, resp.Body.String(), "no_provider_available")
	assertNoUsageEventsForAccount(t, dbPath, accountID)
}

func TestGatewayCoord503RetryMetricsUsesGatewayGeneratedRequestIDClass(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_generated_id")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertRetryMetricsContain(t, h,
		`gateway_coord_503_retry_recovered_total{request_id_class="client_supplied"} 0`,
		`gateway_coord_503_retry_recovered_total{request_id_class="gateway_generated"} 1`,
		`gateway_coord_503_retry_backoff_ms_bucket{le="+Inf"} 1`,
	)
}

func TestGatewayRetryMetricsBypassAllPublicKillSwitch(t *testing.T) {
	h, _, _, _ := newRetryHarness(t, nil, func(cfg *config.Config) {
		cfg.KillSwitch.AllPublicAPI = true
	})

	assertRetryMetricsContain(t, h,
		`gateway_coord_503_retry_recovered_total{request_id_class="client_supplied"} 0`,
		`gateway_coord_503_retry_recovered_total{request_id_class="gateway_generated"} 0`,
		`gateway_coord_503_retry_exhausted_total 0`,
		`gateway_coord_503_retry_backoff_ms_bucket{le="+Inf"} 0`,
	)
}

func TestGatewayCoord503RetrySkipsTier2PolicyError(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	body := `{"error":{"code":"tier2_hash_verified_required","message":"tier2 policy rejected request","param":null,"type":"service_unavailable"}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_tier2")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1", calls)
	}
	if !strings.Contains(resp.Body.String(), `"code":"tier2_hash_verified_required"`) {
		t.Fatalf("coordinator tier2 body not preserved: %s", resp.Body.String())
	}
	assertRetryLogCounts(t, logs.String(), 0, 0, 0)
}

func TestGatewayCoord502RetryRecoversAfterTransientProviderError(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	body := `{"error":{"code":"provider_disconnected","message":"Selected provider disconnected; buyer should retry","param":null,"type":"api_error"}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls <= 2 {
			return responseWithBody(http.StatusBadGateway, http.Header{"Content-Type": []string{"application/json"}}, body), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_502_recovered")

	resp := postChat(t, h, fullKey, chatBody(false), map[string]string{
		"X-Request-ID": "22222222-2222-4222-8222-222222222222",
	})

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 3 {
		t.Fatalf("coordinator calls=%d want 3", calls)
	}
	assertRetryLogCounts(t, logs.String(), 2, 1, 0)
}

func TestGatewayCoord502RetrySkipsStructuredOutputProviderError(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	body := `{"error":{"code":"malformed_json_response","message":"bad json","param":null,"type":"upstream_provider_error","inference_ran":true,"settlement_ran":true}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusBadGateway, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_502_structured")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1", calls)
	}
	assertRetryLogCounts(t, logs.String(), 0, 0, 0)
}

func TestGatewayCoord503RetrySkipsNullUsageProviderError(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	body := `{"error":{"code":"error_model_not_loaded","message":"model not loaded","param":null,"type":"api_error"}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_null_usage")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1", calls)
	}
	assertErrorCode(t, resp.Body.String(), "error_model_not_loaded")
	assertRetryLogCounts(t, logs.String(), 0, 0, 0)
}

func TestGatewayCoord503RetryNoLogsOnFirstAttemptSuccess(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_first_success")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1", calls)
	}
	assertRetryLogCounts(t, logs.String(), 0, 0, 0)
}

func TestGatewayCoord503RetryDisabledKeepsSingleDispatch(t *testing.T) {
	logs := captureRetryLogs(t)
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Retry503.Enabled = false
	})
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_disabled")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1", calls)
	}
	assertRetryLogCounts(t, logs.String(), 0, 0, 0)
}

func TestGatewayCoord503RetryAttemptsRespectRequestRateLimit(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Quotas.AccountRequestRatePerSecond = 1
	})
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_rate_limited")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "no_provider_available")
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1; retry attempts must not multiply request-start rate", calls)
	}
}

func TestGatewayCoord503RetryReplaysIdenticalRequestBodies(t *testing.T) {
	var calls int
	var seen [][]byte
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		body, err := io.ReadAll(r.Body)
		if err != nil {
			t.Fatalf("read attempt body: %v", err)
		}
		seen = append(seen, body)
		if calls <= 2 {
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_replay")
	wantBody := chatBody(false)

	resp := postChat(t, h, fullKey, wantBody, nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if len(seen) != 3 {
		t.Fatalf("captured bodies=%d want 3", len(seen))
	}
	for i, got := range seen {
		if !bytes.Equal(got, []byte(wantBody)) {
			t.Fatalf("attempt %d body=%q want %q", i+1, string(got), wantBody)
		}
	}
}

func TestGatewayCoord503RetryPreservesConcurrencyReservationAcrossAttempts(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls <= 2 {
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	_, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_reservation")
	spy := &retryReservationSpyStore{Store: store}
	h := New(cfg, spy, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(client)).Handler()

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 3 {
		t.Fatalf("coordinator calls=%d want 3", calls)
	}
	if spy.reserveCalls != 1 || spy.acquireCalls != 1 {
		t.Fatalf("reservation calls reserve=%d acquire=%d, want one each", spy.reserveCalls, spy.acquireCalls)
	}
	if spy.refundCalls != 0 {
		t.Fatalf("RefundReservation calls=%d, want 0 before/after recovered retry", spy.refundCalls)
	}
	if spy.releaseCalls != 1 {
		t.Fatalf("ReleaseConcurrency calls=%d, want 1 terminal release only", spy.releaseCalls)
	}
}

func TestGatewayCoord503RetryAppliesBeforeStreamingSplit(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		calls++
		if calls == 1 {
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, "data: {\"id\":\"chatcmpl\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":4,\"total_tokens\":7},\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_stream")

	resp := postChat(t, h, fullKey, chatBody(true), nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 2 {
		t.Fatalf("coordinator calls=%d want 2", calls)
	}
	if strings.Contains(resp.Body.String(), "no_provider_available") || !strings.Contains(resp.Body.String(), "data:") {
		t.Fatalf("stream response mixed retry error with terminal stream: %s", resp.Body.String())
	}
}

func TestGatewayCoord503RetryDefaultBackoffBound(t *testing.T) {
	cfg := config.Default().Retry503
	for i := 0; i < 200; i++ {
		total := coord503RetryBackoff(1, cfg) + coord503RetryBackoff(2, cfg)
		if total > 750*time.Millisecond {
			t.Fatalf("default total retry backoff=%s exceeds 750ms", total)
		}
	}
}

func TestGatewayCoord503RetrySleepStopsOnBuyerCancel(t *testing.T) {
	var calls atomic.Int32
	firstAttemptReturned := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(firstAttemptReturned)
		}
		return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Retry503.BackoffBaseMs = 5000
		cfg.Retry503.BackoffMaxMs = 5000
	})
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_cancel")
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(chatBody(false))).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		h.ServeHTTP(resp, req)
		close(done)
	}()
	select {
	case <-firstAttemptReturned:
	case <-time.After(time.Second):
		t.Fatal("first coordinator attempt was not reached")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("handler did not return promptly after buyer cancel during retry sleep")
	}
	if got := calls.Load(); got != 1 {
		t.Fatalf("coordinator calls=%d want 1; retry sleep should be cancellable before second attempt", got)
	}
}

func TestGatewayCoord503RetryCancelDoesNotConsumeRetryRateToken(t *testing.T) {
	var calls atomic.Int32
	firstAttemptReturned := make(chan struct{})
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if calls.Add(1) == 1 {
			close(firstAttemptReturned)
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, noProviderBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Quotas.AccountRequestRatePerSecond = 2
		cfg.Retry503.BackoffBaseMs = 5000
		cfg.Retry503.BackoffMaxMs = 5000
	})
	fullKey := createAccountAndKey(t, store, cfg, "acct_retry_cancel_rate")
	ctx, cancel := context.WithCancel(context.Background())
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(chatBody(false))).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+fullKey)
	req.Header.Set("Content-Type", "application/json")
	resp := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		h.ServeHTTP(resp, req)
		close(done)
	}()
	select {
	case <-firstAttemptReturned:
	case <-time.After(time.Second):
		t.Fatal("first coordinator attempt was not reached")
	}
	cancel()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("handler did not return promptly after buyer cancel during retry sleep")
	}

	second := postChat(t, h, fullKey, chatBody(false), nil)
	if second.Code != http.StatusOK {
		t.Fatalf("second request status=%d body=%s; canceled retry sleep must not consume request-rate token", second.Code, second.Body.String())
	}
	if got := calls.Load(); got != 2 {
		t.Fatalf("coordinator calls=%d want 2; second request should reach upstream", got)
	}
}

func TestGatewayRetry503ConfigValidationViaLoad(t *testing.T) {
	for _, tc := range []struct {
		name       string
		retryYAML  string
		wantSubstr string
	}{
		{name: "max attempts zero", retryYAML: "max_attempts: 0\n  backoff_base_ms: 100\n  backoff_max_ms: 500", wantSubstr: "retry_503.max_attempts"},
		{name: "max attempts too high", retryYAML: "max_attempts: 11\n  backoff_base_ms: 100\n  backoff_max_ms: 500", wantSubstr: "retry_503.max_attempts"},
		{name: "base too low", retryYAML: "max_attempts: 3\n  backoff_base_ms: 5\n  backoff_max_ms: 500", wantSubstr: "retry_503.backoff_base_ms"},
		{name: "max too high", retryYAML: "max_attempts: 3\n  backoff_base_ms: 100\n  backoff_max_ms: 15000", wantSubstr: "retry_503.backoff_max_ms"},
		{name: "max below base", retryYAML: "max_attempts: 3\n  backoff_base_ms: 500\n  backoff_max_ms: 100", wantSubstr: "retry_503.backoff_max_ms must be >="},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := writeRetryConfig(t, "enabled: true\n  "+tc.retryYAML)
			_, err := config.Load(path)
			if err == nil || !strings.Contains(err.Error(), tc.wantSubstr) {
				t.Fatalf("Load error=%v want containing %q", err, tc.wantSubstr)
			}
		})
	}
}

func newRetryHarness(t *testing.T, client *http.Client, mutate func(*config.Config)) (http.Handler, *sqlite.Store, string, config.Config) {
	t.Helper()
	return newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Retry503.BackoffBaseMs = 10
		cfg.Retry503.BackoffMaxMs = 10
		if mutate != nil {
			mutate(cfg)
		}
	}, WithHTTPClient(client))
}

func captureRetryLogs(t *testing.T) *bytes.Buffer {
	t.Helper()
	var buf bytes.Buffer
	old := slog.Default()
	slog.SetDefault(slog.New(slog.NewTextHandler(&buf, nil)))
	t.Cleanup(func() { slog.SetDefault(old) })
	return &buf
}

func assertRetryLogCounts(t *testing.T, logs string, retry, recovered, exhausted int) {
	t.Helper()
	if got := strings.Count(logs, `msg="gateway coord retry"`); got != retry {
		t.Fatalf("retry log count=%d want %d logs:\n%s", got, retry, logs)
	}
	if got := strings.Count(logs, `msg="gateway coord retry recovered"`); got != recovered {
		t.Fatalf("recovered log count=%d want %d logs:\n%s", got, recovered, logs)
	}
	if got := strings.Count(logs, `msg="gateway coord retry exhausted"`); got != exhausted {
		t.Fatalf("exhausted log count=%d want %d logs:\n%s", got, exhausted, logs)
	}
}

func assertRetryMetricsContain(t *testing.T, h http.Handler, wants ...string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("metrics status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("Content-Type"); !strings.HasPrefix(got, "text/plain; version=0.0.4") {
		t.Fatalf("metrics content-type=%q", got)
	}
	body := resp.Body.String()
	for _, want := range wants {
		if !strings.Contains(body, "\n"+want+"\n") {
			t.Fatalf("metrics missing %q in:\n%s", want, body)
		}
	}
}

func noProviderBody() string {
	return `{"error":{"code":"no_provider_available","message":"No provider available","param":null,"type":"service_unavailable"}}`
}

func chatBody(stream bool) string {
	if stream {
		return `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
	}
	return `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`
}

type retryReservationSpyStore struct {
	*sqlite.Store
	reserveCalls int
	acquireCalls int
	refundCalls  int
	releaseCalls int
}

func (s *retryReservationSpyStore) ReserveQuota(ctx context.Context, req storage.ReservationRequest) (storage.QuotaDecision, error) {
	s.reserveCalls++
	return s.Store.ReserveQuota(ctx, req)
}

func (s *retryReservationSpyStore) AcquireConcurrency(ctx context.Context, req storage.ConcurrencyRequest) (storage.ConcurrencyDecision, error) {
	s.acquireCalls++
	return s.Store.AcquireConcurrency(ctx, req)
}

func (s *retryReservationSpyStore) RefundReservation(ctx context.Context, accountID, requestID string, refundedAt int64) error {
	s.refundCalls++
	return s.Store.RefundReservation(ctx, accountID, requestID, refundedAt)
}

func (s *retryReservationSpyStore) ReleaseConcurrency(ctx context.Context, accountID, requestID string, releasedAt time.Time) error {
	s.releaseCalls++
	return s.Store.ReleaseConcurrency(ctx, accountID, requestID, releasedAt)
}

func writeRetryConfig(t *testing.T, retryBlock string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "gateway.yaml")
	content := fmt.Sprintf(`
listen:
  bind_address: 127.0.0.1
  port: 9443
proxy:
  trusted_cidrs:
    - 127.0.0.1/32
public:
  base_url: https://example.com
  account_path: /account
coordinator:
  buyer_url: https://buyer.example
  operator_url: https://op.example
  operator_key: operator-secret
  poolz_poll_interval_s: 5
storage:
  driver: sqlite
  db_path: /tmp/test.db
auth:
  key_prefix: mp_
  key_hash: hmac_sha256
  key_hash_secret: secret
  github_oauth_enabled: false
  demo:
    signing_secret: demo-secret
  oauth:
    callback_allowlist:
      - https://example.com/auth/github/callback
quotas:
  account_daily_tokens: 100000
  demo_daily_tokens_per_ip: 1000
  demo_sessions_per_ip_per_hour: 10
  account_concurrency: 2
  demo_concurrency: 2
  signup_accounts_per_ip_per_day: 3
  reaper_interval_hours: 1
  reservation_max_age_hours: 24
retry_503:
  %s
`, retryBlock)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write config: %v", err)
	}
	return path
}
