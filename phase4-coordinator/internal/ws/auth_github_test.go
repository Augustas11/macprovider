package ws

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	mpgithub "github.com/augstar/macprovider-coordinator/internal/github"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/session"
	"github.com/rs/zerolog"
)

func TestReturnTo_RejectsOpenRedirectVectors(t *testing.T) {
	tests := map[string]string{
		"/":                   "/",
		"/dashboard":          "/dashboard",
		"//evil.example/path": "/",
		`/\evil`:              "/",
		"%2F%2Fevil.example":  "/",
		"/foo?bar=baz":        "/foo?bar=baz",
		"/bad@host":           "/",
		"/bad%0Apath":         "/",
	}
	for input, want := range tests {
		if got := normalizeReturnTo(input); got != want {
			t.Fatalf("normalizeReturnTo(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestPairOTQueryPattern(t *testing.T) {
	valid := []string{"abc", "ABC_123-xyz", "a"}
	for _, v := range valid {
		if !pairOTQueryPattern.MatchString(v) {
			t.Fatalf("pair_ot %q should be valid", v)
		}
	}
	invalid := []string{"", "has/slash", "has%2fescape", "line\nbreak"}
	for _, v := range invalid {
		if pairOTQueryPattern.MatchString(v) {
			t.Fatalf("pair_ot %q should be invalid", v)
		}
	}
}

func TestGitHubAuthRoutes_Disabled_Return404(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, false)
	req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start", nil)
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want 404", rr.Code)
	}
}

func TestGitHubAuthDisabled_DoesNotInstallRequestLogMiddleware(t *testing.T) {
	var logs bytes.Buffer
	logger := zerolog.New(&logs)
	s, _ := newSpec014AuthTestServerWithClient(t, false, logger, fakeSpec014GitHubClient{})
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if strings.Contains(logs.String(), "provider http request") {
		t.Fatalf("default-off handler emitted GitHub auth request log: %s", logs.String())
	}
}

func TestGitHubStart_MalformedPairOTQuery_Returns400(t *testing.T) {
	var logs bytes.Buffer
	logger := zerolog.New(&logs)
	s, _ := newSpec014AuthTestServerWithClient(t, true, logger, fakeSpec014GitHubClient{})
	req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start?pair_ot=SECRET;x=1", nil)
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	assertAuthError(t, rr, http.StatusBadRequest, "bad_request")
	if strings.Contains(logs.String(), "SECRET") {
		t.Fatalf("request log leaked malformed pair_ot: %s", logs.String())
	}
}

func TestGitHubCallback_StateRace_OneSucceedsOneInvalid(t *testing.T) {
	s, store := newSpec014AuthTestServer(t, true)
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	if err := store.CreateOAuthState(context.Background(), "race-state", "/", nil, now); err != nil {
		t.Fatalf("CreateOAuthState: %v", err)
	}
	handler := s.Handler()
	codes := make(chan int, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/callback?state=race-state&code=ok", nil)
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			codes <- rr.Code
		}()
	}
	wg.Wait()
	close(codes)

	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[http.StatusFound] != 1 || counts[http.StatusBadRequest] != 1 {
		t.Fatalf("status counts = %#v, want one 302 and one 400", counts)
	}
}

func TestGitHubCallbackRejectsOriginHashMismatch(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, true)
	start := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start", nil)
	start.RemoteAddr = "198.51.100.10:1234"
	start.Header.Set("User-Agent", "origin-a")
	startRR := httptest.NewRecorder()
	s.Handler().ServeHTTP(startRR, start)
	if startRR.Code != http.StatusFound {
		t.Fatalf("start status=%d body=%s", startRR.Code, startRR.Body.String())
	}
	redirect, err := url.Parse(startRR.Header().Get("Location"))
	if err != nil {
		t.Fatalf("parse redirect: %v", err)
	}
	state := redirect.Query().Get("state")
	if state == "" {
		t.Fatalf("missing state in redirect %q", redirect.String())
	}
	callback := httptest.NewRequest(http.MethodGet, "/v1/auth/github/callback?state="+url.QueryEscape(state)+"&code=ok", nil)
	callback.RemoteAddr = "198.51.100.11:5678"
	callback.Header.Set("User-Agent", "origin-a")
	callbackRR := httptest.NewRecorder()
	s.Handler().ServeHTTP(callbackRR, callback)
	assertAuthError(t, callbackRR, http.StatusBadRequest, "state_invalid")
}

