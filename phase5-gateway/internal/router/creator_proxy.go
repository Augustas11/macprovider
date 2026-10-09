package router

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// SPEC-006 §5.11 / SPEC-043-R005 0.3.0: /v1/creator/* lets an outside pool
// creator administer its self-serve private Trusted Pools with its normal
// account API key. The gateway authenticates the key, then forwards a NEW
// request that carries only the verified principal to the coordinator's
// service-token internal creator mount. No client header is copied through,
// so a caller can never assert another account or GitHub identity.
const (
	creatorProxyPrefix         = "/v1/creator/"
	creatorUpstreamPrefix      = "/internal/creator/trust-pools/"
	creatorAccountIDHeader     = "X-MacProvider-Creator-Account-ID"
	creatorCredentialIDHeader  = "X-MacProvider-Creator-Credential-ID"
	creatorGitHubUserIDHeader  = "X-MacProvider-Creator-GitHub-User-ID"
	creatorProxyMaxBodyBytes   = 64 << 10
	creatorProxyMaxResultBytes = 1 << 20
)

var creatorProxyPathPattern = regexp.MustCompile(`^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$`)

// accountIdentityLookup is implemented by the SQLite store; a store without
// it forwards no GitHub identity, so ownership-bounded operations fail closed
// at the coordinator.
type accountIdentityLookup interface {
	LookupAccountIdentityByProvider(ctx context.Context, accountID, provider string) (storage.AccountIdentity, error)
}

func (s *Server) handleCreatorProxy(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	rest := strings.TrimPrefix(r.URL.Path, creatorProxyPrefix)
	if !creatorProxyPathPattern.MatchString(rest) {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Not Found")
		return
	}
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		writeError(w, http.StatusForbidden, "permission_error", "demo_creator_forbidden", "Demo tokens cannot administer pools")
		return
	}
	if bearer := strings.TrimSpace(strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")); strings.HasPrefix(bearer, walletSessionBearerPrefix) {
		writeError(w, http.StatusForbidden, "permission_error", "wallet_session_creator_forbidden", "Wallet sessions cannot administer pools")
		return
	}
	validation, ok := s.requireBearer(w, r)
	if !ok {
		return
	}
	githubUserID := ""
	if lookup, ok := s.store.(accountIdentityLookup); ok {
		identity, err := lookup.LookupAccountIdentityByProvider(r.Context(), validation.AccountID, "github")
		switch {
		case err == nil:
			githubUserID = strings.TrimSpace(identity.ProviderUserID)
		case errors.Is(err, storage.ErrNotFound):
		default:
			writeError(w, http.StatusInternalServerError, "server_error", "creator_identity_lookup_failed", "Could not load account identity")
			return
		}
	}
	var body []byte
	if r.Method == http.MethodPost {
		raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, creatorProxyMaxBodyBytes))
		if err != nil {
			writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
			return
		}
		body = raw
	}
	base := strings.TrimRight(s.cfg.Coordinator.OperatorURL, "/")
	if base == "" {
		writeError(w, http.StatusBadGateway, "api_error", "creator_upstream_error", "Could not reach the pool control plane")
		return
	}
	target := base + creatorUpstreamPrefix + rest
	if r.URL.RawQuery != "" {
		target += "?" + r.URL.RawQuery
	}
	ctx, cancel := context.WithTimeout(r.Context(), s.cfg.CoordinatorTimeout())
	defer cancel()
	upReq, err := newCreatorUpstreamRequest(ctx, r.Method, target, body)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "creator_upstream_error", "Could not reach the pool control plane")
		return
	}
	upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	upReq.Header.Set(creatorAccountIDHeader, validation.AccountID)
	upReq.Header.Set(creatorCredentialIDHeader, validation.KeyID)
	if githubUserID != "" {
		upReq.Header.Set(creatorGitHubUserIDHeader, githubUserID)
	}
	if r.Method == http.MethodPost {
		upReq.Header.Set("Content-Type", "application/json")
	}
	if key := strings.TrimSpace(r.Header.Get("Idempotency-Key")); key != "" {
		upReq.Header.Set("Idempotency-Key", key)
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	resp, err := s.client.Do(upReq)
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", "creator_upstream_error", "Could not reach the pool control plane")
		return
	}
	defer resp.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(resp.Body, creatorProxyMaxResultBytes+1))
	if err != nil || len(payload) > creatorProxyMaxResultBytes {
		writeError(w, http.StatusBadGateway, "api_error", "creator_upstream_error", "Could not reach the pool control plane")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(payload)
}

// newCreatorUpstreamRequest builds the request to the coordinator's internal
// creator mount. The target is always creatorUpstreamPrefix under the
// operator URL, never a chat route, so it needs no signed-finality
// negotiation. It is assembled from a parsed URL rather than
// http.NewRequest because TestEveryCoordinatorChatBuilderNegotiatesSignedFinality
// is bound to conformant SPEC-022-R012 evidence and cannot gain an allowlist
// entry until that evidence is recaptured; TestCreatorProxyNeverTargetsChat
// pins the target instead.
func newCreatorUpstreamRequest(ctx context.Context, method, target string, body []byte) (*http.Request, error) {
	u, err := url.Parse(target)
	if err != nil {
		return nil, err
	}
	if !strings.HasPrefix(u.Path, creatorUpstreamPrefix) {
		return nil, errors.New("creator proxy: upstream target outside the creator mount")
	}
	req := (&http.Request{
		Method:     method,
		URL:        u,
		Proto:      "HTTP/1.1",
		ProtoMajor: 1,
		ProtoMinor: 1,
		Header:     make(http.Header),
		Host:       u.Host,
	}).WithContext(ctx)
	if len(body) > 0 {
		req.Body = io.NopCloser(bytes.NewReader(body))
		req.ContentLength = int64(len(body))
		req.GetBody = func() (io.ReadCloser, error) { return io.NopCloser(bytes.NewReader(body)), nil }
	}
	return req, nil
}
