package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

const (
	testRateCardBody = `{"version":"abc123","policy_version":"autotune-policy-v1","rows":{}}` + "\n"
	testRateCardSig  = `{"key_id":"test","signature":"deadbeef"}` + "\n"
	testStatsBody    = `{"generated_at":"2026-08-16T00:00:00Z","network":{"tokens_served_total":1}}` + "\n"
)

func TestPublicFeedsUnauthenticatedExactBytes(t *testing.T) {
	var sawAuth bool
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.Header.Get("Authorization") != "" || r.Header.Get("Cookie") != "" || r.Header.Get("X-Demo-Token") != "" {
			sawAuth = true
		}
		switch {
		case r.URL.Host == "buyer.test" && r.URL.Path == "/v1/rate-card":
			return responseWithBody(http.StatusOK, http.Header{
				"Content-Type":  []string{"application/json"},
				"Cache-Control": []string{"public, max-age=300"},
				"Set-Cookie":    []string{"session=evil"},
				"Location":      []string{"https://evil.example"},
			}, testRateCardBody), nil
		case r.URL.Host == "buyer.test" && r.URL.Path == "/v1/rate-card.sig":
			return responseWithBody(http.StatusOK, http.Header{
				"Content-Type": []string{"application/json"},
			}, testRateCardSig), nil
		case r.URL.Host == "operator.test" && r.URL.Path == "/v1/stats/overview":
			return responseWithBody(http.StatusOK, http.Header{
				"Content-Type":           []string{"application/json; charset=utf-8"},
				"Cache-Control":          []string{"public, max-age=30"},
				"ETag":                   []string{`"ov-1"`},
				"X-Stats-Generated-At":   []string{"2026-08-16T00:00:00Z"},
				"X-MacProvider-Internal": []string{"strip-me"},
			}, testStatsBody), nil
		default:
			t.Errorf("unexpected upstream %s %s", r.Method, r.URL.String())
			return responseWithBody(http.StatusNotFound, nil, `{"error":"unexpected"}`), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	rateCard := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "sk-should-not-forward", "", "192.0.2.10", http.StatusOK)
	if got := rateCard.Body.String(); got != testRateCardBody {
		t.Fatalf("rate-card body=%q want exact upstream bytes", got)
	}
	if got := rateCard.Header().Get("Cache-Control"); got != "public, max-age=300" {
		t.Fatalf("rate-card cache-control=%q", got)
	}
	if got := rateCard.Header().Get("Set-Cookie"); got != "" {
		t.Fatalf("rate-card leaked Set-Cookie=%q", got)
	}
	if got := rateCard.Header().Get("Location"); got != "" {
		t.Fatalf("rate-card leaked Location=%q", got)
	}

	sig := assertStatus(t, h, http.MethodGet, "/v1/rate-card.sig", "", "", "192.0.2.10", http.StatusOK)
	if got := sig.Body.String(); got != testRateCardSig {
		t.Fatalf("rate-card.sig body=%q want exact upstream bytes", got)
	}

	overview := assertStatus(t, h, http.MethodGet, "/v1/stats/overview", "", "", "192.0.2.10", http.StatusOK)
	if got := overview.Body.String(); got != testStatsBody {
		t.Fatalf("stats overview body=%q want exact upstream bytes", got)
	}
	if got := overview.Header().Get("X-Stats-Generated-At"); got != "2026-08-16T00:00:00Z" {
		t.Fatalf("stats generated-at=%q", got)
	}
	if got := overview.Header().Get("ETag"); got != `"ov-1"` {
		t.Fatalf("stats etag=%q", got)
	}
	if got := overview.Header().Get("X-MacProvider-Internal"); got != "" {
		t.Fatalf("stats leaked internal header %q", got)
	}

	alias := assertStatus(t, h, http.MethodGet, "/v1/network-stats", "", "", "192.0.2.10", http.StatusOK)
	if got := alias.Body.String(); got != testStatsBody {
		t.Fatalf("network-stats alias body=%q want overview bytes", got)
	}
	if sawAuth {
		t.Fatal("public feed proxy forwarded buyer credentials upstream")
	}
}

