package router

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

func (s *Server) handleGitHubStart(w http.ResponseWriter, r *http.Request) {
	if !s.cfg.Auth.GitHubOAuthEnabled {
		http.Error(w, "oauth_disabled", http.StatusServiceUnavailable)
		return
	}
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
	// `?action=mint` opts the flow into issuing a fresh API key for an
	// existing account on callback. Without this, the existing-account branch
	// of handleGitHubCallback is a no-op (signup-only key issuance), which
	// makes the /account page's "sign in again to mint a new one" copy a lie.
	// The action is bound to the OAuthState row (not a sibling cookie) so it
	// is single-use, state-linked, and impossible to leak across parallel
	// flows or stick around after an early callback failure.
	action := r.URL.Query().Get("action")
	if action != "" && action != "mint" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "oauth_action_unknown", "Unknown OAuth action")
		return
	}
	returnTo := strings.TrimSpace(r.URL.Query().Get("return_to"))
	if returnTo != "" && !s.returnToAllowed(returnTo) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "oauth_return_to_not_allowed", "OAuth return URL is not allowed")
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
	if err := s.store.StoreOAuthStateWithCap(r.Context(), storage.OAuthState{
		StateHash: auth.StateHash(state), SessionID: sessionID, RedirectURI: redirectURI,
		ReturnTo: returnTo, ClientIP: s.clientIP(r), Action: action, CreatedAt: now, ExpiresAt: auth.OAuthStateExpiry(now),
	}, s.cfg.Auth.OAuth.StateMaxPerIP, now); err != nil {
		if errors.Is(err, storage.ErrOAuthStateCap) {
			writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "oauth_state_rate_limited", "OAuth start limit exceeded")
			return
		}
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
	if !s.cfg.Auth.GitHubOAuthEnabled {
		http.Error(w, "oauth_disabled", http.StatusServiceUnavailable)
		return
	}
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
	// ConsumeOAuthState atomically reads + marks-consumed the state row, and
	// returns the action bound to it at /auth/github/start time. Action lives
	// in the state row exactly so it is single-use and impossible to leak
	// across browser tabs, stale cookies, or early callback failures.
	redirectURI, action, returnTo, err := s.store.ConsumeOAuthState(r.Context(), auth.StateHash(state), cookie.Value, s.now())
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

	issueKey := false
	keyAction := ""
	account, err := s.store.LookupAccountByIdentity(r.Context(), "github", identity.ProviderUserID)
	if errors.Is(err, storage.ErrNotFound) {
		account, err = s.createSignupAccount(w, r.Context(), r, identity)
		if err != nil {
			return
		}
		issueKey = true
	} else if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "account_lookup_failed", "Could not load account")
		return
	} else if action == "mint" {
		issueKey = true
		keyAction = "mint"
	}
	if returnTo != "" {
		if !issueKey {
			s.redirectOAuthReturn(w, r, returnTo, "no_key")
			return
		}
		if err := s.redirectOAuthHandoff(r.Context(), w, r, returnTo, account.AccountID, keyAction); err == nil {
			return
		}
		// No key exists yet. If intent persistence fails, issue directly to
		// the gateway's one-shot /account cookie instead of persisting a key.
	}
	if issueKey {
		fullKey, summary, err := s.keyMgr.Issue(r.Context(), s.store, account.AccountID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "api_key_issuance_failed", "Could not issue API key")
			return
		}
		if keyAction == "mint" {
			s.recordOAuthKeyMint(r, account.AccountID, summary)
		}
		http.SetCookie(w, &http.Cookie{
			Name: "mp_new_api_key", Value: fullKey, Path: "/account", HttpOnly: true,
			Secure: s.secureCookies(), SameSite: http.SameSiteLaxMode, MaxAge: 300,
		})
	}
	http.Redirect(w, r, s.cfg.Public.AccountPath, http.StatusFound)
}

