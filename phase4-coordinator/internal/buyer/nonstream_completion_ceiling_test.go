package buyer_test

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

// SPEC-005 §5.3/§6.8: a successful non-streaming attempt clamps a
// provider-reported completion to the response body length (one byte per
// token), not to the /16 streaming estimate; an unreported completion keeps
// the /16 estimate.

// chatBodyOfSize is a chat completion of exactly size bytes. completion < 0
// omits completion_tokens from usage.
func chatBodyOfSize(t *testing.T, size int, completion int64) []byte {
	t.Helper()
	build := func(pad int) []byte {
		usage := `{"prompt_tokens":4}`
		if completion >= 0 {
			usage = fmt.Sprintf(`{"prompt_tokens":4,"completion_tokens":%d,"total_tokens":%d}`, completion, completion+4)
		}
		return []byte(fmt.Sprintf(`{"id":"ok","object":"chat.completion","choices":[{"index":0,"message":{"role":"assistant","content":"%s"},"finish_reason":"stop"}],"usage":%s}`, strings.Repeat("a", pad), usage))
	}
	pad := size - len(build(0))
	if pad < 0 {
		t.Fatalf("body size %d below envelope size %d", size, len(build(0)))
	}
	body := build(pad)
	if len(body) != size {
		t.Fatalf("body size=%d want %d", len(body), size)
	}
	return body
}

type ceilingLedgerRow struct {
	completion sql.NullInt64
	estimate   sql.NullInt64
	usage      string
	gross      int64
}

func latestCeilingLedgerRow(t *testing.T, dbPath string) ceilingLedgerRow {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var row ceilingLedgerRow
	if err := db.QueryRow(`SELECT completion_tokens, estimated_completion_tokens, usage_source, gross_credits FROM ledger_request_credits ORDER BY id DESC LIMIT 1`).
		Scan(&row.completion, &row.estimate, &row.usage, &row.gross); err != nil {
		t.Fatalf("query ledger: %v", err)
	}
	return row
}

type nonStreamCeilingCase struct {
	name           string
	body           []byte
	reported       int64 // < 0: completion not reported
	wantEstimate   int64
	wantBilledComp int64
}

// nonStreamCeilingCases are the table for a coordinator whose
// tier2.output_bytes_per_token_ceiling resolves to bytesPerToken.
func nonStreamCeilingCases(t *testing.T, bytesPerToken int64) []nonStreamCeilingCase {
	honest := chatBodyOfSize(t, 1800, 400)
	inflated := chatBodyOfSize(t, 1800, 5000)
	unreported := chatBodyOfSize(t, 1800, -1)
	return []nonStreamCeilingCase{
		{name: "honest report under the body ceiling bills the report", body: honest, reported: 400, wantEstimate: 1800, wantBilledComp: 400},
		{name: "inflated report clamps to body bytes", body: inflated, reported: 5000, wantEstimate: 1800, wantBilledComp: 1800},
		{name: "unreported completion keeps the /16 estimate", body: unreported, reported: -1, wantEstimate: (1800 + bytesPerToken - 1) / bytesPerToken, wantBilledComp: (1800 + bytesPerToken - 1) / bytesPerToken},
	}
}