func TestPublicFeedsForwardClientIPNotCredentials(t *testing.T) {
	var rateCardReq *http.Request
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		cloned := r.Clone(r.Context())
		if r.URL.Path == "/v1/rate-card" {
			rateCardReq = cloned
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardBody), nil
		}
		if r.URL.Path == "/v1/rate-card.sig" {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardSig), nil
		}
		if r.URL.Path == "/v1/stats/overview" {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testStatsBody), nil
		}
		t.Errorf("unexpected upstream %s", r.URL.String())
		return responseWithBody(http.StatusNotFound, nil, ""), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card?callback=alert", nil)
	req.Header.Set("Authorization", "Bearer sk-secret")
	req.Header.Set("Cookie", "session=secret")
	req.Header.Set("X-Demo-Token", "demo-secret")
	req.Header.Set("X-Real-IP", "203.0.113.9")
	req.RemoteAddr = "127.0.0.1:443"
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if rateCardReq == nil {
		t.Fatal("upstream rate-card request missing")
	}
	if got := rateCardReq.URL.RawQuery; got != "" {
		t.Fatalf("forwarded query %q; public feeds must use a fixed upstream path", got)
	}
	if got := rateCardReq.Header.Get("Authorization"); got != "" {
		t.Fatalf("forwarded Authorization=%q", got)
	}
	if got := rateCardReq.Header.Get("Cookie"); got != "" {
		t.Fatalf("forwarded Cookie=%q", got)
	}
	if got := rateCardReq.Header.Get("X-Demo-Token"); got != "" {
		t.Fatalf("forwarded X-Demo-Token=%q", got)
	}
	if got := rateCardReq.Header.Get("X-Real-IP"); got != "203.0.113.9" {
		t.Fatalf("X-Real-IP=%q want client IP", got)
	}
	if got := rateCardReq.Header.Get("X-Forwarded-For"); got != "203.0.113.9" {
		t.Fatalf("X-Forwarded-For=%q want client IP", got)
	}
}

func TestPublicFeedsDoNotExposePartnerStatsRoutes(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		t.Errorf("partner/stats leak path contacted upstream %s", r.URL.String())
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"secret":true}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	for _, path := range []string{
		"/v1/stats/leaderboard",
		"/v1/stats/health",
		"/v1/stats/overview/extra",
		"/v1/stats/",
		"/v1/rate-card/extra",
	} {
		resp := assertStatus(t, h, http.MethodGet, path, "", "", "", http.StatusNotFound)
		assertErrorCode(t, resp.Body.String(), "not_found")
	}
}

func TestPublicFeedsMoneyPathStillAuthenticated(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/v1/models" {
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, `{"object":"list","data":[]}`), nil
		}
		t.Errorf("unexpected upstream %s", r.URL.String())
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	resp := assertStatus(t, h, http.MethodGet, "/v1/models", "", "", "1.2.3.4", http.StatusUnauthorized)
	assertErrorCode(t, resp.Body.String(), "missing_bearer_token")
	resp = assertStatus(t, h, http.MethodGet, "/v1/usage", "", "", "1.2.3.4", http.StatusUnauthorized)
	assertErrorCode(t, resp.Body.String(), "missing_bearer_token")
}

func TestPublicFeedsSurvivePublicAPIPause(t *testing.T) {
	upstreamHits := 0
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		upstreamHits++
		switch r.URL.Path {
		case "/v1/rate-card":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardBody), nil
		case "/v1/rate-card.sig":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardSig), nil
		case "/v1/stats/overview":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testStatsBody), nil
		default:
			t.Errorf("unexpected upstream %s", r.URL.String())
			return responseWithBody(http.StatusNotFound, nil, ""), nil
		}
	})}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
		cfg.KillSwitch.AllPublicAPI = true
	}, WithHTTPClient(client))
	fullKey := createAccountAndKey(t, store, cfg, "acct_public_feeds_pause")

	assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusOK)
	assertStatus(t, h, http.MethodGet, "/v1/rate-card.sig", "", "", "192.0.2.10", http.StatusOK)
	assertStatus(t, h, http.MethodGet, "/v1/stats/overview", "", "", "192.0.2.10", http.StatusOK)
	assertStatus(t, h, http.MethodGet, "/v1/network-stats", "", "", "192.0.2.10", http.StatusOK)
	paused := assertStatus(t, h, http.MethodGet, "/v1/models", fullKey, "", "192.0.2.10", http.StatusServiceUnavailable)
	assertErrorCode(t, paused.Body.String(), "public_api_paused")
	if upstreamHits != 3 {
		t.Fatalf("upstream hits=%d want 3 public-feed fetches", upstreamHits)
	}
}

