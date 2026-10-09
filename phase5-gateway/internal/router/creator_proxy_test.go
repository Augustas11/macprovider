package router

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

type creatorUpstreamCall struct {
	method, path, query, body string
	header                    http.Header
}

func TestCreatorProxyForwardsOnlyTheVerifiedPrincipal(t *testing.T) {
	var calls []creatorUpstreamCall
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		calls = append(calls, creatorUpstreamCall{method: r.Method, path: r.URL.Path, query: r.URL.RawQuery, body: string(raw), header: r.Header.Clone()})
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Upstream-Only", "1")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"schema_version":"macprovider.trustpool-admin.v1","ok":true}`))
	}))
	defer coordinator.Close()

	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	key := createAccountAndKey(t, store, cfg, "acct_creator")
	if err := store.AddAccountIdentity(context.Background(), storage.AccountIdentity{
		AccountID: "acct_creator", Provider: "github", ProviderUserID: "4242", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatalf("AddAccountIdentity: %v", err)
	}
	keys, err := store.ListAPIKeys(context.Background(), "acct_creator")
	if err != nil || len(keys) != 1 {
		t.Fatalf("ListAPIKeys = %v err=%v", keys, err)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/creator/pools/AAAAAAAAAAAAAAAAAAAAAA/promote?dry=1", strings.NewReader(`{"reason":"go"}`))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Idempotency-Key", "op-1")
	// Client-supplied principal headers and arbitrary headers never reach the
	// coordinator.
	req.Header.Set("X-MacProvider-Creator-Account-ID", "acct_victim")
	req.Header.Set("X-MacProvider-Creator-GitHub-User-ID", "1")
	req.Header.Set("X-MacProvider-Creator-Credential-ID", "key_victim")
	req.Header.Set("X-MacProvider-Pool", "smuggled")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusAccepted || !strings.Contains(rec.Body.String(), `"ok":true`) {
		t.Fatalf("proxy status=%d body=%s", rec.Code, rec.Body.String())
	}
	if rec.Header().Get("Cache-Control") != "no-store" || rec.Header().Get("X-Upstream-Only") != "" {
		t.Fatalf("response headers = %v", rec.Header())
	}
	if len(calls) != 1 {
		t.Fatalf("upstream calls = %d", len(calls))
	}
	call := calls[0]
	if call.method != http.MethodPost || call.path != "/internal/creator/trust-pools/pools/AAAAAAAAAAAAAAAAAAAAAA/promote" || call.query != "dry=1" || call.body != `{"reason":"go"}` {
		t.Fatalf("upstream call = %+v", call)
	}
	if got := call.header.Get("Authorization"); got != "Bearer service-token" {
		t.Fatalf("upstream Authorization = %q", got)
	}
	if got := call.header.Values("X-MacProvider-Creator-Account-ID"); len(got) != 1 || got[0] != "acct_creator" {
		t.Fatalf("upstream account = %v", got)
	}
	if got := call.header.Values("X-MacProvider-Creator-GitHub-User-ID"); len(got) != 1 || got[0] != "4242" {
		t.Fatalf("upstream github = %v", got)
	}
	if got := call.header.Values("X-MacProvider-Creator-Credential-ID"); len(got) != 1 || got[0] != keys[0].KeyID {
		t.Fatalf("upstream credential = %v, want %s", got, keys[0].KeyID)
	}
	if call.header.Get("Idempotency-Key") != "op-1" || call.header.Get("X-MacProvider-Pool") != "" {
		t.Fatalf("upstream headers = %v", call.header)
	}

	// An account without a linked GitHub identity forwards none.
	plainKey := createAccountAndKey(t, store, cfg, "acct_plain")
	assertStatus(t, h, http.MethodGet, "/v1/creator/providers", plainKey, "", "1.2.3.4", http.StatusAccepted)
	if got := calls[len(calls)-1].header.Values("X-MacProvider-Creator-GitHub-User-ID"); len(got) != 0 {
		t.Fatalf("github header without identity = %v", got)
	}
}

