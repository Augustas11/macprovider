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
	if !strings.Contains(resp.Header().Get("Vary"), "Origin") {
		t.Fatalf("vary missing Origin: %q", resp.Header().Get("Vary"))
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
	if !strings.Contains(resp.Header().Get("Access-Control-Allow-Headers"), "X-Demo-Token") {
		t.Fatalf("allow-headers=%q", resp.Header().Get("Access-Control-Allow-Headers"))
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
