package stats

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

func TestPreflightRateLimitIsSeparateOriginBucket(t *testing.T) {
	mux := NewMuxWithMetricsAndRateLimit(
		nil,
		CORSConfig{
			AccessControlMaxAgeSeconds: 60,
			PartnerOriginAllowlist:     []string{"https://console.malibu.tech", "https://portal.malibu.tech"},
		},
		"",
		"",
		nil,
		zerolog.Nop(),
		nil,
		RateLimitConfig{MaxBuckets: 10, IdleTTL: time.Minute, PreflightRPM: 2},
	)
	h := mux.Handler()

	for i := 0; i < 2; i++ {
		resp := doPreflight(t, h, "https://console.malibu.tech")
		if resp.Code != http.StatusNoContent {
			t.Fatalf("preflight %d status=%d want 204 body=%s", i+1, resp.Code, resp.Body.String())
		}
	}
	limited := doPreflight(t, h, "https://console.malibu.tech")
	if limited.Code != http.StatusTooManyRequests {
		t.Fatalf("third same-origin preflight status=%d want 429", limited.Code)
	}
	if got := limited.Header().Get("Retry-After"); got != "60" {
		t.Fatalf("429 Retry-After=%q want 60", got)
	}

	otherOrigin := doPreflight(t, h, "https://portal.malibu.tech")
	if otherOrigin.Code != http.StatusTooManyRequests {
		t.Fatalf("different-origin preflight status=%d want same client/endpoint 429 bucket", otherOrigin.Code)
	}
	if got := mux.publicLimit.sizeForTest(); got != 0 {
		t.Fatalf("public GET limiter bucket count=%d want 0 after OPTIONS-only traffic", got)
	}
}

func doPreflight(t *testing.T, h http.Handler, origin string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodOptions, "/v1/stats/leaderboard", nil)
	req.RemoteAddr = "203.0.113.10:443"
	req.Header.Set("Origin", origin)
	req.Header.Set("Access-Control-Request-Method", "GET")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}
