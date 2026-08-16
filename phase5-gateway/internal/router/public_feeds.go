package router

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// Public unauthenticated buyer-host feeds (issue #1004). These are
// already served on coordinator.malibu.tech / stats.malibu.tech; the
// buyer API host must mount the same GET paths so SDKs using
// base_url=https://api.malibu.tech/v1 can read prices and pool snapshot.
const (
	publicUpstreamMaxBytes = 1 << 20
	publicUpstreamTimeout  = 10 * time.Second
	publicStatsCacheTTL    = 30 * time.Second
	publicRateCardCacheTTL = 5 * time.Minute
)

var errInvalidPublicUpstream = errors.New("invalid public upstream")

var publicUpstreamHeaderAllowlist = []string{
	"Content-Type",
	"Cache-Control",
	"ETag",
	"Last-Modified",
	"Expires",
	"Retry-After",
	"Allow",
	"Vary",
	"X-Stats-Generated-At",
}

var publicUpstreamAllowedHeaders = func() map[string]bool {
	allowed := make(map[string]bool, len(publicUpstreamHeaderAllowlist))
	for _, name := range publicUpstreamHeaderAllowlist {
		allowed[http.CanonicalHeaderKey(name)] = true
	}
	return allowed
}()

type publicFeedCacheEntry struct {
	expiresAt time.Time
	status    int
	header    http.Header
	body      []byte
}

func isPublicFeedPath(path string) bool {
	switch path {
	case "/v1/rate-card", "/v1/rate-card.sig", "/v1/stats/overview", "/v1/network-stats":
		return true
	default:
		return false
	}
}

func publicFeedCacheTTL(upstreamPath string) time.Duration {
	if upstreamPath == "/v1/stats/overview" {
		return publicStatsCacheTTL
	}
	return publicRateCardCacheTTL
}

func (s *Server) handlePublicRateCard(w http.ResponseWriter, r *http.Request) {
	s.proxyPublicUpstream(w, r, s.coordinatorBuyerURL(), "/v1/rate-card", "coordinator_rate_card_error", "Coordinator rate-card error")
}

func (s *Server) handlePublicRateCardSig(w http.ResponseWriter, r *http.Request) {
	s.proxyPublicUpstream(w, r, s.coordinatorBuyerURL(), "/v1/rate-card.sig", "coordinator_rate_card_error", "Coordinator rate-card error")
}

func (s *Server) handlePublicStatsOverview(w http.ResponseWriter, r *http.Request) {
	s.proxyPublicUpstream(w, r, s.coordinatorOperatorURL(), "/v1/stats/overview", "coordinator_stats_error", "Coordinator stats error")
}

func (s *Server) proxyPublicUpstream(w http.ResponseWriter, r *http.Request, baseURL, upstreamPath, errorCode, errorMessage string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if cached, ok := s.lookupPublicFeed(upstreamPath); ok {
		writePublicFeed(w, r.Method, cached.status, cached.header, cached.body)
		return
	}
	target, err := publicUpstreamURL(baseURL, upstreamPath)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), publicUpstreamTimeout)
	defer cancel()
	upReq, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	upReq.Header.Set("X-Request-ID", requestID(r))
	if accept := strings.TrimSpace(r.Header.Get("Accept")); accept != "" {
		upReq.Header.Set("Accept", accept)
	}
	if match := strings.TrimSpace(r.Header.Get("If-None-Match")); match != "" {
		upReq.Header.Set("If-None-Match", match)
	}
	if ip := s.clientIP(r); ip != "" {
		upReq.Header.Set("X-Real-IP", ip)
		upReq.Header.Set("X-Forwarded-For", ip)
	}
	resp, err := s.doPublicUpstream(upReq)
	if err != nil {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()
	if isDisallowedPublicUpstreamStatus(resp.StatusCode) {
		writeError(w, http.StatusBadGateway, "api_error", errorCode, errorMessage)
		return
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, publicUpstreamMaxBytes+1))
	if err != nil {
		writeError(w, http.StatusBadGateway, "api_error", errorCode, errorMessage)
		return
	}
	if int64(len(body)) > publicUpstreamMaxBytes {
		writeError(w, http.StatusBadGateway, "api_error", errorCode, errorMessage)
		return
	}
	if resp.StatusCode == http.StatusOK {
		s.storePublicFeed(upstreamPath, resp.StatusCode, resp.Header, body)
	}
	writePublicFeed(w, r.Method, resp.StatusCode, resp.Header, body)
}

func (s *Server) lookupPublicFeed(upstreamPath string) (publicFeedCacheEntry, bool) {
	if s == nil || s.publicFeedCache == nil {
		return publicFeedCacheEntry{}, false
	}
	now := time.Now().UTC()
	if s.now != nil {
		now = s.now()
	}
	s.mu.RLock()
	entry, ok := s.publicFeedCache[upstreamPath]
	s.mu.RUnlock()
	if !ok || entry.expiresAt.IsZero() || !now.Before(entry.expiresAt) {
		return publicFeedCacheEntry{}, false
	}
	return entry, true
}

func (s *Server) storePublicFeed(upstreamPath string, status int, header http.Header, body []byte) {
	if s == nil || s.publicFeedCache == nil {
		return
	}
	now := time.Now().UTC()
	if s.now != nil {
		now = s.now()
	}
	clonedBody := append([]byte(nil), body...)
	s.mu.Lock()
	s.publicFeedCache[upstreamPath] = publicFeedCacheEntry{
		expiresAt: now.Add(publicFeedCacheTTL(upstreamPath)),
		status:    status,
		header:    cloneHeader(header),
		body:      clonedBody,
	}
	s.mu.Unlock()
}

func writePublicFeed(w http.ResponseWriter, method string, status int, header http.Header, body []byte) {
	copyPublicUpstreamHeaders(w.Header(), header, status)
	w.WriteHeader(status)
	if method == http.MethodHead {
		return
	}
	_, _ = w.Write(body)
}

func (s *Server) doPublicUpstream(req *http.Request) (*http.Response, error) {
	client := s.client
	if client == nil {
		client = http.DefaultClient
	}
	noRedirect := *client
	noRedirect.CheckRedirect = func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}
	return noRedirect.Do(req)
}

func publicUpstreamURL(baseURL, path string) (string, error) {
	base, err := url.Parse(strings.TrimRight(strings.TrimSpace(baseURL), "/"))
	if err != nil {
		return "", err
	}
	if (base.Scheme != "http" && base.Scheme != "https") || base.Host == "" {
		return "", errInvalidPublicUpstream
	}
	resolved := base.JoinPath(path)
	resolved.RawQuery = ""
	resolved.Fragment = ""
	resolved.User = nil
	return resolved.String(), nil
}

func isDisallowedPublicUpstreamStatus(status int) bool {
	return status >= 300 && status < 400 && status != http.StatusNotModified
}

func copyPublicUpstreamHeaders(dst, src http.Header, status int) {
	for key, values := range src {
		canon := http.CanonicalHeaderKey(key)
		if !publicUpstreamAllowedHeaders[canon] {
			continue
		}
		if canon != "Vary" {
			dst.Del(canon)
		}
		for _, value := range values {
			if strings.TrimSpace(value) == "" {
				continue
			}
			dst.Add(canon, value)
		}
	}
	if status != http.StatusNotModified && dst.Get("Content-Type") == "" {
		dst.Set("Content-Type", "application/json")
	}
}

func cloneHeader(h http.Header) http.Header {
	out := make(http.Header, len(h))
	for key, values := range h {
		out[key] = append([]string(nil), values...)
	}
	return out
}
