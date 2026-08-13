package router

import (
	"context"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

const (
	walletSessionBearerPrefix = "mps_"
	walletSessionRoute        = "/auth/wallet-sessions/{session_id}"
	walletSessionUsageRoute   = "/auth/wallet-sessions/{session_id}/usage"
)

type walletSessionAuth struct {
	Session storage.WalletSession
	Bearer  string
}

func (s *Server) withWalletSessionCORS(methods []string, next http.Handler) http.Handler {
	allowedMethods := map[string]struct{}{}
	for _, method := range methods {
		allowedMethods[method] = struct{}{}
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := s.corsOriginAllowed(origin)
		if r.Method == http.MethodOptions {
			if !allowed {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			requested := r.Header.Get("Access-Control-Request-Method")
			if _, ok := allowedMethods[requested]; !ok {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			setCORSHeaders(w.Header(), origin)
			w.Header().Set("Access-Control-Allow-Methods", strings.Join(methods, ", "))
			w.Header().Set("Access-Control-Allow-Headers", corsAllowedHeaders)
			w.Header().Set("Access-Control-Max-Age", corsMaxAge)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if allowed {
			setCORSHeaders(w.Header(), origin)
		}
		next.ServeHTTP(w, r)
	})
}

func (s *Server) handleWalletSessions(w http.ResponseWriter, r *http.Request) {
	s.setWalletSessionHeaders(w.Header())
	switch r.Method {
	case http.MethodPost:
		s.handleWalletSessionRegister(w, r)
	case http.MethodGet:
		s.handleWalletSessionList(w, r)
	default:
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
	}
}

func (s *Server) handleWalletSessionChallenges(w http.ResponseWriter, r *http.Request) {
	s.setWalletSessionHeaders(w.Header())
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	validation, ok := s.requireWalletSessionAccountBearer(w, r)
	if !ok {
		return
	}
	body, ok := s.readWalletSessionBody(w, r, s.cfg.Auth.WalletSessions.ChallengeBodyBytes)
	if !ok {
		return
	}
	req, err := auth.DecodeWalletChallengeRequestJSON(body)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	models, modelsOK, err := s.canonicalWalletModelAllowlist(r.Context(), req.ModelAllowlist)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "coordinator_models_error", "Coordinator models error")
		return
	}
	if !modelsOK {
		writeError(w, http.StatusForbidden, "permission_error", "wallet_session_model_not_allowed", "Wallet session does not allow this model")
		return
	}
	if len(models) == 0 || req.TotalTokenCap > s.cfg.Auth.WalletSessions.MaxTotalTokenCap ||
		req.PerRequestTokenCap > s.cfg.Auth.WalletSessions.MaxPerRequestTokenCap {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_cap_invalid", "Wallet-session caps are invalid")
		return
	}
	now := s.now().UTC()
	if !s.reserveWalletSessionIssuance(w, r, "wallet_session_challenge", s.clientIP(r), s.cfg.Auth.WalletSessions.ChallengeIssuancePerIPPerHour, now) {
		return
	}
	requestedExpiry := time.Unix(req.ExpiresAtUnix, 0).UTC()
	if !requestedExpiry.After(now) || requestedExpiry.After(now.Add(time.Duration(s.cfg.Auth.WalletSessions.MaxSessionTTLSeconds)*time.Second)) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_expiry_invalid", "Wallet-session expiry is invalid")
		return
	}
	walletFingerprint, err := auth.WalletFingerprint([]byte(s.cfg.Auth.WalletSessions.WalletFingerprintSecret), req.WalletNamespace, req.WalletPublicKey)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	nonce, err := auth.StateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_issuance_failed", "Could not create wallet-session challenge")
		return
	}
	challengeID := "wch_" + nonce
	nonceHash := sha256.Sum256([]byte(nonce))
	modelsJSON, _ := json.Marshal(models)
	sessionPublicKey, err := auth.DecodeBase64URLFixed(req.SessionPublicKey, ed25519.PublicKeySize)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	if err := s.store.StoreWalletSessionChallenge(r.Context(), storage.WalletSessionChallenge{
		NonceHash:          nonceHash[:],
		AccountID:          validation.AccountID,
		WalletNamespace:    req.WalletNamespace,
		WalletFingerprint:  walletFingerprint,
		Purpose:            "wallet-session-registration-v1",
		Audience:           s.cfg.Public.BaseURL,
		RequestedExpiresAt: requestedExpiry,
		PerRequestTokenCap: req.PerRequestTokenCap,
		TotalTokenCap:      req.TotalTokenCap,
		ModelAllowlistJSON: string(modelsJSON),
		SessionPublicKey:   sessionPublicKey,
		CreatedAt:          now,
		ExpiresAt:          now.Add(time.Duration(s.cfg.Auth.WalletSessions.MaxChallengeTTLSeconds) * time.Second),
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_challenge_failed", "Could not store wallet-session challenge")
		return
	}
	challengeExpiresAt := now.Add(time.Duration(s.cfg.Auth.WalletSessions.MaxChallengeTTLSeconds) * time.Second)
	s.recordWalletSessionAudit(r.Context(), validation.AccountID, "", "wallet_session_challenge_created", "account", map[string]any{
		"challenge_id":         challengeID,
		"wallet_namespace":     req.WalletNamespace,
		"wallet_fingerprint":   walletFingerprint,
		"expires_at_unix":      req.ExpiresAtUnix,
		"model_allowlist":      models,
		"total_token_cap":      req.TotalTokenCap,
		"per_request_cap":      req.PerRequestTokenCap,
		"challenge_expires_at": challengeExpiresAt.Unix(),
	})
	writeJSON(w, http.StatusOK, map[string]any{
		"challenge_id":              challengeID,
		"aud":                       s.cfg.Public.BaseURL,
		"account_id":                validation.AccountID,
		"nonce":                     nonce,
		"expires_at_unix":           req.ExpiresAtUnix,
		"challenge_expires_at_unix": challengeExpiresAt.Unix(),
		"proof_version":             auth.WalletProofVersion,
		"model_allowlist":           models,
	})
}

