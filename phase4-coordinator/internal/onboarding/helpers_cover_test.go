package onboarding

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func TestStaticASNResolverLongestPrefixWins(t *testing.T) {
	r, err := NewStaticASNResolver(map[string]string{
		"10.0.0.0/8":    " AS100 ",
		"10.1.0.0/16":   "AS200",
		"2001:db8::/32": "AS300",
	})
	if err != nil {
		t.Fatal(err)
	}
	cases := []struct {
		ip   string
		asn  string
		want bool
	}{
		{"10.1.2.3", "AS200", true},
		{"10.2.2.3", "AS100", true},
		{"2001:db8::1", "AS300", true},
		{"192.0.2.1", "", false},
	}
	for _, c := range cases {
		asn, ok, err := r.ResolveASN(context.Background(), netip.MustParseAddr(c.ip))
		if err != nil || ok != c.want || asn != c.asn {
			t.Fatalf("%s: got %q %v %v want %q %v", c.ip, asn, ok, err, c.asn, c.want)
		}
	}
	var nilResolver *StaticASNResolver
	if asn, ok, _ := nilResolver.ResolveASN(context.Background(), netip.MustParseAddr("10.1.2.3")); ok || asn != "" {
		t.Fatalf("nil resolver resolved %q %v", asn, ok)
	}
}

func TestStaticASNResolverRejectsBadConfig(t *testing.T) {
	if _, err := NewStaticASNResolver(map[string]string{"not-a-prefix": "AS1"}); err == nil {
		t.Fatal("expected error for bad prefix")
	}
	if _, err := NewStaticASNResolver(map[string]string{"10.0.0.0/8": "  "}); err == nil {
		t.Fatal("expected error for empty ASN")
	}
}

func TestMemoryRateLimiterEnforcesLimitAndWindow(t *testing.T) {
	now := time.Date(2026, 7, 17, 12, 0, 0, 0, time.UTC)
	l := NewMemoryRateLimiter(2, time.Minute)
	l.now = func() time.Time { return now }
	if !l.Allow("a") || !l.Allow("a") {
		t.Fatal("first two hits must be allowed")
	}
	if l.Allow("a") {
		t.Fatal("third hit inside window must be denied")
	}
	if !l.Allow("b") {
		t.Fatal("other key is independent")
	}
	now = now.Add(61 * time.Second)
	if !l.Allow("a") {
		t.Fatal("hit after window must be allowed again")
	}
}

func TestMemoryRateLimiterDisabledConfigs(t *testing.T) {
	var nilL *MemoryRateLimiter
	if nilL.Allow("x") {
		t.Fatal("nil limiter must deny")
	}
	if NewMemoryRateLimiter(0, time.Minute).Allow("x") {
		t.Fatal("zero limit must deny")
	}
	if NewMemoryRateLimiter(1, 0).Allow("x") {
		t.Fatal("zero window must deny")
	}
}

func TestDecodeIdentityPubkeyValidates(t *testing.T) {
	good := base64.StdEncoding.EncodeToString(make([]byte, 32))
	if b, err := DecodeIdentityPubkey(good); err != nil || len(b) != 32 {
		t.Fatalf("good key: %v %d", err, len(b))
	}
	if _, err := DecodeIdentityPubkey(base64.StdEncoding.EncodeToString(make([]byte, 31))); err == nil {
		t.Fatal("31-byte key must be rejected")
	}
	if _, err := DecodeIdentityPubkey("!!!not base64"); err == nil {
		t.Fatal("bad base64 must be rejected")
	}
}

func TestReadBoundedBodyEnforcesMax(t *testing.T) {
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader("12345"))
	if b, err := readBoundedBody(rec, req, 5); err != nil || string(b) != "12345" {
		t.Fatalf("at-limit body: %q %v", b, err)
	}
	req = httptest.NewRequest(http.MethodPost, "/", strings.NewReader("123456"))
	if _, err := readBoundedBody(httptest.NewRecorder(), req, 5); err == nil {
		t.Fatal("over-limit body must error")
	}
}

func TestBearerFromRequest(t *testing.T) {
	cases := map[string]string{
		"Bearer abc":     "abc",
		"  Bearer  abc ": "abc",
	}
	for hdr, want := range cases {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.Header.Set("Authorization", hdr)
		got := bearerFromRequest(r)
		if got == nil || *got != want {
			t.Fatalf("%q: got %v want %q", hdr, got, want)
		}
	}
	for _, hdr := range []string{"", "Basic abc", "Bearer ", "bearer abc"} {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		if hdr != "" {
			r.Header.Set("Authorization", hdr)
		}
		if got := bearerFromRequest(r); got != nil {
			t.Fatalf("%q: expected nil, got %q", hdr, *got)
		}
	}
	h := http.Header{}
	h.Set("Authorization", "Bearer tok ")
	if bearerToken(h) != "tok" || bearerToken(http.Header{}) != "" {
		t.Fatal("bearerToken mismatch")
	}
}

