package router

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
	"github.com/augstar/macprovider-gateway/internal/storage/sqlite"
)

// failingHandoffStore wraps a Store and forces StoreOAuthHandoff to fail.
// Recovery issues directly to /account only after intent persistence fails.
type failingHandoffStore struct {
	Store
}

func (f *failingHandoffStore) StoreOAuthHandoff(ctx context.Context, handoff storage.OAuthHandoff) error {
	return errors.New("induced handoff persistence failure")
}

// withMalibuReturnTo wires the return_to allowlist + CORS entries used by the
// Malibu handoff tests so the tests exercise the same shape as production.
func withMalibuReturnTo(cfg *config.Config) {
	cfg.Auth.OAuth.ReturnToAllowlist = []string{
		"https://malibu.tech/console/auth/callback.html",
	}
	cfg.CORS.AllowedOrigins = append(cfg.CORS.AllowedOrigins, "https://malibu.tech")
}

func TestReturnToAllowedRejectsPrefixAndTraversal(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, withMalibuReturnTo)
	cases := []struct {
		name    string
		target  string
		allowed bool
	}{
		{"exact", "https://malibu.tech/console/auth/callback.html", true},
		{"case_insensitive_host", "https://MALIBU.TECH/console/auth/callback.html", true},
		{"scheme_mismatch", "http://malibu.tech/console/auth/callback.html", false},
		{"host_mismatch", "https://malibu.tech.attacker.example/console/auth/callback.html", false},
		{"path_extended", "https://malibu.tech/console/auth/callback.html/extra", false},
		{"path_suffix_pun", "https://malibu.tech/console/auth/callback.htmlx", false},
		{"path_traversal_literal", "https://malibu.tech/console/auth/callback.html/../admin", false},
		{"path_traversal_encoded", "https://malibu.tech/console/auth/callback.html/%2E%2E/admin", false},
		{"empty_scheme", "//malibu.tech/console/auth/callback.html", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, "/auth/github/start?return_to="+url.QueryEscape(tc.target)+"&redirect_uri="+url.QueryEscape("https://api.malibu.tech/auth/github/callback"), nil)
			resp := httptest.NewRecorder()
			h.ServeHTTP(resp, req)
			if tc.allowed {
				if resp.Code != http.StatusFound {
					t.Fatalf("expected 302 for allowed %s, got %d body=%s", tc.target, resp.Code, resp.Body.String())
				}
			} else {
				if resp.Code == http.StatusFound {
					t.Fatalf("expected rejection for %s, got 302 with Location=%s", tc.target, resp.Header().Get("Location"))
				}
				if !strings.Contains(resp.Body.String(), "oauth_return_to_not_allowed") {
					t.Fatalf("expected oauth_return_to_not_allowed for %s, got body=%s", tc.target, resp.Body.String())
				}
			}
		})
	}
}

