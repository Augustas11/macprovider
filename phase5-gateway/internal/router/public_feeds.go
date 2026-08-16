package router

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
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

const (
	publicRateCardPath    = "/v1/rate-card"
	publicRateCardSigPath = "/v1/rate-card.sig"
	publicStatsPath       = "/v1/stats/overview"
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

type publicFeedFetch struct {
	status       int
	header       http.Header
	body         []byte
	transportErr bool
	gatewayErr   bool
}

func isPublicFeedPath(path string) bool {
	switch path {
	case publicRateCardPath, publicRateCardSigPath, publicStatsPath, "/v1/network-stats":
		return true
	default:
		return false
	}
}

func isRateCardPairPath(path string) bool {
	return path == publicRateCardPath || path == publicRateCardSigPath
}

func publicFeedCacheTTL(upstreamPath string) time.Duration {
	if upstreamPath == publicStatsPath {
		return publicStatsCacheTTL
	}
	return publicRateCardCacheTTL
}

func (s *Server) handlePublicRateCard(w http.ResponseWriter, r *http.Request) {
	s.proxyPublicUpstream(w, r, s.coordinatorBuyerURL(), publicRateCardPath, "coordinator_rate_card_error", "Coordinator rate-card error")
}

func (s *Server) handlePublicRateCardSig(w http.ResponseWriter, r *http.Request) {
	s.proxyPublicUpstream(w, r, s.coordinatorBuyerURL(), publicRateCardSigPath, "coordinator_rate_card_error", "Coordinator rate-card error")
}

func (s *Server) handlePublicStatsOverview(w http.ResponseWriter, r *http.Request) {
	s.proxyPublicUpstream(w, r, s.coordinatorOperatorURL(), publicStatsPath, "coordinator_stats_error", "Coordinator stats error")
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
	if isRateCardPairPath(upstreamPath) {
		s.proxyRateCardPair(w, r, baseURL, upstreamPath, errorCode, errorMessage)
		return
	}
	s.proxySinglePublicFeed(w, r, baseURL, upstreamPath, errorCode, errorMessage)
}

func (s *Server) proxySinglePublicFeed(w http.ResponseWriter, r *http.Request, baseURL, upstreamPath, errorCode, errorMessage string) {
	ctx, cancel := context.WithTimeout(r.Context(), publicUpstreamTimeout)
	defer cancel()
	fetched := s.fetchPublicFeed(ctx, r, baseURL, upstreamPath, true)
	s.writeFetchedPublicFeed(w, r, fetched, errorCode, errorMessage)
	if fetched.status == http.StatusOK && !fetched.transportErr && !fetched.gatewayErr {
		s.storePublicFeed(upstreamPath, fetched.status, fetched.header, fetched.body)
	}
}

func (s *Server) proxyRateCardPair(w http.ResponseWriter, r *http.Request, baseURL, requestedPath, errorCode, errorMessage string) {
	ctx, cancel := context.WithTimeout(r.Context(), publicUpstreamTimeout)
	defer cancel()

	var (
		bodyFetch publicFeedFetch
		sigFetch  publicFeedFetch
		wg        sync.WaitGroup
	)
	wg.Add(2)
	go func() {
		defer wg.Done()
		bodyFetch = s.fetchPublicFeed(ctx, r, baseURL, publicRateCardPath, requestedPath == publicRateCardPath)
	}()
	go func() {
		defer wg.Done()
		sigFetch = s.fetchPublicFeed(ctx, r, baseURL, publicRateCardSigPath, requestedPath == publicRateCardSigPath)
	}()
	wg.Wait()

	if bodyFetch.status == http.StatusOK && !bodyFetch.transportErr && !bodyFetch.gatewayErr &&
		sigFetch.status == http.StatusOK && !sigFetch.transportErr && !sigFetch.gatewayErr {
		s.storeRateCardPair(bodyFetch, sigFetch)
	}

	requested := bodyFetch
	if requestedPath == publicRateCardSigPath {
		requested = sigFetch
	}
	s.writeFetchedPublicFeed(w, r, requested, errorCode, errorMessage)
}

func (s *Server) writeFetchedPublicFeed(w http.ResponseWriter, r *http.Request, fetched publicFeedFetch, errorCode, errorMessage string) {
	if fetched.transportErr {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	if fetched.gatewayErr {
		writeError(w, http.StatusBadGateway, "api_error", errorCode, errorMessage)
		return
	}
	writePublicFeed(w, r.Method, fetched.status, fetched.header, fetched.body)
}

func (s *Server) fetchPublicFeed(ctx context.Context, clientReq *http.Request, baseURL, upstreamPath string, forwardIfNoneMatch bool) publicFeedFetch {
	target, err := publicUpstreamURL(baseURL, upstreamPath)
	if err != nil {
		return publicFeedFetch{transportErr: true}
	}
	upReq, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return publicFeedFetch{transportErr: true}
	}
	upReq.Header.Set("X-Request-ID", requestID(clientReq))
	if accept := strings.TrimSpace(clientReq.Header.Get("Accept")); accept != "" {
		upReq.Header.Set("Accept", accept)
	}
	if forwardIfNoneMatch {
		if match := strings.TrimSpace(clientReq.Header.Get("If-None-Match")); match != "" {
			upReq.Header.Set("If-None-Match", match)
		}
	}
	if ip := s.clientIP(clientReq); ip != "" {
		upReq.Header.Set("X-Real-IP", ip)
		upReq.Header.Set("X-Forwarded-For", ip)
	}
	resp, err := s.doPublicUpstream(upReq)
	if err != nil {
		return publicFeedFetch{transportErr: true}
	}
	defer resp.Body.Close()
	if isDisallowedPublicUpstreamStatus(resp.StatusCode) {
		return publicFeedFetch{gatewayErr: true}
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, publicUpstreamMaxBytes+1))
	if err != nil {
		return publicFeedFetch{gatewayErr: true}
	}
	if int64(len(body)) > publicUpstreamMaxBytes {
		return publicFeedFetch{gatewayErr: true}
	}
	return publicFeedFetch{
		status: resp.StatusCode,
		header: resp.Header,
		body:   body,
	}
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
	defer s.mu.RUnlock()
	if isRateCardPairPath(upstreamPath) {
		body, okBody := s.publicFeedCache[publicRateCardPath]
		sig, okSig := s.publicFeedCache[publicRateCardSigPath]
		if !okBody || !okSig || !publicFeedCacheFresh(body, now) || !publicFeedCacheFresh(sig, now) {
			return publicFeedCacheEntry{}, false
		}
		if upstreamPath == publicRateCardPath {
			return body, true
		}
		return sig, true
	}
	entry, ok := s.publicFeedCache[upstreamPath]
	if !ok || !publicFeedCacheFresh(entry, now) {
		return publicFeedCacheEntry{}, false
	}
	return entry, true
}

