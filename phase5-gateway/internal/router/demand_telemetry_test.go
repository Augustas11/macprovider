package router

import (
	"context"
	"database/sql"
	"errors"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestDemandTelemetryRecordsNoProviderAttempt(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		return responseWithBody(http.StatusServiceUnavailable, markedNoProviderHeaders(), noProviderBody()), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_no_provider"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}

	rows, err := store.DemandSummary(context.Background(), storage.DemandSummaryQuery{
		Model:        "llama",
		TrafficClass: "paid",
	})
	if err != nil {
		t.Fatalf("DemandSummary: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("DemandSummary rows=%d want 1: %+v", len(rows), rows)
	}
	row := rows[0]
	if row.RequestedRequests != 1 || row.ServedRequests != 0 || row.CapacityConstrainedRequests != 1 {
		t.Fatalf("summary = %+v, want one capacity-constrained attempted request", row)
	}
	if row.DistinctBuyers != 1 || row.RepeatBuyers != 0 {
		t.Fatalf("buyer summary = distinct %d repeat %d, want 1/0", row.DistinctBuyers, row.RepeatBuyers)
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.TerminalResult != "failure" || event.FailureReason != "all_providers_busy" || !event.EligibleProviderExists {
		t.Fatalf("event = %+v, want busy capacity with eligible provider existence", event)
	}
	if event.RequestedOutputTokens != 20 || event.RequestedTotalTokens < 20 {
		t.Fatalf("requested token exposure = %+v, want max output 20 included", event)
	}
}

func TestDemandTelemetryTenantQuotaDoesNotInflateCapacity(t *testing.T) {
	_, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(noopClient()))
	accountID := "acct_demand_quota"
	key := createAccountAndKey(t, store, cfg, accountID)
	fakeStore := &quotaReserveFakeStore{
		Store: store,
		decision: storage.QuotaDecision{
			LimitTokens: 1000, UsedTokens: 1000, RemainingTokens: 0,
			ResetUnix: resetUnix(fixedNow().UTC().Format("2006-01-02")),
		},
		err: errors.New("quota exhausted"),
	}
	h := New(cfg, fakeStore, fakeOAuth{}, WithNow(fixedNow), WithHTTPClient(noopClient())).Handler()

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d want 429 body=%s", resp.Code, resp.Body.String())
	}

	rows, err := store.DemandSummary(context.Background(), storage.DemandSummaryQuery{Model: "llama", TrafficClass: "paid"})
	if err != nil {
		t.Fatalf("DemandSummary: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("DemandSummary rows=%d want 1: %+v", len(rows), rows)
	}
	row := rows[0]
	if row.RequestedRequests != 1 || row.ServedRequests != 0 || row.CapacityConstrainedRequests != 0 || row.UnmetRequests != 0 {
		t.Fatalf("summary = %+v, want tenant rejection outside capacity/unmet provider buckets", row)
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.FailureReason != "quota_exhausted" || event.EligibleProviderExists {
		t.Fatalf("event = %+v, want quota_exhausted with no provider-existence claim", event)
	}
}

func TestDemandTelemetryRecordsStreamingTerminalError(t *testing.T) {
	terminal := structuredTerminalSSE("provider_timeout") + "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream"}}, terminal), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_stream_terminal"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want committed stream 200 body=%s", resp.Code, resp.Body.String())
	}

	rows, err := store.DemandSummary(context.Background(), storage.DemandSummaryQuery{Model: "llama", TrafficClass: "paid"})
	if err != nil {
		t.Fatalf("DemandSummary: %v", err)
	}
	if len(rows) != 1 || rows[0].ServedRequests != 0 || rows[0].CapacityConstrainedRequests != 0 {
		t.Fatalf("summary = %+v, want terminal provider failure outside served/capacity", rows)
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.TerminalResult != "timeout" || event.FailureReason != "upstream_provider_failure" || !event.EligibleProviderExists {
		t.Fatalf("event = %+v, want provider timeout", event)
	}
}

func TestDemandTelemetryEmptyToolsArrayIsNotToolDemand(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		return responseWithBody(http.StatusServiceUnavailable, markedNoProviderHeaders(), noProviderBody()), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_empty_tools"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"tools":[],"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.ToolsRequested {
		t.Fatalf("event = %+v, want empty tools array to stay tools_requested=false", event)
	}
}