func TestNonStreamingCompletionCeilingIsBodyBytes(t *testing.T) {
	for _, tc := range nonStreamCeilingCases(t, 16) {
		t.Run(tc.name, func(t *testing.T) {
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write(tc.body)
			}))
			defer upstream.Close()
			reqLog, dbPath := openBuyerRequestLog(t)
			defer reqLog.Close()
			billingStore, err := billing.NewStore(reqLog.DB())
			if err != nil {
				t.Fatalf("billing.NewStore: %v", err)
			}
			setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
			rewards := config.RewardsConfig{
				GlobalMultiplier: 1.0,
				ProviderShare:    0.90,
				RateCard: map[string]config.RateCardEntry{
					"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
				},
			}
			registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
			registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
				buyer.WithRequestLog(reqLog),
				buyer.WithBilling(billingStore, rewards),
				buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
			)
			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), nil)
			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			row := latestCeilingLedgerRow(t, dbPath)
			if !row.estimate.Valid || row.estimate.Int64 != tc.wantEstimate {
				t.Fatalf("estimated_completion_tokens=%v want %d", row.estimate, tc.wantEstimate)
			}
			if tc.reported >= 0 && (!row.completion.Valid || row.completion.Int64 != tc.reported) {
				t.Fatalf("stored provider completion=%v want %d", row.completion, tc.reported)
			}
			if tc.reported < 0 && row.completion.Valid {
				t.Fatalf("stored provider completion=%v want NULL", row.completion)
			}
			// The hot path labels every estimate-carrying row byte_estimated
			// (formula.go usageFor); the credited completion is what moves.
			if row.usage != billing.UsageByteEstimated {
				t.Fatalf("usage_source=%q want byte_estimated", row.usage)
			}
			if want := 4 + 2*tc.wantBilledComp; row.gross != want {
				t.Fatalf("gross_credits=%d want %d (completion %d)", row.gross, want, tc.wantBilledComp)
			}
		})
	}
}

func TestWSNonStreamingCompletionCeilingIsBodyBytes(t *testing.T) {
	// The settlement harness configures no output ceiling, so the unreported
	// estimate uses the defensive 4-byte fallback; only its basis is unchanged.
	for _, tc := range nonStreamCeilingCases(t, 4) {
		t.Run(tc.name, func(t *testing.T) {
			h := newBuyerCancelHarness(t, "ws-nonstream-ceiling-catalog", func(h *buyerCancelHarness, ctx context.Context, requestID string, meta *providerws.SettlementReceiptMetadata) *providerws.RelayStream {
				chunks := make(chan providerws.InferenceResponseChunk, 1)
				done := make(chan providerws.InferenceResponseEnd, 1)
				chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Data: string(tc.body)}
				close(chunks)
				end := providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
				if tc.reported >= 0 {
					end.Usage = json.RawMessage(fmt.Sprintf(`{"prompt_tokens":4,"completion_tokens":%d,"total_tokens":%d}`, tc.reported, tc.reported+4))
				}
				done <- end
				return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: make(chan error, 1)}
			})
			rr := h.post(t, []byte(deliveredOnlyChatBody))
			if rr.Code != http.StatusOK {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			row := latestCeilingLedgerRow(t, h.dbPath)
			if !row.estimate.Valid || row.estimate.Int64 != tc.wantEstimate {
				t.Fatalf("estimated_completion_tokens=%v want %d", row.estimate, tc.wantEstimate)
			}
			if tc.reported >= 0 && (!row.completion.Valid || row.completion.Int64 != tc.reported) {
				t.Fatalf("stored provider completion=%v want %d", row.completion, tc.reported)
			}
		})
	}
}

