package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// poolChatOK is a minimal successful coordinator chat response.
const poolChatOK = `{"id":"chatcmpl_1","object":"chat.completion","usage":{"prompt_tokens":3,"completion_tokens":4,"total_tokens":7},"choices":[{"index":0,"message":{"role":"assistant","content":"ok"},"finish_reason":"stop"}]}`

const poolChatBody = `{"model":"llama","max_tokens":20,"messages":[{"role":"user","content":"hi"}]}`

// poolCoordCapture records what the fake coordinator saw so a test can assert
// whether the chat leg was dispatched, whether the capability endpoint was
// consulted, and what pool header (if any) was forwarded.
type poolCoordCapture struct {
	chatHits    int
	routingHits int
	poolHeader  string
	sawPool     bool
}

// newPoolHarness wires a gateway over a fake coordinator. routingBody is the
// JSON returned by /internal/routing (use "" for an old coordinator that has no
// /internal/routing — it 404s). The TrustedPools feature is enabled with
// acct_pool authorized for "poolone" unless mutate overrides it.
func newPoolHarness(t *testing.T, routingBody string, mutate func(*config.Config)) (http.Handler, *poolCoordCapture, string) {
	t.Helper()
	cap := &poolCoordCapture{}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/internal/routing":
			cap.routingHits++
			if routingBody == "" {
				return responseWithBody(http.StatusNotFound, nil, `{}`), nil
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, routingBody), nil
		case "/v1/chat/completions":
			cap.chatHits++
			if v := r.Header.Get("X-MacProvider-Pool"); v != "" {
				cap.sawPool = true
				cap.poolHeader = v
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, poolChatOK), nil
		default:
			t.Fatalf("unexpected coordinator path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, st, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Features.TrustedPools = config.TrustedPoolsConfig{
			Enabled:      true,
			AccountPools: map[string][]string{"acct_pool": {"poolone"}},
		}
		if mutate != nil {
			mutate(cfg)
		}
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, st, cfg, "acct_pool")
	return h, cap, key
}

// selectHeader is the buyer-facing pool selector header (control plane only —
// never a request-body field, so nothing pool-related is forwarded to the
// provider in the data-plane body).
func selectHeader(pool string) map[string]string {
	return map[string]string{"X-MacProvider-Pool-Select": pool}
}

// Authorized pool + coordinator advertises pool support -> forwarded WITH
// X-MacProvider-Pool set to the selected pool_id (SPEC-042-R002).
func TestPoolSelection_AuthorizedAndCapable_EmitsHeader(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, nil)
	resp := postChat(t, h, key, poolChatBody, selectHeader("poolone"))
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if !cap.sawPool || cap.poolHeader != "poolone" {
		t.Fatalf("forwarded pool header = %q (seen=%v), want poolone", cap.poolHeader, cap.sawPool)
	}
}

// The capability check is FRESH per pool-required dispatch (not the 5s-cached
// sticky-hint metadata), so a coordinator rollback cannot be masked by a stale
// cached "true". Two authorized pool requests therefore each consult
// /internal/routing.
func TestPoolSelection_CapabilityCheckedFreshEachRequest(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, nil)
	for i := 0; i < 2; i++ {
		resp := postChat(t, h, key, poolChatBody, selectHeader("poolone"))
		if resp.Code != http.StatusOK {
			t.Fatalf("request %d status=%d body=%s", i, resp.Code, resp.Body.String())
		}
	}
	if cap.routingHits != 2 {
		t.Fatalf("routingHits=%d, want 2 (fresh capability check per pool request, not cached)", cap.routingHits)
	}
}

// Feature off (default) + no pool named -> byte-identical global: forwarded with
// NO pool header.
func TestPoolSelection_FeatureOffNoPool_GlobalNoHeader(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, func(cfg *config.Config) {
		cfg.Features.TrustedPools.Enabled = false
	})
	resp := postChat(t, h, key, poolChatBody, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if cap.sawPool {
		t.Fatalf("global request forwarded a pool header %q; want none", cap.poolHeader)
	}
	if cap.chatHits != 1 {
		t.Fatalf("chatHits=%d, want 1", cap.chatHits)
	}
}

