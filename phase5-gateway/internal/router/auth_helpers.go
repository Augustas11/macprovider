package router

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"net"
	"net/http"
	"net/url"
	"strings"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

func (s *Server) operatorAuthorized(w http.ResponseWriter, r *http.Request) bool {
	if operatorBearerAuthorized(r.Header, s.cfg.Coordinator.OperatorKey) {
		return true
	}
	writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_operator_token", "Invalid operator token")
	return false
}

func (s *Server) shouldPersistInternalHeaderAudit(r *http.Request) bool {
	if strings.HasPrefix(r.URL.Path, "/admin/") {
		return operatorBearerAuthorized(r.Header, s.cfg.Coordinator.OperatorKey)
	}
	if token := r.Header.Get("X-Demo-Token"); token != "" {
		_, err := s.demoMgr.Validate(token, s.clientIP(r), s.now())
		return err == nil
	}
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		return false
	}
	_, err := s.keyMgr.Validate(r.Context(), s.store, strings.TrimSpace(strings.TrimPrefix(header, "Bearer ")))
	return err == nil
}

func operatorBearerAuthorized(headers http.Header, expected string) bool {
	expected = strings.TrimSpace(expected)
	if expected == "" {
		return false
	}
	authHeader := strings.TrimSpace(headers.Get("Authorization"))
	token, ok := strings.CutPrefix(authHeader, "Bearer ")
	if !ok {
		return false
	}
	token = strings.TrimSpace(token)
	tokenHash := sha256.Sum256([]byte(token))
	expectedHash := sha256.Sum256([]byte(expected))
	return hmac.Equal(tokenHash[:], expectedHash[:])
}

func (s *Server) publicPaused(path string) bool {
	if strings.HasPrefix(path, "/admin/") || path == "/v1/status" || path == "/healthz" || path == "/metrics" || isPublicFeedPath(path) {
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

type authResult struct {
	Bearer        *storage.KeyValidation
	WalletSession *walletSessionAuth
	Demo          bool
	DemoPayload   auth.DemoPayload
	DemoToken     string
}

func (s *Server) authenticateAny(w http.ResponseWriter, r *http.Request) (authResult, bool) {
	credentialCount := 0
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		credentialCount++
	}
	rawAuthHeader := r.Header.Get("Authorization")
	authHeader := strings.TrimSpace(rawAuthHeader)
	authBearer := ""
	if strings.HasPrefix(rawAuthHeader, "Bearer ") {
		authBearer = strings.TrimSpace(strings.TrimPrefix(rawAuthHeader, "Bearer "))
	}
	if authHeader != "" && (authBearer != "" || !strings.HasPrefix(rawAuthHeader, "Bearer ")) {
		credentialCount++
	}
	xAPIKey := strings.TrimSpace(r.Header.Get("X-Api-Key"))
	anthropicAliasNormalized := anthropicMessagesAdapterFromContext(r.Context()) != nil && xAPIKey != "" && authHeader == "Bearer "+xAPIKey
	if xAPIKey != "" && !anthropicAliasNormalized {
		credentialCount++
	}
	if credentialCount > 1 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "ambiguous_credentials", "Multiple credential types are not allowed")
		return authResult{}, false
	}
	if token := r.Header.Get("X-Demo-Token"); token != "" {
		if s.demoPaused() {
			writeError(w, http.StatusServiceUnavailable, "service_unavailable", "demo_paused", "Demo access is paused while capacity catches up. API keys continue to work.")
			return authResult{}, false
		}
		payload, err := s.demoMgr.Validate(token, s.clientIP(r), s.now())
		if err != nil {
			writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_demo_token", "Invalid demo token")
			return authResult{}, false
		}
		return authResult{Demo: true, DemoPayload: payload, DemoToken: token}, true
	}
	if bearer := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")); strings.HasPrefix(bearer, walletSessionBearerPrefix) {
		session, ok := s.requireWalletSessionBearer(w, r)
		if !ok {
			return authResult{}, false
		}
		return authResult{WalletSession: session}, true
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return authResult{}, false
	}
	return authResult{Bearer: &validation}, true
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

func (s *Server) clientIP(r *http.Request) string {
	if realIP := strings.TrimSpace(r.Header.Get("X-Real-IP")); realIP != "" && s.requestFromTrustedProxy(r) {
		return realIP
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func (s *Server) requestFromTrustedProxy(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(strings.TrimSpace(host))
	if ip == nil {
		return false
	}
	for _, network := range s.trustedProxyNets {
		if network.Contains(ip) {
			return true
		}
	}
	return false
}
