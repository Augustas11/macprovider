package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCORSAllowedOriginHeaders(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("Origin", "https://console.streamvc.live")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusOK {
		t.Fatalf("status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "https://console.streamvc.live" {
		t.Fatalf("allow-origin=%q", got)
	}
	if got := resp.Header().Get("Access-Control-Allow-Credentials"); got != "false" {
		t.Fatalf("allow-credentials=%q", got)
	}
	if got := resp.Header().Get("Access-Control-Expose-Headers"); got != "X-Request-ID" {
		t.Fatalf("expose-headers=%q", got)
	}
	if !strings.Contains(resp.Header().Get("Vary"), "Origin") {
		t.Fatalf("vary missing Origin: %q", resp.Header().Get("Vary"))
	}
}

func TestCORSApexOriginIsIntentionalFirstPartyOrigin(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("Origin", "https://streamvc.live")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "https://streamvc.live" {
		t.Fatalf("apex allow-origin=%q", got)
	}
}

func TestCORSDisallowedOriginNoHeaders(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("Origin", "https://attacker.com")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("unexpected allow-origin=%q", resp.Header().Get("Access-Control-Allow-Origin"))
	}
	if resp.Header().Get("Access-Control-Allow-Credentials") != "" {
		t.Fatalf("unexpected allow-credentials=%q", resp.Header().Get("Access-Control-Allow-Credentials"))
	}
}

func TestCORSPreflight(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodOptions, "/v1/chat/completions", nil)
	req.Header.Set("Origin", "https://console.streamvc.live")
	req.Header.Set("Access-Control-Request-Method", "POST")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusNoContent {
		t.Fatalf("preflight status=%d body=%s", resp.Code, resp.Body.String())
	}
	if got := resp.Header().Get("Access-Control-Allow-Origin"); got != "https://console.streamvc.live" {
		t.Fatalf("allow-origin=%q", got)
	}
	if got := resp.Header().Get("Access-Control-Allow-Methods"); got != "POST" {
		t.Fatalf("allow-methods=%q", got)
	}
	if got := resp.Header().Get("Access-Control-Max-Age"); got != "3600" {
		t.Fatalf("max-age=%q", got)
	}
	allowHeaders := resp.Header().Get("Access-Control-Allow-Headers")
	for _, want := range []string{"Anthropic-Beta", "Anthropic-Version", "X-Api-Key", "X-Demo-Token"} {
		if !strings.Contains(allowHeaders, want) {
			t.Fatalf("allow-headers=%q missing %s", allowHeaders, want)
		}
	}
}

func TestCORSOriginCaseSensitive(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	req := httptest.NewRequest(http.MethodGet, "/v1/status", nil)
	req.Header.Set("Origin", "https://Console.streamvc.live")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("mixed-case origin was allowed")
	}
}

func TestCORSNotAppliedToNonDemoEndpoints(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))
	for _, path := range []string{"/account", "/auth/github/callback", "/admin/feedback-summary"} {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.Header.Set("Origin", "https://console.streamvc.live")
		resp := httptest.NewRecorder()
		h.ServeHTTP(resp, req)
		if resp.Header().Get("Access-Control-Allow-Origin") != "" {
			t.Fatalf("%s unexpectedly got CORS header", path)
		}
	}
}
