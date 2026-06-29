package buyer_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
	"github.com/rs/zerolog"
)

func TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetry(t *testing.T) {
	for _, code := range []string{"malformed_json_response", "json_schema_validation_failed"} {
		t.Run(code, func(t *testing.T) {
			body := []byte(`{"error":{"message":"structured output failed","type":"upstream_provider_error","param":null,"code":"` + code + `","retryable":true,"request_id":null,"inference_ran":true,"settlement_ran":true}}`)
			var failingCalls int
			failingUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				failingCalls++
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusBadGateway)
				_, _ = w.Write(body)
			}))
			defer failingUpstream.Close()

			var fallbackCalls int
			fallbackUpstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				fallbackCalls++
				w.Header().Set("Content-Type", "application/json")
				_, _ = w.Write([]byte(`{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`))
			}))
			defer fallbackUpstream.Close()

			reqLog, dbPath := openBuyerRequestLog(t)
			defer reqLog.Close()
			billingStore, err := billing.NewStore(reqLog.DB())
			if err != nil {
				t.Fatalf("billing.NewStore: %v", err)
			}
			rewards := config.RewardsConfig{
				GlobalMultiplier: 1.0,
				ProviderShare:    0.90,
				RateCard: map[string]config.RateCardEntry{
					"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
				},
			}
			registry := pool.NewRegistry([]config.ProviderConfig{
				{ProviderID: "fail", EndpointURL: failingUpstream.URL},
				{ProviderID: "ok", EndpointURL: fallbackUpstream.URL},
			})
			registerWithEndpoint(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, failingUpstream.URL, 10)
			registerWithEndpoint(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, fallbackUpstream.URL, 20)
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithRequestLog(reqLog),
				buyer.WithBilling(billingStore, rewards),
				buyer.WithRoutingConfig(config.RoutingConfig{
					MaxRetries:              1,
					RetryPerAttemptTimeoutS: 1,
					StickyTTLS:              1800,
					StickyMaxEntries:        10000,
				}),
			)

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
				"X-MacProvider-Provider": []string{"fail"},
				"X-MacProvider-Retry":    []string{"1"},
			})

			if rr.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			if !bytes.Equal(rr.Body.Bytes(), body) {
				t.Fatalf("body=%s want byte-identical %s", rr.Body.String(), string(body))
			}
			if failingCalls != 1 || fallbackCalls != 0 {
				t.Fatalf("provider calls fail=%d fallback=%d, want fail=1 fallback=0", failingCalls, fallbackCalls)
			}
			rows := queryAllRequestLogRows(t, dbPath)
			if len(rows) != 1 {
				t.Fatalf("request_log rows=%d want 1: %#v", len(rows), rows)
			}
			if !rows[0].ErrorCode.Valid || rows[0].ErrorCode.String != code {
				t.Fatalf("error_code=%#v want %s", rows[0].ErrorCode, code)
			}
			if rows[0].Status != http.StatusBadGateway {
				t.Fatalf("logged status=%d want 502", rows[0].Status)
			}
			_, providerCredits, fault := queryBillingCredit(t, dbPath)
			if providerCredits != 0 || fault != billing.FaultBreakerQualifying {
				t.Fatalf("billing provider_credits=%d fault=%s, want 0 and %s", providerCredits, fault, billing.FaultBreakerQualifying)
			}
		})
	}
}