// The streaming estimate stays ceil(delivered SSE bytes / 16) and is still
// attached to a reported-usage row.
func TestStreamingCompletionEstimateUnchangedByNonStreamCeiling(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\n"))
		_, _ = w.Write([]byte("data: {\"id\":\"chunk\",\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":1,\"total_tokens\":4},\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"))
		_, _ = w.Write([]byte("data: [DONE]\n\n"))
	}))
	defer upstream.Close()
	reqLog, dbPath := openBuyerRequestLog(t)
	defer reqLog.Close()
	billingStore, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}
	rewards := config.RewardsConfig{GlobalMultiplier: 1.0, ProviderShare: 0.90, RateCard: map[string]config.RateCardEntry{
		"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
	}}
	registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
	registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
	server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
		buyer.WithRequestLog(reqLog),
		buyer.WithBilling(billingStore, rewards),
		buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
	)
	rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"hello"}]}`), nil)
	if rr.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
	}
	row := latestCeilingLedgerRow(t, dbPath)
	delivered := int64(rr.Body.Len())
	if !row.estimate.Valid || row.estimate.Int64 != (delivered+15)/16 {
		t.Fatalf("streaming estimated_completion_tokens=%v want ceil(%d/16)=%d", row.estimate, delivered, (delivered+15)/16)
	}
	if !row.completion.Valid || row.completion.Int64 != 1 {
		t.Fatalf("streaming completion=%v want 1", row.completion)
	}
}

// toolCallJSONOfSize is a provider JSON tool-call completion of exactly size
// bytes reporting completion tokens.
func toolCallJSONOfSize(t *testing.T, size int, completion int64) []byte {
	t.Helper()
	build := func(pad int) []byte {
		return []byte(fmt.Sprintf(`{"id":"chatcmpl-test","object":"chat.completion","created":1716768000,"model":"model-a","choices":[{"index":0,"message":{"role":"assistant","content":null,"tool_calls":[{"id":"call_0123456789abcdef","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo %s\"}"}}]},"finish_reason":"tool_calls"}],"usage":{"prompt_tokens":4,"completion_tokens":%d,"total_tokens":%d}}`, strings.Repeat("a", pad), completion, completion+4))
	}
	pad := size - len(build(0))
	if pad < 0 {
		t.Fatalf("body size %d below envelope size %d", size, len(build(0)))
	}
	return build(pad)
}

// A streaming tool-call request the provider answers with one JSON body is
// clamped to that body's length, not to /16 of the rendered SSE.
func TestStreamingToolCallJSONCompletionCeilingIsProviderBodyBytes(t *testing.T) {
	for _, tc := range []struct {
		name           string
		reported       int64
		wantBilledComp int64
	}{
		{name: "honest report bills the report", reported: 400, wantBilledComp: 400},
		{name: "inflated report clamps to the provider body length", reported: 5000, wantBilledComp: 1800},
	} {
		t.Run(tc.name, func(t *testing.T) {
			body := toolCallJSONOfSize(t, 1800, tc.reported)
			upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write(body)
			}))
			defer upstream.Close()
			reqLog, dbPath := openBuyerRequestLog(t)
			defer reqLog.Close()
			billingStore, err := billing.NewStore(reqLog.DB())
			if err != nil {
				t.Fatalf("billing.NewStore: %v", err)
			}
			setSettlementModeForTest(billingStore, billing.RouteSnapshotModeObserve)
			rewards := config.RewardsConfig{GlobalMultiplier: 1.0, ProviderShare: 0.90, RateCard: map[string]config.RateCardEntry{
				"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
			}}
			registry := pool.NewRegistry([]config.ProviderConfig{{ProviderID: "p1", EndpointURL: upstream.URL}})
			registerWithEndpoint(registry, "p1", "s1", "model-a", pool.StateReady, 20000, 1, upstream.URL, 20)
			server := buyer.NewServer(registry, zerolog.Nop(), time.Unix(1716768000, 0),
				buyer.WithRequestLog(reqLog),
				buyer.WithBilling(billingStore, rewards),
				buyer.WithTier2Config(config.Tier2Config{OutputBytesPerTokenCeiling: 16}),
			)
			rr := postChat(t, server, []byte(`{"model":"model-a","stream":true,"messages":[{"role":"user","content":"run echo"}],"tools":[{"type":"function","function":{"name":"bash","parameters":{"type":"object","properties":{"command":{"type":"string"}}}}}]}`), nil)
			if rr.Code != http.StatusOK || !strings.Contains(rr.Body.String(), "data: ") {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			row := latestCeilingLedgerRow(t, dbPath)
			if !row.estimate.Valid || row.estimate.Int64 != 1800 {
				t.Fatalf("estimated_completion_tokens=%v want the provider body length 1800", row.estimate)
			}
			if !row.completion.Valid || row.completion.Int64 != tc.reported {
				t.Fatalf("stored provider completion=%v want %d", row.completion, tc.reported)
			}
			if want := 4 + 2*tc.wantBilledComp; row.gross != want {
				t.Fatalf("gross_credits=%d want %d (completion %d)", row.gross, want, tc.wantBilledComp)
			}
		})
	}
}
