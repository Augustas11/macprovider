package router

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math"
	"net"
	"net/http"
	"net/url"
	"os"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

type Server struct {
	cfg     config.Config
	cfgPath string
	store   Store
	keyMgr  auth.KeyManager
	demoMgr auth.DemoManager
	oauth   auth.OAuthProvider
	now     func() time.Time
	client  *http.Client
	mu      sync.RWMutex
	poolz   statusCache
	// routingMeta is a small TTL cache for /internal/routing probes. Without
	// it, every sticky-eligible chat-completion AND every /v1/models request
	// fires a coordinator roundtrip (the SPEC-004 audit's HIGH perf finding).
	// 5s TTL — coordinator config only changes on reload, so staleness is
	// harmless; cap on bursts.
	routingMeta routingMetaCache
}

type routingMetaCache struct {
	mu        sync.Mutex
	value     coordinatorRoutingMetadata
	ok        bool
	fetchedAt time.Time
}

type Store interface {
	storage.AuthStore
	storage.UsageStore
	storage.AuditStore
	storage.FeedbackStore
	storage.CapacityStore
	storage.HealthStore
}

type Option func(*Server)

type statusCache struct {
	checkedAt time.Time
	body      statusResponse
}

func WithNow(fn func() time.Time) Option {
	return func(s *Server) {
		s.now = fn
	}
}

func WithHTTPClient(client *http.Client) Option {
	return func(s *Server) {
		if client != nil {
			s.client = client
		}
	}
}

func WithConfigPath(path string) Option {
	return func(s *Server) {
		s.cfgPath = path
	}
}

func New(cfg config.Config, store Store, oauth auth.OAuthProvider, opts ...Option) *Server {
	s := &Server{
		cfg:     cfg,
		store:   store,
		keyMgr:  auth.NewKeyManager(cfg.Auth.KeyPrefix, cfg.Auth.KeyHash, cfg.Auth.KeyHashSecret),
		demoMgr: auth.NewDemoManager(cfg.Auth.Demo.SigningSecret),
		oauth:   oauth,
		now:     func() time.Time { return time.Now().UTC() },
		client:  http.DefaultClient,
	}
	for _, opt := range opts {
		opt(s)
	}
	return s
}

func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/auth/github/start", s.handleGitHubStart)
	mux.HandleFunc("/auth/github/callback", s.handleGitHubCallback)
	mux.Handle("/auth/demo-session", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleDemoSession)))
	mux.HandleFunc("/auth/api-keys", s.handleAPIKeys)
	mux.HandleFunc("/auth/api-keys/", s.handleAPIKeyAction)
	mux.HandleFunc("/account", s.handleAccount)
	mux.HandleFunc("/docs", s.handleDocs)
	mux.Handle("/v1/models", s.withCORS(http.MethodGet, http.HandlerFunc(s.handleModels)))
	mux.HandleFunc("/v1/usage", s.handleUsage)
	mux.Handle("/v1/chat/completions", s.withCORS(http.MethodPost, http.HandlerFunc(s.handleChatCompletions)))
	mux.Handle("/v1/sticky", s.withCORS(http.MethodDelete, http.HandlerFunc(s.handleStickyDelete)))
	mux.Handle("/v1/status", s.withCORS(http.MethodGet, http.HandlerFunc(s.handleStatus)))
	mux.HandleFunc("/v1/feedback", s.handleFeedback)
	mux.HandleFunc("/healthz", s.handleHealthz)
	mux.HandleFunc("/admin/feedback-summary", s.handleFeedbackSummary)
	mux.HandleFunc("/admin/kill-switch", s.handleKillSwitch)
	mux.HandleFunc("/admin/capacity-signal", s.handleCapacitySignal)
	mux.HandleFunc("/admin/capacity-tier/evaluate", s.handleCapacityEvaluate)
	mux.HandleFunc("/", s.handleNotFound)
	return s.middleware(mux)
}

func (s *Server) middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requestID := r.Header.Get("X-Request-ID")
		if !isUUIDLike(requestID) {
			requestID = newUUID()
		}
		if stripped := stripInternalMacProviderHeaders(r.Header); len(stripped) > 0 {
			slog.Warn("internal header injection stripped", "request_id", requestID, "headers", stripped)
			_ = s.store.InsertAuditEvent(context.Background(), storage.AuditEvent{
				EventID: mustID("audit"), RequestID: requestID, Actor: "public_ingress", Type: "internal_header_injection_stripped",
				Payload: fmt.Sprintf(`{"headers":%q}`, strings.Join(stripped, ",")), CreatedAt: s.now(),
			})
		}
		w.Header().Set("X-Request-ID", requestID)
		if s.publicPaused(r.URL.Path) {
			writeError(w, http.StatusServiceUnavailable, "server_error", "public_api_paused", "Mac Provider beta is paused while capacity catches up. Please retry later.")
			return
		}
		ctx := context.WithValue(r.Context(), requestIDKey{}, requestID)
		defer func() {
			if recovered := recover(); recovered != nil {
				slog.Error("panic recovered", "panic", recovered, "request_id", requestID, "path", r.URL.Path, "stack", string(debug.Stack()))
				writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Internal server error")
			}
		}()
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func (s *Server) handleGitHubStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	redirectURI := r.URL.Query().Get("redirect_uri")
	if redirectURI == "" {
		redirectURI = s.cfg.Auth.OAuth.CallbackAllowlist[0]
	}
	if !s.callbackAllowed(redirectURI) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "oauth_callback_not_allowed", "OAuth callback URL is not allowed")
		return
	}
	state, err := auth.StateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "state_generation_failed", "Could not start OAuth flow")
		return
	}
	sessionID, err := auth.StateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "session_generation_failed", "Could not start OAuth flow")
		return
	}
	now := s.now()
	if err := s.store.StoreOAuthState(r.Context(), storage.OAuthState{
		StateHash: auth.StateHash(state), SessionID: sessionID, RedirectURI: redirectURI,
		ClientIP: clientIP(r), CreatedAt: now, ExpiresAt: auth.OAuthStateExpiry(now),
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "oauth_state_store_failed", "Could not start OAuth flow")
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name: "mp_oauth_session", Value: sessionID, Path: "/auth/github", HttpOnly: true,
		SameSite: http.SameSiteLaxMode, Secure: s.secureCookies(), MaxAge: 600,
	})
	http.Redirect(w, r, s.githubAuthURL(redirectURI, state), http.StatusFound)
}

func (s *Server) handleGitHubCallback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	state := r.URL.Query().Get("state")
	code := r.URL.Query().Get("code")
	cookie, err := r.Cookie("mp_oauth_session")
	if err != nil || state == "" || code == "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "oauth_state_invalid", "OAuth state is invalid")
		return
	}
	redirectURI, err := s.store.ConsumeOAuthState(r.Context(), auth.StateHash(state), cookie.Value, s.now())
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "oauth_state_invalid", "OAuth state is invalid")
		return
	}
	if !s.callbackAllowed(redirectURI) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "oauth_callback_not_allowed", "OAuth callback URL is not allowed")
		return
	}
	identity, err := s.oauth.Exchange(r.Context(), code, redirectURI)
	if errors.Is(err, auth.ErrForbiddenScope) || (err == nil && !auth.ScopesAllowed(identity.Scopes)) {
		_ = s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
			EventID: mustID("audit"), RequestID: requestID(r), Actor: "github_oauth", Type: "oauth_scope_rejected",
			Payload: fmt.Sprintf(`{"scopes":%q}`, strings.Join(identity.Scopes, " ")), CreatedAt: s.now(),
		})
		writeError(w, http.StatusForbidden, "permission_error", "oauth_scope_forbidden", "OAuth scope is not allowed")
		return
	}
	if err != nil {
		writeError(w, http.StatusBadGateway, "upstream_error", "oauth_exchange_failed", "OAuth exchange failed")
		return
	}
	account, err := s.store.LookupAccountByIdentity(r.Context(), "github", identity.ProviderUserID)
	if errors.Is(err, storage.ErrNotFound) {
		account, err = s.createSignupAccount(w, r.Context(), r, identity)
		if err != nil {
			return
		}
		fullKey, _, err := s.keyMgr.Issue(r.Context(), s.store, account.AccountID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "api_key_issuance_failed", "Could not issue API key")
			return
		}
		http.SetCookie(w, &http.Cookie{Name: "mp_new_api_key", Value: fullKey, Path: "/account", HttpOnly: true, Secure: s.secureCookies(), SameSite: http.SameSiteLaxMode, MaxAge: 300})
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "account_lookup_failed", "Could not load account")
		return
	}
	http.Redirect(w, r, s.cfg.Public.AccountPath, http.StatusFound)
}