func (s *Server) handleWalletSessionRegister(w http.ResponseWriter, r *http.Request) {
	validation, ok := s.requireWalletSessionAccountBearer(w, r)
	if !ok {
		return
	}
	body, ok := s.readWalletSessionBody(w, r, s.cfg.Auth.WalletSessions.RegistrationBodyBytes)
	if !ok {
		return
	}
	req, _, err := auth.DecodeWalletRegistrationRequestJSON(body)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	if req.Proof.AccountID != validation.AccountID || req.Proof.Audience != s.cfg.Public.BaseURL || !strings.HasPrefix(req.Proof.ChallengeID, "wch_") {
		writeError(w, http.StatusForbidden, "permission_error", "wallet_account_mismatch", "Wallet-session proof does not match the authenticated account")
		return
	}
	if err := auth.VerifyWalletProof(req.Proof, req.WalletSignature); err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	walletFingerprint, err := auth.WalletFingerprint([]byte(s.cfg.Auth.WalletSessions.WalletFingerprintSecret), req.Proof.WalletNamespace, req.Proof.WalletPublicKey)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	sessionPublicKey, err := auth.DecodeBase64URLFixed(req.Proof.SessionPublicKey, ed25519.PublicKeySize)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	models := normalizeWalletModelAllowlist(req.Proof.ModelAllowlist)
	modelsJSON, _ := json.Marshal(models)
	nonceHash := sha256.Sum256([]byte(req.Proof.Nonce))
	now := s.now().UTC()
	if !s.reserveWalletSessionIssuance(w, r, "wallet_session_registration", validation.AccountID, s.cfg.Auth.WalletSessions.SessionIssuancePerAccountPerHour, now) {
		return
	}
	sessionID, err := auth.RandomID("walsess")
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_issuance_failed", "Could not create wallet session")
		return
	}
	bearerToken, err := auth.StateToken()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_issuance_failed", "Could not create wallet session")
		return
	}
	rawBearer := walletSessionBearerPrefix + bearerToken
	keyID := s.cfg.Auth.WalletSessions.CurrentBearerHashKeyID
	bearerHash, ok := s.walletSessionBearerHashForKey(rawBearer, keyID)
	if !ok {
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_issuance_failed", "Could not create wallet session")
		return
	}
	verificationKey, err := auth.DecodeBase64URLFixed(req.Proof.WalletPublicKey, ed25519.PublicKeySize)
	if err != nil {
		s.writeWalletSessionDecodeError(w, err)
		return
	}
	session, err := s.store.RegisterWalletSession(r.Context(), storage.WalletSessionRegistrationRequest{
		ChallengeNonceHash:    nonceHash[:],
		SessionID:             sessionID,
		AccountID:             validation.AccountID,
		WalletNamespace:       req.Proof.WalletNamespace,
		WalletFingerprint:     walletFingerprint,
		Audience:              req.Proof.Audience,
		RequestedExpiresAt:    time.Unix(req.Proof.ExpiresAtUnix, 0).UTC(),
		PerRequestTokenCap:    req.Proof.PerRequestTokenCap,
		TotalTokenCap:         req.Proof.TotalTokenCap,
		ModelAllowlistJSON:    string(modelsJSON),
		SessionPublicKey:      sessionPublicKey,
		BearerHash:            bearerHash,
		BearerKeyID:           keyID,
		VerificationPublicKey: verificationKey,
		CreatedAt:             now,
		MaxActivePerAccount:   s.cfg.Auth.WalletSessions.MaxActiveSessionsPerAccount,
		MaxActivePerWallet:    s.cfg.Auth.WalletSessions.MaxActiveSessionsPerWallet,
	})
	if err != nil {
		s.writeWalletSessionStoreError(w, err)
		return
	}
	s.recordWalletSessionAudit(r.Context(), validation.AccountID, session.SessionID, "wallet_session_created", "account", map[string]any{
		"wallet_namespace":      session.WalletNamespace,
		"wallet_fingerprint":    session.WalletFingerprint,
		"expires_at_unix":       session.ExpiresAt.UTC().Unix(),
		"model_allowlist":       modelAllowlistFromJSON(session.ModelAllowlistJSON),
		"total_token_cap":       session.TotalTokenCap,
		"per_request_token_cap": session.PerRequestTokenCap,
	})
	writeJSON(w, http.StatusCreated, map[string]any{
		"session_id":            session.SessionID,
		"session_bearer":        rawBearer,
		"expires_at_unix":       session.ExpiresAt.UTC().Unix(),
		"per_request_token_cap": session.PerRequestTokenCap,
		"total_token_cap":       session.TotalTokenCap,
		"model_allowlist":       modelAllowlistFromJSON(session.ModelAllowlistJSON),
	})
}

func (s *Server) handleWalletSessionList(w http.ResponseWriter, r *http.Request) {
	validation, ok := s.requireWalletSessionAccountBearer(w, r)
	if !ok {
		return
	}
	limit, ok := parseWalletSessionLimit(w, r)
	if !ok {
		return
	}
	sessions, err := s.readStore().ListWalletSessions(r.Context(), validation.AccountID)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_load_failed", "Could not load wallet sessions")
		return
	}
	page, nextCursor, ok := paginateWalletSessions(w, r, sessions, limit)
	if !ok {
		return
	}
	out := make([]map[string]any, 0, len(page))
	for _, session := range page {
		usage, err := s.readStore().WalletSessionUsage(r.Context(), validation.AccountID, session.SessionID)
		if err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_load_failed", "Could not load wallet sessions")
			return
		}
		out = append(out, sessionResponseWithUsage(session, usage))
	}
	response := map[string]any{"data": out, "has_more": nextCursor != ""}
	if nextCursor == "" {
		response["next_cursor"] = nil
	} else {
		response["next_cursor"] = nextCursor
	}
	writeJSON(w, http.StatusOK, response)
}