func TestOAuthHandoffFlowRoundTrip(t *testing.T) {
	identity := auth.OAuthIdentity{ProviderUserID: "handoff-user", Scopes: []string{"read:user"}}
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{identity: identity}, withMalibuReturnTo)
	returnTo := "https://malibu.tech/console/auth/callback.html"

	startPath := "/auth/github/start?redirect_uri=" + url.QueryEscape("https://api.malibu.tech/auth/github/callback") + "&return_to=" + url.QueryEscape(returnTo)
	startReq := httptest.NewRequest(http.MethodGet, startPath, nil)
	startResp := httptest.NewRecorder()
	h.ServeHTTP(startResp, startReq)
	if startResp.Code != http.StatusFound {
		t.Fatalf("start status=%d body=%s", startResp.Code, startResp.Body.String())
	}
	location, err := url.Parse(startResp.Header().Get("Location"))
	if err != nil {
		t.Fatalf("parse start location: %v", err)
	}
	state := location.Query().Get("state")
	if state == "" {
		t.Fatal("state missing from start redirect")
	}

	callbackReq := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	for _, c := range startResp.Result().Cookies() {
		callbackReq.AddCookie(c)
	}
	callbackResp := httptest.NewRecorder()
	h.ServeHTTP(callbackResp, callbackReq)
	if callbackResp.Code != http.StatusFound {
		t.Fatalf("callback status=%d body=%s", callbackResp.Code, callbackResp.Body.String())
	}
	callbackLoc, err := url.Parse(callbackResp.Header().Get("Location"))
	if err != nil {
		t.Fatalf("parse callback location: %v", err)
	}
	if !strings.EqualFold(callbackLoc.Host, "malibu.tech") || callbackLoc.Path != "/console/auth/callback.html" {
		t.Fatalf("callback did not redirect to Malibu return_to, got %s", callbackLoc.String())
	}
	handoff := callbackLoc.Query().Get("handoff")
	if handoff == "" {
		t.Fatalf("callback did not include handoff query, location=%s", callbackLoc.String())
	}
	if got := callbackResp.Header().Get("Referrer-Policy"); got != "no-referrer" {
		t.Fatalf("Referrer-Policy=%q want no-referrer (token leaks via referrer chain otherwise)", got)
	}
	if got := callbackResp.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("Cache-Control=%q want no-store", got)
	}
	if findCookie(callbackResp, "mp_new_api_key") != "" {
		t.Fatal("handoff callback must not issue or expose a key before exchange")
	}
	account, err := store.LookupAccountByIdentity(context.Background(), "github", identity.ProviderUserID)
	if err != nil {
		t.Fatal(err)
	}
	if keys, err := store.ListAPIKeys(context.Background(), account.AccountID); err != nil || len(keys) != 0 {
		t.Fatalf("keys before exchange=%d err=%v", len(keys), err)
	}

	body, _ := json.Marshal(map[string]string{"handoff": handoff})
	exchangeReq := httptest.NewRequest(http.MethodPost, "/auth/handoff/exchange", bytes.NewReader(body))
	exchangeReq.Header.Set("Content-Type", "application/json")
	exchangeResp := httptest.NewRecorder()
	h.ServeHTTP(exchangeResp, exchangeReq)
	if exchangeResp.Code != http.StatusOK {
		t.Fatalf("exchange status=%d body=%s", exchangeResp.Code, exchangeResp.Body.String())
	}
	if got := exchangeResp.Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("exchange Cache-Control=%q want no-store", got)
	}
	var reply struct {
		APIKey string `json:"api_key"`
	}
	if err := json.Unmarshal(exchangeResp.Body.Bytes(), &reply); err != nil {
		t.Fatalf("decode exchange body: %v", err)
	}
	if !strings.HasPrefix(reply.APIKey, "mp_") {
		t.Fatalf("api_key=%q must start with mp_", reply.APIKey)
	}
	manager := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret)
	if validation, err := manager.Validate(context.Background(), store, reply.APIKey); err != nil || validation.AccountID != account.AccountID {
		t.Fatalf("exchanged key account=%q err=%v", validation.AccountID, err)
	}
	for _, path := range []string{cfg.Storage.DBPath, cfg.Storage.DBPath + "-wal"} {
		data, err := os.ReadFile(path)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(data, []byte(reply.APIKey)) || bytes.Contains(data, []byte(handoff)) {
			t.Fatal("OAuth flow persisted a raw credential")
		}
	}

	// Replay must fail with the same generic error surface.
	replayReq := httptest.NewRequest(http.MethodPost, "/auth/handoff/exchange", bytes.NewReader(body))
	replayReq.Header.Set("Content-Type", "application/json")
	replayResp := httptest.NewRecorder()
	h.ServeHTTP(replayResp, replayReq)
	if replayResp.Code != http.StatusBadRequest {
		t.Fatalf("replay status=%d want 400 body=%s", replayResp.Code, replayResp.Body.String())
	}
	if !strings.Contains(replayResp.Body.String(), "invalid_handoff") {
		t.Fatalf("replay body=%q want invalid_handoff", replayResp.Body.String())
	}
	if keys, err := store.ListAPIKeys(context.Background(), account.AccountID); err != nil || len(keys) != 1 {
		t.Fatalf("keys after replay=%d err=%v", len(keys), err)
	}
}