func TestCreatorProxyRejectsUnauthenticatedAndNonKeyCredentials(t *testing.T) {
	upstream := 0
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		upstream++
		w.WriteHeader(http.StatusOK)
	}))
	defer coordinator.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	key := createAccountAndKey(t, store, cfg, "acct_creator")

	assertStatus(t, h, http.MethodGet, "/v1/creator/me", "", "", "1.2.3.4", http.StatusUnauthorized)
	assertStatus(t, h, http.MethodGet, "/v1/creator/me", "mp_live_not_a_key", "", "1.2.3.4", http.StatusUnauthorized)
	assertStatus(t, h, http.MethodGet, "/v1/creator/me", walletSessionBearerPrefix+"session", "", "1.2.3.4", http.StatusForbidden)
	assertStatus(t, h, http.MethodGet, "/v1/creator/me", key, "demo-token", "1.2.3.4", http.StatusForbidden)
	assertStatus(t, h, http.MethodDelete, "/v1/creator/me", key, "", "1.2.3.4", http.StatusMethodNotAllowed)
	assertStatus(t, h, http.MethodGet, "/v1/creator/", key, "", "1.2.3.4", http.StatusNotFound)
	assertStatus(t, h, http.MethodGet, "/v1/creator/pools/a.b", key, "", "1.2.3.4", http.StatusNotFound)
	if upstream != 0 {
		t.Fatalf("rejected requests reached the coordinator %d times", upstream)
	}

	req := httptest.NewRequest(http.MethodPost, "/v1/creator/events", strings.NewReader(strings.Repeat("x", creatorProxyMaxBodyBytes+1)))
	req.Header.Set("Authorization", "Bearer "+key)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusRequestEntityTooLarge || upstream != 0 {
		t.Fatalf("oversized body status=%d upstream=%d", rec.Code, upstream)
	}
}

func TestCreatorProxyMapsUnreachableCoordinatorToBadGateway(t *testing.T) {
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	url := coordinator.URL
	coordinator.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = url
	})
	key := createAccountAndKey(t, store, cfg, "acct_creator")
	rec := assertStatus(t, h, http.MethodGet, "/v1/creator/me", key, "", "1.2.3.4", http.StatusBadGateway)
	if !strings.Contains(rec.Body.String(), "creator_upstream_error") {
		t.Fatalf("body=%s", rec.Body.String())
	}
}

// An upstream 401 means the coordinator refused the gateway service token;
// the caller's key was valid, so the caller sees a gateway fault, not 401.
func TestCreatorProxyMapsUpstreamUnauthorizedToBadGateway(t *testing.T) {
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"code":"unauthorized"}}`))
	}))
	defer coordinator.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	key := createAccountAndKey(t, store, cfg, "acct_creator")
	rec := assertStatus(t, h, http.MethodGet, "/v1/creator/me", key, "", "1.2.3.4", http.StatusBadGateway)
	if !strings.Contains(rec.Body.String(), "creator_upstream_error") {
		t.Fatalf("body=%s", rec.Body.String())
	}
}

func TestCreatorProxyNeverTargetsChat(t *testing.T) {
	for _, target := range []string{"http://c/v1/chat/completions", "http://c/internal/routing", "http://c/internal/creator/../../v1/chat/completions"} {
		if _, err := newCreatorUpstreamRequest(context.Background(), http.MethodPost, target, nil); err == nil {
			t.Fatalf("upstream request built for %s", target)
		}
	}
	req, err := newCreatorUpstreamRequest(context.Background(), http.MethodPost, "http://c/internal/creator/trust-pools/events", []byte(`{}`))
	if err != nil || req.ContentLength != 2 || req.URL.Path != "/internal/creator/trust-pools/events" {
		t.Fatalf("req=%v err=%v", req, err)
	}
}

// #1880: the creator revoke, lifecycle, and pricing-bounds operations are
// reachable through /v1/creator/* with the verified principal and map 1:1
// onto the coordinator's self-serve mount.
func TestCreatorProxyMapsRevokeLifecycleAndPricingBounds(t *testing.T) {
	var calls []creatorUpstreamCall
	coordinator := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		calls = append(calls, creatorUpstreamCall{method: r.Method, path: r.URL.Path, body: string(raw), header: r.Header.Clone()})
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer coordinator.Close()
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, func(cfg *config.Config) {
		cfg.Coordinator.OperatorURL = coordinator.URL
	}, WithHTTPClient(coordinator.Client()))
	key := createAccountAndKey(t, store, cfg, "acct_creator")
	const pool = "AAAAAAAAAAAAAAAAAAAAAA"
	for _, tc := range []struct{ method, path, body, upstream string }{
		{http.MethodPost, "/v1/creator/events", `{"event_type":"member_revoked","pool_id":"` + pool + `","provider_id":"mp-1"}`, "/internal/creator/trust-pools/events"},
		{http.MethodPost, "/v1/creator/pools/" + pool + "/lifecycle", `{"lifecycle":"draining","reason":"done"}`, "/internal/creator/trust-pools/pools/" + pool + "/lifecycle"},
		{http.MethodGet, "/v1/creator/pricing-bounds", "", "/internal/creator/trust-pools/pricing-bounds"},
	} {
		req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		req.Header.Set("Authorization", "Bearer "+key)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusAccepted {
			t.Fatalf("%s %s status=%d body=%s", tc.method, tc.path, rec.Code, rec.Body.String())
		}
		call := calls[len(calls)-1]
		if call.method != tc.method || call.path != tc.upstream || call.body != tc.body || call.header.Get(creatorAccountIDHeader) != "acct_creator" {
			t.Fatalf("%s upstream call = %+v", tc.path, call)
		}
	}
}