func (s *Server) handleWalletSessionItem(w http.ResponseWriter, r *http.Request) {
	s.setWalletSessionHeaders(w.Header())
	sessionID, usagePath, ok := walletSessionPathParts(r.URL.Path)
	if !ok {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
		return
	}
	if usagePath && r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !usagePath && r.Method != http.MethodGet && r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.requireEmptyWalletSessionBody(w, r) {
		return
	}
	if !s.requireWalletSessionEndpointCredentialUnambiguous(w, r) {
		return
	}
	accountID, walletAuth, ok := s.requireWalletSessionAccountOrSelf(w, r, sessionID, routeForWalletSessionItem(usagePath), nil)
	if !ok {
		return
	}
	switch {
	case usagePath:
		usage, err := s.readStore().WalletSessionUsage(r.Context(), accountID, sessionID)
		if err != nil {
			s.writeWalletSessionStoreError(w, err)
			return
		}
		response := map[string]any{"usage": walletSessionUsageResponse(usage)}
		if walletAuth == nil {
			limit, ok := parseWalletSessionUsageLimit(w, r)
			if !ok {
				return
			}
			since, until, ok := parseWalletSessionUsageRange(w, r, s.now().UTC())
			if !ok {
				return
			}
			details, nextCursor, err := s.readStore().ListWalletSessionUsageDetails(r.Context(), accountID, sessionID, limit, r.URL.Query().Get("cursor"), since, until)
			if err != nil {
				if errors.Is(err, storage.ErrBadCursor) {
					writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_cursor", "Invalid cursor")
					return
				}
				writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_load_failed", "Could not load wallet-session usage")
				return
			}
			data := make([]map[string]any, 0, len(details))
			for _, detail := range details {
				data = append(data, walletSessionUsageDetailResponse(detail))
			}
			response["since_unix"] = since.Unix()
			response["until_unix"] = until.Unix()
			response["data"] = data
			response["has_more"] = nextCursor != ""
			if nextCursor == "" {
				response["next_cursor"] = nil
			} else {
				response["next_cursor"] = nextCursor
			}
		}
		writeJSON(w, http.StatusOK, response)
	case r.Method == http.MethodGet:
		session, err := s.readStore().GetWalletSession(r.Context(), accountID, sessionID)
		if err != nil {
			s.writeWalletSessionStoreError(w, err)
			return
		}
		usage, err := s.readStore().WalletSessionUsage(r.Context(), accountID, sessionID)
		if err != nil {
			s.writeWalletSessionStoreError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"session": sessionResponseWithUsage(session, usage)})
	case r.Method == http.MethodDelete:
		actor := "account"
		if walletAuth != nil {
			actor = "session"
		}
		if err := s.store.RevokeWalletSession(r.Context(), accountID, sessionID, actor, "buyer_requested", s.now().UTC()); err != nil {
			s.writeWalletSessionStoreError(w, err)
			return
		}
		s.recordWalletSessionAudit(r.Context(), accountID, sessionID, "wallet_session_revoked", actor, map[string]any{"reason": "buyer_requested"})
		writeJSON(w, http.StatusOK, map[string]any{"session_id": sessionID, "status": "revoked"})
	}
}

func (s *Server) requireWalletSessionAccountOrSelf(w http.ResponseWriter, r *http.Request, sessionID, canonicalRoute string, rawBody []byte) (string, *walletSessionAuth, bool) {
	bearer := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer "))
	if strings.HasPrefix(bearer, walletSessionBearerPrefix) {
		walletAuth, ok := s.requireWalletSessionSignature(w, r, canonicalRoute, rawBody)
		if !ok {
			return "", nil, false
		}
		if walletAuth.Session.SessionID != sessionID {
			writeError(w, http.StatusForbidden, "permission_error", "wallet_session_scope_mismatch", "Wallet session scope mismatch")
			return "", nil, false
		}
		if !s.admitWalletSessionMetadata(w, r, walletAuth, canonicalRoute) {
			return "", nil, false
		}
		return walletAuth.Session.AccountID, walletAuth, true
	}
	validation, ok := s.requireWalletSessionAccountBearer(w, r)
	if !ok {
		return "", nil, false
	}
	session, err := s.readStore().GetWalletSession(r.Context(), validation.AccountID, sessionID)
	if err != nil {
		s.writeWalletSessionStoreError(w, err)
		return "", nil, false
	}
	return session.AccountID, nil, true
}

func (s *Server) requireWalletSessionAccountBearer(w http.ResponseWriter, r *http.Request) (storage.KeyValidation, bool) {
	if !s.requireWalletSessionEndpointCredentialUnambiguous(w, r) {
		return storage.KeyValidation{}, false
	}
	header := r.Header.Get("Authorization")
	bearer := ""
	if strings.HasPrefix(header, "Bearer ") {
		bearer = strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
	}
	if bearer == "" || strings.HasPrefix(bearer, walletSessionBearerPrefix) {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_account_auth_required", "Wallet-session management requires account API-key authentication")
		return storage.KeyValidation{}, false
	}
	return s.requireBearer(w, r)
}

func (s *Server) requireWalletSessionEndpointCredentialUnambiguous(w http.ResponseWriter, r *http.Request) bool {
	if walletSessionEndpointCredentialCount(r) <= 1 {
		return true
	}
	writeError(w, http.StatusBadRequest, "invalid_request_error", "ambiguous_credentials", "Multiple credential types are not allowed")
	return false
}

func walletSessionEndpointCredentialCount(r *http.Request) int {
	count := 0
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		count++
	}
	rawAuthHeader := r.Header.Get("Authorization")
	authHeader := strings.TrimSpace(rawAuthHeader)
	authBearer := ""
	if strings.HasPrefix(rawAuthHeader, "Bearer ") {
		authBearer = strings.TrimSpace(strings.TrimPrefix(rawAuthHeader, "Bearer "))
	}
	if authHeader != "" && (authBearer != "" || !strings.HasPrefix(rawAuthHeader, "Bearer ")) {
		count++
	}
	if strings.TrimSpace(r.Header.Get("X-Api-Key")) != "" {
		count++
	}
	return count
}