// TestOAuthHandoffPersistenceFailureRedirectsToAccount pins the recovery
// contract when intent persistence fails: issue once to the gateway cookie
// and redirect to /account, without requiring a handoff exchange.
func TestOAuthHandoffPersistenceFailureRedirectsToAccount(t *testing.T) {
	identity := auth.OAuthIdentity{ProviderUserID: "handoff-fail-user", Scopes: []string{"read:user"}}
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Auth.OAuth.GitHub.ClientID = "client-id"
	cfg.Auth.OAuth.GitHub.ClientSecret = "client-secret"
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Auth.OAuth.CallbackAllowlist = []string{"https://api.malibu.tech/auth/github/callback"}
	cfg.Storage.DBPath = filepath.Join(t.TempDir(), "gateway.db")
	withMalibuReturnTo(&cfg)

	realStore, err := sqlite.Open(context.Background(), cfg.Storage.DBPath)
	if err != nil {
		t.Fatalf("sqlite.Open: %v", err)
	}
	t.Cleanup(func() { _ = realStore.Close() })
	wrapped := &failingHandoffStore{Store: realStore}
	h := New(cfg, wrapped, fakeOAuth{identity: identity}, WithNow(fixedNow)).Handler()

	returnTo := "https://malibu.tech/console/auth/callback.html"
	startPath := "/auth/github/start?redirect_uri=" + url.QueryEscape("https://api.malibu.tech/auth/github/callback") + "&return_to=" + url.QueryEscape(returnTo)
	startReq := httptest.NewRequest(http.MethodGet, startPath, nil)
	startResp := httptest.NewRecorder()
	h.ServeHTTP(startResp, startReq)
	if startResp.Code != http.StatusFound {
		t.Fatalf("start status=%d body=%s", startResp.Code, startResp.Body.String())
	}
	location, err := url.Parse(startResp.Header().Get("Location"))
	if err != nil {
		t.Fatalf("parse start location: %v", err)
	}
	state := location.Query().Get("state")

	callbackReq := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(state), nil)
	for _, c := range startResp.Result().Cookies() {
		callbackReq.AddCookie(c)
	}
	callbackResp := httptest.NewRecorder()
	h.ServeHTTP(callbackResp, callbackReq)
	if callbackResp.Code != http.StatusFound {
		t.Fatalf("callback status=%d body=%s", callbackResp.Code, callbackResp.Body.String())
	}
	if got := callbackResp.Header().Get("Location"); got != cfg.Public.AccountPath {
		t.Fatalf("failure redirect Location=%q want %q — recovery must anchor to gateway /account, not Malibu", got, cfg.Public.AccountPath)
	}
	if findCookie(callbackResp, "mp_new_api_key") == "" {
		t.Fatal("mp_new_api_key cookie missing on handoff-failure redirect — /account cannot deliver the key without it")
	}
}