func (s *Server) handleHandoffExchange(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	var req struct {
		Handoff string `json:"handoff"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_handoff", "Handoff token is invalid")
		return
	}
	req.Handoff = strings.TrimSpace(req.Handoff)
	if req.Handoff == "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_handoff", "Handoff token is invalid")
		return
	}
	apiKey, key, err := s.keyMgr.Generate("")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "api_key_issuance_failed", "Could not issue API key")
		return
	}
	handoff, err := s.store.ConsumeOAuthHandoff(r.Context(), auth.StateHash(req.Handoff), key, s.now())
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_handoff", "Handoff token is invalid")
		return
	}
	if handoff.Action == "mint" {
		s.recordOAuthKeyMint(r, handoff.AccountID, key)
	}
	setNoStoreHeaders(w.Header())
	writeJSON(w, http.StatusOK, map[string]any{"api_key": apiKey})
}

func (s *Server) recordOAuthKeyMint(r *http.Request, accountID string, key storage.APIKey) {
	_ = s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
		EventID: mustID("audit"), RequestID: requestID(r), Actor: accountID,
		Type: "api_key_minted_via_oauth",
		Payload: fmt.Sprintf(`{"action":"mint","key_id":%q,"key_prefix":%q}`,
			key.KeyID, key.KeyHashPrefix),
		CreatedAt: s.now(),
	})
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
	ip := s.clientIP(r)
	now := s.now()
	if err := s.store.ReservePublicIssuance(ctx, storage.PublicIssuanceReservation{
		Surface: "signup", ClientIP: ip, WindowStart: now.Add(-24 * time.Hour), Limit: s.cfg.Quotas.SignupAccountsPerIPPerDay, CreatedAt: now,
	}); err != nil {
		if errors.Is(err, storage.ErrRateLimit) {
			writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "signup_rate_limited", "Signup limit exceeded")
			return storage.Account{}, err
		}
		writeError(w, http.StatusInternalServerError, "server_error", "signup_limit_check_failed", "Could not check signup limit")
		return storage.Account{}, err
	}
	accountID := mustID("acct")
	account := storage.Account{AccountID: accountID, Status: "active", QuotaClass: "default", ConcurrencyClass: "default", CreatedAt: now}
	if err := s.store.CreateAccount(ctx, account); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "account_create_failed", "Could not create account")
		return storage.Account{}, err
	}
	if err := s.store.AddAccountIdentity(ctx, storage.AccountIdentity{
		AccountID: accountID, Provider: "github", ProviderUserID: identity.ProviderUserID, Email: identity.Email, CreatedAt: now,
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "identity_create_failed", "Could not create identity")
		return storage.Account{}, err
	}
	if err := s.store.RecordSignupEvent(ctx, storage.SignupEvent{
		EventID: mustID("signup"), AccountID: accountID, ClientIP: ip, Provider: "github", CreatedAt: now,
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
	ip := s.clientIP(r)
	now := s.now()
	if err := s.store.ReservePublicIssuance(r.Context(), storage.PublicIssuanceReservation{
		Surface: "demo_session", ClientIP: ip, WindowStart: now.Add(-time.Hour), Limit: s.cfg.Quotas.DemoSessionsPerIPPerHour, CreatedAt: now,
	}); err != nil {
		if errors.Is(err, storage.ErrRateLimit) {
			writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "demo_session_rate_limited", "Demo session limit exceeded")
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "demo_session_check_failed", "Could not check demo session limit")
		return
	}
	token, expires, err := s.demoMgr.Issue(ip, now, 24*time.Hour)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "demo_token_issuance_failed", "Could not issue demo token")
		return
	}
	if err := s.store.RecordDemoSessionEvent(r.Context(), storage.DemoSessionEvent{EventID: mustID("demo"), ClientIP: ip, CreatedAt: now}); err != nil {
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
	// revoked_current is derived from exact key IDs after a successful
	// account-scoped revoke. It is a non-secret boolean so a console can
	// drop the local bearer before any follow-up authenticated refresh.
	setNoStoreHeaders(w.Header())
	writeJSON(w, http.StatusOK, map[string]any{
		"status":          "revoked",
		"key_id":          keyID,
		"revoked_current": keyID == validation.KeyID,
	})
}

func (s *Server) callbackAllowed(callback string) bool {
	for _, allowed := range s.cfg.Auth.OAuth.CallbackAllowlist {
		if callback == allowed {
			return true
		}
	}
	return false
}

func (s *Server) redirectOAuthHandoff(ctx context.Context, w http.ResponseWriter, r *http.Request, returnTo, accountID, action string) error {
	token, err := auth.StateToken()
	if err != nil {
		return err
	}
	now := s.now()
	if err := s.store.StoreOAuthHandoff(ctx, storage.OAuthHandoff{
		TokenHash: auth.StateHash(token),
		AccountID: accountID,
		Action:    action,
		CreatedAt: now,
		ExpiresAt: now.Add(5 * time.Minute),
	}); err != nil {
		return err
	}
	target, err := url.Parse(returnTo)
	if err != nil {
		return err
	}
	values := target.Query()
	values.Set("handoff", token)
	target.RawQuery = values.Encode()
	// The raw handoff token rides in the redirect URL as a query param, so it
	// lands in nginx access logs and browser history. Suppress the outbound
	// referrer from the Malibu callback page so the token does not leak to
	// third parties Malibu subsequently fetches, and mark the redirect
	// response as no-store so intermediary proxies do not cache the URL.
	w.Header().Set("Referrer-Policy", "no-referrer")
	setNoStoreHeaders(w.Header())
	http.Redirect(w, r, target.String(), http.StatusFound)
	return nil
}

func (s *Server) redirectOAuthReturn(w http.ResponseWriter, r *http.Request, returnTo, errCode string) {
	target, err := url.Parse(returnTo)
	if err != nil {
		http.Redirect(w, r, s.cfg.Public.AccountPath, http.StatusFound)
		return
	}
	if errCode != "" {
		values := target.Query()
		values.Set("error", errCode)
		target.RawQuery = values.Encode()
	}
	http.Redirect(w, r, target.String(), http.StatusFound)
}

// returnToAllowed matches a caller-supplied return_to URL against the
// allowlist. Scheme and Host match case-insensitively. Path semantics:
//
//   - Reject any target whose Path contains a "." or ".." segment (before
//     or after URL-decoding), so `/console/auth/callback.html/../admin`
//     cannot smuggle a token onto an unintended route on the same host.
//   - Allowlist path "" or "/" matches any target path on that host.
//   - Allowlist path with a trailing "/" is an explicit directory prefix
//     match; the target path must have the allowlist path as a prefix.
//   - Any other allowlist path requires an exact match — so
//     `/console/auth/callback.html` does NOT accept
//     `/console/auth/callback.htmlx` or
//     `/console/auth/callback.html/other`.
func (s *Server) returnToAllowed(returnTo string) bool {
	target, err := url.Parse(returnTo)
	if err != nil || target.Scheme == "" || target.Host == "" {
		return false
	}
	if hasDotSegment(target.Path) || hasDotSegment(target.EscapedPath()) {
		return false
	}
	for _, allowed := range s.cfg.Auth.OAuth.ReturnToAllowlist {
		u, err := url.Parse(allowed)
		if err != nil || u.Scheme == "" || u.Host == "" {
			continue
		}
		if !strings.EqualFold(target.Scheme, u.Scheme) || !strings.EqualFold(target.Host, u.Host) {
			continue
		}
		switch {
		case u.Path == "" || u.Path == "/":
			return true
		case strings.HasSuffix(u.Path, "/"):
			if strings.HasPrefix(target.Path, u.Path) {
				return true
			}
		default:
			if target.Path == u.Path {
				return true
			}
		}
	}
	return false
}

func hasDotSegment(p string) bool {
	for _, seg := range strings.Split(p, "/") {
		if seg == "." || seg == ".." {
			return true
		}
		lowered := strings.ToLower(seg)
		if lowered == "%2e" || lowered == "%2e%2e" {
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