func TestGitHubStartRateLimitsOAuthStatesByOrigin(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, true)
	handler := s.Handler()
	for i := 0; i < 20; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start", nil)
		req.RemoteAddr = "198.51.100.20:1234"
		req.Header.Set("User-Agent", "origin-rate")
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code != http.StatusFound {
			t.Fatalf("start %d status=%d body=%s, want 302", i, rr.Code, rr.Body.String())
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start", nil)
	req.RemoteAddr = "198.51.100.20:1234"
	req.Header.Set("User-Agent", "origin-rate")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	assertAuthError(t, rr, http.StatusTooManyRequests, "rate_limited")
}

func TestGitHubStartRateLimitIgnoresSpoofedForwardedHeaders(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, true)
	handler := s.Handler()
	for i := 0; i < 20; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start", nil)
		req.RemoteAddr = "198.51.100.30:1234"
		req.Header.Set("User-Agent", "origin-spoof")
		req.Header.Set("X-Forwarded-For", "203.0.113."+itoa(i+1))
		req.Header.Set("X-Real-IP", "203.0.113."+itoa(i+101))
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if rr.Code != http.StatusFound {
			t.Fatalf("start %d status=%d body=%s, want 302", i, rr.Code, rr.Body.String())
		}
	}

	req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start", nil)
	req.RemoteAddr = "198.51.100.30:1234"
	req.Header.Set("User-Agent", "origin-spoof")
	req.Header.Set("X-Forwarded-For", "203.0.113.250")
	req.Header.Set("X-Real-IP", "203.0.113.251")
	rr := httptest.NewRecorder()
	handler.ServeHTTP(rr, req)
	assertAuthError(t, rr, http.StatusTooManyRequests, "rate_limited")
}

func TestGitHubCallback_RequestLogRedactsCodeAndState(t *testing.T) {
	var logs bytes.Buffer
	logger := zerolog.New(&logs)
	s, _ := newSpec014AuthTestServerWithClient(t, true, logger, fakeSpec014GitHubClient{})
	req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/callback?code=SECRET_CODE&state=SECRET_STATE", nil)
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if strings.Contains(logs.String(), "SECRET_CODE") || strings.Contains(logs.String(), "SECRET_STATE") {
		t.Fatalf("request log leaked oauth code/state: %s", logs.String())
	}
}

func TestRandomState_EntropySanity(t *testing.T) {
	seen := map[string]struct{}{}
	for i := 0; i < 10000; i++ {
		state, err := randomState()
		if err != nil {
			t.Fatalf("randomState: %v", err)
		}
		if len(state) != 64 {
			t.Fatalf("state length = %d, want 64 hex chars", len(state))
		}
		if _, err := hex.DecodeString(state); err != nil {
			t.Fatalf("state is not hex: %v", err)
		}
		if _, ok := seen[state]; ok {
			t.Fatalf("duplicate state after %d iterations", i)
		}
		seen[state] = struct{}{}
	}
}

func TestLogout_StaleCookie_Returns204AndClearsCookie(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, true)
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", nil)
	req.AddCookie(&http.Cookie{Name: session.Name, Value: "stale"})
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rr.Code)
	}
	if got := rr.Header().Get("Set-Cookie"); !strings.Contains(got, "mp_session=") || !strings.Contains(got, "Max-Age=0") || !strings.Contains(got, "Path=/") {
		t.Fatalf("Set-Cookie = %q, want mp_session clear", got)
	}
}