func TestDemandTelemetryRecordsRoutedModelSubstitution(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		body := `{"id":"chatcmpl-demand-sub","object":"chat.completion","model":"qwen","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":3,"prompt_tokens_details":{"cached_tokens":1},"completion_tokens":2,"completion_tokens_details":{"reasoning_tokens":1},"total_tokens":5}}`
		headers := http.Header{"Content-Type": []string{"application/json"}}
		return responseWithBody(http.StatusOK, headers, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_substitution"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}

	rows, err := store.DemandSummary(context.Background(), storage.DemandSummaryQuery{Model: "llama", TrafficClass: "paid"})
	if err != nil {
		t.Fatalf("DemandSummary: %v", err)
	}
	if len(rows) != 1 || rows[0].ServedRequests != 1 || rows[0].SubstitutedRequests != 1 {
		t.Fatalf("summary = %+v, want served substitution", rows)
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.RoutedModel != "qwen" || !event.Substituted || event.CachedPromptTokens != 1 || event.ReasoningTokens != 1 {
		t.Fatalf("event = %+v, want routed qwen substitution with cached/reasoning tokens", event)
	}
}

func TestDemandTelemetryRejectsProviderControlledModelText(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		body := `{"id":"chatcmpl-demand-bad-model","object":"chat.completion","model":"llama leaked content","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}`
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_bad_provider_model"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.RoutedModel != demandInvalidModelID || !event.Substituted {
		t.Fatalf("event=%+v, want unsafe provider model bucketed as invalid substitution", event)
	}
}

func TestDemandTelemetryBucketsUnknownRequestedModelAndInvalidProviderID(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		headers := markedNoProviderHeaders()
		headers.Set("X-MacProvider-Provider", "provider_id=p1 raw_prompt=secret")
		return responseWithBody(http.StatusServiceUnavailable, headers, noProviderBody()), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_unknown_requested_model"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"sk-live-secret-model","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.RequestedModel != demandUnknownModelID || event.ProviderID != "" {
		t.Fatalf("event=%+v, want unknown model bucket and dropped invalid provider id", event)
	}
}

func TestDemandTelemetryRecordsStreamingRoutedModelSubstitution(t *testing.T) {
	stream := strings.Join([]string{
		`data: {"id":"chatcmpl-demand-stream-sub","object":"chat.completion.chunk","model":"qwen","choices":[{"delta":{"content":"ok"},"index":0}]}`,
		`data: {"id":"chatcmpl-demand-stream-sub","object":"chat.completion.chunk","model":"qwen","choices":[{"delta":{},"finish_reason":"stop","index":0}],"usage":{"prompt_tokens":3,"prompt_tokens_details":{"cached_tokens":1},"completion_tokens":2,"total_tokens":5}}`,
		`data: [DONE]`,
		``,
	}, "\n\n")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_stream_substitution"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.RoutedModel != "qwen" || !event.Substituted || event.CachedPromptTokens != 1 {
		t.Fatalf("event = %+v, want streaming routed qwen substitution with cached tokens", event)
	}
}

