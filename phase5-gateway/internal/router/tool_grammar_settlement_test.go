package router

import (
	"net/http"
	"testing"
)

// Re-audit r1 (security, #2107): the coordinator answers a tool request whose
// serving providers cannot parse the model's tool grammar with 503
// tool_grammar_provider_unavailable. That outcome is a pre-dispatch shape like
// no_provider_available, so it must not refund a request whose earlier gateway
// attempt already dispatched (and may have credited) a provider.
func toolGrammarUnavailableBody() string {
	return `{"error":{"code":"tool_grammar_provider_unavailable","message":"No provider serving this model parses its tool-call grammar yet","param":null,"type":"service_unavailable","retryable":true}}`
}

func TestGatewayRetriedProvider502ThenToolGrammarUnavailableDoesNotRefund(t *testing.T) {
	providerFailedBody := `{"error":{"message":"Selected provider failed; buyer should retry","type":"upstream_error","param":null,"code":"provider_failed","retryable":true,"request_id":null,"inference_ran":false,"settlement_ran":false}}`
	for _, stream := range []bool{false, true} {
		name := "non_streaming"
		if stream {
			name = "streaming"
		}
		t.Run(name, func(t *testing.T) {
			var calls int
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					return responseWithBody(http.StatusBadGateway, http.Header{"Content-Type": []string{"application/json"}}, providerFailedBody), nil
				}
				// A fresh coordinator request finds only grammar-ineligible
				// providers; it never dispatched, so it carries the marker.
				return responseWithBody(http.StatusServiceUnavailable, markedNoProviderHeaders(), toolGrammarUnavailableBody()), nil
			})}
			h, store, _, cfg := newRetryHarness(t, client, nil)
			fullKey := createAccountAndKey(t, store, cfg, "acct_retry_provider_then_grammar_"+name)

			resp := postChat(t, h, fullKey, chatBody(stream), nil)

			if calls != 2 {
				t.Fatalf("coordinator calls=%d, want 2", calls)
			}
			if resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s — grammar-unavailable after a prior provider dispatch must settle as upstream_provider_error", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used == 0 {
				t.Fatalf("daily_tokens_used=0 — grammar-unavailable after a prior provider dispatch must charge the estimate, not refund")
			}
		})
	}
}

func TestGatewayUnmarkedToolGrammarUnavailableSettlesConservatively(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_streaming"
		if stream {
			name = "streaming"
		}
		t.Run(name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				// No marker: a coordinator-internal failover may already have
				// credited a provider before the grammar-ineligible re-select.
				return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}}, toolGrammarUnavailableBody()), nil
			})}
			h, store, _, cfg := newRetryHarness(t, client, nil)
			fullKey := createAccountAndKey(t, store, cfg, "acct_unmarked_grammar_"+name)

			resp := postChat(t, h, fullKey, chatBody(stream), nil)

			if resp.Code != http.StatusBadGateway {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used == 0 {
				t.Fatalf("daily_tokens_used=0 — an unmarked grammar-unavailable 503 cannot prove no dispatch")
			}
		})
	}
}

func TestGatewayMarkedToolGrammarUnavailableRefunds(t *testing.T) {
	for _, stream := range []bool{false, true} {
		name := "non_streaming"
		if stream {
			name = "streaming"
		}
		t.Run(name, func(t *testing.T) {
			var calls int
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				calls++
				return responseWithBody(http.StatusServiceUnavailable, markedNoProviderHeaders(), toolGrammarUnavailableBody()), nil
			})}
			h, store, dbPath, cfg := newRetryHarness(t, client, nil)
			accountID := "acct_marked_grammar_" + name
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, chatBody(stream), nil)

			if calls != 1 {
				t.Fatalf("coordinator calls=%d, want 1 (not a no-provider retry)", calls)
			}
			if resp.Code != http.StatusServiceUnavailable {
				t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "tool_grammar_provider_unavailable")
			assertRefundedAuditOutcome(t, dbPath, accountID, "tool_grammar_provider_unavailable")
		})
	}
}

func TestCoordinatorStructuredNoProviderNeedsSettlementCoversToolGrammar(t *testing.T) {
	body := []byte(toolGrammarUnavailableBody())
	marked := markedNoProviderHeaders()
	prior := markedNoProviderHeaders()
	prior.Set(gatewayPriorProviderDispatchHeader, "1")
	if coordinatorStructuredNoProviderNeedsSettlement(http.StatusServiceUnavailable, body, marked) {
		t.Fatal("marked grammar-unavailable 503 proves no dispatch and stays refundable")
	}
	if !coordinatorStructuredNoProviderNeedsSettlement(http.StatusServiceUnavailable, body, http.Header{}) {
		t.Fatal("unmarked grammar-unavailable 503 must settle conservatively")
	}
	if !coordinatorStructuredNoProviderNeedsSettlement(http.StatusServiceUnavailable, body, prior) {
		t.Fatal("gateway prior-dispatch marker must force settlement of a grammar-unavailable 503")
	}
	if coordinatorStructuredNoProviderNeedsSettlement(http.StatusTooManyRequests, body, http.Header{}) {
		t.Fatal("grammar-unavailable is a 503 outcome only")
	}
}