func TestLogout_ConfiguredDomainCookie_ClearIncludesDomain(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, true)
	s.cfg.Auth.GitHubOAuth.SessionCookieDomain = ".example.com"
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/logout", nil)
	req.AddCookie(&http.Cookie{Name: session.Name, Value: "stale"})
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204", rr.Code)
	}
	if got := rr.Header().Get("Set-Cookie"); !strings.Contains(got, "Domain=.example.com") {
		t.Fatalf("Set-Cookie = %q, want configured Domain clear", got)
	}
}

func TestAuthMeProviders_TamperedCookie_Returns401AndClearsCookie(t *testing.T) {
	s, _ := newSpec014AuthTestServer(t, true)
	req := httptest.NewRequest(http.MethodGet, "/v1/auth/me/providers", nil)
	req.AddCookie(&http.Cookie{Name: session.Name, Value: "tampered"})
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	assertAuthError(t, rr, http.StatusUnauthorized, "session_invalid")
	if got := rr.Header().Get("Set-Cookie"); !strings.Contains(got, "mp_session=") || !strings.Contains(got, "Max-Age=0") || !strings.Contains(got, "Path=/") {
		t.Fatalf("Set-Cookie = %q, want mp_session clear", got)
	}
}

func TestInstallPairRefresh_RateLimitUsesRefreshSuccessLog(t *testing.T) {
	s, store := newSpec014AuthTestServer(t, true)
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	_, token, err := store.IssueToken(context.Background(), "provider-a", "Provider A")
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	handler := s.Handler()

	for i := 0; i < 6; i++ {
		req := httptest.NewRequest(http.MethodPost, "/v1/install/pair/refresh", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		req.RemoteAddr = "203.0.113.10:1234"
		req.Header.Set("User-Agent", "spec014-test")
		rr := httptest.NewRecorder()
		handler.ServeHTTP(rr, req)
		if i < 5 && rr.Code != http.StatusOK {
			t.Fatalf("refresh %d status = %d, want 200 body=%s", i, rr.Code, rr.Body.String())
		}
		if i == 5 {
			if rr.Code != http.StatusTooManyRequests {
				t.Fatalf("sixth refresh status = %d, want 429 body=%s", rr.Code, rr.Body.String())
			}
			if rr.Header().Get("Retry-After") == "" {
				t.Fatalf("sixth refresh missing Retry-After")
			}
		}
	}
	logs, err := store.ListPairOTMintLog(context.Background(), "provider-a")
	if err != nil {
		t.Fatalf("ListPairOTMintLog: %v", err)
	}
	if len(logs) != 6 {
		t.Fatalf("mint log rows = %d, want 6", len(logs))
	}
	var okRows, rateLimitedRows int
	for _, row := range logs {
		switch row.Outcome {
		case http.StatusOK:
			okRows++
		case http.StatusTooManyRequests:
			rateLimitedRows++
		}
	}
	if okRows != 5 || rateLimitedRows != 1 {
		t.Fatalf("mint log outcomes ok=%d rate_limited=%d, want 5/1", okRows, rateLimitedRows)
	}
}

func TestInstallPairRefresh_UnauthenticatedWrites401Log(t *testing.T) {
	s, store := newSpec014AuthTestServer(t, true)
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	req := httptest.NewRequest(http.MethodPost, "/v1/install/pair/refresh", nil)
	req.RemoteAddr = "203.0.113.10:1234"
	req.Header.Set("User-Agent", "spec014-unauth-test")
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	assertAuthError(t, rr, http.StatusUnauthorized, "unauthenticated")
	logs, err := store.ListPairOTMintLog(context.Background(), "unknown")
	if err != nil {
		t.Fatalf("ListPairOTMintLog: %v", err)
	}
	if len(logs) != 1 || logs[0].Outcome != http.StatusUnauthorized {
		t.Fatalf("mint log rows = %#v, want one 401 unknown row", logs)
	}
}

func TestInstallPairRefresh_ConcurrentRequestsCappedAtFive(t *testing.T) {
	s, store := newSpec014AuthTestServer(t, true)
	now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
	s.now = func() time.Time { return now }
	_, token, err := store.IssueToken(context.Background(), "provider-a", "Provider A")
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	handler := s.Handler()
	const requests = 20
	codes := make(chan int, requests)
	var wg sync.WaitGroup
	for i := 0; i < requests; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			req := httptest.NewRequest(http.MethodPost, "/v1/install/pair/refresh", nil)
			req.Header.Set("Authorization", "Bearer "+token)
			req.RemoteAddr = "203.0.113.10:1234"
			req.Header.Set("User-Agent", "spec014-concurrent-test")
			rr := httptest.NewRecorder()
			handler.ServeHTTP(rr, req)
			codes <- rr.Code
		}(i)
	}
	wg.Wait()
	close(codes)
	counts := map[int]int{}
	for code := range codes {
		counts[code]++
	}
	if counts[http.StatusOK] != 5 || counts[http.StatusTooManyRequests] != requests-5 {
		t.Fatalf("status counts = %#v, want 5x200 and %dx429", counts, requests-5)
	}
	logs, err := store.ListPairOTMintLog(context.Background(), "provider-a")
	if err != nil {
		t.Fatalf("ListPairOTMintLog: %v", err)
	}
	if len(logs) != requests {
		t.Fatalf("mint log rows = %d, want %d", len(logs), requests)
	}
}

