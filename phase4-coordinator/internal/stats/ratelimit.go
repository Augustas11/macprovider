package stats

import (
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// SPEC §5.6 v0.1.8 three-tier rate limiter — in-process bucket
// per the locked auth-failure / public / partner tiers.
//
// Tiers:
//
//   - public        : (client_ip, endpoint) → 60 req/min
//   - auth-failure  : (client_ip, endpoint) → 300 req/min,
//                     scoped to Authorization-present requests
//                     ONLY; reserve-then-refund so 200 partner
//                     responses don't double-count.
//   - partner       : (partner_keys.id, endpoint) → key's
//                     `rate_limit_rpm` (default 600).
//
// Client IP derivation honors the operator-configured trusted-
// proxy allowlist per SECURITY r5 H1: trusted XFF is parsed
// (first hop AFTER the trusted proxy); untrusted XFF is
// ignored (use r.RemoteAddr).

// limiter is a single per-key fixed-window bucket. We use a
// fixed 60-second window keyed by minute-of-epoch for
// simplicity + idempotent expiry. A sliding window or token
// bucket would surface more even rate enforcement; for v0.1's
// §5.6 floor the fixed-window approach is conformant
// ("60 req/min") and lock-pinned in BUILD §F.5.
type limiter struct {
	mu      sync.Mutex
	windows map[string]*bucketEntry
}

type bucketEntry struct {
	windowMinute int64
	count        int
}

func newLimiter() *limiter {
	return &limiter{windows: make(map[string]*bucketEntry)}
}

// allow increments and returns whether the next request fits
// under `limit` for the (key, now). Side effect: a fresh
// window evicts the previous count. The implementation does
// NOT actively garbage-collect stale entries; a periodic
// sweep is acceptable for v0.1 (low cardinality — IPs +
// partner key IDs).
func (l *limiter) allow(key string, now time.Time, limit int) bool {
	if limit <= 0 {
		return false
	}
	min := now.Unix() / 60
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.windows[key]
	if !ok || b.windowMinute != min {
		l.windows[key] = &bucketEntry{windowMinute: min, count: 1}
		return true
	}
	if b.count >= limit {
		return false
	}
	b.count++
	return true
}

// CountForTest returns the current per-window count for `key`,
// or 0 if no bucket entry exists for the active window.
// Exported only for round-7 CODE M coverage; production code
// MUST NOT call this.
func (l *limiter) CountForTest(key string, now time.Time) int {
	min := now.Unix() / 60
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.windows[key]
	if !ok || b.windowMinute != min {
		return 0
	}
	return b.count
}

// refund decrements the active-window count for `key`. Used by
// the auth-failure reserve-then-refund pattern when the auth
// dispatcher returns 200 partner — the reserved slot is
// released so valid keys are not double-counted across the
// auth-failure + partner tiers.
func (l *limiter) refund(key string, now time.Time) {
	min := now.Unix() / 60
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.windows[key]
	if !ok || b.windowMinute != min {
		return
	}
	if b.count > 0 {
		b.count--
	}
}

// clientIP returns the trusted-proxy-aware client IP per
// SPEC §5.6 v0.1.8 auth-failure tier rules:
//
//  1. If immediate peer (`r.RemoteAddr`) is in the trusted-
//     proxy allowlist, parse the first XFF hop AFTER the
//     trusted proxy.
//  2. Otherwise, use `r.RemoteAddr`'s host portion.
func clientIP(r *http.Request, trustedCIDRs []*net.IPNet) string {
	peer := hostFromAddr(r.RemoteAddr)
	if !ipInAny(peer, trustedCIDRs) {
		return peer
	}
	xff := r.Header.Get("X-Forwarded-For")
	if xff == "" {
		return peer
	}
	// XFF is "client, proxy1, proxy2, ...". Walk right-to-left
	// from the rightmost (most trusted) hop until we exit the
	// trusted-proxy set; that's the client IP.
	parts := strings.Split(xff, ",")
	for i := len(parts) - 1; i >= 0; i-- {
		ip := strings.TrimSpace(parts[i])
		if ip == "" {
			continue
		}
		if !ipInAny(ip, trustedCIDRs) {
			return ip
		}
	}
	return peer
}

func hostFromAddr(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

func ipInAny(ipStr string, cidrs []*net.IPNet) bool {
	if ipStr == "" || len(cidrs) == 0 {
		return false
	}
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	for _, c := range cidrs {
		if c.Contains(ip) {
			return true
		}
	}
	return false
}

// parseTrustedProxies converts a slice of CIDR strings into
// *net.IPNet. Invalid entries are skipped silently; the caller
// (main.go startup) logs the count parsed.
func parseTrustedProxies(cidrs []string) []*net.IPNet {
	out := make([]*net.IPNet, 0, len(cidrs))
	for _, c := range cidrs {
		_, n, err := net.ParseCIDR(strings.TrimSpace(c))
		if err != nil {
			continue
		}
		out = append(out, n)
	}
	return out
}