func (s *Server) requireWalletSessionBearer(w http.ResponseWriter, r *http.Request) (*walletSessionAuth, bool) {
	if !s.cfg.Auth.WalletSessions.Enabled {
		writeError(w, http.StatusNotFound, "invalid_request_error", "wallet_sessions_disabled", "Wallet sessions are disabled")
		return nil, false
	}
	header := r.Header.Get("Authorization")
	if !strings.HasPrefix(header, "Bearer ") {
		writeError(w, http.StatusUnauthorized, "authentication_error", "missing_bearer_token", "Missing bearer token")
		return nil, false
	}
	bearer := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
	if !strings.HasPrefix(bearer, walletSessionBearerPrefix) {
		writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_wallet_session", "Invalid wallet session")
		return nil, false
	}
	for _, hash := range s.walletSessionBearerHashes(bearer) {
		session, err := s.store.LookupWalletSessionByBearerHash(r.Context(), hash)
		if err == nil {
			if session.Status == "revoked" {
				writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_revoked", "Wallet session revoked")
				return nil, false
			}
			if !s.now().UTC().Before(session.ExpiresAt) {
				s.recordWalletSessionAudit(r.Context(), session.AccountID, session.SessionID, "wallet_session_expired", "gateway", map[string]any{
					"route":      walletCanonicalRouteForRequest(r),
					"expires_at": session.ExpiresAt.UTC().Format(time.RFC3339),
				})
				writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_expired", "Wallet session expired")
				return nil, false
			}
			if session.Status != "active" {
				writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_wallet_session", "Invalid wallet session")
				return nil, false
			}
			return &walletSessionAuth{Session: session, Bearer: bearer}, true
		}
		if !errors.Is(err, storage.ErrNotFound) {
			writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_lookup_failed", "Could not validate wallet session")
			return nil, false
		}
	}
	writeError(w, http.StatusUnauthorized, "authentication_error", "invalid_wallet_session", "Invalid wallet session")
	return nil, false
}

func (s *Server) requireWalletSessionSignature(w http.ResponseWriter, r *http.Request, canonicalRoute string, rawBody []byte) (*walletSessionAuth, bool) {
	sessionAuth, ok := s.requireWalletSessionBearer(w, r)
	if !ok {
		return nil, false
	}
	if requestIDClass(r) != retry503RequestIDClassClientSupplied || !auth.ValidateUUIDv4RequestID(requestID(r)) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_request_id_required", "Wallet sessions require a client-supplied UUIDv4 X-Request-ID")
		return nil, false
	}
	if r.URL.RawQuery != "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_query_forbidden", "Wallet-session signed routes do not accept query strings")
		return nil, false
	}
	ts, err := strconv.ParseInt(strings.TrimSpace(r.Header.Get("X-MacProvider-Session-Timestamp")), 10, 64)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_stale", "Wallet-session timestamp is invalid")
		return nil, false
	}
	signature := strings.TrimSpace(r.Header.Get("X-MacProvider-Session-Signature"))
	if signature == "" {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_invalid", "Wallet-session signature is invalid")
		return nil, false
	}
	obj, err := auth.NewWalletRequestSignatureObject(sessionAuth.Session.SessionID, r.Method, canonicalRoute, requestID(r), rawBody, r.Header, ts)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_invalid", "Wallet-session signature is invalid")
		return nil, false
	}
	if err := auth.VerifyWalletRequestSignature(obj, signature, sessionAuth.Session.SessionPublicKey, s.now().UTC(),
		time.Duration(s.cfg.Auth.WalletSessions.SignatureMaxAgeSeconds)*time.Second,
		time.Duration(s.cfg.Auth.WalletSessions.SignatureMaxFutureSkewSeconds)*time.Second); err != nil {
		if errors.Is(err, auth.ErrWalletSignatureStale) {
			writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_stale", "Wallet-session signature is stale")
			return nil, false
		}
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_invalid", "Wallet-session signature is invalid")
		return nil, false
	}
	return sessionAuth, true
}

func (s *Server) admitWalletSessionMetadata(w http.ResponseWriter, r *http.Request, sessionAuth *walletSessionAuth, canonicalRoute string) bool {
	bodyHash := sha256.Sum256(nil)
	headersHash, err := auth.SemanticHeadersSHA256Base64URL(canonicalRoute, r.Header)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_invalid", "Wallet-session signature is invalid")
		return false
	}
	headersHashBytes, _ := auth.DecodeBase64URLFixed(headersHash, sha256.Size)
	windowStart := s.now().UTC().Add(-time.Minute)
	err = s.store.AdmitWalletSessionMetadata(r.Context(), storage.WalletSessionMetadataAdmissionRequest{
		SessionID: sessionAuth.Session.SessionID,
		AccountID: sessionAuth.Session.AccountID,
		Replay: storage.WalletSessionReplayMaterial{
			SessionID: sessionAuth.Session.SessionID, RequestID: requestID(r), Method: r.Method,
			CanonicalRoute: canonicalRoute, SemanticHeadersHash: headersHashBytes, RawBodyHash: bodyHash[:],
			BodyBytes: 0, MetadataClientIP: s.clientIP(r),
		},
		WindowStart: windowStart, RateLimit: s.cfg.Auth.WalletSessions.MetadataRequestsPerMinute,
		MaxReplayRows:  s.cfg.Auth.WalletSessions.ReplayMaxRowsPerSession,
		MaxReplayBytes: s.cfg.Auth.WalletSessions.ReplayMaxBytesPerSession,
		CreatedAt:      s.now().UTC(),
	})
	if err == nil {
		return true
	}
	s.recordWalletSessionAudit(r.Context(), sessionAuth.Session.AccountID, sessionAuth.Session.SessionID, "wallet_session_rejected", "gateway", map[string]any{
		"request_id":      requestID(r),
		"canonical_route": canonicalRoute,
		"reason":          walletSessionAdmissionAuditReason(err),
	})
	s.writeWalletAdmissionError(w, err, storage.WalletSessionAdmissionDecision{})
	return false
}