func TestPushOwnershipBound_ReturnsConnectedSessionEnqueueError(t *testing.T) {
	registry := pool.NewRegistry(nil)
	p := &pool.Provider{ProviderID: "provider-a", AssignedID: "assigned-a", ModelID: "model-a"}
	if _, ok := registry.Register(p, nil); !ok {
		t.Fatalf("Register provider failed")
	}
	s := NewServer(config.Default(), registry, zerolog.Nop())
	ps := newProviderSession("provider-a", "assigned-a", nil, 1)
	ps.writeCh <- providerFrame{payload: []byte("occupied")}
	s.sessions.Store(sessionKey("provider-a", "assigned-a"), ps)

	if err := s.pushOwnershipBound("provider-a", "octo"); !errors.Is(err, ErrRelayBackpressure) {
		t.Fatalf("pushOwnershipBound err = %v, want ErrRelayBackpressure", err)
	}
}

func TestBindEndpoint_EmptyBodyConsumesPendingHintAndReissuesCookie(t *testing.T) {
	s, store := newSpec014AuthTestServer(t, true)
	ctx := context.Background()
	old := time.Date(2026, 6, 20, 10, 0, 0, 0, time.UTC)
	now := old.Add(25 * time.Hour)
	s.now = func() time.Time { return now }
	sessionID, pairOT := seedSpec014HTTPBindState(t, store, now)
	if _, err := store.DB().ExecContext(ctx, `
UPDATE mp_sessions
   SET pending_pair_ot = ?,
       pending_pair_ot_expires_at = ?,
       last_seen_at = ?,
       last_setcookie_at = ?
 WHERE id = ?`,
		pairOT,
		timeTextForSpec014HTTPTest(now.Add(10*time.Minute)),
		timeTextForSpec014HTTPTest(old),
		timeTextForSpec014HTTPTest(old),
		sessionID,
	); err != nil {
		t.Fatalf("seed pending pair_ot: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/v1/auth/me/providers/bind", strings.NewReader("{}"))
	req.AddCookie(&http.Cookie{Name: session.Name, Value: sessionID})
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200 body=%s", rr.Code, rr.Body.String())
	}
	if got := rr.Header().Get("Set-Cookie"); !strings.Contains(got, "mp_session="+sessionID) || !strings.Contains(got, "Max-Age=2592000") {
		t.Fatalf("Set-Cookie = %q, want sliding cookie reissue", got)
	}
	owned, err := store.ListOwnedProviders(ctx, 42)
	if err != nil {
		t.Fatalf("ListOwnedProviders: %v", err)
	}
	if len(owned) != 1 || owned[0].ProviderID != "provider-a" {
		t.Fatalf("owned providers = %#v, want provider-a", owned)
	}

	req = httptest.NewRequest(http.MethodPost, "/v1/auth/me/providers/bind", strings.NewReader("{}"))
	req.AddCookie(&http.Cookie{Name: session.Name, Value: sessionID})
	rr = httptest.NewRecorder()
	s.Handler().ServeHTTP(rr, req)
	if rr.Code != http.StatusBadRequest {
		t.Fatalf("second empty bind status = %d, want 400", rr.Code)
	}
}

