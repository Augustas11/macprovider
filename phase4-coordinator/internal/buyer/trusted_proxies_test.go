package buyer

// Issue #125 — trusted-proxy + X-Forwarded-For coverage.
//
// PR #124's partial fix taught poolCheckClientKey to honor X-Real-IP
// when r.RemoteAddr is a loopback address (production nginx-on-
// localhost topology). The remaining gap was non-loopback proxy
// topologies (remote LB, sidecar reverse proxies) plus chained-
// trusted-proxy hops via X-Forwarded-For. This file covers:
//
//   - Loopback default still honors X-Real-IP (back-compat with
//     the PR #124 fix; also covered by
//     TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback in
//     catalog_endpoints_test.go).
//   - Trusted non-loopback proxy CIDR: X-Forwarded-For rightmost-
//     untrusted hop becomes the bucket key.
//   - Untrusted proxy attempting spoof: X-Forwarded-For / X-Real-IP
//     IGNORED; r.RemoteAddr is the bucket key.
//   - Multi-hop X-Forwarded-For with chained trusted proxies: the
//     rightmost-untrusted entry is the buyer.
//   - X-Forwarded-For takes priority over X-Real-IP when both are
//     present on a trusted-proxy request.
//   - Empty trusted-proxies set: NO proxy is trusted, even loopback.
//   - Malformed X-Forwarded-For hops: parse error skips that hop,
//     falls through to next-rightmost or fallback.

import (
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestPoolCheckClientKey_LoopbackDefaultHonorsXRealIP(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Real-IP", "198.51.100.7")
	if got := s.poolCheckClientKey(req); got != "198.51.100.7" {
		t.Fatalf("loopback X-Real-IP key = %q, want 198.51.100.7", got)
	}
}

func TestPoolCheckClientKey_NonLoopbackTrustedProxyHonorsXFF(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "10.5.0.42:43210"
	req.Header.Set("X-Forwarded-For", "203.0.113.99")
	if got := s.poolCheckClientKey(req); got != "203.0.113.99" {
		t.Fatalf("trusted-proxy XFF key = %q, want 203.0.113.99", got)
	}
}

func TestPoolCheckClientKey_UntrustedProxyIgnoresXFFAndXRealIP(t *testing.T) {
	// Loopback-only trusted set. A spoofing client from the open
	// internet MUST NOT escape its bucket by sending XFF / X-Real-IP.
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "203.0.113.5:50000"
	req.Header.Set("X-Forwarded-For", "1.2.3.4")
	req.Header.Set("X-Real-IP", "5.6.7.8")
	if got := s.poolCheckClientKey(req); got != "203.0.113.5" {
		t.Fatalf("untrusted spoof key = %q, want 203.0.113.5 (XFF/X-Real-IP MUST be ignored)", got)
	}
}

func TestPoolCheckClientKey_MultiHopXFFReturnsRightmostUntrusted(t *testing.T) {
	// Trusted: loopback + 10.0.0.0/8 (e.g. a remote LB at 10.5.0.42
	// forwards to nginx on 127.0.0.1 which forwards to the
	// coordinator on 127.0.0.1).
	// XFF chain: buyer (203.0.113.99) → LB (10.5.0.42) → nginx
	// (127.0.0.1). Rightmost-untrusted is the buyer.
	s := &Server{trustedProxies: []netip.Prefix{
		netip.MustParsePrefix("127.0.0.0/8"),
		netip.MustParsePrefix("10.0.0.0/8"),
	}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "203.0.113.99, 10.5.0.42, 127.0.0.1")
	if got := s.poolCheckClientKey(req); got != "203.0.113.99" {
		t.Fatalf("multi-hop XFF key = %q, want 203.0.113.99", got)
	}
}

func TestPoolCheckClientKey_XFFTakesPriorityOverXRealIP(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "198.51.100.99")
	req.Header.Set("X-Real-IP", "198.51.100.7")
	if got := s.poolCheckClientKey(req); got != "198.51.100.99" {
		t.Fatalf("XFF vs X-Real-IP priority: got %q, want 198.51.100.99 (XFF wins)", got)
	}
}

func TestPoolCheckClientKey_EmptyTrustedSetIgnoresForwardedHeaders(t *testing.T) {
	// Empty trusted set = strictest posture. Even loopback callers
	// cannot use X-Real-IP / X-Forwarded-For.
	s := &Server{trustedProxies: nil}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "1.2.3.4")
	req.Header.Set("X-Real-IP", "5.6.7.8")
	if got := s.poolCheckClientKey(req); got != "127.0.0.1" {
		t.Fatalf("empty-trusted key = %q, want 127.0.0.1 (no proxy is trusted)", got)
	}
}

func TestPoolCheckClientKey_AllHopsTrustedFallsBackToXRealIP(t *testing.T) {
	// XFF chain is entirely inside the trusted set → rightmostUntrustedXFF
	// returns "". The helper then falls through to X-Real-IP.
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "127.0.0.1, 127.0.0.2")
	req.Header.Set("X-Real-IP", "198.51.100.7")
	if got := s.poolCheckClientKey(req); got != "198.51.100.7" {
		t.Fatalf("all-trusted-hops + X-Real-IP fallback key = %q, want 198.51.100.7", got)
	}
}