func TestDemandTelemetryRecordsNonStreamingFinalityHoldEstimatedUsage(t *testing.T) {
	responseBody := `{"id":"chatcmpl-demand-finality","object":"chat.completion","model":"llama","choices":[{"message":{"role":"assistant","content":"ok"},"finish_reason":"stop","index":0}]}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		headers := settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "verified", "valid", "true", "receipt_verified")
		headers.Set("Content-Type", "application/json")
		return responseWithBody(http.StatusOK, headers, responseBody), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_finality_hold_estimated"
	key := createAccountAndKey(t, store, cfg, accountID)
	requestBody := `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`

	resp := postChat(t, h, key, requestBody, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	wantPrompt := event.RequestedTotalTokens - event.RequestedOutputTokens
	if event.TerminalResult != "success" || event.PromptTokens != wantPrompt || event.CompletionTokens != 0 || event.TotalTokens != wantPrompt {
		t.Fatalf("event = %+v, want finality hold to record gateway-estimated prompt-only usage", event)
	}
}

func TestDemandTelemetryRecordsStreamingFinalityHoldEstimatedUsage(t *testing.T) {
	content := "ok"
	stream := strings.Join([]string{
		`data: {"id":"chatcmpl-demand-stream-finality","object":"chat.completion.chunk","model":"llama","choices":[{"delta":{"content":"` + content + `"},"index":0}]}`,
		`data: [DONE]`,
		``,
	}, "\n\n")
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		trailer := settlementFinalityTrailerForTest("enforce", settlementPolicyVersion, "verified", "valid", "true", "receipt_verified")
		return &http.Response{
			StatusCode: http.StatusOK,
			Header: http.Header{
				"Content-Type": []string{"text/event-stream"},
				"Trailer":      []string{strings.Join(settlementFinalityHeaderNamesForTest(), ", ")},
			},
			Trailer: trailer,
			Body:    io.NopCloser(strings.NewReader(stream)),
		}, nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_stream_finality_hold_estimated"
	key := createAccountAndKey(t, store, cfg, accountID)
	requestBody := `{"model":"llama","stream":true,"max_tokens":200,"messages":[{"role":"user","content":"hi"}]}`

	resp := postChat(t, h, key, requestBody, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	wantPrompt := event.RequestedTotalTokens - event.RequestedOutputTokens
	if event.TerminalResult != "success" || event.PromptTokens != wantPrompt || event.CompletionTokens <= 0 || event.TotalTokens != event.PromptTokens+event.CompletionTokens {
		t.Fatalf("event = %+v, want finality hold to record nonzero gateway-estimated streaming usage", event)
	}
}

func TestDemandTelemetryRecordsPreDispatchEngineRoutingRejection(t *testing.T) {
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(noopClient()))
	accountID := "acct_demand_engine_reject"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, map[string]string{
		engineSelectHeader: "ollama",
	})
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.FailureReason != "trust_routing_rejection" || event.EligibleProviderExists {
		t.Fatalf("event = %+v, want pre-dispatch trust routing rejection", event)
	}
}

func TestDemandTelemetryBucketsUnknownProviderErrorCode(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/chat/completions" {
			return responseWithBody(http.StatusNotFound, nil, `{}`), nil
		}
		headers := http.Header{"X-MacProvider-Provider": []string{"provider_1"}}
		body := `{"error":{"message":"provider failed","type":"server_error","code":"provider_specific_private_detail"}}`
		return responseWithBody(http.StatusBadGateway, headers, body), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_unknown_provider_error"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d want 502 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.FailureReason != "upstream_provider_failure" || !event.EligibleProviderExists {
		t.Fatalf("event = %+v, want upstream_provider_failure with eligible provider", event)
	}
}

func TestDemandTelemetryRecordsCoordinatorUnavailableAsUpstreamFailure(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, errors.New("coordinator down")
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_demand_coordinator_unavailable"
	key := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, key, `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`, nil)
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", resp.Code, resp.Body.String())
	}
	event := readDemandEvent(t, dbPath, accountID)
	if event.FailureReason != "upstream_provider_failure" || !event.EligibleProviderExists {
		t.Fatalf("event = %+v, want coordinator outage in upstream failure bucket", event)
	}
}

type demandEventSnapshot struct {
	RequestedModel         string
	TerminalResult         string
	FailureReason          string
	EligibleProviderExists bool
	RoutedModel            string
	ProviderID             string
	Substituted            bool
	CachedPromptTokens     int64
	ReasoningTokens        int64
	ToolsRequested         bool
	RequestedOutputTokens  int64
	RequestedTotalTokens   int64
	PromptTokens           int64
	CompletionTokens       int64
	TotalTokens            int64
	TimeToFirstTokenMs     int64
	ProviderPrefillMs      int64
	ProviderDecodeMs       int64
	OutputTPSMilliTokens   int64
}

func readDemandEvent(t *testing.T, dbPath, accountID string) demandEventSnapshot {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()
	var event demandEventSnapshot
	var eligible, substituted, toolsRequested int
	err = db.QueryRow(`
		SELECT requested_model, terminal_result, failure_reason, eligible_provider_exists, routed_model, provider_id, substituted,
			tools_requested, requested_output_tokens, requested_total_tokens,
			prompt_tokens, completion_tokens, total_tokens,
			cached_prompt_tokens, reasoning_tokens, time_to_first_token_ms, provider_prefill_ms,
			provider_decode_ms, output_tps_millitokens
		FROM demand_events
		WHERE buyer_hash = ?
		ORDER BY event_id DESC
		LIMIT 1`, demandBuyerHash("test-key-hash-secret", accountID)).Scan(&event.RequestedModel, &event.TerminalResult, &event.FailureReason, &eligible, &event.RoutedModel, &event.ProviderID, &substituted,
		&toolsRequested, &event.RequestedOutputTokens, &event.RequestedTotalTokens,
		&event.PromptTokens, &event.CompletionTokens, &event.TotalTokens,
		&event.CachedPromptTokens, &event.ReasoningTokens, &event.TimeToFirstTokenMs, &event.ProviderPrefillMs,
		&event.ProviderDecodeMs, &event.OutputTPSMilliTokens)
	if err != nil {
		t.Fatalf("demand event for %s: %v", accountID, err)
	}
	event.EligibleProviderExists = eligible == 1
	event.Substituted = substituted == 1
	event.ToolsRequested = toolsRequested == 1
	return event
}

func demandEventCount(t *testing.T, dbPath, accountID string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`
		SELECT COUNT(*)
		FROM demand_events
		WHERE buyer_hash = ?`, demandBuyerHash("test-key-hash-secret", accountID)).Scan(&count); err != nil {
		t.Fatalf("count demand events for %s: %v", accountID, err)
	}
	return count
}