// Feature on + no pool named -> still global, no header (the credential's
// authorized set is a ceiling, not an automatic assignment; SPEC-042-R002).
func TestPoolSelection_FeatureOnNoPool_GlobalNoHeader(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, nil)
	resp := postChat(t, h, key, poolChatBody, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if cap.sawPool {
		t.Fatalf("no-selector request forwarded a pool header %q; want none", cap.poolHeader)
	}
}

// Feature off + a pool IS named -> fail closed (no silent pool->global). The
// chat leg MUST NOT be dispatched.
func TestPoolSelection_FeatureOffPoolNamed_FailsClosed(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, func(cfg *config.Config) {
		cfg.Features.TrustedPools.Enabled = false
	})
	resp := postChat(t, h, key, poolChatBody, selectHeader("poolone"))
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("chat dispatched under disabled pool feature (chatHits=%d)", cap.chatHits)
	}
}

// Unauthorized pool -> generic non-disclosing pool_unavailable, chat NOT
// dispatched, and — the timing-oracle guard (SPEC-042-R010) — the coordinator
// capability endpoint is NEVER consulted, so latency cannot reveal existence.
func TestPoolSelection_Unauthorized_FailsClosedWithoutCapabilityFetch(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, nil)
	resp := postChat(t, h, key, poolChatBody, selectHeader("pooUNKNOWN"))
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("chat dispatched for unauthorized pool (chatHits=%d)", cap.chatHits)
	}
	if cap.routingHits != 0 {
		t.Fatalf("capability endpoint consulted for an unauthorized caller (routingHits=%d); timing oracle", cap.routingHits)
	}
}

// Authorized pool but coordinator advertises pools.enabled=false -> fail closed
// (no pool->global spill under version skew). Chat NOT dispatched.
func TestPoolSelection_CoordinatorDeclinesCapability_FailsClosed(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":false}}`, nil)
	resp := postChat(t, h, key, poolChatBody, selectHeader("poolone"))
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("chat dispatched despite coordinator declining pool support (chatHits=%d)", cap.chatHits)
	}
}

// Old coordinator that omits the pools advertisement entirely -> fail closed.
func TestPoolSelection_OldCoordinatorNoAdvertisement_FailsClosed(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"sticky":{"enabled":false,"ttl_seconds":1800}}`, nil)
	resp := postChat(t, h, key, poolChatBody, selectHeader("poolone"))
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s, want 503", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("chat dispatched to a coordinator with no pool advertisement (chatHits=%d)", cap.chatHits)
	}
}

// Conflicting selection sources (the selector header supplied twice with
// different values) -> pool_selection_invalid (400), never confirming either
// pool exists.
func TestPoolSelection_ConflictingSources_Invalid(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, nil)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(poolChatBody))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Add("X-MacProvider-Pool-Select", "poolone")
	req.Header.Add("X-MacProvider-Pool-Select", "poolother")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest {
		t.Fatalf("status=%d body=%s, want 400", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_selection_invalid")
	if cap.chatHits != 0 {
		t.Fatalf("chat dispatched under a conflicting selection (chatHits=%d)", cap.chatHits)
	}
}

// Regression (money-path audit round 2): because the pool selector is a header,
// not a body field, two id-less requests with IDENTICAL bodies that differ only
// in pool selection MUST NOT share an id-less-dedupe fingerprint. Otherwise the
// second would replay the first's attempt and never dispatch to the pool — a
// silent pool<->global reassignment SPEC-042-R002 forbids. The fixed clock puts
// the second request inside the first's dedupe window, so a collision would
// replay.
func TestPoolSelection_IdlessDedupeSeparatesPoolFromGlobal(t *testing.T) {
	h, cap, key := newPoolHarness(t, `{"pools":{"enabled":true}}`, nil)
	// First: global (no selector) — dispatches and publishes a dedupe entry.
	r1 := postChat(t, h, key, poolChatBody, nil)
	if r1.Code != http.StatusOK {
		t.Fatalf("global status=%d body=%s", r1.Code, r1.Body.String())
	}
	// Second: identical body, now pool-selected, within the dedupe window.
	r2 := postChat(t, h, key, poolChatBody, selectHeader("poolone"))
	if r2.Code != http.StatusOK {
		t.Fatalf("pool status=%d body=%s", r2.Code, r2.Body.String())
	}
	if cap.chatHits != 2 {
		t.Fatalf("chatHits=%d, want 2 — the pool request replayed the global attempt via id-less dedupe", cap.chatHits)
	}
	if !cap.sawPool || cap.poolHeader != "poolone" {
		t.Fatalf("pool request did not dispatch with X-MacProvider-Pool (dedupe replay masked it): seen=%v hdr=%q", cap.sawPool, cap.poolHeader)
	}
}

// Demo traffic (like wallet sessions) may not select a pool even if the demo
// account is authorized in config: the row-0 auth-mode gate rejects it before
// authorization. This pins the `!authn.Demo` half of the gate independently.
func TestPoolSelection_DemoCannotSelectPool(t *testing.T) {
	cap := &poolCoordCapture{}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/internal/routing":
			cap.routingHits++
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true}}`), nil
		case "/v1/chat/completions":
			cap.chatHits++
			if v := r.Header.Get("X-MacProvider-Pool"); v != "" {
				cap.sawPool = true
				cap.poolHeader = v
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, poolChatOK), nil
		default:
			t.Fatalf("unexpected coordinator path %s", r.URL.Path)
			return nil, nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://coordinator.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.Quotas.DemoDailyTokensPerIP = 1000
		cfg.Limits.DemoMaxTokensPerRequest = 100
		// Even with the demo account explicitly authorized, row-0 must reject.
		cfg.Features.TrustedPools = config.TrustedPoolsConfig{
			Enabled:      true,
			AccountPools: map[string][]string{"demo:1.2.3.4": {"poolone"}},
		}
	}, WithHTTPClient(client))
	demo := issueDemoToken(t, h, "1.2.3.4")
	resp := postChat(t, h, "", poolChatBody, map[string]string{
		"X-Demo-Token":              demo,
		"X-Real-IP":                 "1.2.3.4",
		"X-MacProvider-Pool-Select": "poolone",
	})
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("demo pool selection status=%d body=%s, want 503", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("demo pool request dispatched (chatHits=%d)", cap.chatHits)
	}
	if cap.sawPool {
		t.Fatalf("demo request emitted pool header %q; want none", cap.poolHeader)
	}
}