func TestPublicFeedsMethodNotAllowed(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		t.Errorf("POST must not contact upstream %s", r.URL.String())
		return responseWithBody(http.StatusOK, nil, `{}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	for _, path := range []string{"/v1/rate-card", "/v1/stats/overview", "/v1/network-stats"} {
		resp := assertStatus(t, h, http.MethodPost, path, "", "", "", http.StatusMethodNotAllowed)
		assertErrorCode(t, resp.Body.String(), "method_not_allowed")
	}
}

func TestPublicFeedsPassThroughStatsStaleAndRateLimit(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path != "/v1/stats/overview" {
			t.Errorf("unexpected upstream %s", r.URL.String())
		}
		if r.Header.Get("If-None-Match") == `"ov-1"` {
			return responseWithBody(http.StatusNotModified, http.Header{
				"ETag":          []string{`"ov-1"`},
				"Cache-Control": []string{"public, max-age=30"},
			}, ""), nil
		}
		return responseWithBody(http.StatusServiceUnavailable, http.Header{
			"Content-Type":  []string{"application/json; charset=utf-8"},
			"Retry-After":   []string{"30"},
			"Cache-Control": []string{"no-store"},
		}, `{"error":{"code":"stale","message":"snapshot stale"}}`), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	stale := assertStatus(t, h, http.MethodGet, "/v1/stats/overview", "", "", "192.0.2.10", http.StatusServiceUnavailable)
	if !strings.Contains(stale.Body.String(), `"code":"stale"`) {
		t.Fatalf("stale body=%s want origin envelope", stale.Body.String())
	}
	if got := stale.Header().Get("Retry-After"); got != "30" {
		t.Fatalf("Retry-After=%q", got)
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/stats/overview", nil)
	req.Header.Set("If-None-Match", `"ov-1"`)
	notModified := httptest.NewRecorder()
	h.ServeHTTP(notModified, req)
	if notModified.Code != http.StatusNotModified {
		t.Fatalf("status=%d want 304 body=%s", notModified.Code, notModified.Body.String())
	}
	if notModified.Body.Len() != 0 {
		t.Fatalf("304 body=%q", notModified.Body.String())
	}
	if got := notModified.Header().Get("Content-Type"); got != "" {
		t.Fatalf("304 synthesized Content-Type=%q", got)
	}
}

func TestPublicFeedsHeadHasNoBody(t *testing.T) {
	var methods []string
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		methods = append(methods, r.Method)
		return responseWithBody(http.StatusOK, http.Header{
			"Content-Type":  []string{"application/json"},
			"Cache-Control": []string{"public, max-age=30"},
		}, testStatsBody), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	resp := assertStatus(t, h, http.MethodHead, "/v1/stats/overview", "", "", "192.0.2.10", http.StatusOK)
	if resp.Body.Len() != 0 {
		t.Fatalf("HEAD body=%q", resp.Body.String())
	}
	if got := resp.Header().Get("Cache-Control"); got != "public, max-age=30" {
		t.Fatalf("HEAD cache-control=%q", got)
	}
	if len(methods) != 1 || methods[0] != http.MethodGet {
		t.Fatalf("upstream methods=%v want GET so chi GET-only feeds still work", methods)
	}

	rateCard := assertStatus(t, h, http.MethodHead, "/v1/rate-card", "", "", "192.0.2.10", http.StatusOK)
	if rateCard.Body.Len() != 0 {
		t.Fatalf("rate-card HEAD body=%q", rateCard.Body.String())
	}
}

func TestPublicFeedsRateCardAndSigCacheTogether(t *testing.T) {
	const rotatedBody = `{"version":"rotated","policy_version":"autotune-policy-v1","rows":{}}` + "\n"
	const rotatedSig = `{"key_id":"test","signature":"cafebabe"}` + "\n"
	var (
		mu       sync.Mutex
		body     = testRateCardBody
		sig      = testRateCardSig
		pathHits = map[string]int{}
	)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		mu.Lock()
		pathHits[r.URL.Path]++
		currentBody, currentSig := body, sig
		mu.Unlock()
		switch r.URL.Path {
		case "/v1/rate-card":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, currentBody), nil
		case "/v1/rate-card.sig":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, currentSig), nil
		default:
			t.Errorf("unexpected upstream %s", r.URL.String())
			return responseWithBody(http.StatusNotFound, nil, ""), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	first := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusOK)
	if first.Body.String() != testRateCardBody {
		t.Fatalf("first body=%q", first.Body.String())
	}

	mu.Lock()
	body = rotatedBody
	sig = rotatedSig
	mu.Unlock()

	cachedBody := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusOK)
	cachedSig := assertStatus(t, h, http.MethodGet, "/v1/rate-card.sig", "", "", "192.0.2.10", http.StatusOK)
	if cachedBody.Body.String() != testRateCardBody {
		t.Fatalf("cached body drifted to %q", cachedBody.Body.String())
	}
	if cachedSig.Body.String() != testRateCardSig {
		t.Fatalf("cached sig drifted to %q; body and signature must refresh as one unit", cachedSig.Body.String())
	}
	if pathHits["/v1/rate-card"] != 1 || pathHits["/v1/rate-card.sig"] != 1 {
		t.Fatalf("upstream hits=%v want one paired fetch", pathHits)
	}
}

func TestPublicFeedsCacheCollapsesRepeatReads(t *testing.T) {
	hits := 0
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		hits++
		if r.URL.Path != "/v1/stats/overview" {
			t.Errorf("unexpected upstream %s", r.URL.String())
		}
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testStatsBody), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	assertStatus(t, h, http.MethodGet, "/v1/stats/overview", "", "", "192.0.2.10", http.StatusOK)
	alias := assertStatus(t, h, http.MethodGet, "/v1/network-stats", "", "", "192.0.2.10", http.StatusOK)
	if alias.Body.String() != testStatsBody {
		t.Fatalf("cached alias body=%q", alias.Body.String())
	}
	if hits != 1 {
		t.Fatalf("upstream hits=%d want 1 cached overview fetch", hits)
	}
}

func TestPublicFeedsRejectRedirectsAndOversizedBodies(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/rate-card":
			return responseWithBody(http.StatusFound, http.Header{
				"Location": []string{"https://evil.example/rate-card"},
			}, "redirect"), nil
		case "/v1/rate-card.sig":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardSig), nil
		case "/v1/stats/overview":
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(strings.Repeat("x", publicStatsMaxBytes+2))),
			}, nil
		default:
			t.Errorf("unexpected upstream %s", r.URL.String())
			return responseWithBody(http.StatusNotFound, nil, ""), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	redirect := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusBadGateway)
	assertErrorCode(t, redirect.Body.String(), "coordinator_rate_card_error")
	if got := redirect.Header().Get("Location"); got != "" {
		t.Fatalf("redirect Location leaked %q", got)
	}

	oversize := assertStatus(t, h, http.MethodGet, "/v1/stats/overview", "", "", "192.0.2.10", http.StatusBadGateway)
	assertErrorCode(t, oversize.Body.String(), "coordinator_stats_error")
}

func TestPublicFeedsAcceptsCoordinatorSizedRateCard(t *testing.T) {
	largeBody := strings.Repeat("a", publicStatsMaxBytes+1)
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/rate-card":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, largeBody), nil
		case "/v1/rate-card.sig":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardSig), nil
		default:
			t.Errorf("unexpected upstream %s", r.URL.String())
			return responseWithBody(http.StatusNotFound, nil, ""), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	resp := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusOK)
	if resp.Body.String() != largeBody {
		t.Fatalf("rate-card len=%d want coordinator-valid size %d", resp.Body.Len(), len(largeBody))
	}
}

func TestPublicFeedsRejectsOversizedRateCard(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.Path {
		case "/v1/rate-card":
			return &http.Response{
				StatusCode: http.StatusOK,
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(strings.Repeat("x", publicRateCardMaxBytes+2))),
			}, nil
		case "/v1/rate-card.sig":
			return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardSig), nil
		default:
			t.Errorf("unexpected upstream %s", r.URL.String())
			return responseWithBody(http.StatusNotFound, nil, ""), nil
		}
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	resp := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusBadGateway)
	assertErrorCode(t, resp.Body.String(), "coordinator_rate_card_error")
}

func TestPublicFeedsCoordinatorUnavailable(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return nil, io.ErrUnexpectedEOF
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	resp := assertStatus(t, h, http.MethodGet, "/v1/rate-card", "", "", "192.0.2.10", http.StatusServiceUnavailable)
	assertErrorCode(t, resp.Body.String(), "coordinator_unavailable")
}

func TestPublicFeedsCORSMatchesStatus(t *testing.T) {
	client := &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
		return responseWithBody(http.StatusOK, http.Header{"Content-Type": []string{"application/json"}}, testRateCardBody), nil
	})}
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.BuyerURL = "http://buyer.test"
		cfg.Coordinator.OperatorURL = "http://operator.test"
	}, WithHTTPClient(client))

	req := httptest.NewRequest(http.MethodGet, "/v1/rate-card", nil)
	req.Header.Set("Origin", "https://malibu.tech")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "https://malibu.tech" {
		t.Fatalf("allow-origin=%q", got)
	}
	if !strings.Contains(resp.Header().Get("Vary"), "Origin") {
		t.Fatalf("vary missing Origin: %q", resp.Header().Get("Vary"))
	}

	preflight := httptest.NewRequest(http.MethodOptions, "/v1/stats/overview", nil)
	preflight.Header.Set("Origin", "https://malibu.tech")
	preflight.Header.Set("Access-Control-Request-Method", "GET")
	preflightResp := httptest.NewRecorder()
	h.ServeHTTP(preflightResp, preflight)
	if preflightResp.Code != http.StatusNoContent {
		t.Fatalf("preflight status=%d", preflightResp.Code)
	}
	if got := preflightResp.Header().Get("Access-Control-Allow-Methods"); got != http.MethodGet {
		t.Fatalf("allow-methods=%q", got)
	}
}

func TestPublicUpstreamURLRejectsNonHTTP(t *testing.T) {
	if _, err := publicUpstreamURL("file:///etc/passwd", "/v1/rate-card"); err == nil {
		t.Fatal("file URL must be rejected")
	}
	if _, err := publicUpstreamURL("/relative", "/v1/rate-card"); err == nil {
		t.Fatal("relative URL must be rejected")
	}
	got, err := publicUpstreamURL("http://buyer.test/base", "/v1/rate-card")
	if err != nil {
		t.Fatalf("url: %v", err)
	}
	if got != "http://buyer.test/base/v1/rate-card" {
		t.Fatalf("resolved=%q", got)
	}
}

func TestAPINginxKeepsPublicFeedsOnGatewayMux(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "dist", "nginx-api.malibu.tech.conf"))
	if err != nil {
		t.Fatalf("read nginx: %v", err)
	}
	cfg := string(b)
	v1 := strings.Index(cfg, "location /v1/ {")
	if v1 < 0 {
		t.Fatal("buyer nginx missing location /v1/")
	}
	if !strings.Contains(cfg[v1:], "proxy_pass http://127.0.0.1:9443;") {
		t.Fatal("buyer /v1/ must keep proxying to the gateway")
	}
	for _, path := range []string{
		"location = /v1/rate-card",
		"location = /v1/rate-card.sig",
		"location = /v1/stats/overview",
		"location = /v1/network-stats",
		"location = /v1/stats/leaderboard",
	} {
		if strings.Contains(cfg, path) {
			t.Fatalf("buyer nginx must not split public feeds off the gateway mux; found %q", path)
		}
	}
}