func TestStructuredOutputProviderDetailErrorsPassThroughWithoutRetryWS(t *testing.T) {
	for _, code := range []string{"malformed_json_response", "json_schema_validation_failed"} {
		t.Run(code, func(t *testing.T) {
			var failingCalls int
			var fallbackCalls int
			reqLog, dbPath := openBuyerRequestLog(t)
			defer reqLog.Close()
			billingStore, err := billing.NewStore(reqLog.DB())
			if err != nil {
				t.Fatalf("billing.NewStore: %v", err)
			}
			rewards := config.RewardsConfig{
				GlobalMultiplier: 1.0,
				ProviderShare:    0.90,
				RateCard: map[string]config.RateCardEntry{
					"model-a": {PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 2000000},
				},
			}
			registry := pool.NewRegistry(nil)
			registerWithPath(registry, "fail", "s1", "model-a", pool.StateReady, 20000, 1, "", 10, pool.TierProvisional, pool.InferencePathWSTunneled)
			registerWithPath(registry, "ok", "s2", "model-a", pool.StateReady, 20000, 1, "", 20, pool.TierProvisional, pool.InferencePathWSTunneled)
			retryable := true
			server := buyer.NewServer(
				registry,
				zerolog.Nop(),
				time.Unix(1716768000, 0),
				buyer.WithRequestLog(reqLog),
				buyer.WithBilling(billingStore, rewards),
				buyer.WithRoutingConfig(config.RoutingConfig{
					MaxRetries:              1,
					RetryPerAttemptTimeoutS: 1,
					StickyTTLS:              1800,
					StickyMaxEntries:        10000,
				}),
				buyer.WithRelay(func(ctx context.Context, provider pool.Provider, requestID string, body []byte, stream bool) (*providerws.RelayStream, error) {
					chunks := make(chan providerws.InferenceResponseChunk, 1)
					done := make(chan providerws.InferenceResponseEnd, 1)
					errs := make(chan error, 1)
					if provider.ProviderID == "fail" {
						failingCalls++
						done <- providerws.InferenceResponseEnd{
							Type:      "inference_response_end",
							RequestID: requestID,
							Status:    code,
							Error:     "structured output failed",
							Retryable: &retryable,
						}
						return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
					}
					fallbackCalls++
					chunks <- providerws.InferenceResponseChunk{Type: "inference_response_chunk", RequestID: requestID, Seq: 0, Data: `{"id":"ok","choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}`}
					done <- providerws.InferenceResponseEnd{Type: "inference_response_end", RequestID: requestID, Status: "complete", ChunksSent: 1}
					return &providerws.RelayStream{RequestID: requestID, Chunks: chunks, Done: done, Errors: errs}, nil
				}, time.Second),
			)

			rr := postChat(t, server, []byte(`{"model":"model-a","messages":[{"role":"user","content":"hello"}]}`), http.Header{
				"X-MacProvider-Provider": []string{"fail"},
				"X-MacProvider-Retry":    []string{"1"},
			})

			if rr.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s", rr.Code, rr.Body.String())
			}
			var envelope struct {
				Error struct {
					Message       string `json:"message"`
					Type          string `json:"type"`
					Code          string `json:"code"`
					Retryable     bool   `json:"retryable"`
					InferenceRan  bool   `json:"inference_ran"`
					SettlementRan bool   `json:"settlement_ran"`
				} `json:"error"`
			}
			if err := json.Unmarshal(rr.Body.Bytes(), &envelope); err != nil {
				t.Fatalf("response json: %v body=%s", err, rr.Body.String())
			}
			if envelope.Error.Message != "structured output failed" ||
				envelope.Error.Type != "upstream_error" ||
				envelope.Error.Code != code ||
				!envelope.Error.Retryable ||
				!envelope.Error.InferenceRan ||
				!envelope.Error.SettlementRan {
				t.Fatalf("unexpected error envelope: %#v", envelope.Error)
			}
			if failingCalls != 1 || fallbackCalls != 0 {
				t.Fatalf("provider calls fail=%d fallback=%d, want fail=1 fallback=0", failingCalls, fallbackCalls)
			}
			rows := queryAllRequestLogRows(t, dbPath)
			if len(rows) != 1 {
				t.Fatalf("request_log rows=%d want 1: %#v", len(rows), rows)
			}
			if !rows[0].ErrorCode.Valid || rows[0].ErrorCode.String != code {
				t.Fatalf("error_code=%#v want %s", rows[0].ErrorCode, code)
			}
			if rows[0].Status != http.StatusBadGateway {
				t.Fatalf("logged status=%d want 502", rows[0].Status)
			}
			_, providerCredits, fault := queryBillingCredit(t, dbPath)
			if providerCredits != 0 || fault != billing.FaultBreakerQualifying {
				t.Fatalf("billing provider_credits=%d fault=%s, want 0 and %s", providerCredits, fault, billing.FaultBreakerQualifying)
			}
		})
	}
}