func (s *Server) admitWalletSessionInference(r *http.Request, sessionAuth *walletSessionAuth, rawBody []byte, model string, reservationTokens, dailyQuota int64, window string, expiresAt time.Time) (storage.WalletSessionAdmissionDecision, error) {
	bodyHash := sha256.Sum256(rawBody)
	headersHash, err := auth.SemanticHeadersSHA256Base64URL(walletCanonicalRouteForRequest(r), r.Header)
	if err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	headersHashBytes, err := auth.DecodeBase64URLFixed(headersHash, sha256.Size)
	if err != nil {
		return storage.WalletSessionAdmissionDecision{}, err
	}
	return s.store.AdmitWalletSessionInference(r.Context(), storage.WalletSessionAdmissionRequest{
		SessionID: sessionAuth.Session.SessionID, AccountID: sessionAuth.Session.AccountID,
		RequestID: requestID(r), Method: r.Method, CanonicalRoute: walletCanonicalRouteForRequest(r),
		ModelID: model, WindowDate: window, RequestedTokens: reservationTokens, DailyQuota: dailyQuota,
		Replay: storage.WalletSessionReplayMaterial{
			SessionID: sessionAuth.Session.SessionID, RequestID: requestID(r), Method: r.Method,
			CanonicalRoute: walletCanonicalRouteForRequest(r), SemanticHeadersHash: headersHashBytes,
			RawBodyHash: bodyHash[:], BodyBytes: int64(len(rawBody)),
		},
		CreatedAt: s.now().UTC(), ExpiresAt: expiresAt.UTC(),
	})
}

func (s *Server) refundWalletAwareReservation(subject usageSubject, reqID string) error {
	if subject.WalletSessionID != "" {
		return s.store.RefundWalletSessionReservation(context.Background(), subject.AccountID, subject.WalletSessionID, reqID, s.now().UTC())
	}
	return s.store.RefundReservation(context.Background(), subject.AccountID, reqID, s.now().Unix())
}

func (s *Server) holdWalletAwareReservation(ctx context.Context, subject usageSubject, reqID string) error {
	if subject.WalletSessionID != "" {
		return s.store.HoldWalletSessionReservation(ctx, subject.AccountID, subject.WalletSessionID, reqID, s.now().UTC())
	}
	return s.store.MarkReservationSettlementHold(ctx, subject.AccountID, reqID)
}

func (s *Server) sealWalletSessionUsageEvent(subject usageSubject, reqID string, settledTokens int64) error {
	if subject.WalletSessionID == "" {
		return nil
	}
	return s.store.SealWalletSessionUsageEvent(context.Background(), subject.AccountID, subject.WalletSessionID, reqID, settledTokens, s.now().UTC())
}

func (s *Server) requireEmptyWalletSessionBody(w http.ResponseWriter, r *http.Request) bool {
	if r.Body == nil || r.Body == http.NoBody {
		return true
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return false
	}
	if len(body) > 0 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_body_forbidden", "Wallet-session metadata routes do not accept request bodies")
		return false
	}
	return true
}

func walletCanonicalRouteForRequest(r *http.Request) string {
	if responsesAdapterFromContext(r.Context()) != nil {
		return "/v1/responses"
	}
	if anthropicMessagesAdapterFromContext(r.Context()) != nil {
		return "/v1/messages"
	}
	return r.URL.Path
}

func (s *Server) setWalletSessionHeaders(h http.Header) {
	setNoStoreHeaders(h)
	h.Add("Vary", "Authorization")
	h.Add("Vary", "X-Api-Key")
}

func (s *Server) readWalletSessionBody(w http.ResponseWriter, r *http.Request, limit int64) ([]byte, bool) {
	body, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return nil, false
	}
	if int64(len(body)) > limit {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
		return nil, false
	}
	return body, true
}

func (s *Server) walletSessionBearerHashForKey(bearer, keyID string) ([]byte, bool) {
	secret, ok := s.cfg.Auth.WalletSessions.BearerHashKeys[keyID]
	if !ok || secret == "" {
		return nil, false
	}
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(bearer))
	return mac.Sum(nil), true
}

func (s *Server) walletSessionBearerHashes(bearer string) [][]byte {
	ids := []string{s.cfg.Auth.WalletSessions.CurrentBearerHashKeyID}
	ids = append(ids, s.cfg.Auth.WalletSessions.PreviousBearerHashKeyIDs...)
	ids = append(ids, s.cfg.Auth.WalletSessions.RetiringBearerHashKeyIDs...)
	seen := map[string]struct{}{}
	hashes := make([][]byte, 0, len(ids))
	for _, id := range ids {
		if _, ok := seen[id]; ok {
			continue
		}
		seen[id] = struct{}{}
		if hash, ok := s.walletSessionBearerHashForKey(bearer, id); ok {
			hashes = append(hashes, hash)
		}
	}
	return hashes
}

func normalizeWalletModelAllowlist(models []string) []string {
	seen := map[string]struct{}{}
	for _, model := range models {
		model = strings.TrimSpace(model)
		if model == "" {
			continue
		}
		seen[model] = struct{}{}
	}
	out := make([]string, 0, len(seen))
	for model := range seen {
		out = append(out, model)
	}
	sort.Strings(out)
	return out
}

func (s *Server) canonicalWalletModelAllowlist(ctx context.Context, models []string) ([]string, bool, error) {
	normalized := normalizeWalletModelAllowlist(models)
	if len(normalized) == 0 {
		return nil, false, nil
	}
	status, err := s.statusFromPoolz(ctx)
	if err != nil {
		return nil, false, err
	}
	catalog := map[string]struct{}{}
	for _, model := range status.Models {
		catalog[model.ID] = struct{}{}
	}
	for _, model := range normalized {
		if _, ok := catalog[model]; !ok {
			return nil, false, nil
		}
	}
	return normalized, true, nil
}