func TestAuthErrorTaxonomy_DeclaredErrors(t *testing.T) {
	t.Run("400_bad_request", func(t *testing.T) {
		s, _ := newSpec014AuthTestServer(t, true)
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start?pair_ot=a&pair_ot=b", nil)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		assertAuthError(t, rr, http.StatusBadRequest, "bad_request")
	})
	t.Run("401_session_invalid", func(t *testing.T) {
		s, _ := newSpec014AuthTestServer(t, true)
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/me/providers", nil)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		assertAuthError(t, rr, http.StatusUnauthorized, "session_invalid")
	})
	t.Run("409_already_owned", func(t *testing.T) {
		s, store := newSpec014AuthTestServer(t, true)
		now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
		s.now = func() time.Time { return now }
		sessionID, pairOT := seedSpec014HTTPBindState(t, store, now)
		if err := store.UpsertGitHubIdentity(context.Background(), 99, "other", now); err != nil {
			t.Fatalf("UpsertGitHubIdentity other: %v", err)
		}
		if _, err := store.DB().ExecContext(context.Background(), `INSERT INTO provider_ownership (provider_id, github_user_id, claimed_at) VALUES (?, ?, ?)`, "provider-a", 99, timeTextForSpec014HTTPTest(now)); err != nil {
			t.Fatalf("seed ownership: %v", err)
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/auth/me/providers/bind", strings.NewReader(`{"pair_ot":"`+pairOT+`"}`))
		req.AddCookie(&http.Cookie{Name: session.Name, Value: sessionID})
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		assertAuthError(t, rr, http.StatusConflict, "already_owned")
	})
	t.Run("410_pair_ot_invalid", func(t *testing.T) {
		s, store := newSpec014AuthTestServer(t, true)
		now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
		s.now = func() time.Time { return now }
		sessionID, _ := seedSpec014HTTPBindState(t, store, now)
		req := httptest.NewRequest(http.MethodPost, "/v1/auth/me/providers/bind", strings.NewReader(`{"pair_ot":"missingtoken"}`))
		req.AddCookie(&http.Cookie{Name: session.Name, Value: sessionID})
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		assertAuthError(t, rr, http.StatusGone, "pair_ot_invalid")
	})
	t.Run("429_rate_limited", func(t *testing.T) {
		s, store := newSpec014AuthTestServer(t, true)
		now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
		s.now = func() time.Time { return now }
		_, token, err := store.IssueToken(context.Background(), "provider-a", "Provider A")
		if err != nil {
			t.Fatalf("IssueToken: %v", err)
		}
		for i := 0; i < 5; i++ {
			if err := store.LogPairOTMint(context.Background(), "provider-a", "127.0.0.1", "test", http.StatusOK, now.Add(time.Duration(i)*time.Minute)); err != nil {
				t.Fatalf("seed mint log %d: %v", i, err)
			}
		}
		req := httptest.NewRequest(http.MethodPost, "/v1/install/pair/refresh", nil)
		req.Header.Set("Authorization", "Bearer "+token)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		assertAuthError(t, rr, http.StatusTooManyRequests, "rate_limited")
		if rr.Header().Get("Retry-After") == "" {
			t.Fatalf("missing Retry-After")
		}
	})
	t.Run("502_github_token_exchange_failed", func(t *testing.T) {
		client := fakeSpec014GitHubClient{exchangeErr: errors.New("exchange failed")}
		s, store := newSpec014AuthTestServerWithClient(t, true, zerolog.Nop(), client)
		now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
		s.now = func() time.Time { return now }
		if err := store.CreateOAuthState(context.Background(), "state", "/", nil, now); err != nil {
			t.Fatalf("CreateOAuthState: %v", err)
		}
		req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/callback?state=state&code=ok", nil)
		rr := httptest.NewRecorder()
		s.Handler().ServeHTTP(rr, req)
		assertAuthError(t, rr, http.StatusBadGateway, "github_token_exchange_failed")
	})
}

func TestBindEndpoint_RejectsInvalidJSONBodies(t *testing.T) {
	tests := map[string]string{
		"empty":          "",
		"null_pair_ot":   `{"pair_ot":null}`,
		"blank_pair_ot":  `{"pair_ot":" "}`,
		"unknown_field":  `{"extra":1}`,
		"trailing_token": `{} {}`,
	}
	for name, body := range tests {
		t.Run(name, func(t *testing.T) {
			s, store := newSpec014AuthTestServer(t, true)
			now := time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)
			s.now = func() time.Time { return now }
			sessionID, _ := seedSpec014HTTPBindState(t, store, now)
			req := httptest.NewRequest(http.MethodPost, "/v1/auth/me/providers/bind", strings.NewReader(body))
			req.AddCookie(&http.Cookie{Name: session.Name, Value: sessionID})
			rr := httptest.NewRecorder()

			s.Handler().ServeHTTP(rr, req)

			assertAuthError(t, rr, http.StatusBadRequest, "bad_request")
		})
	}
}