// SPEC-042-R002 deferral: a wallet-session credential MUST NOT select a pool
// until the wallet semantic signature covers pool_id + the manifest digest.
// Even when the account is authorized for the pool and the coordinator
// advertises support, a wallet-session request presenting the (unsigned)
// selector header is rejected before dispatch and emits no pool header.
func TestPoolSelection_WalletSessionCannotSelectPool(t *testing.T) {
	cap := &poolCoordCapture{}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if strings.HasSuffix(r.URL.Path, "/poolz") {
			// Wallet-session registration validates its model allowlist against
			// the coordinator model pool.
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}},
				`{"pool":[{"model_id":"llama","state":"ready","slots_free":1,"slots_total":1,"max_context_tokens":4096,"auth_state":"bearer_validated"}]}`), nil
		}
		switch r.URL.Path {
		case "/internal/routing":
			cap.routingHits++
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true}}`), nil
		case "/v1/chat/completions":
			cap.chatHits++
			if v := r.Header.Get("X-MacProvider-Pool"); v != "" {
				cap.sawPool = true
				cap.poolHeader = v
			}
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, poolChatOK), nil
		default:
			t.Fatalf("unexpected coordinator path %s", r.URL.Path)
			return nil, nil
		}
	})}
	accountID := "acct_wallet_pool"
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
			Enabled:      true,
			AccountPools: map[string][]string{accountID: {"poolone"}},
		}
	}, WithHTTPClient(client))
	apiKey := createAccountAndKey(t, store, cfg, accountID)
	walletClient := registerWalletSessionViaAPIWithCaps(t, h, cfg, apiKey, accountID, []string{"llama"}, 100000, 4096)

	req := signedWalletRequest(t, walletClient, http.MethodPost, "/v1/chat/completions", "/v1/chat/completions",
		"018f7b7b-7c35-4cf0-8d4e-3f0ab1c2f929", []byte(poolChatBody))
	// The selector header is NOT part of the wallet signed profile — appending
	// it after signing is exactly the attack the row-0 gate blocks.
	req.Header.Set("X-MacProvider-Pool-Select", "poolone")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)

	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("wallet pool selection status=%d body=%s, want 503", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("wallet-session pool request dispatched (chatHits=%d)", cap.chatHits)
	}
	if cap.sawPool {
		t.Fatalf("wallet-session request emitted pool header %q; want none", cap.poolHeader)
	}
}
