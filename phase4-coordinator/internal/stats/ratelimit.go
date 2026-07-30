package stats

import (
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"sort"
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
	mu         sync.Mutex
	windows    map[string]*bucketEntry
	maxBuckets int
	idleTTL    time.Duration
}

type bucketEntry struct {
	windowMinute int64
	count        int
	lastSeen     time.Time
}

func newLimiter() *limiter {
	return newLimiterWithBounds(100000, 15*time.Minute)
}

func newLimiterWithBounds(maxBuckets int, idleTTL time.Duration) *limiter {
	if maxBuckets <= 0 {
		maxBuckets = 100000
	}
	if idleTTL <= 0 {
		idleTTL = 15 * time.Minute
	}
	return &limiter{
		windows:    make(map[string]*bucketEntry),
		maxBuckets: maxBuckets,
		idleTTL:    idleTTL,
	}
}

// allow increments and returns whether the next request fits
// under `limit` for the (key, now). Side effect: a fresh
// window evicts the previous count, and new buckets trigger
// idle/max-cardinality sweeps to bound memory use.
func (l *limiter) allow(key string, now time.Time, limit int) bool {
	if limit <= 0 {
		return false
	}
	min := now.Unix() / 60
	l.mu.Lock()
	defer l.mu.Unlock()
	b, ok := l.windows[key]
	if !ok || b.windowMinute != min {
		l.windows[key] = &bucketEntry{windowMinute: min, count: 1, lastSeen: now}
		l.sweepLocked(now)
		return true
	}
	b.lastSeen = now
	if b.count >= limit {
		return false
	}
	b.count++
	return true
}

func (l *limiter) sweep(now time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.sweepLocked(now)
}

func (l *limiter) sweepLocked(now time.Time) {
	if len(l.windows) == 0 {
		return
	}
	cutoff := now.Add(-l.idleTTL)
	for key, b := range l.windows {
		if b.lastSeen.Before(cutoff) {
			delete(l.windows, key)
		}
	}
	if len(l.windows) <= l.maxBuckets {
		return
	}
	oldest := make([]keyedBucket, 0, len(l.windows))
	for key, b := range l.windows {
		oldest = append(oldest, keyedBucket{key: key, lastSeen: b.lastSeen})
	}
	sortBucketsByAge(oldest)
	for len(l.windows) > l.maxBuckets && len(oldest) > 0 {
		delete(l.windows, oldest[0].key)
		oldest = oldest[1:]
	}
}

func sortBucketsByAge(buckets []keyedBucket) {
	sort.Slice(buckets, func(i, j int) bool {
		return buckets[i].lastSeen.Before(buckets[j].lastSeen)
	})
}

type keyedBucket struct {
	key      string
	lastSeen time.Time
}

func (l *limiter) sizeForTest() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.windows)
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
func clientIP(r *http.Request, trustedCIDRs []netip.Prefix) string {
	peer := hostFromAddr(r.RemoteAddr)
	peerAddr, err := netip.ParseAddr(peer)
	if err != nil || !ipInAny(peerAddr, trustedCIDRs) {
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
		ip := normalizeForwardedHop(strings.TrimSpace(parts[i]))
		if ip == "" {
			continue
		}
		addr, err := netip.ParseAddr(ip)
		if err != nil {
			continue
		}
		if !ipInAny(addr, trustedCIDRs) {
			return addr.String()
		}
	}
	return firstForwardedHop(parts, peer)
}

func hostFromAddr(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

func ipInAny(ip netip.Addr, cidrs []netip.Prefix) bool {
	for _, c := range cidrs {
		if c.Contains(ip) {
			return true
		}
	}
	return false
}

func normalizeForwardedHop(raw string) string {
	if raw == "" {
		return ""
	}
	if host, _, err := net.SplitHostPort(raw); err == nil {
		raw = host
	}
	return strings.Trim(raw, "[]")
}

func firstForwardedHop(parts []string, fallback string) string {
	for _, part := range parts {
		ip := normalizeForwardedHop(strings.TrimSpace(part))
		if ip == "" {
			continue
		}
		addr, err := netip.ParseAddr(ip)
		if err == nil {
			return addr.String()
		}
	}
	return fallback
}

// parseTrustedProxies converts a slice of CIDR strings into
// netip.Prefix values. Invalid entries are errors so startup
// validation cannot silently fall back to the direct peer.
func parseTrustedProxies(cidrs []string) ([]netip.Prefix, error) {
	out := make([]netip.Prefix, 0, len(cidrs))
	for _, c := range cidrs {
		trimmed := strings.TrimSpace(c)
		if trimmed == "" {
			continue
		}
		p, err := netip.ParsePrefix(trimmed)
		if err != nil {
			return nil, fmt.Errorf("stats.trusted_proxies[%q]: %w", c, err)
		}
		if p.Bits() == 0 {
			return nil, fmt.Errorf("stats.trusted_proxies[%q]: default-route prefix is not a valid trusted proxy", c)
		}
		out = append(out, p)
	}
	return out, nil
}
