package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

// engineCoordCapture records what the fake coordinator saw for SPEC-006-R016.
type engineCoordCapture struct {
	chatHits     int
	engineHeader string
	sawEngine    bool
	sawSelect    bool
	poolHeader   string
}

// newEngineHarness is newPoolHarness with the engine headers captured and a
// configurable X-MacProvider-Engine on the coordinator's chat response.
func newEngineHarness(t *testing.T, respEngine string) (http.Handler, *engineCoordCapture, string) {
	t.Helper()
	cap := &engineCoordCapture{}
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/internal/routing":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"pools":{"enabled":true}}`), nil
		case "/v1/chat/completions":
			cap.chatHits++
			if v := r.Header.Get(engineEmitHeader); v != "" {
				cap.sawEngine = true
				cap.engineHeader = v
			}
			cap.sawSelect = r.Header.Get(engineSelectHeader) != ""
			cap.poolHeader = r.Header.Get(poolEmitHeader)
			h := http.Header{"Content-Type": []string{"application/json"}}
			if respEngine != "" {
				h.Set(engineResponseHeader, respEngine)
			}
			return responseWithBody(http.StatusOK, h, poolChatOK), nil
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
			AccountPools: map[string][]string{"acct_pool": {testPoolID}},
		}
	}, WithHTTPClient(client))
	key := createAccountAndKey(t, st, cfg, "acct_pool")
	return h, cap, key
}

func TestEngineSelection_AbsentIsUnchanged(t *testing.T) {
	h, cap, key := newEngineHarness(t, "")
	resp := postChat(t, h, key, poolChatBody, nil)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if cap.sawEngine || cap.sawSelect {
		t.Fatalf("no selection must emit nothing upstream: engine=%q select=%v", cap.engineHeader, cap.sawSelect)
	}
}

func TestEngineSelection_EmitsMappedRuntimeClass(t *testing.T) {
	for _, tc := range []struct {
		selector, pool, want string
	}{
		{"native", "", "mlx_cache"},
		{"  native ", "", "mlx_cache"},
		{"native", testPoolID, "mlx_cache"},
		{"llamacpp", testPoolID, "llamacpp_loopback"},
		{"ollama", testPoolID, "ollama_loopback"},
	} {
		h, cap, key := newEngineHarness(t, "")
		headers := map[string]string{engineSelectHeader: tc.selector}
		if tc.pool != "" {
			headers[poolSelectHeader] = tc.pool
		}
		resp := postChat(t, h, key, poolChatBody, headers)
		if resp.Code != http.StatusOK {
			t.Fatalf("%+v: status=%d body=%s", tc, resp.Code, resp.Body.String())
		}
		if cap.engineHeader != tc.want || cap.sawSelect {
			t.Fatalf("%+v: emitted %q (buyer header forwarded=%v), want %q", tc, cap.engineHeader, cap.sawSelect, tc.want)
		}
		if cap.poolHeader != tc.pool {
			t.Fatalf("%+v: pool header %q", tc, cap.poolHeader)
		}
	}
}

// SPEC-006-R016 rule 3 / SPEC-042-R014 (a): a non-native engine on a global
// route fails closed before dispatch; it is never served natively.
func TestEngineSelection_NonNativeOnGlobalRouteFailsClosed(t *testing.T) {
	for _, selector := range []string{"llamacpp", "ollama"} {
		h, cap, key := newEngineHarness(t, "")
		resp := postChat(t, h, key, poolChatBody, map[string]string{engineSelectHeader: selector})
		if resp.Code != http.StatusServiceUnavailable {
			t.Fatalf("%s: status=%d body=%s, want 503", selector, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "engine_unavailable")
		if !strings.Contains(resp.Body.String(), `"retryable":false`) {
			t.Fatalf("%s: engine_unavailable must be non-retryable: %s", selector, resp.Body.String())
		}
		if cap.chatHits != 0 {
			t.Fatalf("%s: dispatched a non-native selection on a global route", selector)
		}
	}
}

func TestEngineSelection_InvalidSelectorRejected(t *testing.T) {
	for _, values := range [][]string{{"LLAMACPP"}, {"vllm"}, {"mlx_cache"}, {"native, llamacpp"}, {"native", "llamacpp"}} {
		h, cap, key := newEngineHarness(t, "")
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(poolChatBody))
		req.Header.Set("Authorization", "Bearer "+key)
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(poolSelectHeader, testPoolID)
		for _, v := range values {
			req.Header.Add(engineSelectHeader, v)
		}
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Code != http.StatusBadRequest {
			t.Fatalf("%q: status=%d body=%s, want 400", values, resp.Code, resp.Body.String())
		}
		assertErrorCode(t, resp.Body.String(), "invalid_engine_selection")
		if cap.chatHits != 0 {
			t.Fatalf("%q: dispatched an invalid selection", values)
		}
	}
}