func (s *Server) createSignupAccount(w http.ResponseWriter, ctx context.Context, r *http.Request, identity auth.OAuthIdentity) (storage.Account, error) {
	tier, err := s.store.GetCapacityTier(ctx)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_tier_load_failed", "Could not check capacity state")
		return storage.Account{}, err
	}
	if tier.Tier >= 1 {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "capacity_signup_closed", "Signup is closed while capacity catches up. Existing keys continue to work.")
		return storage.Account{}, storage.ErrQuotaExceeded
	}
	ip := clientIP(r)
	count, err := s.store.CountSignupEventsSince(ctx, ip, s.now().Add(-24*time.Hour))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "signup_limit_check_failed", "Could not check signup limit")
		return storage.Account{}, err
	}
	if count >= s.cfg.Quotas.SignupAccountsPerIPPerDay {
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "signup_rate_limited", "Signup limit exceeded")
		return storage.Account{}, storage.ErrQuotaExceeded
	}
	accountID := mustID("acct")
	account := storage.Account{AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: s.now()}
	if err := s.store.CreateAccount(ctx, account); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "account_create_failed", "Could not create account")
		return storage.Account{}, err
	}
	if err := s.store.AddAccountIdentity(ctx, storage.AccountIdentity{
		AccountID: accountID, Provider: "github", ProviderUserID: identity.ProviderUserID, Email: identity.Email, CreatedAt: s.now(),
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "identity_create_failed", "Could not create identity")
		return storage.Account{}, err
	}
	if err := s.store.RecordSignupEvent(ctx, storage.SignupEvent{
		EventID: mustID("signup"), AccountID: accountID, ClientIP: ip, Provider: "github", CreatedAt: s.now(),
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "signup_event_failed", "Could not record signup")
		return storage.Account{}, err
	}
	return account, nil
}

func (s *Server) handleDemoSession(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if s.demoPaused() {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "demo_paused", "Demo access is paused while capacity catches up. API keys continue to work.")
		return
	}
	ip := clientIP(r)
	count, err := s.store.CountDemoSessionEventsSince(r.Context(), ip, s.now().Add(-time.Hour))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "demo_session_check_failed", "Could not check demo session limit")
		return
	}
	if count >= s.cfg.Quotas.DemoSessionsPerIPPerHour {
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "demo_session_rate_limited", "Demo session limit exceeded")
		return
	}
	token, expires, err := s.demoMgr.Issue(ip, s.now(), 24*time.Hour)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "demo_token_issuance_failed", "Could not issue demo token")
		return
	}
	if err := s.store.RecordDemoSessionEvent(r.Context(), storage.DemoSessionEvent{EventID: mustID("demo"), ClientIP: ip, CreatedAt: s.now()}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "demo_session_record_failed", "Could not record demo session")
		return
	}
	setNoStoreHeaders(w.Header())
	writeJSON(w, http.StatusCreated, map[string]any{"demo_token": token, "expires_at": expires.Format(time.RFC3339)})
}

func (s *Server) handleAPIKeys(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	fullKey, key, err := s.keyMgr.Generate(validation.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "api_key_issuance_failed", "Could not issue API key")
		return
	}
	if err := s.store.RotateAPIKey(r.Context(), validation.KeyID, validation.AccountID, key, "account", requestID(r)); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "api_key_rotation_failed", "Could not rotate API key")
		return
	}
	setNoStoreHeaders(w.Header())
	writeJSON(w, http.StatusCreated, map[string]any{"api_key": fullKey, "key_id": key.KeyID, "key_prefix": key.KeyHashPrefix})
}

func (s *Server) handleAPIKeyAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	keyID := strings.TrimPrefix(r.URL.Path, "/auth/api-keys/")
	keyID = strings.TrimSuffix(keyID, "/revoke")
	if keyID == "" || !strings.HasSuffix(r.URL.Path, "/revoke") {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not found")
		return
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	if err := s.store.RevokeAPIKeyForAccount(r.Context(), validation.AccountID, keyID, "account", requestID(r)); err != nil {
		if errors.Is(err, storage.ErrNotFound) {
			writeError(w, http.StatusNotFound, "invalid_request_error", "api_key_not_found", "API key not found")
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "api_key_revoke_failed", "Could not revoke API key")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "revoked", "key_id": keyID})
}

func (s *Server) handleModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if _, ok := s.authenticateAny(w, r); !ok {
		return
	}
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodGet, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/models", nil)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	resp, err := s.client.Do(upReq)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_models_error", "Coordinator models error")
		return
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_models_error", "Coordinator models error")
		return
	}
	disclosure, ok := s.tier1DisclosureForModels(body, r.Context())
	if !ok {
		writeError(w, http.StatusBadGateway, "api_error", "tier2_metadata_unavailable", "Coordinator Tier-2 metadata unavailable")
		return
	}
	body["tier1_disclosure"] = disclosure
	copyCleanHeaders(w.Header(), resp.Header)
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "unavailable"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"status": "ok"})
}

func (s *Server) handleNotFound(w http.ResponseWriter, r *http.Request) {
	writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
}

func (s *Server) handleUsage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	window := s.now().UTC().Format("2006-01-02")
	used, reserved, err := s.store.DailyUsage(r.Context(), validation.AccountID, window)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "usage_load_failed", "Could not load usage")
		return
	}
	keys, err := s.store.ListAPIKeys(r.Context(), validation.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "keys_load_failed", "Could not load API keys")
		return
	}
	limit := s.effectiveAccountDailyQuota(r.Context())
	remaining := limit - used - reserved
	if remaining < 0 {
		remaining = 0
	}
	setRateLimitHeaders(w, limit, remaining, resetUnix(window))
	tier, _ := s.store.GetCapacityTier(r.Context())
	writeJSON(w, http.StatusOK, map[string]any{
		"account_id": validation.AccountID,
		"quota": map[string]any{
			"window_date": window, "daily_tokens_used": used, "daily_tokens_reserved": reserved,
			"daily_tokens_remaining": remaining, "daily_tokens_limit": limit,
		},
		"capacity": map[string]any{"tier": tier.Tier},
		"keys":     keys,
		"models":   []any{},
		"rating":   nil,
	})
}

func (s *Server) handleStickyDelete(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	authn, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	accountID := authn.AccountID
	upReq, err := http.NewRequestWithContext(r.Context(), http.MethodDelete, strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")+"/internal/sticky?account_id="+url.QueryEscape(accountID), nil)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.OperatorKey)
	resp, err := s.client.Do(upReq)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_sticky_error", "Coordinator sticky purge error")
		return
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_sticky_error", "Coordinator sticky purge error")
		return
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	resp, err := s.statusFromPoolz(r.Context())
	if err != nil {
		writeJSON(w, http.StatusOK, statusResponse{
			Status: "down", Degraded: false,
			Coordinator: coordinatorStatus{Status: "down", CheckedAt: s.now().Format(time.RFC3339)},
		})
		return
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleFeedback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	var req struct {
		Rating    int    `json:"rating"`
		Comment   string `json:"comment"`
		RequestID string `json:"request_id"`
		Scope     string `json:"scope"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, int64(s.cfg.Limits.MaxFeedbackCommentBytes)+4096)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_feedback", "Invalid feedback")
		return
	}
	if req.Rating < 1 || req.Rating > 4 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_rating", "rating must be 1 through 4")
		return
	}
	if len([]byte(req.Comment)) > s.cfg.Limits.MaxFeedbackCommentBytes {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "comment_too_long", "comment too long")
		return
	}
	if req.RequestID != "" && !safeID(req.RequestID) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_id", "request_id is invalid")
		return
	}
	if req.Scope == "" {
		if req.RequestID != "" {
			req.Scope = "request"
		} else {
			req.Scope = "account"
		}
	}
	if !validFeedbackScope(req.Scope) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_feedback_scope", "scope is invalid")
		return
	}
	accountID := ""
	if req.Scope == "playground" {
		if s.demoPaused() {
			writeError(w, http.StatusServiceUnavailable, "server_error", "demo_paused", "Demo is temporarily paused")
			return
		}
		token := r.Header.Get("X-Demo-Token")
		payload, err := s.demoMgr.Validate(token, clientIP(r), s.now())
		if err != nil {
			writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_demo_token", "Invalid demo token")
			return
		}
		accountID = "demo:" + payload.IP
	} else {
		validation, ok := s.requireBearer(w, r)
		if !ok {
			return
		}
		accountID = validation.AccountID
	}
	now := s.now()
	event := storage.FeedbackEvent{
		EventID: mustID("fb"), RequestID: req.RequestID, AccountID: accountID, Scope: req.Scope,
		Rating: req.Rating, Comment: req.Comment, CreatedAt: now,
	}
	if err := s.store.InsertFeedbackEvent(r.Context(), event); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "feedback_store_failed", "Could not store feedback")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "feedback_id": event.EventID, "received_at": now.Format(time.RFC3339)})
}

func (s *Server) handleFeedbackSummary(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	days := 7
	if r.URL.Query().Get("window") == "14d" {
		days = 14
	} else if q := r.URL.Query().Get("window"); q != "" && q != "7d" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_window", "window must be 7d or 14d")
		return
	}
	end := s.now()
	start := end.AddDate(0, 0, -days)
	events, err := s.store.ListFeedbackEventsSince(r.Context(), start)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "feedback_summary_failed", "Could not summarize feedback")
		return
	}
	writeJSON(w, http.StatusOK, buildFeedbackSummary(events, start, end))
}

func (s *Server) handleKillSwitch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	var req struct {
		DemoOnly     *bool `json:"demo_only"`
		AllPublicAPI *bool `json:"all_public_api"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_kill_switch", "Invalid kill switch request")
		return
	}
	s.mu.RLock()
	old := s.cfg.KillSwitch
	next := s.cfg
	s.mu.RUnlock()
	if req.DemoOnly != nil {
		next.KillSwitch.DemoOnly = *req.DemoOnly
	}
	if req.AllPublicAPI != nil {
		next.KillSwitch.AllPublicAPI = *req.AllPublicAPI
	}
	if s.cfgPath != "" {
		if err := persistKillSwitch(s.cfgPath, next.KillSwitch); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "kill_switch_persist_failed", "Could not persist kill switch")
			return
		}
	}
	s.mu.Lock()
	s.cfg.KillSwitch = next.KillSwitch
	s.mu.Unlock()
	_ = s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
		EventID: mustID("audit"), RequestID: requestID(r), Actor: "operator", Type: "kill_switch_toggled",
		Payload:   fmt.Sprintf(`{"old_demo_only":%t,"new_demo_only":%t,"old_all_public_api":%t,"new_all_public_api":%t}`, old.DemoOnly, next.KillSwitch.DemoOnly, old.AllPublicAPI, next.KillSwitch.AllPublicAPI),
		CreatedAt: s.now(),
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "kill_switch": next.KillSwitch})
}

