package router

import (
	"database/sql"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	_ "modernc.org/sqlite"
)

func TestStreamingStructuredOutputTerminalSSEErrorPassesThroughWithoutOKSettlement(t *testing.T) {
	body := `data: {"choices":[{"delta":{"content":"{\"age\":\""}}]}`
	terminal := `data: {"error":{"message":"bad age","type":"upstream_provider_error","param":"/age","code":"json_schema_validation_failed","retryable":true,"request_id":"req-downstream","inference_ran":true,"settlement_ran":true}}`
	stream := body + "\n\n" + terminal + "\n\ndata: [DONE]\n\n"
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"text/event-stream; charset=utf-8"}}, stream), nil
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_error"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), terminal) {
		t.Fatalf("terminal frame not forwarded verbatim: %s", resp.Body.String())
	}
	if strings.Contains(resp.Body.String(), "stream_malformed") {
		t.Fatalf("terminal structured error was remapped: %s", resp.Body.String())
	}
	assertNoUsageOutcome(t, dbPath, accountID, "ok")
}

func TestStreamingStructuredOutputGatewayTimeoutEmitsProviderTimeout(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		<-r.Context().Done()
		return nil, r.Context().Err()
	})}
	h, store, dbPath, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Timeouts.CoordinatorRequestSeconds = 1
	}, WithHTTPClient(client))
	accountID := "acct_stream_structured_timeout"
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, structuredStreamingRequestBody(), nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !strings.Contains(resp.Body.String(), `"code":"provider_timeout"`) ||
		!strings.Contains(resp.Body.String(), `"settlement_ran":true`) ||
		strings.Contains(resp.Body.String(), "provider_disconnected") ||
		strings.Contains(resp.Body.String(), "stream_truncated") {
		t.Fatalf("unexpected timeout SSE body: %s", resp.Body.String())
	}
	outcome, _ := usageEventOutcome(t, dbPath, accountID)
	if outcome != "provider_timeout" {
		t.Fatalf("usage outcome=%s want provider_timeout", outcome)
	}
}

func structuredStreamingRequestBody() string {
	return `{"model":"llama","stream":true,"max_tokens":20,"messages":[{"role":"user","content":"hi"}],"response_format":{"type":"json_schema","json_schema":{"name":"person-v1","strict":true,"schema":{"type":"object","properties":{"age":{"type":"integer","minimum":0}},"required":["age"],"additionalProperties":false}}}}`
}

func assertNoUsageOutcome(t *testing.T, dbPath, accountID, outcome string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	defer db.Close()
	var count int
	err = db.QueryRow(`SELECT COUNT(*) FROM usage_events WHERE account_id = ? AND outcome = ?`, accountID, outcome).Scan(&count)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		t.Fatalf("query usage_events: %v", err)
	}
	if count != 0 {
		t.Fatalf("usage_events outcome %q count=%d, want 0", outcome, count)
	}
}