func publicFeedCacheFresh(entry publicFeedCacheEntry, now time.Time) bool {
	return !entry.expiresAt.IsZero() && now.Before(entry.expiresAt)
}

func (s *Server) storePublicFeed(upstreamPath string, status int, header http.Header, body []byte) {
	if s == nil || s.publicFeedCache == nil {
		return
	}
	now := time.Now().UTC()
	if s.now != nil {
		now = s.now()
	}
	s.mu.Lock()
	s.publicFeedCache[upstreamPath] = publicFeedCacheEntry{
		expiresAt: now.Add(publicFeedCacheTTL(upstreamPath)),
		status:    status,
		header:    cloneHeader(header),
		body:      append([]byte(nil), body...),
	}
	s.mu.Unlock()
}

func (s *Server) storeRateCardPair(body, sig publicFeedFetch) {
	if s == nil || s.publicFeedCache == nil {
		return
	}
	now := time.Now().UTC()
	if s.now != nil {
		now = s.now()
	}
	expiresAt := now.Add(publicRateCardCacheTTL)
	s.mu.Lock()
	s.publicFeedCache[publicRateCardPath] = publicFeedCacheEntry{
		expiresAt: expiresAt,
		status:    body.status,
		header:    cloneHeader(body.header),
		body:      append([]byte(nil), body.body...),
	}
	s.publicFeedCache[publicRateCardSigPath] = publicFeedCacheEntry{
		expiresAt: expiresAt,
		status:    sig.status,
		header:    cloneHeader(sig.header),
		body:      append([]byte(nil), sig.body...),
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