func (s *Server) reserveWalletSessionIssuance(w http.ResponseWriter, r *http.Request, surface, key string, limit int, now time.Time) bool {
	err := s.store.ReservePublicIssuance(r.Context(), storage.PublicIssuanceReservation{
		Surface:     surface,
		ClientIP:    key,
		WindowStart: now.Add(-time.Hour),
		Limit:       limit,
		CreatedAt:   now,
	})
	if err == nil {
		return true
	}
	if errors.Is(err, storage.ErrRateLimit) {
		setConcurrencyRateLimitHeaders(w, limit, 0, 3600, now)
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "wallet_session_rate_limited", "Wallet-session rate limit exceeded")
		return false
	}
	writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_issuance_failed", "Could not reserve wallet-session issuance")
	return false
}

func (s *Server) recordWalletSessionAudit(ctx context.Context, accountID, sessionID, eventType, actor string, payload map[string]any) {
	if payload == nil {
		payload = map[string]any{}
	}
	if sessionID != "" {
		payload["session_id"] = sessionID
	}
	rawPayload, err := json.Marshal(payload)
	if err != nil {
		rawPayload = []byte(`{"payload_error":"marshal_failed"}`)
	}
	eventID, err := auth.RandomID("aud")
	if err != nil {
		return
	}
	if actor == "" {
		actor = "gateway"
	}
	_ = s.store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID:   eventID,
		AccountID: accountID,
		Actor:     actor,
		Type:      eventType,
		Payload:   string(rawPayload),
		CreatedAt: s.now().UTC(),
	})
}

func walletSessionAdmissionAuditReason(err error) string {
	switch {
	case errors.Is(err, storage.ErrWalletSessionReplayMismatch):
		return "replay_mismatch"
	case errors.Is(err, storage.ErrWalletSessionReplayDuplicate):
		return "duplicate_request"
	case errors.Is(err, storage.ErrWalletSessionReplayCapacity):
		return "replay_capacity"
	case errors.Is(err, storage.ErrWalletSessionPerRequestCap):
		return "per_request_cap"
	case errors.Is(err, storage.ErrWalletSessionCapExceeded):
		return "session_cap"
	case errors.Is(err, storage.ErrWalletSessionModelDenied):
		return "model_denied"
	case errors.Is(err, storage.ErrRateLimit):
		return "rate_limited"
	default:
		return "admission_failed"
	}
}

func walletModelAllowlist(session storage.WalletSession) map[string]struct{} {
	var models []string
	_ = json.Unmarshal([]byte(session.ModelAllowlistJSON), &models)
	allow := map[string]struct{}{}
	for _, model := range models {
		allow[model] = struct{}{}
	}
	return allow
}

func filterModelsForWalletSession(body map[string]any, allow map[string]struct{}) {
	known := knownWalletModelIDs(body)
	for key, value := range body {
		if walletModelKeyDisallowed(key, "", allow, known) {
			delete(body, key)
			continue
		}
		if filtered, keep := filterWalletModelValue(key, value, allow, known); keep {
			body[key] = filtered
		} else {
			delete(body, key)
		}
	}
}

func filterWalletModelValue(field string, value any, allow, known map[string]struct{}) (any, bool) {
	switch typed := value.(type) {
	case []any:
		return filterWalletModelSlice(field, typed, allow, known), true
	case map[string]any:
		if !walletModelMapAllowed(typed, allow) {
			return nil, false
		}
		for key, child := range typed {
			if walletModelKeyDisallowed(key, field, allow, known) {
				delete(typed, key)
				continue
			}
			if filtered, keep := filterWalletModelValue(key, child, allow, known); keep {
				typed[key] = filtered
			} else {
				delete(typed, key)
			}
		}
		return typed, true
	case string:
		if walletModelField(field) || walletModelListField(field) || walletModelKnown(typed, known) {
			if _, ok := allow[typed]; !ok {
				return nil, false
			}
		}
		return typed, true
	default:
		return value, true
	}
}

func filterWalletModelSlice(field string, values []any, allow, known map[string]struct{}) []any {
	out := make([]any, 0, len(values))
	for _, value := range values {
		if filtered, keep := filterWalletModelValue(field, value, allow, known); keep {
			out = append(out, filtered)
		}
	}
	return out
}

func walletModelMapAllowed(value map[string]any, allow map[string]struct{}) bool {
	for _, key := range []string{"id", "model", "model_id"} {
		if model, ok := value[key].(string); ok && model != "" {
			_, allowed := allow[model]
			return allowed
		}
	}
	return true
}

func knownWalletModelIDs(body map[string]any) map[string]struct{} {
	known := map[string]struct{}{}
	collectKnownWalletModelIDs("", body, known)
	return known
}

func collectKnownWalletModelIDs(field string, value any, known map[string]struct{}) {
	switch typed := value.(type) {
	case map[string]any:
		for key, child := range typed {
			if walletModelKeyContainer(field) && walletModelIdentifierCandidate(key) {
				known[key] = struct{}{}
			}
			switch childTyped := child.(type) {
			case string:
				if (walletModelField(key) || walletModelListField(key)) && childTyped != "" {
					known[childTyped] = struct{}{}
				}
			case []any:
				if walletModelListField(key) {
					for _, item := range childTyped {
						if model, ok := item.(string); ok && model != "" {
							known[model] = struct{}{}
						}
					}
				}
			}
			collectKnownWalletModelIDs(key, child, known)
		}
	case []any:
		for _, child := range typed {
			collectKnownWalletModelIDs(field, child, known)
		}
	}
}

