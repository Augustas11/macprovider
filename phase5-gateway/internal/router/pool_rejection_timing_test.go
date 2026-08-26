package router

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// TestPoolRejectionTimingFloor_EnforcedAndUniform covers SPEC-043-R007: every
// pool-selection rejection honors the active timing floor, unknown vs
// unauthorized vs disabled rejection latency stays inside the p95/p99 delta
// bounds, and the shared pool_unavailable envelope is non-retryable.
func TestPoolRejectionTimingFloor_EnforcedAndUniform(t *testing.T) {
	const floor = 50 * time.Millisecond
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, func(cfg *config.Config) {
		cfg.Features.TrustedPools.RejectionTimingFloorMS = 50
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	})

	assertPoolUnavailableShape := func(t *testing.T, resp *httptest.ResponseRecorder) {
		t.Helper()
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("status=%d body=%s, want 503", resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "pool_unavailable")
		if got := resp.Header().Get("Retry-After"); got != "" {
			t.Fatalf("Retry-After=%q, want absent", got)
		}
		var env struct {
			Error struct {
				Code      string `json:"code"`
				Retryable bool   `json:"retryable"`
			} `json:"error"`
		}
		if err := json.Unmarshal(resp.Body.Bytes(), &env); err != nil {
			t.Fatalf("decode body: %v", err)
		}
		if env.Error.Retryable {
			t.Fatalf("retryable=true body=%s, want false", resp.Body.String())
		}
		if !gatewayPermanentCodes["pool_unavailable"] {
			t.Fatal("pool_unavailable missing from gatewayPermanentCodes")
		}
		if gatewayRetryable("pool_unavailable") {
			t.Fatal("pool_unavailable must classify retryable=false")
		}
	}

	measure := func(selector string) time.Duration {
		t.Helper()
		start := time.Now()
		resp := postChat(t, h, key, poolChatBody, selectHeader(selector))
		elapsed := time.Since(start)
		assertPoolUnavailableShape(t, resp)
		if elapsed+5*time.Millisecond < floor {
			t.Fatalf("elapsed=%s below floor=%s for selector=%q", elapsed, floor, selector)
		}
		return elapsed
	}

	const samples = 16
	unknown := make([]time.Duration, 0, samples)
	unauthorized := make([]time.Duration, 0, samples)
	for i := 0; i < samples; i++ {
		unknown = append(unknown, measure("zzzzzzzzzzzzzzzzzzzzzz"))
		unauthorized = append(unauthorized, measure("bbbbbbbbbbbbbbbbbbbbbb"))
	}
	if cap.chatHits != 0 || cap.routingHits != 0 {
		t.Fatalf("rejection path consulted coordinator chat=%d routing=%d", cap.chatHits, cap.routingHits)
	}
	assertDurationDeltasWithinOracleBounds(t, "unknown", unknown, "unauthorized", unauthorized)

	disabledH, disabledCap, disabledKey := newPoolHarness(t, `{"pools":{"enabled":true}}`, func(cfg *config.Config) {
		cfg.Features.TrustedPools.Enabled = false
		cfg.Features.TrustedPools.RejectionTimingFloorMS = 50
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	})
	disabled := make([]time.Duration, 0, samples)
	for i := 0; i < samples; i++ {
		start := time.Now()
		resp := postChat(t, disabledH, disabledKey, poolChatBody, selectHeader(testPoolID))
		elapsed := time.Since(start)
		assertPoolUnavailableShape(t, resp)
		if elapsed+5*time.Millisecond < floor {
			t.Fatalf("disabled elapsed=%s below floor=%s", elapsed, floor)
		}
		disabled = append(disabled, elapsed)
	}
	if disabledCap.chatHits != 0 {
		t.Fatalf("disabled rejection dispatched chat=%d", disabledCap.chatHits)
	}
	assertDurationDeltasWithinOracleBounds(t, "unknown", unknown, "disabled", disabled)
	assertDurationDeltasWithinOracleBounds(t, "unauthorized", unauthorized, "disabled", disabled)
}