func TestRedactTokenQuery_RemovesPairTokens(t *testing.T) {
	u, err := url.Parse("/v1/auth/github/start?pair_ot=SECRET&return_to=%2Fclaim%3Fot%3DSECRET2&x=1")
	if err != nil {
		t.Fatalf("parse url: %v", err)
	}
	redacted := redactTokenQuery(u)
	if strings.Contains(redacted, "SECRET") || strings.Contains(redacted, "SECRET2") {
		t.Fatalf("redacted path leaked token: %q", redacted)
	}
	if !strings.Contains(redacted, "pair_ot=REDACTED") {
		t.Fatalf("redacted path = %q, want pair_ot redacted", redacted)
	}

	u, err = url.Parse("/claim?ot=SECRET")
	if err != nil {
		t.Fatalf("parse claim url: %v", err)
	}
	redacted = redactTokenQuery(u)
	if redacted != "/claim?ot=REDACTED" {
		t.Fatalf("redacted claim path = %q, want /claim?ot=REDACTED", redacted)
	}

	u, err = url.Parse("/v1/auth/github/start?pair_ot=SECRET;x=1")
	if err != nil {
		t.Fatalf("parse malformed url: %v", err)
	}
	redacted = redactTokenQuery(u)
	if strings.Contains(redacted, "SECRET") || !strings.Contains(redacted, "redacted=1") {
		t.Fatalf("malformed redacted path = %q, want no token and redacted marker", redacted)
	}

	u, err = url.Parse("/v1/auth/github/callback?code=SECRET_CODE&state=SECRET_STATE")
	if err != nil {
		t.Fatalf("parse callback url: %v", err)
	}
	redacted = redactTokenQuery(u)
	if strings.Contains(redacted, "SECRET_CODE") || strings.Contains(redacted, "SECRET_STATE") {
		t.Fatalf("callback redacted path leaked oauth params: %q", redacted)
	}
}

