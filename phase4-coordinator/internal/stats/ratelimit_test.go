package stats

import (
	"net/http"
	"testing"
	"time"
)

func TestClientIPTrustedProxyWalksForwardedChain(t *testing.T) {
	trusted, err := parseTrustedProxies([]string{"192.0.2.0/24", "198.51.100.0/24"})
	if err != nil {
		t.Fatalf("parse trusted proxies: %v", err)
	}

	req := &http.Request{
		RemoteAddr: "192.0.2.10:443",
		Header: http.Header{
			"X-Forwarded-For": []string{"203.0.113.9, 198.51.100.7, 192.0.2.9"},
		},
	}
	if got := clientIP(req, trusted); got != "203.0.113.9" {
		t.Fatalf("clientIP()=%q want first untrusted hop", got)
	}
}

func TestClientIPFullyTrustedForwardedChainFallsBackToLeftmost(t *testing.T) {
	trusted, err := parseTrustedProxies([]string{"192.0.2.0/24", "198.51.100.0/24"})
	if err != nil {
		t.Fatalf("parse trusted proxies: %v", err)
	}

	req := &http.Request{
		RemoteAddr: "192.0.2.10:443",
		Header: http.Header{
			"X-Forwarded-For": []string{"198.51.100.7, 192.0.2.9"},
		},
	}
	if got := clientIP(req, trusted); got != "198.51.100.7" {
		t.Fatalf("clientIP()=%q want leftmost forwarded hop for fully trusted chain", got)
	}
}

func TestClientIPIgnoresForwardedHeaderFromUntrustedPeer(t *testing.T) {
	trusted, err := parseTrustedProxies([]string{"192.0.2.0/24"})
	if err != nil {
		t.Fatalf("parse trusted proxies: %v", err)
	}

	req := &http.Request{
		RemoteAddr: "203.0.113.10:443",
		Header: http.Header{
			"X-Forwarded-For": []string{"198.51.100.7"},
		},
	}
	if got := clientIP(req, trusted); got != "203.0.113.10" {
		t.Fatalf("clientIP()=%q want direct peer for untrusted source", got)
	}
}

func TestParseTrustedProxiesRejectsInvalidAndDefaultRoute(t *testing.T) {
	if _, err := parseTrustedProxies([]string{"not-a-cidr"}); err == nil {
		t.Fatal("parseTrustedProxies accepted malformed CIDR")
	}
	if _, err := parseTrustedProxies([]string{"::/0"}); err == nil {
		t.Fatal("parseTrustedProxies accepted IPv6 default route")
	}
}

func TestLimiterBoundsIdleAndMaxBuckets(t *testing.T) {
	base := time.Unix(1_700_000_000, 0).UTC()
	l := newLimiterWithBounds(2, time.Minute)

	if !l.allow("old", base, 10) {
		t.Fatal("initial old bucket rejected")
	}
	if !l.allow("fresh-a", base.Add(2*time.Minute), 10) {
		t.Fatal("fresh-a bucket rejected")
	}
	if got := l.sizeForTest(); got != 1 {
		t.Fatalf("size after idle sweep=%d want 1", got)
	}

	if !l.allow("fresh-b", base.Add(2*time.Minute), 10) {
		t.Fatal("fresh-b bucket rejected")
	}
	if !l.allow("fresh-c", base.Add(2*time.Minute), 10) {
		t.Fatal("fresh-c bucket rejected")
	}
	if got := l.sizeForTest(); got != 2 {
		t.Fatalf("size after max-bucket eviction=%d want 2", got)
	}
}
