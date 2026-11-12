package onboarding

import (
	"context"
	"math"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"testing"
	"time"
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
