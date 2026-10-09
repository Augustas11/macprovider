package router

import (
	"net/http"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// The coordinator's SPEC-006 §7.8 capacity shed (#1906): the model has
// serving-capable supply but every provider is full. It is a pre-dispatch
// outcome, so the gateway must settle it exactly like the 503 it replaced.
func capacityShedBody() string {
	return `{"error":{"code":"no_provider_available","message":"All providers for model llama are at capacity; retry shortly","param":null,"type":"rate_limit_exceeded","retryable":true}}`
}

func capacityShedHeaders() http.Header {
	h := markedNoProviderHeaders()
	h.Set("Retry-After", "1")
	return h
}

// Every coordinator chat hop opts into the capacity 429; a coordinator
// answers callers without the header with the pre-#1906 503.
func assertCapacityShed429Advertised(t *testing.T, r *http.Request) {
	t.Helper()
	if got := r.Header.Get(capacityShed429CapabilityHeader); got != "1" {
		t.Errorf("coordinator hop %s %s: %s=%q, want 1", r.Method, r.URL.Path, capacityShed429CapabilityHeader, got)
	}
}

func assertGatewayCapacityShed(t *testing.T, code int, header http.Header, body string) {
	t.Helper()
	if code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s, want 429 capacity shed", code, body)
	}
	assertErrorCode(t, body, "no_provider_available")
	if got := header.Get("Retry-After"); got != "1" {
		t.Fatalf("Retry-After=%q want 1", got)
	}
	if !strings.Contains(body, `"retryable":true`) {
		t.Fatalf("capacity shed body not retryable: %s", body)
	}
}

func TestPublicCoordinatorCapacityShedPassesThroughAs429AndRefunds(t *testing.T) {
	for _, stream := range []bool{false, true} {
		stream := stream
		name := "non_streaming"
		if stream {
			name = "streaming"
		}
		t.Run(name, func(t *testing.T) {
			client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
				assertCapacityShed429Advertised(t, r)
				if got := r.Header.Get(wholesaleInternalHeader); got != "" {
					t.Fatalf("public traffic leaked wholesale header %q", got)
				}
				return responseWithBody(http.StatusTooManyRequests, capacityShedHeaders(), capacityShedBody()), nil
			})}
			accountID := "acct_public_capacity_" + name
			h, store, dbPath, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
				cfg.Retry503.Enabled = false
			})
			fullKey := createAccountAndKey(t, store, cfg, accountID)

			resp := postChat(t, h, fullKey, chatBody(stream), nil)

			assertGatewayCapacityShed(t, resp.Code, resp.Header(), resp.Body.String())
			assertRefundedNoProviderAudit(t, dbPath, accountID)
			usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
			if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used != 0 {
				t.Fatalf("daily_tokens_used=%v — a capacity shed ran no inference and must not charge", used)
			}
		})
	}
}

func TestWholesaleCoordinatorCapacityShedStays429(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		assertCapacityShed429Advertised(t, r)
		if got := r.Header.Get(wholesaleInternalHeader); got != "1" {
			t.Fatalf("wholesale header=%q want 1", got)
		}
		return responseWithBody(http.StatusTooManyRequests, capacityShedHeaders(), capacityShedBody()), nil
	})}
	accountID := "acct_wholesale_capacity"
	h, store, dbPath, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Auth.WholesaleAccountIDs = []string{accountID}
		cfg.Retry503.Enabled = false
	})
	fullKey := createAccountAndKey(t, store, cfg, accountID)

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	assertGatewayCapacityShed(t, resp.Code, resp.Header(), resp.Body.String())
	assertRefundedNoProviderAudit(t, dbPath, accountID)
}

func TestUnmarkedCoordinatorCapacityShedSettlesConservatively(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		assertCapacityShed429Advertised(t, r)
		return responseWithBody(http.StatusTooManyRequests, http.Header{"Content-Type": []string{"application/json"}}, capacityShedBody()), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, func(cfg *config.Config) {
		cfg.Retry503.Enabled = false
	})
	fullKey := createAccountAndKey(t, store, cfg, "acct_unmarked_capacity")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusBadGateway {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "upstream_provider_error")
	usageResp := assertStatus(t, h, http.MethodGet, "/v1/usage", fullKey, "", "1.2.3.4", http.StatusOK)
	if used := readQuota(t, usageResp)["daily_tokens_used"].(float64); used == 0 {
		t.Fatalf("daily_tokens_used=0 — an unmarked capacity shed cannot prove no dispatch and must charge the estimate")
	}
}

func TestGatewayRetriesCoordinatorCapacityShedLikeNoProvider503(t *testing.T) {
	var calls int
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		assertCapacityShed429Advertised(t, r)
		calls++
		if calls == 1 {
			return responseWithBody(http.StatusTooManyRequests, capacityShedHeaders(), capacityShedBody()), nil
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, retryChatSuccessBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_capacity_retry")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if calls != 2 {
		t.Fatalf("coordinator calls=%d want 2", calls)
	}
}

func TestGatewayDoesNotRetryOtherCoordinator429(t *testing.T) {
	var calls int
	quotaBody := `{"error":{"code":"provisional_quota_exceeded","message":"Selected provider is over request quota","param":null,"type":"rate_limit_error","retryable":true}}`
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		assertCapacityShed429Advertised(t, r)
		calls++
		return responseWithBody(http.StatusTooManyRequests, markedNoProviderHeaders(), quotaBody), nil
	})}
	h, store, _, cfg := newRetryHarness(t, client, nil)
	fullKey := createAccountAndKey(t, store, cfg, "acct_quota_no_retry")

	resp := postChat(t, h, fullKey, chatBody(false), nil)

	if resp.Code != http.StatusTooManyRequests {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "provisional_quota_exceeded")
	if calls != 1 {
		t.Fatalf("coordinator calls=%d want 1", calls)
	}
}

func TestCoordinatorCapacityShedClassifiers(t *testing.T) {
	body := []byte(capacityShedBody())
	if !isCoordCapacityShed429(http.StatusTooManyRequests, body) || !isCoordNoProviderAvailable(http.StatusTooManyRequests, body) {
		t.Fatal("429 no_provider_available must classify as a coordinator capacity shed")
	}
	if isCoordCapacityShed429(http.StatusTooManyRequests, []byte(`{"error":{"code":"provisional_quota_exceeded"}}`)) {
		t.Fatal("other coordinator 429 codes are not capacity sheds")
	}
	if isCoordCapacityShed429(http.StatusTooManyRequests, nil) {
		t.Fatal("an empty 429 body is not a capacity shed")
	}
	marked := http.Header{}
	marked.Set(settlementNoPriorDispatchHeader, "1")
	if coordinatorStructuredNoProviderNeedsSettlement(http.StatusTooManyRequests, body, marked) {
		t.Fatal("marked capacity 429 must stay refundable clean capacity")
	}
	if !coordinatorStructuredNoProviderNeedsSettlement(http.StatusTooManyRequests, body, http.Header{}) {
		t.Fatal("unmarked capacity 429 must settle conservatively")
	}
	prior := marked.Clone()
	prior.Set(gatewayPriorProviderDispatchHeader, "1")
	if !coordinatorStructuredNoProviderNeedsSettlement(http.StatusTooManyRequests, body, prior) {
		t.Fatal("gateway prior-dispatch marker must force conservative settlement of a capacity 429")
	}
}
