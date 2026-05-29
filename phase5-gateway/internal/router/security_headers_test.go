package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestSensitiveIssuanceResponsesAreNoStore(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{}, WithHTTPClient(modelsOKClient()))

	demoReq := httptest.NewRequest(http.MethodPost, "/auth/demo-session", nil)
	demoReq.Header.Set("X-Real-IP", "1.2.3.4")
	demoResp := httptest.NewRecorder()
	h.ServeHTTP(demoResp, demoReq)
	if demoResp.Code != http.StatusCreated {
		t.Fatalf("demo status=%d body=%s", demoResp.Code, demoResp.Body.String())
	}
	assertNoStore(t, demoResp.Header())

	fullKey := createAccountAndKey(t, store, cfg, "acct_no_store")
	keyReq := httptest.NewRequest(http.MethodPost, "/auth/api-keys", nil)
	keyReq.Header.Set("Authorization", "Bearer "+fullKey)
	keyResp := httptest.NewRecorder()
	h.ServeHTTP(keyResp, keyReq)
	if keyResp.Code != http.StatusCreated {
		t.Fatalf("key status=%d body=%s", keyResp.Code, keyResp.Body.String())
	}
	assertNoStore(t, keyResp.Header())
}

func TestHTMLRoutesSetBrowserSecurityHeaders(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	for _, path := range []string{"/account", "/docs"} {
		resp := assertStatus(t, h, http.MethodGet, path, "", "", "", http.StatusOK)
		if got := resp.Header().Get("X-Content-Type-Options"); got != "nosniff" {
			t.Fatalf("%s nosniff=%q", path, got)
		}
		if got := resp.Header().Get("Referrer-Policy"); got != "no-referrer" {
			t.Fatalf("%s referrer-policy=%q", path, got)
		}
		if got := resp.Header().Get("Permissions-Policy"); !strings.Contains(got, "geolocation=()") {
			t.Fatalf("%s permissions-policy=%q", path, got)
		}
		if got := resp.Header().Get("Content-Security-Policy"); !strings.Contains(got, "frame-ancestors 'none'") {
			t.Fatalf("%s csp=%q", path, got)
		}
	}
}

func assertNoStore(t *testing.T, h http.Header) {
	t.Helper()
	if got := h.Get("Cache-Control"); got != "no-store" {
		t.Fatalf("cache-control=%q", got)
	}
	if got := h.Get("Pragma"); got != "no-cache" {
		t.Fatalf("pragma=%q", got)
	}
	if got := h.Get("Expires"); got != "0" {
		t.Fatalf("expires=%q", got)
	}
}