func TestWriteReferralErrorMapping(t *testing.T) {
	cases := []struct {
		err    error
		status int
		code   string
		reason string
	}{
		{auth.ErrReferralRequired, 400, "referral_required", "missing"},
		{auth.ErrReferralExpired, 410, "referral_expired", "expired"},
		{auth.ErrReferralRevoked, 410, "referral_revoked", "revoked"},
		{auth.ErrReferralExhausted, 409, "referral_exhausted", "exhausted"},
		{auth.ErrReferralConflict, 409, "referral_conflict", "invalid"},
		{fmt.Errorf("other"), 400, "referral_invalid", "invalid"},
	}
	for _, c := range cases {
		rec := httptest.NewRecorder()
		writeReferralError(rec, fmt.Errorf("wrapped: %w", c.err))
		var body struct {
			Error  struct{ Code string } `json:"error"`
			Reason string                `json:"reason"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
			t.Fatal(err)
		}
		if rec.Code != c.status || body.Error.Code != c.code || body.Reason != c.reason {
			t.Fatalf("%v: got %d %s %s", c.err, rec.Code, body.Error.Code, body.Reason)
		}
	}
}

func TestWriteAppTrackErrorMapping(t *testing.T) {
	prep := []struct {
		err    error
		status int
		code   string
	}{
		{ErrNonceReplay, 409, "nonce_replay"},
		{ErrTOFUConflict, 409, "provider_id_pubkey_mismatch"},
		{ErrAttestKeyReused, 409, "app_attest_key_reused"},
		{fmt.Errorf("db down"), 500, "internal_error"},
	}
	for _, c := range prep {
		rec := httptest.NewRecorder()
		writeAppTrackPrepareError(rec, c.err)
		if rec.Code != c.status || !strings.Contains(rec.Body.String(), `"`+c.code+`"`) {
			t.Fatalf("prepare %v: %d %s", c.err, rec.Code, rec.Body.String())
		}
	}
	mint := []struct {
		err    error
		status int
		code   string
	}{
		{auth.ErrReferralInvalid, 400, "referral_invalid"},
		{auth.ErrReferralExpired, 410, "referral_expired"},
		{auth.ErrAppTrackExistingTokenNoProof, 409, "existing_active_token_no_proof"},
		{auth.ErrAppTrackReissueCooldown, 429, "reissue_cooldown"},
		{fmt.Errorf("boom"), 500, "internal_error"},
	}
	for _, c := range mint {
		rec := httptest.NewRecorder()
		writeAppTrackMintError(rec, c.err)
		if rec.Code != c.status || !strings.Contains(rec.Body.String(), `"`+c.code+`"`) {
			t.Fatalf("mint %v: %d %s", c.err, rec.Code, rec.Body.String())
		}
		if c.code == "reissue_cooldown" && rec.Header().Get("Retry-After") != "300" {
			t.Fatal("cooldown must set Retry-After")
		}
	}
}

func TestHexAndSHAValidators(t *testing.T) {
	if !isLowerHex("abcdef09") || isLowerHex("ABCDEF") || isLowerHex("xyz") || isLowerHex("abc") {
		t.Fatal("isLowerHex mismatch")
	}
	if !isLowerSHA256(strings.Repeat("a", 64)) {
		t.Fatal("valid sha rejected")
	}
	for _, s := range []string{strings.Repeat("a", 63), strings.Repeat("A", 64), strings.Repeat("g", 64)} {
		if isLowerSHA256(s) {
			t.Fatalf("%q accepted", s)
		}
	}
}

func TestMaxBenchmarkTPSIgnoresNonFinite(t *testing.T) {
	got := maxBenchmarkTPS([]HardwareEvidenceBenchmark{
		{SustainedTPS: 10}, {SustainedTPS: math.Inf(1)}, {SustainedTPS: math.NaN()}, {SustainedTPS: 25.5}, {SustainedTPS: -3},
	})
	if got != 25.5 {
		t.Fatalf("got %v want 25.5", got)
	}
	if maxBenchmarkTPS(nil) != 0 {
		t.Fatal("empty must be 0")
	}
}

func TestClientIPExportedAndFallbacks(t *testing.T) {
	trusted := []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}
	mk := func(remote, xff, xrip string) *http.Request {
		r := httptest.NewRequest(http.MethodGet, "/", nil)
		r.RemoteAddr = remote
		if xff != "" {
			r.Header.Set("X-Forwarded-For", xff)
		}
		if xrip != "" {
			r.Header.Set("X-Real-IP", xrip)
		}
		return r
	}
	// Untrusted peer: headers ignored.
	if got := ClientIP(mk("203.0.113.9:1", "1.2.3.4", ""), trusted); got != "203.0.113.9" {
		t.Fatalf("untrusted peer got %s", got)
	}
	// Trusted peer, XFF all trusted: falls back to X-Real-IP.
	if got := ClientIP(mk("10.0.0.1:1", "10.0.0.5, 10.0.0.6", "198.51.100.7"), trusted); got != "198.51.100.7" {
		t.Fatalf("xrip fallback got %s", got)
	}
	// Trusted peer, garbage headers: falls back to peer host.
	if got := ClientIP(mk("10.0.0.1:1", "garbage", "garbage"), trusted); got != "10.0.0.1" {
		t.Fatalf("garbage fallback got %s", got)
	}
	// Bracketed IPv6 with port in XFF.
	if got := rightmostUntrustedXFF("1.1.1.1, [2001:db8::1]:443", trusted); got != "2001:db8::1" {
		t.Fatalf("ipv6 xff got %s", got)
	}
	// RemoteAddr without port.
	if got := clientIP(mk("203.0.113.9", "", ""), trusted); got != "203.0.113.9" {
		t.Fatalf("no-port got %s", got)
	}
}