// Repeating the same selector is not a conflict.
func TestEngineSelection_RepeatedSameSelectorAccepted(t *testing.T) {
	h, cap, key := newEngineHarness(t, "")
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(poolChatBody))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(poolSelectHeader, testPoolID)
	req.Header.Add(engineSelectHeader, "llamacpp")
	req.Header.Add(engineSelectHeader, " llamacpp")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK || cap.engineHeader != "llamacpp_loopback" {
		t.Fatalf("status=%d engine=%q body=%s", resp.Code, cap.engineHeader, resp.Body.String())
	}
}

// SPEC-006-R016 rule 5: the pool is resolved first, so an unauthorized pool
// still answers with the generic pool_unavailable, never an engine code.
func TestEngineSelection_UnauthorizedPoolAnswersPoolUnavailableFirst(t *testing.T) {
	h, cap, key := newEngineHarness(t, "")
	resp := postChat(t, h, key, poolChatBody, map[string]string{
		poolSelectHeader:   "zyxwvutsrqponmlkjihgfe",
		engineSelectHeader: "llamacpp",
	})
	if resp.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	assertErrorCode(t, resp.Body.String(), "pool_unavailable")
	if cap.chatHits != 0 {
		t.Fatalf("dispatched")
	}
}

func TestEngineSelection_ResponseHeaderDisclosedWithClosedVocabulary(t *testing.T) {
	for _, tc := range []struct{ upstream, want string }{
		{"llamacpp_loopback", "llamacpp_loopback"},
		{"mlx_cache", "mlx_cache"},
		{"ollama_loopback", "ollama_loopback"},
		{"lmstudio_loopback", ""},
		{"llamacpp_loopback\r\nX-Evil: 1", ""},
		{" mlx_cache", ""},
	} {
		h, _, key := newEngineHarness(t, tc.upstream)
		resp := postChat(t, h, key, poolChatBody, map[string]string{poolSelectHeader: testPoolID, engineSelectHeader: "llamacpp"})
		if resp.Code != http.StatusOK {
			t.Fatalf("%q: status=%d body=%s", tc.upstream, resp.Code, resp.Body.String())
		}
		if got := resp.Header().Get(engineResponseHeader); got != tc.want {
			t.Fatalf("upstream %q: buyer saw %q, want %q", tc.upstream, got, tc.want)
		}
	}
	dst := http.Header{}
	copyCleanHeaders(dst, http.Header{engineResponseHeader: []string{"bogus", "ollama_loopback"}})
	if got := dst.Values(engineResponseHeader); len(got) != 1 || got[0] != "ollama_loopback" {
		t.Fatalf("streaming copy kept %q", got)
	}
}

func TestEngineSelection_CodesArePermanent(t *testing.T) {
	for _, code := range []string{"engine_unavailable", "invalid_engine_selection"} {
		if !gatewayPermanentCodes[code] || gatewayRetryable(code) {
			t.Fatalf("%s must be classified permanent and non-retryable", code)
		}
	}
}

// SPEC-006-R016 rule 6: the relay-blind pilot is an authenticated global route;
// an engine selector is refused like a pool selector.
func TestEngineSelection_RelayBlindRejectsSelector(t *testing.T) {
	r := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
	if relayBlindPoolSelected(r) {
		t.Fatal("no selector must not trip the relay-blind guard")
	}
	r.Header.Set(engineSelectHeader, "native")
	if !relayBlindPoolSelected(r) {
		t.Fatal("an engine selector must trip the relay-blind guard")
	}
}

// Two id-less requests that differ only in engine are different dispatches.
func TestEngineSelection_IdlessFingerprintSeparatesEngines(t *testing.T) {
	body := []byte(`{"a":1}`)
	none := idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "", "", "", testPoolID, "", body)
	native := idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "", "", "", testPoolID, "mlx_cache", body)
	llama := idlessRequestFingerprint(idlessDedupeEntrypointChat, "acct", "", "", "", testPoolID, "llamacpp_loopback", body)
	if none == native || none == llama || native == llama {
		t.Fatal("engine selection must be part of the id-less dedupe fingerprint")
	}
}