func walletModelKeyDisallowed(key, parentField string, allow, known map[string]struct{}) bool {
	if _, ok := allow[key]; ok {
		return false
	}
	if walletModelKnown(key, known) {
		return true
	}
	return walletModelKeyContainer(parentField) && walletModelIdentifierCandidate(key)
}

func walletModelKnown(model string, known map[string]struct{}) bool {
	_, ok := known[model]
	return ok
}

func walletModelField(key string) bool {
	switch strings.ToLower(key) {
	case "id", "model", "model_id", "default_model", "fallback", "recommended", "alias", "alias_of", "routing_target", "target_model", "active_model":
		return true
	default:
		return false
	}
}

func walletModelListField(key string) bool {
	switch strings.ToLower(key) {
	case "models", "model_ids", "supported_models", "allowed_models", "available_models", "model_allowlist":
		return true
	default:
		return false
	}
}

func walletModelKeyContainer(key string) bool {
	switch strings.ToLower(key) {
	case "catalog", "model_catalog", "models_by_id", "by_model", "metadata", "model_metadata", "model_disclosures", "routing":
		return true
	default:
		return false
	}
}

func walletModelIdentifierCandidate(value string) bool {
	value = strings.TrimSpace(value)
	if value == "" {
		return false
	}
	if strings.HasPrefix(value, "model-") || strings.HasPrefix(value, "gpt-") || strings.HasPrefix(value, "claude-") {
		return true
	}
	return strings.ContainsAny(value, "/:-")
}

func safeAuditError(err error) string {
	if err == nil {
		return ""
	}
	msg := err.Error()
	if len(msg) > 160 {
		return msg[:160]
	}
	return msg
}

func sessionResponse(session storage.WalletSession) map[string]any {
	return map[string]any{
		"session_id":            session.SessionID,
		"account_id":            session.AccountID,
		"wallet_namespace":      session.WalletNamespace,
		"wallet_fingerprint":    session.WalletFingerprint,
		"status":                session.Status,
		"expires_at":            session.ExpiresAt.UTC().Format(time.RFC3339),
		"total_token_cap":       session.TotalTokenCap,
		"per_request_token_cap": session.PerRequestTokenCap,
		"model_allowlist":       modelAllowlistFromJSON(session.ModelAllowlistJSON),
		"created_at":            session.CreatedAt.UTC().Format(time.RFC3339),
		"revoked_at":            optionalTimeRFC3339(session.RevokedAt),
		"revoked_by":            session.RevokedBy,
		"revoked_reason":        session.RevokedReason,
	}
}

func sessionResponseWithUsage(session storage.WalletSession, usage storage.WalletSessionUsage) map[string]any {
	out := sessionResponse(session)
	out["remaining_tokens"] = usage.RemainingTokens
	out["usage"] = walletSessionUsageResponse(usage)
	return out
}

func walletSessionUsageResponse(usage storage.WalletSessionUsage) map[string]any {
	return map[string]any{
		"session_id": usage.SessionID, "account_id": usage.AccountID,
		"total_token_cap": usage.TotalCap, "per_request_token_cap": usage.PerRequestCap,
		"settled_tokens": usage.SettledTokens, "reserved_tokens": usage.ReservedTokens,
		"held_tokens": usage.HeldTokens, "remaining_tokens": usage.RemainingTokens,
		"request_count": usage.RequestCount,
	}
}

func walletSessionUsageDetailResponse(detail storage.WalletSessionUsageDetail) map[string]any {
	out := map[string]any{
		"request_id":             detail.RequestID,
		"quota_reservation_id":   detail.QuotaReservationID,
		"session_reservation_id": detail.SessionReservationID,
		"model":                  detail.ModelID,
		"reserved_tokens":        detail.ReservedTokens,
		"settled_tokens":         detail.SettledTokens,
		"prompt_tokens":          detail.PromptTokens,
		"completion_tokens":      detail.CompletionTokens,
		"total_tokens":           detail.TotalTokens,
		"token_source":           detail.TokenSource,
		"outcome":                detail.Outcome,
		"terminal_status":        detail.TerminalStatus,
		"reconciliation_status":  detail.ReconciliationStatus,
		"reservation_created_at": optionalTimeRFC3339(detail.ReservationCreatedAt),
		"reservation_settled_at": optionalTimeRFC3339(detail.ReservationSettledAt),
		"usage_event_created_at": optionalTimeRFC3339(detail.UsageEventCreatedAt),
	}
	if detail.UsageEventID != "" {
		out["usage_event_id"] = detail.UsageEventID
	}
	return out
}

func parseWalletSessionUsageLimit(w http.ResponseWriter, r *http.Request) (int, bool) {
	raw := strings.TrimSpace(r.URL.Query().Get("limit"))
	if raw == "" {
		return 50, true
	}
	limit, err := strconv.Atoi(raw)
	if err != nil || limit <= 0 || limit > 100 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_limit", "Invalid limit")
		return 0, false
	}
	return limit, true
}

func parseWalletSessionLimit(w http.ResponseWriter, r *http.Request) (int, bool) {
	return parseWalletSessionUsageLimit(w, r)
}

func paginateWalletSessions(w http.ResponseWriter, r *http.Request, sessions []storage.WalletSession, limit int) ([]storage.WalletSession, string, bool) {
	cursor := strings.TrimSpace(r.URL.Query().Get("cursor"))
	start := 0
	if cursor != "" {
		start = -1
		for i, session := range sessions {
			if session.SessionID == cursor {
				start = i + 1
				break
			}
		}
		if start < 0 {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_cursor", "Invalid cursor")
			return nil, "", false
		}
	}
	if start >= len(sessions) {
		return []storage.WalletSession{}, "", true
	}
	end := start + limit
	if end >= len(sessions) {
		return sessions[start:], "", true
	}
	return sessions[start:end], sessions[end-1].SessionID, true
}