func TestRedactedRequestLogMiddleware_RedactsMalformedTokenQueries(t *testing.T) {
	var logs bytes.Buffer
	logger := zerolog.New(&logs)
	s, _ := newSpec014AuthTestServerWithClient(t, true, logger, fakeSpec014GitHubClient{})
	req := httptest.NewRequest(http.MethodGet, "/v1/auth/github/start?pair_ot=SECRET;x=1", nil)
	rr := httptest.NewRecorder()

	s.Handler().ServeHTTP(rr, req)

	if strings.Contains(logs.String(), "SECRET") {
		t.Fatalf("request log leaked token: %s", logs.String())
	}
	if !strings.Contains(logs.String(), "redacted=1") {
		t.Fatalf("request log missing redacted marker: %s", logs.String())
	}
}

func TestGitHubAuthHandlers_DoNotUseOperatorKeyOrAdminRoutes(t *testing.T) {
	src, err := os.ReadFile("auth_github.go")
	if err != nil {
		t.Fatalf("read auth_github.go: %v", err)
	}
	for _, forbidden := range []string{
		"operator_key",
		"/poolz",
		"/admin/blacklist",
		"/admin/provisional",
		"/admin/promote/",
		"/admin/reject/",
		"/admin/ledger/",
	} {
		if bytes.Contains(src, []byte(forbidden)) {
			t.Fatalf("auth_github.go contains forbidden operator surface %q", forbidden)
		}
	}
}

type fakeSpec014GitHubClient struct {
	exchangeErr error
	userErr     error
}

func (f fakeSpec014GitHubClient) ExchangeCode(context.Context, string, string, string, string) (string, error) {
	if f.exchangeErr != nil {
		return "", f.exchangeErr
	}
	return "github-access-token", nil
}

func (f fakeSpec014GitHubClient) User(context.Context, string) (mpgithub.User, error) {
	if f.userErr != nil {
		return mpgithub.User{}, f.userErr
	}
	return mpgithub.User{ID: 42, Login: "octo"}, nil
}

func newSpec014AuthTestServer(t *testing.T, enabled bool) (*Server, *auth.Store) {
	return newSpec014AuthTestServerWithClient(t, enabled, zerolog.Nop(), fakeSpec014GitHubClient{})
}

func newSpec014AuthTestServerWithClient(t *testing.T, enabled bool, logger zerolog.Logger, client githubOAuthClient) (*Server, *auth.Store) {
	t.Helper()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })
	cfg := config.Default()
	cfg.Auth.GitHubOAuth = config.GitHubOAuthConfig{
		Enabled:       enabled,
		ClientID:      "client-id",
		ClientSecret:  "client-secret",
		RedirectURI:   "https://coordinator.example/v1/auth/github/callback",
		PortalBaseURL: "https://portal.example",
	}
	s := NewServer(
		cfg,
		pool.NewRegistry(nil),
		logger,
		WithTokenValidator(store),
		WithTokenIssuer(store),
		WithGitHubAuthStore(store),
		WithGitHubOAuthClient(client),
	)
	return s, store
}

func seedSpec014HTTPBindState(t *testing.T, store *auth.Store, now time.Time) (string, string) {
	t.Helper()
	ctx := context.Background()
	if err := store.UpsertGitHubIdentity(ctx, 42, "octo", now); err != nil {
		t.Fatalf("UpsertGitHubIdentity: %v", err)
	}
	sessionID, err := store.CreateMPSession(ctx, 42, sql.NullString{}, now)
	if err != nil {
		t.Fatalf("CreateMPSession: %v", err)
	}
	mint, err := store.MintPairOT(ctx, "provider-a", now)
	if err != nil {
		t.Fatalf("MintPairOT: %v", err)
	}
	return sessionID, mint.PairOT
}

func timeTextForSpec014HTTPTest(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05Z")
}

func assertAuthError(t *testing.T, rr *httptest.ResponseRecorder, status int, code string) {
	t.Helper()
	if rr.Code != status {
		t.Fatalf("status = %d, want %d body=%s", rr.Code, status, rr.Body.String())
	}
	var body map[string]string
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode error body: %v body=%q", err, rr.Body.String())
	}
	if len(body) != 1 || body["error"] != code {
		t.Fatalf("body = %#v, want {error:%q}", body, code)
	}
}
