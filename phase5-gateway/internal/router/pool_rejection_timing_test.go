package router

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
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
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true,"routeable_pools":["abcdefghijklmnopqrstuv"]}}`, func(cfg *config.Config) {
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

	disabledH, disabledCap, disabledKey := newPoolHarness(t, `{"pools":{"enabled":true,"routeable_pools":["abcdefghijklmnopqrstuv"]}}`, func(cfg *config.Config) {
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
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true,"routeable_pools":["abcdefghijklmnopqrstuv"]}}`), nil
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

	unknownH, _, unknownKey := newPoolHarness(t, `{"pools":{"enabled":true,"routeable_pools":["abcdefghijklmnopqrstuv"]}}`, func(cfg *config.Config) {
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

// TestPoolRejectionTimingFloor_CoordinatorAuthorizedClassesShareLocalPath is
// the production-shape (coordinator_authorizes, no static account_pools)
// regression for the 2026-10-06 R007 oracle: an authorized buyer selecting a
// paused pool used to be forwarded to the coordinator, which stacked its own
// round trip and rejection floor on top of the gateway's, so "disabled" was
// ~55 ms slower than "unknown"/"unauthorized". The coordinator projection now
// omits non-active pools, so every class is refused by the same local lookup
// after the same /internal/routing fetch. The fake coordinator adds latency to
// both calls; a forwarded chat would add a further 80 ms and fail the bounds.
func TestPoolRejectionTimingFloor_CoordinatorAuthorizedClassesShareLocalPath(t *testing.T) {
	const (
		floor         = 50 * time.Millisecond
		samples       = 16
		pausedPoolID  = "pausedpoolxxxxxxxxxxxx"
		foreignPoolID = "bbbbbbbbbbbbbbbbbbbbbb"
		unknownPoolID = "zzzzzzzzzzzzzzzzzzzzzz"
	)
	// Projection as the coordinator now serves it: acct_pool is a buyer of
	// testPoolID (active) and of pausedPoolID (paused, therefore omitted);
	// foreignPoolID exists for another buyer only.
	routingBody := `{"pools":{"enabled":true,"account_pools":{"acct_pool":["` + testPoolID + `"],"acct_other":["` + foreignPoolID + `"]},"buyer_authorization_generation":3,"routeable_pools":["` + testPoolID + `","` + foreignPoolID + `"]}}`
	var mu sync.Mutex
	routingHits, chatHits := 0, 0
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/internal/routing":
			time.Sleep(10 * time.Millisecond)
			mu.Lock()
			routingHits++
			mu.Unlock()
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, routingBody), nil
		case "/v1/chat/completions":
			// What the coordinator answers for a forwarded paused pool:
			// its own floor plus round trip, then pool_unavailable.
			time.Sleep(80 * time.Millisecond)
			mu.Lock()
			chatHits++
			mu.Unlock()
			return responseWithBody(http.StatusServiceUnavailable, http.Header{"Content-Type": []string{"application/json"}},
				`{"error":{"type":"service_unavailable","code":"pool_unavailable","message":"Pool unavailable"}}`), nil
		default:
			t.Fatalf("unexpected coordinator path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, st, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Features.TrustedPools = config.TrustedPoolsConfig{Enabled: true, CoordinatorAuthorizes: true}
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, st, cfg, "acct_pool")

	measure := func(class, selector string) time.Duration {
		t.Helper()
		start := time.Now()
		resp := postChat(t, h, key, poolChatBody, selectHeader(selector))
		elapsed := time.Since(start)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s status=%d body=%s, want 503", class, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "pool_unavailable")
		if elapsed+5*time.Millisecond < floor {
			t.Fatalf("%s elapsed=%s below floor=%s", class, elapsed, floor)
		}
		return elapsed
	}

	byClass := map[string][]time.Duration{}
	selectors := map[string]string{"unknown": unknownPoolID, "unauthorized": foreignPoolID, "disabled": pausedPoolID}
	order := []string{"unknown", "unauthorized", "disabled"}
	for i := 0; i < samples; i++ {
		// Rotate class order per round so warm-up and drift do not bias one class.
		for j := range order {
			class := order[(i+j)%len(order)]
			byClass[class] = append(byClass[class], measure(class, selectors[class]))
		}
	}
	mu.Lock()
	gotChat, gotRouting := chatHits, routingHits
	mu.Unlock()
	if gotChat != 0 {
		t.Fatalf("a pool_unavailable class was forwarded to the coordinator chat path %d times; all classes must be refused locally", gotChat)
	}
	if gotRouting != samples*len(order) {
		t.Fatalf("routing fetches=%d, want one per request (%d) on every class", gotRouting, samples*len(order))
	}
	assertDurationDeltasWithinOracleBounds(t, "unknown", byClass["unknown"], "unauthorized", byClass["unauthorized"])
	assertDurationDeltasWithinOracleBounds(t, "unknown", byClass["unknown"], "disabled", byClass["disabled"])
	assertDurationDeltasWithinOracleBounds(t, "unauthorized", byClass["unauthorized"], "disabled", byClass["disabled"])
}

// TestPoolRejectionTimingFloor_ModelsPoolViewHonorsFloor covers the SPEC-006
// R018 pool view: a /v1/models pool selection is authorized like a chat pool
// selection, so its pool_unavailable rejection also holds the R007 floor.
func TestPoolRejectionTimingFloor_ModelsPoolViewHonorsFloor(t *testing.T) {
	const floor = 50 * time.Millisecond
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true,"routeable_pools":["abcdefghijklmnopqrstuv"]}}`, func(cfg *config.Config) {
		cfg.Quotas.AccountRequestRatePerSecond = 1000
	})
	for _, selector := range []string{"zzzzzzzzzzzzzzzzzzzzzz", "bbbbbbbbbbbbbbbbbbbbbb"} {
		req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set(poolSelectHeader, selector)
		start := time.Now()
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		elapsed := time.Since(start)
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("selector=%q status=%d body=%s, want 503", selector, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "pool_unavailable")
		if elapsed+5*time.Millisecond < floor {
			t.Fatalf("selector=%q elapsed=%s below floor=%s", selector, elapsed, floor)
		}
	}
	if cap.chatHits != 0 || cap.routingHits != 0 {
		t.Fatalf("static-scope rejection consulted coordinator chat=%d routing=%d", cap.chatHits, cap.routingHits)
	}
}

// TestPoolRejectionTimingFloor_StaticScopeNonRouteablePoolRefusedLocally
// (#1690 BUG-3 audit r1): in static account_pools mode a configured pool that
// the coordinator no longer lists as routeable (paused, expired,
// candidate-blocked) is refused on the same local floored path as an unknown
// pool, for chat and the /v1/models pool view, without a coordinator chat or
// models call. A coordinator that omits routeable_pools routes none.
func TestPoolRejectionTimingFloor_StaticScopeNonRouteablePoolRefusedLocally(t *testing.T) {
	const (
		floor        = 50 * time.Millisecond
		pausedPoolID = "pausedpoolxxxxxxxxxxxx"
	)
	for _, tc := range []struct {
		name        string
		routingBody string
	}{
		{name: "not listed", routingBody: `{"pools":{"enabled":true,"routeable_pools":["` + testPoolID + `"]}}`},
		{name: "old coordinator", routingBody: `{"pools":{"enabled":true}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h, cap, key := newPoolHarness(t, tc.routingBody, func(cfg *config.Config) {
				cfg.Features.TrustedPools.AccountPools = map[string][]string{"acct_pool": {testPoolID, pausedPoolID}}
				cfg.Quotas.AccountRequestRatePerSecond = 1000
			})
			start := time.Now()
			resp := postChat(t, h, key, poolChatBody, selectHeader(pausedPoolID))
			elapsed := time.Since(start)
			if resp.Code != http.StatusServiceUnavailable {
				t.Fatalf("chat status=%d body=%s, want 503", resp.Code, resp.Body.String())
			}
			assertErrorCode(t, resp.Body.String(), "pool_unavailable")
			if elapsed+5*time.Millisecond < floor {
				t.Fatalf("chat elapsed=%s below floor=%s", elapsed, floor)
			}

			req := httptest.NewRequest(http.MethodGet, "/v1/models", nil)
			req.Header.Set("Authorization", "Bearer "+key)
			req.Header.Set(poolSelectHeader, pausedPoolID)
			start = time.Now()
			models := httptest.NewRecorder()
			h.ServeHTTP(models, req)
			elapsed = time.Since(start)
			if models.Code != http.StatusServiceUnavailable {
				t.Fatalf("models status=%d body=%s, want 503", models.Code, models.Body.String())
			}
			assertErrorCode(t, models.Body.String(), "pool_unavailable")
			if elapsed+5*time.Millisecond < floor {
				t.Fatalf("models elapsed=%s below floor=%s", elapsed, floor)
			}
			if cap.chatHits != 0 {
				t.Fatalf("a non-routeable pool was forwarded to the coordinator chat path %d times", cap.chatHits)
			}
			if cap.routingHits != 2 {
				t.Fatalf("routing fetches=%d, want one per request", cap.routingHits)
			}
		})
	}
}