func TestPoolRejectionTimingFloor_WalletSessionMatchesUnknown(t *testing.T) {
	const floor = 50 * time.Millisecond
	const samples = 8

	cap := &poolCoordCapture{}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/poolz") {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}},
				`{"pool":[{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"}]}`), nil
		}
		switch r.URL.Path {
		case "/internal/routing":
			cap.routingHits++
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true}}`), nil
		case "/v1/chat/completions":
			cap.chatHits++
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, poolChatOK), nil
		default:
			t.Fatalf("unexpected coordinator path %s", r.URL.Path)
			return nil, nil
		}
	})}
	accountID := "acct_wallet_timing"
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Public.BaseURL = "https://api.malibu.test"
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Auth.WalletSessions.Enabled = true
		cfg.Auth.WalletSessions.BearerHashKeys = map[string]string{"k1": strings.Repeat("b", 32)}
		cfg.Auth.WalletSessions.CurrentBearerHashKeyID = "k1"
		cfg.Auth.WalletSessions.WalletFingerprintSecret = strings.Repeat("f", 32)
		cfg.Auth.WalletSessions.MetadataRequestsPerMinute = 100
		cfg.Features.TrustedPools = config.TrustedPoolsConfig{
			Enabled:                true,
			RejectionTimingFloorMS: 50,
			AccountPools:           map[string][]string{accountID: {testPoolID}},
		}
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	}, WithHTTPClient(client))
	apiKey := createAccountAndKey(t, store, cfg, accountID)
	walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"llama"}, 100000, 4096)

	unknownH, _, unknownKey := newPoolHarness(t, `{"pools":{"enabled":true}}`, func(cfg *config.Config) {
		cfg.Features.TrustedPools.RejectionTimingFloorMS = 50
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	})

	measureUnknown := func() time.Duration {
		t.Helper()
		start := time.Now()
		resp := postChat(t, unknownH, unknownKey, poolChatBody, selectHeader("zzzzzzzzzzzzzzzzzzzzzz"))
		elapsed := time.Since(start)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("unknown status=%d body=%s", resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "pool_unavailable")
		if got := resp.Header().Get("Retry-After"); got != "" {
			t.Fatalf("Retry-After=%q, want absent", got)
		}
		return elapsed
	}
	measureWallet := func(i int) time.Duration {
		t.Helper()
		req := signedWalletRequest(t, walletClient, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions",
			fmt.Sprintf("018f7b7b-7c35-4cf0-8d4e-3f0ab1c2%04d", i),
			[]byte(poolChatBody))
		req.Header.Set("X-MacProvider-Pool-Select", testPoolID)
		start := time.Now()
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		elapsed := time.Since(start)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("wallet status=%d body=%s", resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "pool_unavailable")
		if got := resp.Header().Get("Retry-After"); got != "" {
			t.Fatalf("Retry-After=%q, want absent", got)
		}
		if elapsed+5*time.Millisecond < floor {
			t.Fatalf("wallet elapsed=%s below floor=%s", elapsed, floor)
		}
		return elapsed
	}

	unknown := make([]time.Duration, 0, samples)
	wallet := make([]time.Duration, 0, samples)
	for i := 0; i < samples; i++ {
		unknown = append(unknown, measureUnknown())
		wallet = append(wallet, measureWallet(i))
	}
	if cap.chatHits != 0 {
		t.Fatalf("wallet rejection dispatched chat=%d", cap.chatHits)
	}
	assertDurationDeltasWithinOracleBounds(t, "unknown", unknown, "wallet_session", wallet)
}

func assertDurationDeltasWithinOracleBounds(t *testing.T, aName string, a []time.Duration, bName string, b []time.Duration) {
	t.Helper()
	p95Delta := absDuration(percentileDuration(a, 0.95) - percentileDuration(b, 0.95))
	p99Delta := absDuration(percentileDuration(a, 0.99) - percentileDuration(b, 0.99))
	if p95Delta > 15*time.Millisecond {
		t.Fatalf("p95 delta=%s exceeds 15ms %s=%v %s=%v", p95Delta, aName, a, bName, b)
	}
	if p99Delta > 25*time.Millisecond {
		t.Fatalf("p99 delta=%s exceeds 25ms %s=%v %s=%v", p99Delta, aName, a, bName, b)
	}
}

func percentileDuration(values []time.Duration, p float64) time.Duration {
	if len(values) == 0 {
		return 0
	}
	sorted := append([]time.Duration(nil), values...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i] < sorted[j] })
	idx := int(float64(len(sorted)-1) * p)
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func absDuration(d time.Duration) time.Duration {
	if d < 0 {
		return -d
	}
	return d
}