func (s *Server) handleCapacitySignal(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	var req struct {
		Signal    string  `json:"signal"`
		Value     float64 `json:"value"`
		Threshold float64 `json:"threshold"`
		Firing    bool    `json:"firing"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Signal == "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_capacity_signal", "Invalid capacity signal")
		return
	}
	event := storage.CapacitySignalEvent{EventID: mustID("cap"), Signal: req.Signal, Value: req.Value, Threshold: req.Threshold, Firing: req.Firing, CreatedAt: s.now()}
	if err := s.store.InsertCapacitySignalEvent(r.Context(), event); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_signal_store_failed", "Could not store capacity signal")
		return
	}
	if req.Firing {
		tier, _ := s.store.GetCapacityTier(r.Context())
		if req.Signal == "monthly_cost" && req.Value >= float64(s.cfg.Capacity.MonthlyBudgetUSD) {
			_ = s.setCapacityTier(r.Context(), 3, req.Signal, "capacity_tier_escalated")
			s.setAllPublicPaused(r.Context(), true, "capacity_tier_3")
		} else if req.Signal == "provider_drop" && req.Value >= 2 {
			_ = s.setCapacityTier(r.Context(), 3, req.Signal, "capacity_tier_escalated")
			s.setAllPublicPaused(r.Context(), true, "capacity_tier_3")
		} else if tier.Tier == 0 {
			_ = s.setCapacityTier(r.Context(), 1, req.Signal, "capacity_tier_escalated")
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "event_id": event.EventID})
}

func (s *Server) handleCapacityEvaluate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	tier, err := s.store.GetCapacityTier(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_tier_load_failed", "Could not load capacity tier")
		return
	}
	signals, err := s.store.LatestCapacitySignals(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_signal_load_failed", "Could not load capacity signals")
		return
	}
	anyFiring := false
	for _, signal := range signals {
		anyFiring = anyFiring || signal.Firing
	}
	previous := tier.Tier
	next := previous
	below := !anyFiring
	if previous == 1 && !below && s.now().Sub(tier.UpdatedAt) >= 7*24*time.Hour {
		next = 2
		_ = s.setCapacityTier(r.Context(), next, "tier_1_signal_still_firing", "capacity_tier_escalated")
	} else if previous > 0 && below && s.now().Sub(tier.UpdatedAt) >= time.Duration(s.cfg.Capacity.TierCooldownSeconds)*time.Second {
		next = previous - 1
		_ = s.setCapacityTier(r.Context(), next, "signals_below_threshold", "capacity_tier_deescalated")
		if previous == 3 {
			s.setAllPublicPaused(r.Context(), false, "capacity_tier_deescalated")
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"previous_tier": previous, "new_tier": next, "signals_below_threshold": below})
}

type chatRequest struct {
	Model     string            `json:"model"`
	Messages  []json.RawMessage `json:"messages"`
	MaxTokens *int64            `json:"max_tokens"`
	N         *int              `json:"n"`
	Stream    bool              `json:"stream"`
}

type tokenUsage struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	TotalTokens      int64 `json:"total_tokens"`
}

type tier1Disclosure struct {
	Version                 string                    `json:"version"`
	PlaintextToProvider     bool                      `json:"plaintext_to_provider"`
	ModelIdentity           string                    `json:"model_identity"`
	HardwareAttestation     string                    `json:"hardware_attestation"`
	Tier2Milestone          string                    `json:"tier2_milestone"`
	StickyAffinity          *stickyAffinityDisclosure `json:"sticky_affinity"`
	ModelHashVerified       string                    `json:"model_hash_verified,omitempty"`
	ProviderLegEncryption   string                    `json:"provider_leg_encryption,omitempty"`
	UntrustedProviderSafety string                    `json:"untrusted_provider_safety,omitempty"`
	Tier2                   *tier2Disclosure          `json:"tier2,omitempty"`
}

type stickyAffinityDisclosure struct {
	Enabled     bool   `json:"enabled"`
	TTLSeconds  int    `json:"ttl_seconds"`
	Description string `json:"description"`
}

type tier2Disclosure struct {
	Phase            any                        `json:"phase"`
	ModelHash        modelHashDisclosure        `json:"model_hash"`
	EncryptedLeg     encryptedLegDisclosure     `json:"encrypted_leg"`
	Attestation      attestationDisclosure      `json:"attestation"`
	BehavioralSafety behavioralSafetyDisclosure `json:"behavioral_safety"`
}

type modelHashDisclosure struct {
	State                     string `json:"state"`
	VerifiedProviderCount     int    `json:"verified_provider_count"`
	UncataloguedProviderCount int    `json:"uncatalogued_provider_count"`
	Mixed                     bool   `json:"mixed"`
}

type encryptedLegDisclosure struct {
	State                    string `json:"state"`
	EncryptedProviderCount   int    `json:"encrypted_provider_count"`
	UnencryptedProviderCount int    `json:"unencrypted_provider_count"`
	Mixed                    bool   `json:"mixed"`
	Scope                    string `json:"scope"`
}

type attestationDisclosure struct {
	State                    string `json:"state"`
	AttestedProviderCount    int    `json:"attested_provider_count"`
	UnsupportedProviderCount int    `json:"unsupported_provider_count"`
	Mixed                    bool   `json:"mixed"`
}

type behavioralSafetyDisclosure struct {
	State              string `json:"state"`
	SizeCap            bool   `json:"size_cap"`
	EncodingValidation bool   `json:"encoding_validation"`
	TTFTAnomalyLogging bool   `json:"ttft_anomaly_logging"`
}

func (s *Server) makeTier1Disclosure(ctxs ...context.Context) tier1Disclosure {
	disclosure := tier1Disclosure{
		Version:             "v0.8",
		PlaintextToProvider: true,
		ModelIdentity:       "provider_reported",
		HardwareAttestation: "none",
		Tier2Milestone:      "future",
		StickyAffinity: &stickyAffinityDisclosure{
			Enabled: false, TTLSeconds: 0,
			Description: "Sticky affinity is disabled; related requests are not preferentially routed to the same provider.",
		},
	}
	if s.cfg.Routing.StickyEnabled {
		ctx := context.Background()
		if len(ctxs) > 0 && ctxs[0] != nil {
			ctx = ctxs[0]
		}
		metadata, ok := s.coordinatorRoutingMetadata(ctx)
		if !ok || !metadata.Sticky.Enabled || metadata.Sticky.TTLSeconds != s.cfg.Routing.StickyTTLS {
			return disclosure
		}
		disclosure.StickyAffinity = &stickyAffinityDisclosure{
			Enabled: true, TTLSeconds: metadata.Sticky.TTLSeconds,
			Description: "Related requests with the same conversation tag are preferentially routed to one provider for up to this many seconds, so that provider can observe and correlate more of your traffic than under default routing.",
		}
	}
	return disclosure
}

func (s *Server) makeTier1DisclosureForModels(body map[string]any, ctxs ...context.Context) tier1Disclosure {
	disclosure, _ := s.tier1DisclosureForModels(body, ctxs...)
	return disclosure
}

func (s *Server) tier1DisclosureForModels(body map[string]any, ctxs ...context.Context) (tier1Disclosure, bool) {
	disclosure := s.makeTier1Disclosure(ctxs...)
	bodyActive, state, verified, uncatalogued := tier2ModelHashState(body)
	bodyMetadataActive := tier2BodyMetadataActive(body)
	phase := any(1)
	ctx := context.Background()
	if len(ctxs) > 0 && ctxs[0] != nil {
		ctx = ctxs[0]
	}
	metadata, ok := s.coordinatorRoutingMetadataFresh(ctx)
	if !ok {
		if bodyActive {
			phase = 1
		} else {
			return disclosure, !bodyMetadataActive
		}
	} else if !metadata.Tier2.ModelHash.Active && !metadata.Tier2.EncryptedLeg.active() && !metadata.Tier2.Attestation.active() && !metadata.Tier2.BehavioralSafety.active() {
		return disclosure, !(bodyActive || bodyMetadataActive)
	} else {
		phase = tier2PhaseFromMetadata(metadata.Tier2.Phase)
		if !bodyActive {
			state = disclosureStateFromMetadata(metadata.Tier2.ModelHash.State)
		}
	}
	disclosure.Version = "v0.8+tier2-v0.2"
	disclosure.ModelHashVerified = state
	disclosure.ProviderLegEncryption = metadata.Tier2.EncryptedLeg.disclosureState()
	disclosure.HardwareAttestation = metadata.Tier2.Attestation.disclosureState()
	disclosure.UntrustedProviderSafety = metadata.Tier2.BehavioralSafety.disclosureState()
	disclosure.Tier2 = &tier2Disclosure{
		Phase: phase,
		ModelHash: modelHashDisclosure{
			State:                     state,
			VerifiedProviderCount:     verified,
			UncataloguedProviderCount: uncatalogued,
			Mixed:                     state == "partial",
		},
		EncryptedLeg:     metadata.Tier2.EncryptedLeg.toDisclosure(),
		Attestation:      metadata.Tier2.Attestation.toDisclosure(),
		BehavioralSafety: metadata.Tier2.BehavioralSafety.toDisclosure(),
	}
	return disclosure, true
}

func tier2BodyMetadataActive(body map[string]any) bool {
	tier2Raw, _ := body["tier2"].(map[string]any)
	if tier2Raw == nil {
		return false
	}
	modelHash, _ := tier2Raw["model_hash"].(map[string]any)
	active, _ := modelHash["active"].(bool)
	if active {
		return true
	}
	encryptedLeg, _ := tier2Raw["encrypted_leg"].(map[string]any)
	state, _ := encryptedLeg["state"].(string)
	if state != "" && state != "none" {
		return true
	}
	attestation, _ := tier2Raw["attestation"].(map[string]any)
	state, _ = attestation["state"].(string)
	if state != "" && state != "none" {
		return true
	}
	behavioralSafety, _ := tier2Raw["behavioral_safety"].(map[string]any)
	state, _ = behavioralSafety["state"].(string)
	return state != "" && state != "none"
}

func disclosureStateFromMetadata(state string) string {
	switch state {
	case "all", "partial", "none":
		return state
	case "required":
		return "none"
	default:
		return "none"
	}
}

func tier2PhaseFromMetadata(phase any) any {
	switch v := phase.(type) {
	case string:
		if v == "mixed" {
			return v
		}
	case float64:
		if v == 0 || v == 1 || v == 2 || v == 3 {
			return int(v)
		}
	case json.Number:
		i, err := v.Int64()
		if err == nil && i >= 0 && i <= 3 {
			return int(i)
		}
	}
	return 0
}

func tier2ModelHashState(body map[string]any) (active bool, state string, verified int, uncatalogued int) {
	state = "none"
	data, _ := body["data"].([]any)
	nonVerified := 0
	for _, item := range data {
		entry, _ := item.(map[string]any)
		if entry == nil {
			continue
		}
		hvRaw, hashFieldPresent := entry["hash_verified"]
		hv, ok := entry["hash_verification"].(map[string]any)
		if !ok {
			if hashFieldPresent {
				active = true
				if b, ok := hvRaw.(bool); ok && b {
					verified++
				} else {
					nonVerified++
				}
			}
			continue
		}
		active = true
		v := intFromModelField(hv["verified_provider_count"])
		u := intFromModelField(hv["uncatalogued_provider_count"])
		m := intFromModelField(hv["mismatch_provider_count"])
		invalid := intFromModelField(hv["invalid_provider_count"])
		verified += v
		uncatalogued += u
		nonVerified += u + m + invalid
		if b, ok := hvRaw.(bool); ok && !b && u+m+invalid == 0 {
			nonVerified++
		}
		if s, ok := hv["status"].(string); ok && s == "catalog_unavailable" {
			nonVerified++
		}
	}
	switch {
	case !active:
		return false, "", 0, 0
	case verified > 0 && nonVerified == 0:
		state = "all"
	case verified > 0:
		state = "partial"
	default:
		state = "none"
	}
	return active, state, verified, uncatalogued
}

func intFromModelField(v any) int {
	switch n := v.(type) {
	case float64:
		return int(n)
	case json.Number:
		i, _ := n.Int64()
		return int(i)
	default:
		return 0
	}
}

type coordinatorRoutingMetadata struct {
	Sticky struct {
		Enabled    bool `json:"enabled"`
		TTLSeconds int  `json:"ttl_seconds"`
	} `json:"sticky"`
	Tier2 struct {
		Phase     any `json:"phase"`
		ModelHash struct {
			Active bool   `json:"active"`
			State  string `json:"state"`
		} `json:"model_hash"`
		EncryptedLeg     coordinatorEncryptedLegMetadata     `json:"encrypted_leg"`
		Attestation      coordinatorAttestationMetadata      `json:"attestation"`
		BehavioralSafety coordinatorBehavioralSafetyMetadata `json:"behavioral_safety"`
	} `json:"tier2"`
}

type coordinatorEncryptedLegMetadata struct {
	State                    string `json:"state"`
	EncryptedProviderCount   int    `json:"encrypted_provider_count"`
	UnencryptedProviderCount int    `json:"unencrypted_provider_count"`
	Mixed                    bool   `json:"mixed"`
	Scope                    string `json:"scope"`
}

func (m coordinatorEncryptedLegMetadata) active() bool {
	return m.State != "" && m.State != "none"
}

func (m coordinatorEncryptedLegMetadata) disclosureState() string {
	if !m.active() {
		return "none"
	}
	if m.State == "all" {
		return "all"
	}
	return "partial"
}

func (m coordinatorEncryptedLegMetadata) toDisclosure() encryptedLegDisclosure {
	if !m.active() {
		return encryptedLegDisclosure{State: "none", Scope: "coordinator_to_provider_only"}
	}
	scope := m.Scope
	if scope == "" {
		scope = "coordinator_to_provider_only"
	}
	return encryptedLegDisclosure{
		State:                    m.State,
		EncryptedProviderCount:   m.EncryptedProviderCount,
		UnencryptedProviderCount: m.UnencryptedProviderCount,
		Mixed:                    m.Mixed || m.State == "partial",
		Scope:                    scope,
	}
}

type coordinatorAttestationMetadata struct {
	State                    string `json:"state"`
	AttestedProviderCount    int    `json:"attested_provider_count"`
	UnsupportedProviderCount int    `json:"unsupported_provider_count"`
	Mixed                    bool   `json:"mixed"`
}

func (m coordinatorAttestationMetadata) active() bool {
	return m.State != "" && m.State != "none"
}

func (m coordinatorAttestationMetadata) disclosureState() string {
	switch m.State {
	case "all", "partial", "unsupported":
		return m.State
	default:
		return "none"
	}
}

func (m coordinatorAttestationMetadata) toDisclosure() attestationDisclosure {
	if !m.active() {
		return attestationDisclosure{State: "none"}
	}
	return attestationDisclosure{
		State:                    m.State,
		AttestedProviderCount:    m.AttestedProviderCount,
		UnsupportedProviderCount: m.UnsupportedProviderCount,
		Mixed:                    m.Mixed || m.State == "partial",
	}
}

type coordinatorBehavioralSafetyMetadata struct {
	State              string `json:"state"`
	SizeCap            bool   `json:"size_cap"`
	EncodingValidation bool   `json:"encoding_validation"`
	TTFTAnomalyLogging bool   `json:"ttft_anomaly_logging"`
}

func (m coordinatorBehavioralSafetyMetadata) active() bool {
	return m.State != "" && m.State != "none"
}

func (m coordinatorBehavioralSafetyMetadata) disclosureState() string {
	if !m.active() {
		return "none"
	}
	if m.State == "enforced" {
		return "enforced"
	}
	return "partial"
}

func (m coordinatorBehavioralSafetyMetadata) toDisclosure() behavioralSafetyDisclosure {
	if !m.active() {
		return behavioralSafetyDisclosure{State: "none"}
	}
	return behavioralSafetyDisclosure{
		State:              m.State,
		SizeCap:            m.SizeCap,
		EncodingValidation: m.EncodingValidation,
		TTFTAnomalyLogging: m.TTFTAnomalyLogging,
	}
}

const routingMetaTTL = 5 * time.Second

func (s *Server) coordinatorRoutingMetadata(ctx context.Context) (coordinatorRoutingMetadata, bool) {
	// Per-request roundtrip cost is bad at scale (audit HIGH). 5s TTL is
	// safe for sticky-affinity hints because staleness only affects whether
	// sticky headers are attempted on the next request. Buyer-visible trust
	// disclosure uses coordinatorRoutingMetadataFresh instead.
	s.routingMeta.mu.Lock()
	if s.routingMeta.ok && s.now().Sub(s.routingMeta.fetchedAt) < routingMetaTTL {
		v, ok := s.routingMeta.value, s.routingMeta.ok
		s.routingMeta.mu.Unlock()
		return v, ok
	}
	s.routingMeta.mu.Unlock()

	return s.coordinatorRoutingMetadataFresh(ctx)
}

func (s *Server) coordinatorRoutingMetadataFresh(ctx context.Context) (coordinatorRoutingMetadata, bool) {
	var metadata coordinatorRoutingMetadata
	reqCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")+"/internal/routing", nil)
	if err != nil {
		return metadata, false
	}
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.OperatorKey)
	resp, err := s.client.Do(req)
	if err != nil {
		return metadata, false
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return metadata, false
	}
	if err := json.NewDecoder(resp.Body).Decode(&metadata); err != nil {
		slog.Warn("coordinator routing metadata decode failed", "error", err.Error())
		return metadata, false
	}

	s.routingMeta.mu.Lock()
	s.routingMeta.value = metadata
	s.routingMeta.ok = true
	s.routingMeta.fetchedAt = s.now()
	s.routingMeta.mu.Unlock()
	return metadata, true
}

func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	// G3: capture per-request observability. status, wall_ms, model, stream
	// mode, and account_id are logged on every chat completion regardless of
	// outcome, so the flaky-provider failure mode can be diagnosed without
	// re-instrumenting the binary.
	start := s.now()
	sw := &statusWriter{ResponseWriter: w, statusCode: 0}
	w = sw
	var accountID, model string
	var streamMode bool
	defer func() {
		slog.Info("chat completion",
			"request_id", requestID(r),
			"account_id", accountID,
			"model", model,
			"stream", streamMode,
			"wall_ms", s.now().Sub(start).Milliseconds(),
			"status", sw.statusCode,
		)
	}()

	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	authn, ok := s.authenticateAny(w, r)
	if !ok {
		return
	}
	subject := usageSubject{}
	dailyQuota := s.effectiveAccountDailyQuota(r.Context())
	maxAllowed := s.cfg.Limits.MaxTokensPerRequest
	if authn.Demo {
		subject = usageSubject{
			AccountID:     "demo:" + authn.DemoPayload.IP,
			DemoIdentity:  authn.DemoPayload.IP,
			DemoTokenHash: demoTokenHash(authn.DemoToken),
		}
		dailyQuota = s.cfg.Quotas.DemoDailyTokensPerIP
		maxAllowed = s.cfg.Limits.DemoMaxTokensPerRequest
	} else {
		subject = usageSubject{AccountID: authn.Bearer.AccountID}
	}
	accountID = subject.AccountID
	body, err := io.ReadAll(io.LimitReader(r.Body, s.cfg.Limits.RequestBodyBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return
	}
	if int64(len(body)) > s.cfg.Limits.RequestBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
		return
	}
	chat, err := parseChatRequest(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request", err.Error())
		return
	}
	model = chat.Model
	streamMode = chat.Stream
	if chat.N != nil && *chat.N != 1 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "n_must_be_1", "n must be 1")
		return
	}
	maxTokens := maxAllowed
	if chat.MaxTokens != nil {
		maxTokens = *chat.MaxTokens
	}
	if maxTokens <= 0 || maxTokens > maxAllowed {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "max_tokens_exceeded", "max_tokens exceeds configured limit")
		return
	}
	window := s.now().UTC().Format("2006-01-02")
	reservationMaxAge := time.Duration(s.cfg.Quotas.ReservationMaxAgeHours) * time.Hour
	decision, err := s.store.ReserveQuota(r.Context(), storage.ReservationRequest{
		AccountID: subject.AccountID, RequestID: requestID(r), WindowDate: window,
		RequestedTokens: maxTokens, DailyQuota: dailyQuota,
		CreatedAt: s.now(), ExpiresAt: s.now().Add(reservationMaxAge),
	})
	if errors.Is(err, storage.ErrQuotaExceeded) {
		setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
		return
	}
	if err != nil && decision.Admitted {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	}
	// Belt-and-suspenders: if the store returned an unexpected error but the
	// decision already shows quota exceeded, surface 429 rather than 500.
	if err != nil && !decision.Admitted && decision.RemainingTokens == 0 && decision.LimitTokens > 0 {
		setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
		return
	}
	if err != nil {
		// Defensive cleanup: if the reservation INSERT committed before the
		// context was cancelled (commit-boundary race), this unwinds it.
		// If no row was written, RefundReservation is a safe no-op
		// (returns ErrReservationNotFound which we ignore here).
		if !decision.Admitted {
			_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		}
		// If the error is a client disconnect, avoid writing a response to a
		// dead connection — the buyer already gave up.
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "quota_reservation_failed", "Could not reserve quota")
		return
	}
	setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
	if !authn.Demo {
		if _, err := s.store.AcquireConcurrency(r.Context(), storage.ConcurrencyRequest{
			AccountID: subject.AccountID, RequestID: requestID(r), Limit: s.cfg.Quotas.AccountConcurrency,
			CreatedAt: s.now(), ExpiresAt: s.now().Add(s.cfg.CoordinatorTimeout() + time.Minute),
		}); errors.Is(err, storage.ErrQuotaExceeded) {
			_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
			writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "account_concurrency_exceeded", "Account concurrency limit exceeded")
			return
		} else if err != nil {
			_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return
			}
			writeError(w, http.StatusInternalServerError, "server_error", "concurrency_reservation_failed", "Could not reserve concurrency")
			return
		}
		defer func() {
			_ = s.store.ReleaseConcurrency(context.Background(), subject.AccountID, requestID(r), s.now())
		}()
	}

	upCtx, cancelUpstream := context.WithTimeout(r.Context(), s.cfg.CoordinatorTimeout())
	defer cancelUpstream()
	upReq, err := http.NewRequestWithContext(upCtx, http.MethodPost, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	copyForwardHeaders(upReq.Header, r.Header)
	upReq.Header.Set("Content-Type", "application/json")
	upReq.Header.Set("X-Request-ID", requestID(r))
	if s.cfg.Routing.StickyEnabled && !authn.Demo {
		if tag := strings.TrimSpace(r.Header.Get("X-MacProvider-Conversation")); tag != "" {
			if !validConversationTag(tag) {
				_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
				writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_conversation_tag", "Invalid conversation tag")
				return
			}
			if metadata, ok := s.coordinatorRoutingMetadata(upCtx); ok && metadata.Sticky.Enabled && metadata.Sticky.TTLSeconds == s.cfg.Routing.StickyTTLS {
				upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.OperatorKey)
				upReq.Header.Set("X-MacProvider-Account", subject.AccountID)
				upReq.Header.Set("X-MacProvider-Internal-Conv", s.deriveConversationKey(subject.AccountID, tag))
			}
		}
	}
	resp, err := s.client.Do(upReq)
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()

	promptEstimate := estimatePromptTokens(body)
	if chat.Stream {
		s.forwardStreamingChat(w, r, resp, subject, promptEstimate, cancelUpstream)
		return
	}
	s.forwardNonStreamingChat(w, r, resp, subject, promptEstimate)
}

func (s *Server) forwardNonStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate int64) {
	body, err := io.ReadAll(resp.Body)
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	if resp.StatusCode == http.StatusServiceUnavailable {
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "provider_unavailable", "No provider available")
		return
	}
	if resp.StatusCode == http.StatusGatewayTimeout {
		_ = s.settleRequest(r, subject, promptEstimate, 0, "gateway_estimated", "provider_timeout")
		writeError(w, http.StatusGatewayTimeout, "api_error", "provider_timeout", "Provider timed out")
		return
	}
	// Coordinator-issued 404 means the request was structurally rejected
	// (e.g. model_not_found — no provider has advertised the requested model).
	// No provider was reached → no prompt-token settlement; refund the
	// reservation and pass the OpenAI-shaped error body through verbatim so
	// the buyer sees an actionable 404 instead of an opaque 502.
	if resp.StatusCode == http.StatusNotFound {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
		return
	}
	if coordinatorTier2PolicyError(resp.StatusCode, body) {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
		return
	}
	if resp.StatusCode != http.StatusOK {
		completion := completionFromHeader(resp.Header)
		_ = s.settleRequest(r, subject, promptEstimate, completion, "gateway_estimated", "upstream_error")
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	usage, ok := usageFromJSON(body)
	tokenSource := "gateway_estimated"
	if !ok {
		usage = tokenUsage{PromptTokens: promptEstimate, CompletionTokens: 0, TotalTokens: promptEstimate}
	} else {
		tokenSource = "provider_reported"
	}
	_ = s.settleRequest(r, subject, usage.PromptTokens, usage.CompletionTokens, tokenSource, "ok")
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (s *Server) forwardStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate int64, cancelUpstream func()) {
	if resp.StatusCode == http.StatusServiceUnavailable {
		body, _ := io.ReadAll(resp.Body)
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "provider_unavailable", "No provider available")
		return
	}
	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusGatewayTimeout {
			_ = s.settleRequest(r, subject, promptEstimate, 0, "gateway_estimated", "provider_timeout")
			writeError(w, http.StatusGatewayTimeout, "api_error", "provider_timeout", "Provider timed out")
			return
		}
		// Coordinator 404 = structural rejection (model_not_found, etc.);
		// no provider reached, no charge. Pass through the OpenAI-shaped body
		// verbatim so the buyer sees a clean 404 instead of an opaque 502.
		// See forwardNonStreamingChat for the matching non-stream branch.
		if resp.StatusCode == http.StatusNotFound {
			body, _ := io.ReadAll(resp.Body)
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		body, _ := io.ReadAll(resp.Body)
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.settleRequest(r, subject, promptEstimate, completionFromHeader(resp.Header), "gateway_estimated", "upstream_error")
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var cancelOnce sync.Once
	cancelCoordinator := func() {
		cancelOnce.Do(cancelUpstream)
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-r.Context().Done():
			cancelCoordinator()
		case <-done:
		}
	}()
	var emitted int64
	var reported *tokenUsage
	for scanner.Scan() {
		select {
		case <-r.Context().Done():
			if reported != nil {
				_ = s.settleRequest(r, subject, reported.PromptTokens, reported.CompletionTokens, "provider_reported", "client_disconnect")
				return
			}
			s.settleCancelledStream(r, subject, promptEstimate, emitted, cancelCoordinator)
			return
		default:
		}
		line := scanner.Text()
		if strings.HasPrefix(line, "data: ") {
			data := strings.TrimPrefix(line, "data: ")
			if data != "[DONE]" {
				emitted += int64(len(data))
				if usage, ok := usageFromJSON([]byte(data)); ok {
					reported = &usage
				}
			}
		}
		_, _ = w.Write([]byte(line + "\n"))
		if flusher != nil {
			flusher.Flush()
		}
	}
	if errors.Is(r.Context().Err(), context.Canceled) {
		if reported != nil {
			_ = s.settleRequest(r, subject, reported.PromptTokens, reported.CompletionTokens, "provider_reported", "client_disconnect")
			return
		}
		s.settleCancelledStream(r, subject, promptEstimate, emitted, cancelCoordinator)
		return
	}
	if reported != nil {
		_ = s.settleRequest(r, subject, reported.PromptTokens, reported.CompletionTokens, "provider_reported", "ok")
		return
	}
	_ = s.settleRequest(r, subject, promptEstimate, int64(math.Ceil(float64(emitted)/4.0)), "gateway_estimated", "ok")
}

func (s *Server) passThroughNoProviderCoordinatorError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte) {
	_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func coordinatorTier2PolicyError(status int, body []byte) bool {
	code := openAIErrorCode(body)
	switch code {
	case "tier2_hash_verified_required", "tier2_hash_mismatch":
		return status == http.StatusServiceUnavailable
	case "tier2_hard_pin_predicate_failed":
		return status == http.StatusBadRequest
	default:
		return false
	}
}

func openAIErrorCode(body []byte) string {
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return ""
	}
	return strings.TrimSpace(envelope.Error.Code)
}

func (s *Server) settleCancelledStream(r *http.Request, subject usageSubject, promptEstimate, emitted int64, cancelCoordinator func()) {
	cancelCoordinator()
	_ = s.settleRequest(r, subject, promptEstimate, int64(math.Ceil(float64(emitted)/4.0)), "gateway_estimated", "client_disconnect")
}

func validConversationTag(tag string) bool {
	if len(tag) < 1 || len(tag) > 128 || strings.TrimSpace(tag) != tag {
		return false
	}
	for _, r := range tag {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			continue
		}
		switch r {
		case '.', '_', ':', '-':
			continue
		default:
			return false
		}
	}
	return true
}

func (s *Server) deriveConversationKey(accountID, tag string) string {
	const scope = "spec006-v0.8-sticky-conversation-v1"
	mac := hmac.New(sha256.New, []byte(s.cfg.Auth.KeyHashSecret))
	_, _ = mac.Write([]byte(scope))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(accountID))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(tag))
	return "conv:" + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *Server) settleRequest(r *http.Request, subject usageSubject, prompt, completion int64, source, outcome string) error {
	settlement := storage.ReservationSettlement{
		AccountID: subject.AccountID, RequestID: requestID(r), PromptTokens: prompt, CompletionTokens: completion,
		TokenSource: source, Outcome: outcome, SettledAt: s.now(),
	}
	if subject.DemoIdentity != "" {
		return s.store.SettleDemoReservation(context.Background(), settlement, storage.DemoUsageEvent{
			RequestID: requestID(r), ClientIP: subject.DemoIdentity, DemoTokenHash: subject.DemoTokenHash, CreatedAt: s.now(),
		})
	}
	return s.store.SettleReservation(context.Background(), settlement)
}

type authResult struct {
	Bearer      *storage.KeyValidation
	Demo        bool
	DemoPayload auth.DemoPayload
	DemoToken   string
}

type usageSubject struct {
	AccountID     string
	DemoIdentity  string
	DemoTokenHash string
}

type statusResponse struct {
	Status      string            `json:"status"`
	Degraded    bool              `json:"degraded"`
	Coordinator coordinatorStatus `json:"coordinator"`
	Pool        statusPool        `json:"pool"`
	Models      []statusModel     `json:"models"`
}

type coordinatorStatus struct {
	Status    string `json:"status"`
	CheckedAt string `json:"checked_at"`
}

type statusPool struct {
	TotalProviders int `json:"total_providers"`
	Ready          int `json:"ready"`
	Degraded       int `json:"degraded"`
	Draining       int `json:"draining"`
	Unavailable    int `json:"unavailable"`
}

type statusModel struct {
	ID                 string `json:"id"`
	ProviderCount      int    `json:"provider_count"`
	ReadyProviderCount int    `json:"ready_provider_count"`
	TotalSlots         int    `json:"total_slots"`
	SlotsFree          int    `json:"slots_free"`
	MaxContextTokens   int    `json:"max_context_tokens"`
	Degraded           bool   `json:"degraded"`
	Available          bool   `json:"available"`
	Availability       string `json:"availability"`
}

type poolzResponse struct {
	Pool []struct {
		ProviderID       string `json:"provider_id"`
		AssignedID       string `json:"assigned_id"`
		EndpointURL      string `json:"endpoint_url"`
		Hostname         string `json:"hostname"`
		ModelID          string `json:"model_id"`
		State            string `json:"state"`
		SlotsFree        int    `json:"slots_free"`
		SlotsTotal       int    `json:"slots_total"`
		MaxContextTokens int    `json:"max_context_tokens"`
		MemoryBytes      int64  `json:"memory_bytes"`
		CPUCount         int    `json:"cpu_count"`
		OperatorIdentity string `json:"operator_identity"`
	} `json:"pool"`
	Summary struct {
		TotalProviders int `json:"total_providers"`
		Ready          int `json:"ready"`
		TotalSlots     int `json:"total_slots"`
		FreeSlots      int `json:"free_slots"`
	} `json:"summary"`
}

func (s *Server) authenticateAny(w http.ResponseWriter, r *http.Request) (authResult, bool) {
	if token := r.Header.Get("X-Demo-Token"); token != "" {
		if s.demoPaused() {
			writeError(w, http.StatusServiceUnavailable, "service_unavailable", "demo_paused", "Demo access is paused while capacity catches up. API keys continue to work.")
			return authResult{}, false
		}
		payload, err := s.demoMgr.Validate(token, clientIP(r), s.now())
		if err != nil {
			writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_demo_token", "Invalid demo token")
			return authResult{}, false
		}
		return authResult{Demo: true, DemoPayload: payload, DemoToken: token}, true
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return authResult{}, false
	}
	return authResult{Bearer: &validation}, true
}

func (s *Server) statusFromPoolz(ctx context.Context) (statusResponse, error) {
	s.mu.RLock()
	if !s.poolz.checkedAt.IsZero() && s.now().Sub(s.poolz.checkedAt) < 10*time.Second {
		cached := s.poolz.body
		s.mu.RUnlock()
		return cached, nil
	}
	s.mu.RUnlock()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")+"/poolz", nil)
	if err != nil {
		return statusResponse{}, err
	}
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.OperatorKey)
	resp, err := s.client.Do(req)
	if err != nil {
		s.flushStatusCache()
		return statusResponse{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		s.flushStatusCache()
		return statusResponse{}, fmt.Errorf("poolz status %d", resp.StatusCode)
	}
	var poolz poolzResponse
	if err := json.NewDecoder(resp.Body).Decode(&poolz); err != nil {
		s.flushStatusCache()
		return statusResponse{}, err
	}
	out := aggregateStatus(poolz, s.cfg.Capacity.ReadyProviderDegradedThreshold, s.now())
	s.mu.Lock()
	s.poolz = statusCache{checkedAt: s.now(), body: out}
	s.mu.Unlock()
	return out, nil
}

func (s *Server) coordinatorBuyerURL() string {
	for _, target := range s.cfg.Coordinators {
		if target.Enabled {
			return target.BaseURL
		}
	}
	return s.cfg.Coordinator.BuyerURL
}

func (s *Server) flushStatusCache() {
	s.mu.Lock()
	s.poolz = statusCache{}
	s.mu.Unlock()
}

func aggregateStatus(poolz poolzResponse, readyThreshold int, now time.Time) statusResponse {
	models := map[string]statusModel{}
	stats := map[string]poolzModelStats{}
	out := statusResponse{
		Status:      "up",
		Coordinator: coordinatorStatus{Status: "up", CheckedAt: now.Format(time.RFC3339)},
	}
	for _, p := range poolz.Pool {
		out.Pool.TotalProviders++
		switch p.State {
		case "ready":
			out.Pool.Ready++
		case "degraded", "busy":
			out.Pool.Degraded++
		case "draining":
			out.Pool.Draining++
		default:
			out.Pool.Unavailable++
		}
		if p.ModelID == "" {
			continue
		}
		m := models[p.ModelID]
		m.ID = p.ModelID
		m.ProviderCount++
		m.TotalSlots += p.SlotsTotal
		m.SlotsFree += p.SlotsFree
		if p.State == "ready" {
			m.ReadyProviderCount++
		}
		if p.MaxContextTokens > m.MaxContextTokens {
			m.MaxContextTokens = p.MaxContextTokens
		}
		models[p.ModelID] = m
		st := stats[p.ModelID]
		st.TotalProviders++
		st.SlotsFreeTotal += p.SlotsFree
		if p.State == "ready" {
			st.Ready++
			st.ReadySlotsFree += p.SlotsFree
		}
		if p.State == "unavailable" || p.State == "draining" {
			st.UnavailableOrDraining++
		}
		stats[p.ModelID] = st
	}
	if out.Pool.TotalProviders == 0 && poolz.Summary.TotalProviders > 0 {
		out.Pool.TotalProviders = poolz.Summary.TotalProviders
		out.Pool.Ready = poolz.Summary.Ready
	}
	if out.Pool.Ready == 0 {
		out.Status = "idle"
		out.Degraded = false
	} else if out.Pool.Ready < readyThreshold {
		out.Status = "degraded"
		out.Degraded = true
	}
	for _, model := range models {
		model.Degraded = computeDegraded(stats[model.ID])
		model.Available, model.Availability = computeAvailability(stats[model.ID])
		out.Models = append(out.Models, model)
	}
	sort.Slice(out.Models, func(i, j int) bool { return out.Models[i].ID < out.Models[j].ID })
	return out
}

type poolzModelStats struct {
	TotalProviders        int
	UnavailableOrDraining int
	Ready                 int
	SlotsFreeTotal        int
	ReadySlotsFree        int
}

func computeDegraded(modelStats poolzModelStats) bool {
	if modelStats.TotalProviders == 0 {
		return true
	}
	if modelStats.UnavailableOrDraining == modelStats.TotalProviders {
		return true
	}
	if (2 * modelStats.Ready) < modelStats.TotalProviders {
		return true
	}
	if modelStats.SlotsFreeTotal == 0 {
		return true
	}
	return false
}

func computeAvailability(modelStats poolzModelStats) (bool, string) {
	if modelStats.Ready == 0 {
		return false, "no_awake_provider"
	}
	if modelStats.ReadySlotsFree == 0 {
		return false, "no_free_slots"
	}
	return true, "available"
}

func buildFeedbackSummary(events []storage.FeedbackSummaryEvent, start, end time.Time) map[string]any {
	latest := map[string]storage.FeedbackSummaryEvent{}
	for _, event := range events {
		key := event.EventID
		if event.RequestID != "" {
			key = event.AccountID + "\x00" + event.RequestID
		}
		latest[key] = event
	}
	distribution := map[string]int{"1": 0, "2": 0, "3": 0, "4": 0}
	type scopeAgg struct {
		count int
		sum   int
	}
	scopes := map[string]*scopeAgg{
		"request": {}, "session": {}, "account": {}, "playground": {},
	}
	var sum int
	var low int
	comments := []map[string]any{}
	for _, event := range latest {
		distribution[strconv.Itoa(event.Rating)]++
		sum += event.Rating
		if event.Rating <= 2 {
			low++
		}
		if _, ok := scopes[event.Scope]; !ok {
			scopes[event.Scope] = &scopeAgg{}
		}
		scopes[event.Scope].count++
		scopes[event.Scope].sum += event.Rating
		if event.Comment != "" {
			comments = append(comments, map[string]any{
				"rating": event.Rating, "comment": event.Comment, "scope": event.Scope, "timestamp": event.CreatedAt.Format(time.RFC3339),
			})
		}
	}
	sort.Slice(comments, func(i, j int) bool {
		return comments[i]["timestamp"].(string) > comments[j]["timestamp"].(string)
	})
	if len(comments) > 20 {
		comments = comments[:20]
	}
	count := len(latest)
	mean := 0.0
	share := 0.0
	if count > 0 {
		mean = float64(sum) / float64(count)
		share = float64(low) / float64(count)
	}
	byScope := map[string]any{}
	for scope, agg := range scopes {
		scopeMean := 0.0
		if agg.count > 0 {
			scopeMean = float64(agg.sum) / float64(agg.count)
		}
		byScope[scope] = map[string]any{"rating_count": agg.count, "mean": scopeMean}
	}
	return map[string]any{
		"window_start":    start.Format(time.RFC3339),
		"window_end":      end.Format(time.RFC3339),
		"rating_count":    count,
		"mean":            mean,
		"distribution":    distribution,
		"by_scope":        byScope,
		"trend":           map[string]any{"7d_share_1_2": share, "14d_share_1_2": share, "delta_pct": 0.0, "iteration_trigger": count >= 20 && share > 0.4},
		"comment_samples": comments,
	}
}

func (s *Server) setCapacityTier(ctx context.Context, tier int, signals, eventType string) error {
	now := s.now()
	if err := s.store.SetCapacityTier(ctx, storage.CapacityTier{Tier: tier, Signals: signals, UpdatedAt: now}); err != nil {
		return err
	}
	return s.store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID: mustID("audit"), RequestID: mustID("req"), Actor: "capacity_monitor", Type: eventType,
		Payload: fmt.Sprintf(`{"new_tier":%d,"signals":%q}`, tier, signals), CreatedAt: now,
	})
}

func (s *Server) operatorAuthorized(w http.ResponseWriter, r *http.Request) bool {
	if r.Header.Get("Authorization") == "Bearer "+s.cfg.Coordinator.OperatorKey {
		return true
	}
	writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_operator_token", "Invalid operator token")
	return false
}

func (s *Server) publicPaused(path string) bool {
	if strings.HasPrefix(path, "/admin/") || path == "/v1/status" || path == "/healthz" {
		return false
	}
	s.mu.RLock()
	paused := s.cfg.KillSwitch.AllPublicAPI
	s.mu.RUnlock()
	return paused
}

func (s *Server) demoPaused() bool {
	s.mu.RLock()
	paused := s.cfg.KillSwitch.DemoOnly
	s.mu.RUnlock()
	return paused
}

func (s *Server) secureCookies() bool {
	u, err := url.Parse(s.cfg.Public.BaseURL)
	return err == nil && u.Scheme == "https"
}

func (s *Server) effectiveAccountDailyQuota(ctx context.Context) int64 {
	limit := s.cfg.Quotas.AccountDailyTokens
	tier, err := s.store.GetCapacityTier(ctx)
	if err == nil && tier.Tier >= 2 {
		limit = limit / 2
		if limit < 1 {
			limit = 1
		}
	}
	return limit
}

func (s *Server) setAllPublicPaused(ctx context.Context, paused bool, reason string) {
	s.mu.Lock()
	old := s.cfg.KillSwitch.AllPublicAPI
	s.cfg.KillSwitch.AllPublicAPI = paused
	s.mu.Unlock()
	if old == paused {
		return
	}
	_ = s.store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID: mustID("audit"), RequestID: mustID("req"), Actor: "capacity_monitor", Type: "kill_switch_toggled",
		Payload: fmt.Sprintf(`{"old_all_public_api":%t,"new_all_public_api":%t,"reason":%q}`, old, paused, reason), CreatedAt: s.now(),
	})
	if s.cfgPath != "" {
		s.mu.RLock()
		ks := s.cfg.KillSwitch
		s.mu.RUnlock()
		_ = persistKillSwitch(s.cfgPath, ks)
	}
}

func demoTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

func validFeedbackScope(scope string) bool {
	return scope == "request" || scope == "session" || scope == "account" || scope == "playground"
}

func safeID(v string) bool {
	if len(v) > 128 {
		return false
	}
	for _, ch := range v {
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') || ch == '_' || ch == '-' {
			continue
		}
		return false
	}
	return true
}

func persistKillSwitch(path string, ks config.KillSwitchConfig) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	text := string(b)
	text = replaceYAMLBool(text, "demo_only", ks.DemoOnly)
	text = replaceYAMLBool(text, "all_public_api", ks.AllPublicAPI)
	return os.WriteFile(path, []byte(text), 0600)
}

func replaceYAMLBool(text, key string, value bool) string {
	lines := strings.Split(text, "\n")
	replacement := fmt.Sprintf("  %s: %t", key, value)
	for i, line := range lines {
		if strings.TrimSpace(strings.SplitN(line, ":", 2)[0]) == key {
			prefix := line[:len(line)-len(strings.TrimLeft(line, " "))]
			lines[i] = prefix + strings.TrimSpace(replacement)
		}
	}
	return strings.Join(lines, "\n")
}

func (s *Server) requireBearer(w http.ResponseWriter, r *http.Request) (storage.KeyValidation, bool) {
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		writeError(w, http.StatusUnauthorized, "authentication_error", "missing_bearer_token", "Missing bearer token")
		return storage.KeyValidation{}, false
	}
	validation, err := s.keyMgr.Validate(r.Context(), s.store, strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
	if errors.Is(err, storage.ErrNotFound) {
		writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_api_key", "Invalid API key")
		return storage.KeyValidation{}, false
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "api_key_lookup_failed", "Could not validate API key")
		return storage.KeyValidation{}, false
	}
	if validation.KeyStatus == "revoked" {
		writeError(w, http.StatusForbidden, "permission_error", "api_key_revoked", "API key revoked")
		return storage.KeyValidation{}, false
	}
	if validation.AccountStatus == "blocked" {
		writeError(w, http.StatusForbidden, "permission_error", "account_blocked", "Account blocked")
		return storage.KeyValidation{}, false
	}
	return validation, true
}

func (s *Server) callbackAllowed(callback string) bool {
	for _, allowed := range s.cfg.Auth.OAuth.CallbackAllowlist {
		if callback == allowed {
			return true
		}
	}
	return false
}

func (s *Server) githubAuthURL(redirectURI, state string) string {
	values := url.Values{}
	values.Set("client_id", s.cfg.Auth.OAuth.GitHub.ClientID)
	values.Set("redirect_uri", redirectURI)
	values.Set("state", state)
	values.Set("scope", "read:user")
	return s.cfg.Auth.OAuth.GitHub.AuthorizeURL + "?" + values.Encode()
}

type requestIDKey struct{}

// statusWriter wraps http.ResponseWriter to capture the HTTP status code that
// was written. handleChatCompletions uses it for an end-of-request log line
// (G3 — operator observability for the flaky-provider failure mode).
type statusWriter struct {
	http.ResponseWriter
	statusCode int
	flushed    bool
}

func (sw *statusWriter) WriteHeader(code int) {
	if !sw.flushed {
		sw.statusCode = code
		sw.flushed = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *statusWriter) Write(b []byte) (int, error) {
	if !sw.flushed {
		sw.statusCode = http.StatusOK
		sw.flushed = true
	}
	return sw.ResponseWriter.Write(b)
}

// Flush satisfies http.Flusher so SSE streaming through this wrapper still
// flushes chunks to the buyer in real time.
func (sw *statusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func requestID(r *http.Request) string {
	if v, ok := r.Context().Value(requestIDKey{}).(string); ok {
		return v
	}
	return newUUID()
}

func clientIP(r *http.Request) string {
	if realIP := strings.TrimSpace(r.Header.Get("X-Real-IP")); realIP != "" {
		return realIP
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeError(w http.ResponseWriter, status int, typ, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": message, "type": typ, "code": code}})
}

func parseChatRequest(body []byte) (chatRequest, error) {
	var req chatRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return chatRequest{}, errors.New("Malformed JSON")
	}
	if strings.TrimSpace(req.Model) == "" {
		return chatRequest{}, errors.New("model is required")
	}
	if len(req.Messages) == 0 {
		return chatRequest{}, errors.New("messages is required")
	}
	return req, nil
}

func usageFromJSON(body []byte) (tokenUsage, bool) {
	var envelope struct {
		Usage *tokenUsage `json:"usage"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil || envelope.Usage == nil {
		return tokenUsage{}, false
	}
	if envelope.Usage.TotalTokens == 0 {
		envelope.Usage.TotalTokens = envelope.Usage.PromptTokens + envelope.Usage.CompletionTokens
	}
	return *envelope.Usage, true
}

func completionFromHeader(header http.Header) int64 {
	raw := header.Get("X-MacProvider-Completion-Tokens")
	if raw == "" {
		return 0
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func estimatePromptTokens(body []byte) int64 {
	if len(body) == 0 {
		return 0
	}
	return int64(math.Ceil(float64(len(body)) / 4.0))
}

func copyForwardHeaders(dst, src http.Header) {
	if accept := strings.TrimSpace(src.Get("Accept")); accept != "" {
		dst.Set("Accept", accept)
	}
	if retry := strings.TrimSpace(src.Get("X-MacProvider-Retry")); retry != "" {
		dst.Set("X-MacProvider-Retry", retry)
	}
}

func copyCleanHeaders(dst, src http.Header) {
	for key, values := range src {
		if isMacProviderHeader(key) || strings.EqualFold(key, "Content-Length") {
			continue
		}
		for _, value := range values {
			dst.Add(key, value)
		}
	}
}

func stripInternalMacProviderHeaders(header http.Header) []string {
	var stripped []string
	for key := range header {
		if isInternalMacProviderHeader(key) {
			stripped = append(stripped, key)
			header.Del(key)
		}
	}
	sort.Strings(stripped)
	return stripped
}

func isMacProviderHeader(key string) bool {
	return strings.HasPrefix(strings.ToLower(key), "x-macprovider-")
}

func isInternalMacProviderHeader(key string) bool {
	lower := strings.ToLower(key)
	return lower == "x-macprovider-internal-conv" || strings.HasPrefix(lower, "x-macprovider-internal-")
}

func contentTypeOrJSON(header http.Header) string {
	if ct := header.Get("Content-Type"); ct != "" {
		return ct
	}
	return "application/json"
}

func setRateLimitHeaders(w http.ResponseWriter, limit, remaining, reset int64) {
	w.Header().Set("X-RateLimit-Limit", fmt.Sprintf("%d", limit))
	w.Header().Set("X-RateLimit-Remaining", fmt.Sprintf("%d", remaining))
	w.Header().Set("X-RateLimit-Reset", fmt.Sprintf("%d", reset))
}

func resetUnix(windowDate string) int64 {
	t, err := time.Parse("2006-01-02", windowDate)
	if err != nil {
		return 0
	}
	return t.Add(24 * time.Hour).Unix()
}

func mustID(prefix string) string {
	id, err := auth.RandomID(prefix)
	if err != nil {
		panic(err)
	}
	return id
}

func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func isUUIDLike(v string) bool {
	if len(v) != 36 {
		return false
	}
	for i, ch := range v {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if ch != '-' {
				return false
			}
			continue
		}
		if (ch < '0' || ch > '9') && (ch < 'a' || ch > 'f') && (ch < 'A' || ch > 'F') {
			return false
		}
	}
	if v[14] != '4' {
		return false
	}
	variant := v[19]
	return variant == '8' || variant == '9' || variant == 'a' || variant == 'b' || variant == 'A' || variant == 'B'
}
