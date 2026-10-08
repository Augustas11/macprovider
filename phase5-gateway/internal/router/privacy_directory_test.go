package router

import (
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
)

func getPrivacyDirectory(h http.Handler, key string, headers map[string]string) *httptest.ResponseRecorder {
	r := httptest.NewRequest(http.MethodGet, privacyDirectoryRoute, nil)
	if key != "" {
		r.Header.Set("Authorization", "Bearer "+key)
	}
	for name, value := range headers {
		r.Header.Set(name, value)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

// SPEC-049-R028: the gateway forwards the coordinator's signed directory
// byte for byte, adds no trust, and maps failures to the privacy inventory.
func TestPrivacyDirectoryPassthrough(t *testing.T) {
	const envelope = `{"version":"privacy-identity-directory-envelope-v1","key_id":"k","payload":"p","signature":"s"}`
	var hops int
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hops++
		if r.URL.Path != privacyDirectoryRoute || r.Method != http.MethodGet {
			t.Errorf("upstream %s %s", r.Method, r.URL.Path)
		}
		if r.Header.Get("X-MacProvider-Account") == "" || r.Header.Get("Authorization") == "" {
			t.Error("upstream hop lacks trusted gateway context")
		}
		io.WriteString(w, envelope)
	}))
	defer upstream.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-directory")

	if resp := getPrivacyDirectory(h, "", nil); resp.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated directory = %d %s", resp.Code, resp.Body.String())
	}
	resp := getPrivacyDirectory(h, key, nil)
	if resp.Code != http.StatusOK || resp.Body.String() != envelope || resp.Header().Get("Cache-Control") == "" {
		t.Fatalf("directory = %d %v %s", resp.Code, resp.Header(), resp.Body.String())
	}
	if resp := getPrivacyDirectory(h, key, map[string]string{poolSelectHeader: "pool"}); resp.Code != http.StatusBadRequest {
		t.Fatalf("pool-scoped directory = %d", resp.Code)
	}
	post := postPrivacy(h, key, privacyDirectoryRoute, nil, nil)
	if post.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST directory = %d", post.Code)
	}
	if hops != 1 {
		t.Fatalf("upstream hops = %d", hops)
	}
}

func TestPrivacyDirectoryDisabledAndUpstreamErrors(t *testing.T) {
	status, body := http.StatusServiceUnavailable, `{"error":{"code":"privacy_class_disabled"}}`
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(status)
		io.WriteString(w, body)
	}))
	defer upstream.Close()

	off, offStore, _, offCfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		c.Features.RelayBlindRequests.Enabled = true
		c.Coordinator.BuyerURL = upstream.URL
	})
	offKey := createAccountAndKey(t, offStore, offCfg, "privacy-directory-off")
	resp := getPrivacyDirectory(off, offKey, nil)
	assertPrivacyError(t, resp.Body.String(), http.StatusServiceUnavailable, privacyClassDisabled, "none", "")

	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(c *config.Config) {
		enablePrivacy(c)
		c.Coordinator.BuyerURL = upstream.URL
	})
	key := createAccountAndKey(t, store, cfg, "privacy-directory-errors")
	resp = getPrivacyDirectory(h, key, nil)
	assertPrivacyError(t, resp.Body.String(), http.StatusServiceUnavailable, privacyClassDisabled, "none", "")

	status, body = http.StatusInternalServerError, `{"error":{"code":"internal_detail_leak"}}`
	resp = getPrivacyDirectory(h, key, nil)
	assertPrivacyError(t, resp.Body.String(), http.StatusServiceUnavailable, privacyClassUnavailable, "none", "")
}
