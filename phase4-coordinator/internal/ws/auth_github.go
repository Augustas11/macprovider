package ws

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	mpgithub "github.com/augstar/macprovider-coordinator/internal/github"
	"github.com/augstar/macprovider-coordinator/internal/session"
)

type githubOAuthClient interface {
	ExchangeCode(context.Context, string, string, string, string) (string, error)
	User(context.Context, string) (mpgithub.User, error)
}

var pairOTQueryPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,256}$`)
var returnToPattern = regexp.MustCompile(`^/[A-Za-z0-9._~\-/?=&%:]*$`)

func (s *Server) handleGitHubStart(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.authStore == nil {
		writeAuthError(w, http.StatusInternalServerError, "oauth_not_configured")
		return
	}
	q, err := url.ParseQuery(r.URL.RawQuery)
	if err != nil {
		writeAuthError(w, http.StatusBadRequest, "bad_request")
		return
	}
	pairValues, hasPair := q["pair_ot"]
	if len(pairValues) > 1 {
		writeAuthError(w, http.StatusBadRequest, "bad_request")
		return
	}
	var pending *string
	if hasPair {
		value := pairValues[0]
		if !pairOTQueryPattern.MatchString(value) {
			writeAuthError(w, http.StatusBadRequest, "bad_request")
			return
		}
		pending = &value
	}
	state, err := randomState()
	if err != nil {
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	returnTo := normalizeReturnTo(q.Get("return_to"))
	originHash := s.oauthStateOriginHash(r)
	if err := s.authStore.CreateOAuthStateBound(r.Context(), state, returnTo, pending, originHash, s.now()); err != nil {
		if errors.Is(err, auth.ErrOAuthStateRateLimited) {
			writeAuthError(w, http.StatusTooManyRequests, "rate_limited")
			return
		}
		s.log.Warn().Err(err).Msg("oauth state create failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	w.Header().Set("Referrer-Policy", "no-referrer")
	http.Redirect(w, r, mpgithub.AuthorizeURL(s.cfg.Auth.GitHubOAuth.ClientID, s.cfg.Auth.GitHubOAuth.RedirectURI, state), http.StatusFound)
}

func (s *Server) handleGitHubCallback(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.authStore == nil {
		writeAuthError(w, http.StatusInternalServerError, "oauth_not_configured")
		return
	}
	state := strings.TrimSpace(r.URL.Query().Get("state"))
	code := strings.TrimSpace(r.URL.Query().Get("code"))
	if state == "" || code == "" {
		writeAuthError(w, http.StatusBadRequest, "state_invalid")
		return
	}
	consumed, ok, err := s.authStore.ConsumeOAuthStateBound(r.Context(), state, s.oauthStateOriginHash(r), s.now())
	if err != nil {
		s.log.Warn().Err(err).Msg("oauth state consume failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if !ok {
		writeAuthError(w, http.StatusBadRequest, "state_invalid")
		return
	}
	client := s.githubOAuth
	if client == nil {
		client = mpgithub.Client{}
	}
	accessToken, err := client.ExchangeCode(r.Context(), s.cfg.Auth.GitHubOAuth.ClientID, s.cfg.Auth.GitHubOAuth.ClientSecret, s.cfg.Auth.GitHubOAuth.RedirectURI, code)
	if err != nil {
		s.log.Warn().Err(err).Msg("github token exchange failed")
		writeAuthError(w, http.StatusBadGateway, "github_token_exchange_failed")
		return
	}
	user, err := client.User(r.Context(), accessToken)
	if err != nil {
		s.log.Warn().Err(err).Msg("github user lookup failed")
		writeAuthError(w, http.StatusBadGateway, "github_user_lookup_failed")
		return
	}
	now := s.now()
	if err := s.authStore.UpsertGitHubIdentity(r.Context(), user.ID, user.Login, now); err != nil {
		s.log.Warn().Err(err).Msg("github identity upsert failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	sessionID, err := s.authStore.CreateMPSession(r.Context(), user.ID, consumed.PendingPairOT, now)
	if err != nil {
		s.log.Warn().Err(err).Msg("mp_session create failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	session.SetCookie(w, sessionID, s.cfg.Auth.GitHubOAuth.SessionCookieDomain)
	http.Redirect(w, r, consumed.ReturnTo, http.StatusFound)
}

func (s *Server) oauthStateOriginHash(r *http.Request) string {
	secret := strings.TrimSpace(s.cfg.Auth.OperatorKey)
	if secret == "" {
		secret = strings.TrimSpace(s.cfg.Auth.GitHubOAuth.ClientSecret)
	}
	if secret == "" {
		return ""
	}
	ipHash := sha256.Sum256([]byte(oauthStatePeerIP(r)))
	uaHash := sha256.Sum256([]byte(r.UserAgent()))
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write(ipHash[:])
	_, _ = mac.Write(uaHash[:])
	return hex.EncodeToString(mac.Sum(nil))
}

func (s *Server) handleAuthMeProviders(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	sess, ok := s.authenticateMPSession(w, r)
	if !ok {
		return
	}
	providers, err := s.authStore.ListOwnedProviders(r.Context(), sess.GitHubUserID)
	if err != nil {
		s.log.Warn().Err(err).Msg("owned providers list failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	lastSeen := map[string]string{}
	for _, p := range s.pool.Snapshot() {
		lastSeen[p.ProviderID] = p.LastActivityAt.UTC().Format(time.RFC3339)
	}
	for i := range providers {
		if providers[i].LastSeenAt == "" {
			providers[i].LastSeenAt = lastSeen[providers[i].ProviderID]
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"providers": providers})
}

func (s *Server) handleAuthMeProvidersBind(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if s.authStore == nil {
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	sess, ok := s.authenticateMPSession(w, r)
	if !ok {
		return
	}
	bodyProvided := false
	bodyPairOT := ""
	if r.Body != nil {
		var raw map[string]json.RawMessage
		dec := json.NewDecoder(r.Body)
		if err := dec.Decode(&raw); err != nil && !errors.Is(err, http.ErrBodyNotAllowed) {
			writeAuthError(w, http.StatusBadRequest, "bad_request")
			return
		}
		if raw == nil {
			writeAuthError(w, http.StatusBadRequest, "bad_request")
			return
		}
		var trailing json.RawMessage
		if err := dec.Decode(&trailing); err != io.EOF {
			writeAuthError(w, http.StatusBadRequest, "bad_request")
			return
		}
		for key := range raw {
			if key != "pair_ot" {
				writeAuthError(w, http.StatusBadRequest, "bad_request")
				return
			}
		}
		if rawPairOT, ok := raw["pair_ot"]; ok {
			var decoded string
			if err := json.Unmarshal(rawPairOT, &decoded); err != nil || strings.TrimSpace(decoded) == "" {
				writeAuthError(w, http.StatusBadRequest, "bad_request")
				return
			}
			bodyProvided = true
			bodyPairOT = strings.TrimSpace(decoded)
		}
	}
	pairOT := bodyPairOT
	if !bodyProvided {
		var err error
		pairOT, err = s.authStore.ConsumePendingPairOT(r.Context(), sess.ID, s.now())
		if err != nil {
			if errors.Is(err, auth.ErrPendingPairOTMissing) {
				writeAuthError(w, http.StatusBadRequest, "bad_request")
				return
			}
			s.log.Warn().Err(err).Msg("pending pair_ot consume failed")
			writeAuthError(w, http.StatusInternalServerError, "internal_error")
			return
		}
	}
	result, err := s.authStore.BindPairOT(r.Context(), sess.ID, pairOT, s.now(), func(result auth.BindResult) error {
		return s.pushOwnershipBound(result.ProviderID, result.GitHubLogin)
	})
	switch {
	case err == nil:
	case errors.Is(err, auth.ErrSessionInvalid):
		session.ClearCookie(w, s.cfg.Auth.GitHubOAuth.SessionCookieDomain)
		writeAuthError(w, http.StatusUnauthorized, "session_invalid")
		return
	case errors.Is(err, auth.ErrPendingPairOTMissing):
		writeAuthError(w, http.StatusBadRequest, "bad_request")
		return
	case errors.Is(err, auth.ErrPairOTInvalid):
		writeAuthError(w, http.StatusGone, "pair_ot_invalid")
		return
	case errors.Is(err, auth.ErrPairOTAlreadyOwned):
		writeAuthError(w, http.StatusConflict, "already_owned")
		return
	default:
		s.log.Warn().Err(err).Msg("pair_ot bind failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id":  result.ProviderID,
		"github_login": result.GitHubLogin,
		"claimed_at":   result.ClaimedAt,
	})
}

func (s *Server) handleAuthLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if cookie, err := r.Cookie(session.Name); err == nil && cookie.Value != "" && s.authStore != nil {
		_ = s.authStore.DeleteMPSession(r.Context(), cookie.Value)
	}
	session.ClearCookie(w, s.cfg.Auth.GitHubOAuth.SessionCookieDomain)
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleInstallPairRefresh(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok, err := s.providerIDFromBearer(r.Context(), r)
	if err != nil {
		s.log.Warn().Err(err).Msg("pair refresh token validation failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if !ok {
		if err := s.logPairMint(r, "unknown", http.StatusUnauthorized); err != nil {
			s.log.Warn().Err(err).Msg("pair refresh unauthenticated log failed")
			writeAuthError(w, http.StatusInternalServerError, "internal_error")
			return
		}
		writeAuthError(w, http.StatusUnauthorized, "unauthenticated")
		return
	}
	now := s.now()
	result, err := s.authStore.MintPairOTRefresh(r.Context(), providerID, remoteIP(r), r.UserAgent(), now)
	if err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Msg("pair refresh mint failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return
	}
	if result.RateLimited {
		w.Header().Set("Retry-After", fmt.Sprintf("%d", result.RetryAfter))
		writeAuthError(w, http.StatusTooManyRequests, "rate_limited")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"pair_ot":    result.Mint.PairOT,
		"claim_url":  s.claimURL(result.Mint.PairOT),
		"expires_in": 600,
	})
}

func (s *Server) authenticateMPSession(w http.ResponseWriter, r *http.Request) (auth.MPSession, bool) {
	if s.authStore == nil {
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return auth.MPSession{}, false
	}
	cookie, err := r.Cookie(session.Name)
	if err != nil || cookie.Value == "" {
		session.ClearCookie(w, s.cfg.Auth.GitHubOAuth.SessionCookieDomain)
		writeAuthError(w, http.StatusUnauthorized, "session_invalid")
		return auth.MPSession{}, false
	}
	now := s.now()
	sess, ok, err := s.authStore.LoadMPSession(r.Context(), cookie.Value, now)
	if err != nil {
		s.log.Warn().Err(err).Msg("mp_session load failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return auth.MPSession{}, false
	}
	if !ok {
		session.ClearCookie(w, s.cfg.Auth.GitHubOAuth.SessionCookieDomain)
		writeAuthError(w, http.StatusUnauthorized, "session_invalid")
		return auth.MPSession{}, false
	}
	reissue := session.NeedsReissue(sess.LastSetCookieAt, now)
	if err := s.authStore.TouchMPSession(r.Context(), sess.ID, now, reissue); err != nil {
		s.log.Warn().Err(err).Msg("mp_session touch failed")
		writeAuthError(w, http.StatusInternalServerError, "internal_error")
		return auth.MPSession{}, false
	}
	if reissue {
		session.SetCookie(w, sess.ID, s.cfg.Auth.GitHubOAuth.SessionCookieDomain)
	}
	return sess, true
}

func (s *Server) providerIDFromBearer(ctx context.Context, r *http.Request) (string, bool, error) {
	authz := strings.TrimSpace(r.Header.Get("Authorization"))
	token, ok := strings.CutPrefix(authz, "Bearer ")
	if !ok || strings.TrimSpace(token) == "" || s.authStore == nil {
		return "", false, nil
	}
	return s.authStore.ValidateToken(ctx, strings.TrimSpace(token))
}

func (s *Server) logPairMint(r *http.Request, providerID string, outcome int) error {
	if s.authStore == nil {
		return nil
	}
	return s.authStore.LogPairOTMint(r.Context(), providerID, remoteIP(r), r.UserAgent(), outcome, s.now())
}

func (s *Server) pushOwnershipBound(providerID, githubLogin string) error {
	event := OwnershipEvent{Type: "ownership_event", ProviderID: providerID, GitHubLogin: githubLogin, Event: "bound"}
	payload, err := json.Marshal(event)
	if err != nil {
		return err
	}
	for _, p := range s.pool.Snapshot() {
		if p.ProviderID != providerID {
			continue
		}
		if sess, ok := s.sessionFor(p.ProviderID, p.AssignedID); ok {
			if err := sess.send(payload); err != nil {
				return err
			}
		}
	}
	return nil
}

func (s *Server) claimURL(pairOT string) string {
	base := strings.TrimRight(s.cfg.Auth.GitHubOAuth.PortalBaseURL, "/")
	return base + "/claim?ot=" + url.QueryEscape(pairOT)
}

func writeAuthError(w http.ResponseWriter, status int, code string) {
	writeJSON(w, status, map[string]string{"error": code})
}

func normalizeReturnTo(v string) string {
	if v == "" {
		return "/"
	}
	if !validReturnTo(v) {
		return "/"
	}
	decodedOnce, err := url.QueryUnescape(v)
	if err != nil || !validReturnTo(decodedOnce) {
		return "/"
	}
	return v
}

func validReturnTo(v string) bool {
	return v != "" &&
		strings.HasPrefix(v, "/") &&
		!strings.HasPrefix(v, "//") &&
		!strings.HasPrefix(v, `/\`) &&
		!strings.Contains(v, `\`) &&
		returnToPattern.MatchString(v)
}

func randomState() (string, error) {
	var raw [32]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw[:]), nil
}

func remoteIP(r *http.Request) string {
	for _, header := range []string{"X-Real-IP", "X-Forwarded-For"} {
		v := strings.TrimSpace(r.Header.Get(header))
		if v == "" {
			continue
		}
		if header == "X-Forwarded-For" {
			v = strings.TrimSpace(strings.Split(v, ",")[0])
		}
		if ip := net.ParseIP(v); ip != nil {
			return ip.String()
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func oauthStatePeerIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err == nil {
		return host
	}
	return r.RemoteAddr
}

func (s *Server) redactedRequestLogMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s.log.Info().
			Str("method", r.Method).
			Str("path", redactTokenQuery(r.URL)).
			Msg("provider http request")
		next.ServeHTTP(w, r)
	})
}

func redactTokenQuery(u *url.URL) string {
	return redactTokenQueryDepth(u, 0)
}

func redactTokenQueryDepth(u *url.URL, depth int) string {
	if u == nil {
		return ""
	}
	clone := *u
	if clone.RawQuery != "" {
		if _, err := url.ParseQuery(clone.RawQuery); err != nil {
			clone.RawQuery = "redacted=1"
			return clone.RequestURI()
		}
	}
	values := clone.Query()
	changed := false
	for _, key := range []string{"ot", "pair_ot", "code", "state"} {
		current, ok := values[key]
		if !ok {
			continue
		}
		for i := range current {
			current[i] = "REDACTED"
		}
		values[key] = current
		changed = true
	}
	if depth < 2 {
		if current, ok := values["return_to"]; ok {
			for i, v := range current {
				nested, err := url.Parse(v)
				if err != nil || nested.RawQuery == "" {
					continue
				}
				current[i] = redactTokenQueryDepth(nested, depth+1)
				changed = true
			}
			values["return_to"] = current
		}
	}
	if changed {
		clone.RawQuery = values.Encode()
	}
	return clone.RequestURI()
}