func TestHandoffExchangeErrorSurface(t *testing.T) {
	h, _, _, _ := newTestHarnessConfig(t, fakeOAuth{}, withMalibuReturnTo)

	// Wrong method: 405.
	getReq := httptest.NewRequest(http.MethodGet, "/auth/handoff/exchange", nil)
	getResp := httptest.NewRecorder()
	h.ServeHTTP(getResp, getReq)
	if getResp.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET status=%d want 405", getResp.Code)
	}

	// Empty body: 400 invalid_handoff.
	emptyReq := httptest.NewRequest(http.MethodPost, "/auth/handoff/exchange", strings.NewReader(""))
	emptyResp := httptest.NewRecorder()
	h.ServeHTTP(emptyResp, emptyReq)
	if emptyResp.Code != http.StatusBadRequest || !strings.Contains(emptyResp.Body.String(), "invalid_handoff") {
		t.Fatalf("empty body status=%d body=%s", emptyResp.Code, emptyResp.Body.String())
	}

	// Unknown token: same error code (no distinguisher).
	unknownBody, _ := json.Marshal(map[string]string{"handoff": "notatoken"})
	unknownReq := httptest.NewRequest(http.MethodPost, "/auth/handoff/exchange", bytes.NewReader(unknownBody))
	unknownReq.Header.Set("Content-Type", "application/json")
	unknownResp := httptest.NewRecorder()
	h.ServeHTTP(unknownResp, unknownReq)
	if unknownResp.Code != http.StatusBadRequest || !strings.Contains(unknownResp.Body.String(), "invalid_handoff") {
		t.Fatalf("unknown token status=%d body=%s", unknownResp.Code, unknownResp.Body.String())
	}
}

func TestOAuthHandoffConcurrentHTTPExchange(t *testing.T) {
	h, store, _, cfg := newTestHarnessConfig(t, fakeOAuth{}, withMalibuReturnTo)
	ctx := context.Background()
	if err := store.CreateAccount(ctx, storage.Account{
		AccountID: "acct_handoff", Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: fixedNow(),
	}); err != nil {
		t.Fatal(err)
	}
	token, err := auth.StateToken()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.StoreOAuthHandoff(ctx, storage.OAuthHandoff{
		TokenHash: auth.StateHash(token), AccountID: "acct_handoff", Action: "mint",
		CreatedAt: fixedNow(), ExpiresAt: fixedNow().Add(5 * time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	body, _ := json.Marshal(map[string]string{"handoff": token})
	var succeeded atomic.Int32
	var rejected atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	for i := 0; i < 16; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			response := httptest.NewRecorder()
			h.ServeHTTP(response, httptest.NewRequest(http.MethodPost, "/auth/handoff/exchange", bytes.NewReader(body)))
			switch response.Code {
			case http.StatusOK:
				succeeded.Add(1)
				var reply struct {
					APIKey string `json:"api_key"`
				}
				if err := json.Unmarshal(response.Body.Bytes(), &reply); err != nil {
					t.Errorf("decode: %v", err)
					return
				}
				manager := auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret)
				if validation, err := manager.Validate(ctx, store, reply.APIKey); err != nil || validation.AccountID != "acct_handoff" {
					t.Errorf("issued key account=%q err=%v", validation.AccountID, err)
				}
			case http.StatusBadRequest:
				rejected.Add(1)
				if !strings.Contains(response.Body.String(), "invalid_handoff") {
					t.Error("replay response did not use generic invalid_handoff")
				}
			default:
				t.Errorf("exchange status=%d", response.Code)
			}
		}()
	}
	close(start)
	wg.Wait()
	if succeeded.Load() != 1 || rejected.Load() != 15 {
		t.Fatalf("succeeded=%d rejected=%d", succeeded.Load(), rejected.Load())
	}
	if keys, err := store.ListAPIKeys(ctx, "acct_handoff"); err != nil || len(keys) != 1 {
		t.Fatalf("issued keys=%d err=%v", len(keys), err)
	}
}