func TestPoolCheckClientKey_AllHopsTrustedNoHeadersFallsBackToRemoteAddr(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "127.0.0.1, 127.0.0.2")
	// No X-Real-IP either.
	if got := s.poolCheckClientKey(req); got != "127.0.0.1" {
		t.Fatalf("all-trusted no-X-Real-IP key = %q, want 127.0.0.1", got)
	}
}

func TestPoolCheckClientKey_IPv6LoopbackHonored(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("::1/128")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "[::1]:54321"
	req.Header.Set("X-Real-IP", "2001:db8::1")
	if got := s.poolCheckClientKey(req); got != "2001:db8::1" {
		t.Fatalf("IPv6 loopback X-Real-IP key = %q, want 2001:db8::1", got)
	}
}

func TestPoolCheckClientKey_MalformedXFFHopSkipped(t *testing.T) {
	// XFF has a junk middle entry. The rightmost-untrusted walk should
	// skip "not-an-ip" and return the next valid untrusted entry.
	s := &Server{trustedProxies: []netip.Prefix{
		netip.MustParsePrefix("127.0.0.0/8"),
		netip.MustParsePrefix("10.0.0.0/8"),
	}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "203.0.113.99, not-an-ip, 10.5.0.42, 127.0.0.1")
	if got := s.poolCheckClientKey(req); got != "203.0.113.99" {
		t.Fatalf("malformed-XFF-hop key = %q, want 203.0.113.99 (skip junk, find rightmost-untrusted)", got)
	}
}

func TestPoolCheckClientKey_UnparseableRemoteAddrFallsBack(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "garbage" // no host:port shape
	req.Header.Set("X-Forwarded-For", "1.2.3.4")
	// Unparseable peer never trusts forwarded headers; returns the
	// raw RemoteAddr string so the bucket is at least deterministic.
	if got := s.poolCheckClientKey(req); got != "garbage" {
		t.Fatalf("unparseable peer key = %q, want \"garbage\"", got)
	}
}

// Issue #125 r1 code-lane L3 + security-lane L1 follow-ups: explicit
// edge-case pins for XFF separator handling + X-Real-IP canonicalization.

func TestPoolCheckClientKey_XFFWhitespaceTrimmed(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "   198.51.100.99  ,   127.0.0.1  ")
	if got := s.poolCheckClientKey(req); got != "198.51.100.99" {
		t.Fatalf("whitespace-padded XFF key = %q, want 198.51.100.99", got)
	}
}

func TestPoolCheckClientKey_XFFEmptyHopsSkipped(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", "198.51.100.99,,,127.0.0.1")
	if got := s.poolCheckClientKey(req); got != "198.51.100.99" {
		t.Fatalf("empty-XFF-hops key = %q, want 198.51.100.99 (empty hops MUST be skipped)", got)
	}
}

func TestPoolCheckClientKey_XFFOnlyCommasFallsThrough(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Forwarded-For", ",,, ,,")
	req.Header.Set("X-Real-IP", "198.51.100.7")
	if got := s.poolCheckClientKey(req); got != "198.51.100.7" {
		t.Fatalf("only-commas XFF key = %q, want 198.51.100.7 (XFF returns \"\"; X-Real-IP fallback fires)", got)
	}
}

func TestPoolCheckClientKey_XRealIPMalformedFallsThrough(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	req.Header.Set("X-Real-IP", "not-an-ip-at-all")
	// Malformed X-Real-IP MUST NOT poison the bucket key; helper
	// falls through to r.RemoteAddr's host. Issue #125 security-lane L1.
	if got := s.poolCheckClientKey(req); got != "127.0.0.1" {
		t.Fatalf("malformed X-Real-IP key = %q, want 127.0.0.1 (parse failure → fallback)", got)
	}
}

func TestPoolCheckClientKey_XRealIPWithPortRejected(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "127.0.0.1:54321"
	// nginx's `proxy_set_header X-Real-IP $remote_addr` produces a
	// bare IP without port. A port-bearing value (manual misconfig
	// or a non-nginx proxy) is rejected by netip.ParseAddr and
	// falls through. Issue #125 code-lane L4 + security-lane L1.
	req.Header.Set("X-Real-IP", "198.51.100.7:8080")
	if got := s.poolCheckClientKey(req); got != "127.0.0.1" {
		t.Fatalf("port-bearing X-Real-IP key = %q, want 127.0.0.1 (port-bearing values are NOT accepted; fallback to peer)", got)
	}
}

func TestPoolCheckClientKey_XRealIPIPv6Canonicalized(t *testing.T) {
	s := &Server{trustedProxies: []netip.Prefix{netip.MustParsePrefix("::1/128")}}
	req := httptest.NewRequest("GET", "/", nil)
	req.RemoteAddr = "[::1]:54321"
	// IPv6 with full notation should canonicalize to the short form
	// via addr.String().
	req.Header.Set("X-Real-IP", "2001:0db8:0000:0000:0000:0000:0000:0001")
	if got := s.poolCheckClientKey(req); got != "2001:db8::1" {
		t.Fatalf("IPv6 X-Real-IP canonical form = %q, want 2001:db8::1", got)
	}
}
