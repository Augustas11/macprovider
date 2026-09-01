package router

import (
	"encoding/json"
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

	var rotated struct {
		APIKey string `json:"api_key"`
		KeyID  string `json:"key_id"`
	}
	if err := json.Unmarshal(keyResp.Body.Bytes(), &rotated); err != nil {
		t.Fatalf("rotate json: %v", err)
	}
	revokeReq := httptest.NewRequest(http.MethodPost, "/auth/api-keys/"+rotated.KeyID+"/revoke", nil)
	revokeReq.Header.Set("Authorization", "Bearer "+rotated.APIKey)
	revokeResp := httptest.NewRecorder()
	h.ServeHTTP(revokeResp, revokeReq)
	if revokeResp.Code != http.StatusOK {
		t.Fatalf("revoke status=%d", revokeResp.Code)
	}
	assertNoStore(t, revokeResp.Header())
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
		if got := resp.Header().Get("Content-Security-Policy"); strings.Contains(got, "script-src 'unsafe-inline'") {
			t.Fatalf("%s csp allows inline script: %q", path, got)
		}
	}
}

func TestAccountPageScriptUsesCSPNonce(t *testing.T) {
	h, _, _, _ := newTestHarness(t, fakeOAuth{})
	resp := assertStatus(t, h, http.MethodGet, "/account", "", "", "", http.StatusOK)
	csp := resp.Header().Get("Content-Security-Policy")
	marker := "script-src 'nonce-"
	start := strings.Index(csp, marker)
	if start < 0 {
		t.Fatalf("account csp missing nonce: %q", csp)
	}
	nonceStart := start + len(marker)
	nonceEnd := strings.Index(csp[nonceStart:], "'")
	if nonceEnd < 0 {
		t.Fatalf("account csp malformed nonce: %q", csp)
	}
	nonce := csp[nonceStart : nonceStart+nonceEnd]
	if nonce == "" {
		t.Fatalf("account csp empty nonce: %q", csp)
	}
	if !strings.Contains(resp.Body.String(), `<script nonce="`+nonce+`">`) {
		t.Fatalf("account script nonce does not match csp nonce %q", nonce)
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
