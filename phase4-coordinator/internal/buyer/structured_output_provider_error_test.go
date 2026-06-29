package buyer_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/buyer"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
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