func TestOAuthHandoffExistingAccountIntent(t *testing.T) {
	for _, action := range []string{"", "mint"} {
		t.Run("action_"+action, func(t *testing.T) {
			ctx := context.Background()
			identity := auth.OAuthIdentity{ProviderUserID: "existing-handoff", Scopes: []string{"read:user"}}
			h, store, _, _ := newTestHarnessConfig(t, fakeOAuth{identity: identity}, withMalibuReturnTo)
			completeOAuth(t, h, "", "https://api.malibu.tech/auth/github/callback")
			account, err := store.LookupAccountByIdentity(ctx, "github", identity.ProviderUserID)
			if err != nil {
				t.Fatal(err)
			}
			query := url.Values{"action": {action}, "return_to": {"https://malibu.tech/console/auth/callback.html"}}
			start := httptest.NewRecorder()
			h.ServeHTTP(start, httptest.NewRequest(http.MethodGet, "/auth/github/start?"+query.Encode(), nil))
			location, err := url.Parse(start.Header().Get("Location"))
			if err != nil || start.Code != http.StatusFound {
				t.Fatalf("start status=%d err=%v", start.Code, err)
			}
			callback := httptest.NewRequest(http.MethodGet, "/auth/github/callback?code=ok&state="+url.QueryEscape(location.Query().Get("state")), nil)
			for _, cookie := range start.Result().Cookies() {
				callback.AddCookie(cookie)
			}
			response := httptest.NewRecorder()
			h.ServeHTTP(response, callback)
			if response.Code != http.StatusFound || findCookie(response, "mp_new_api_key") != "" {
				t.Fatalf("callback status=%d or premature key cookie", response.Code)
			}
			if keys, err := store.ListAPIKeys(ctx, account.AccountID); err != nil || len(keys) != 1 {
				t.Fatalf("keys before exchange=%d err=%v", len(keys), err)
			}
			target, err := url.Parse(response.Header().Get("Location"))
			if err != nil {
				t.Fatal(err)
			}
			token := target.Query().Get("handoff")
			if action == "" {
				if token != "" || target.Query().Get("error") != "no_key" {
					t.Fatal("plain sign-in unexpectedly created an issuance intent")
				}
				return
			}
			body, _ := json.Marshal(map[string]string{"handoff": token})
			exchange := httptest.NewRecorder()
			h.ServeHTTP(exchange, httptest.NewRequest(http.MethodPost, "/auth/handoff/exchange", bytes.NewReader(body)))
			if exchange.Code != http.StatusOK {
				t.Fatalf("exchange status=%d", exchange.Code)
			}
			if keys, err := store.ListAPIKeys(ctx, account.AccountID); err != nil || len(keys) != 2 {
				t.Fatalf("keys after mint=%d err=%v", len(keys), err)
			}
		})
	}
}

// TestReturnToConfigRequiresMatchingCORSOrigin locks in the config-time
// cross-check between auth.oauth.return_to_allowlist and cors.allowed_origins.
// Without this, an operator can add a Malibu return-to entry, ship it, and
// see the OAuth flow silently break on the browser-side exchange.
func TestReturnToConfigRequiresMatchingCORSOrigin(t *testing.T) {
	cfg := baselineValidConfig(t)
	cfg.Auth.OAuth.ReturnToAllowlist = []string{"https://accounts.malibu.tech/console/auth/callback.html"}
	// Deliberately DO NOT add accounts.malibu.tech to CORS.AllowedOrigins.
	err := cfg.Validate()
	if err == nil {
		t.Fatal("Validate must reject a return_to entry without matching CORS origin")
	}
	if !strings.Contains(err.Error(), "missing matching cors.allowed_origins") {
		t.Fatalf("error=%v want missing-cors-origins message", err)
	}

	cfg.CORS.AllowedOrigins = append(cfg.CORS.AllowedOrigins, "https://accounts.malibu.tech")
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate with matching CORS origin failed: %v", err)
	}
}

func baselineValidConfig(t *testing.T) config.Config {
	t.Helper()
	cfg := config.Default()
	cfg.Auth.KeyHashSecret = "test-key-hash-secret"
	cfg.Auth.Demo.SigningSecret = "test-demo-secret"
	cfg.Auth.OAuth.GitHub.ClientID = "client-id"
	cfg.Auth.OAuth.GitHub.ClientSecret = "client-secret"
	cfg.Coordinator.OperatorKey = "operator-key"
	cfg.Coordinator.ServiceToken = "service-token"
	cfg.Auth.OAuth.CallbackAllowlist = []string{"https://api.malibu.tech/auth/github/callback"}
	return cfg
}