func parseWalletSessionUsageRange(w http.ResponseWriter, r *http.Request, now time.Time) (time.Time, time.Time, bool) {
	until := now.UTC()
	since := until.Add(-30 * 24 * time.Hour)
	if raw := strings.TrimSpace(r.URL.Query().Get("since_unix")); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request", "Invalid usage time range")
			return time.Time{}, time.Time{}, false
		}
		since = time.Unix(parsed, 0).UTC()
	}
	if raw := strings.TrimSpace(r.URL.Query().Get("until_unix")); raw != "" {
		parsed, err := strconv.ParseInt(raw, 10, 64)
		if err != nil || parsed < 0 {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request", "Invalid usage time range")
			return time.Time{}, time.Time{}, false
		}
		until = time.Unix(parsed, 0).UTC()
	}
	if !since.Before(until) || until.Sub(since) > 90*24*time.Hour {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request", "Invalid usage time range")
		return time.Time{}, time.Time{}, false
	}
	return since, until, true
}

func modelAllowlistFromJSON(raw string) []string {
	var models []string
	_ = json.Unmarshal([]byte(raw), &models)
	return models
}

func optionalTimeRFC3339(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t.UTC().Format(time.RFC3339)
}

func walletSessionPathParts(path string) (sessionID string, usage bool, ok bool) {
	rest := strings.TrimPrefix(path, "/auth/wallet-sessions/")
	if rest == path || rest == "" {
		return "", false, false
	}
	if strings.HasSuffix(rest, "/usage") {
		sessionID = strings.TrimSuffix(rest, "/usage")
		return sessionID, sessionID != "" && safeID(sessionID), sessionID != "" && safeID(sessionID)
	}
	return rest, false, safeID(rest)
}

func routeForWalletSessionItem(usage bool) string {
	if usage {
		return walletSessionUsageRoute
	}
	return walletSessionRoute
}

func (s *Server) writeWalletSessionDecodeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, auth.ErrWalletAlgorithmUnsupported):
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_algorithm_unsupported", "Wallet algorithm unsupported")
	case errors.Is(err, auth.ErrWalletSignatureInvalid):
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_signature_invalid", "Wallet signature invalid")
	case errors.Is(err, auth.ErrWalletSignatureStale):
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_stale", "Wallet-session signature is stale")
	default:
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_canonical_invalid", "Wallet-session request is invalid")
	}
}

func (s *Server) writeWalletSessionStoreError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, storage.ErrNotFound):
		writeError(w, http.StatusNotFound, "invalid_request_error", "wallet_session_not_found", "Wallet session not found")
	case errors.Is(err, storage.ErrWalletChallengeConsumed):
		writeError(w, http.StatusConflict, "invalid_request_error", "wallet_challenge_consumed", "Wallet-session challenge already consumed")
	case errors.Is(err, storage.ErrWalletChallengeExpired):
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_challenge_expired", "Wallet-session challenge expired")
	case errors.Is(err, storage.ErrWalletChallengeMismatch):
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_signature_invalid", "Wallet signature invalid")
	case errors.Is(err, storage.ErrWalletIdentityConflict):
		writeError(w, http.StatusForbidden, "permission_error", "wallet_identity_conflict", "Wallet identity cannot be used with this account")
	case errors.Is(err, storage.ErrWalletSessionActiveCap):
		writeError(w, http.StatusConflict, "invalid_request_error", "wallet_session_active_cap_exceeded", "Wallet-session active cap exceeded")
	case errors.Is(err, storage.ErrWalletSessionCapExceeded):
		writeError(w, http.StatusPaymentRequired, "billing_error", "wallet_session_exhausted", "Wallet-session cap exceeded")
	default:
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_store_failed", "Wallet-session store failed")
	}
}

func (s *Server) writeWalletAdmissionError(w http.ResponseWriter, err error, decision storage.WalletSessionAdmissionDecision) {
	switch {
	case errors.Is(err, storage.ErrWalletSessionReplayMismatch):
		writeError(w, http.StatusConflict, "invalid_request_error", "wallet_session_replay_mismatch", "Wallet-session replay material mismatch")
	case errors.Is(err, storage.ErrWalletSessionReplayDuplicate):
		writeError(w, http.StatusConflict, "invalid_request_error", "wallet_session_duplicate_request", "Wallet-session duplicate request")
	case errors.Is(err, storage.ErrWalletSessionReplayCapacity):
		writeError(w, http.StatusConflict, "invalid_request_error", "wallet_session_replay_capacity_exhausted", "Wallet-session replay capacity exhausted")
	case errors.Is(err, storage.ErrWalletSessionInactive):
		writeError(w, http.StatusForbidden, "permission_error", "wallet_session_inactive", "Wallet session inactive")
	case errors.Is(err, storage.ErrWalletSessionModelDenied):
		writeError(w, http.StatusForbidden, "permission_error", "wallet_session_model_not_allowed", "Wallet session does not allow this model")
	case errors.Is(err, storage.ErrWalletSessionPerRequestCap):
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_request_cap_exceeded", "Wallet-session per-request cap exceeded")
	case errors.Is(err, storage.ErrWalletSessionCapExceeded):
		writeError(w, http.StatusPaymentRequired, "billing_error", "wallet_session_exhausted", "Wallet-session total cap exceeded")
	case errors.Is(err, storage.ErrQuotaExceeded):
		setRateLimitHeaders(w, decision.AccountQuota.LimitTokens, decision.AccountQuota.RemainingTokens, decision.AccountQuota.ResetUnix)
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
	case errors.Is(err, storage.ErrRateLimit):
		setConcurrencyRateLimitHeaders(w, s.cfg.Auth.WalletSessions.MetadataRequestsPerMinute, 0, 60, s.now().UTC())
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "wallet_session_rate_limited", "Wallet-session rate limit exceeded")
	default:
		writeError(w, http.StatusInternalServerError, "server_error", "wallet_session_admission_failed", "Wallet-session admission failed")
	}
}

func decodeBase64URLHash(value string) []byte {
	decoded, err := base64.RawURLEncoding.DecodeString(value)
	if err != nil {
		return nil
	}
	return decoded
}
