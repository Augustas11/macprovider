package stats

import (
	"database/sql"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
	"github.com/rs/zerolog"
	_ "modernc.org/sqlite"
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

func TestTrimEndpointIncludesPublicRoutabilityViews(t *testing.T) {
	for _, tc := range []struct {
		path string
		want string
	}{
		{"/v1/stats/routability", "routability"},
		{"/v1/stats/models", "models"},
		{"/v1/stats/providers", "providers"},
		{"/v1/stats/providers/extra", ""},
		{"/v1/stats/model", ""},
	} {
		if got := trimEndpointFromPath(tc.path); got != tc.want {
			t.Fatalf("trimEndpointFromPath(%q)=%q want %q", tc.path, got, tc.want)
		}
	}
}

func TestPublicRoutabilityViewErrorHeadersMatchSuccessRows(t *testing.T) {
	for _, path := range []string{"/v1/stats/routability", "/v1/stats/models", "/v1/stats/providers"} {
		t.Run(path, func(t *testing.T) {
			req := httptest.NewRequest(http.MethodGet, path, nil)
			rec := httptest.NewRecorder()
			writeError(rec, req, http.StatusServiceUnavailable, codeStatsStale, "routability is stale", time.Unix(1_700_000_000, 0).UTC(), errorRetry(30))

			if got := rec.Header().Get("Cache-Control"); got != "public, max-age=30, s-maxage=30, stale-while-revalidate=60" {
				t.Fatalf("Cache-Control=%q want public routability error row", got)
			}
			if got := rec.Header().Get("Vary"); got != "Accept-Encoding, Origin" {
				t.Fatalf("Vary=%q want public vary row", got)
			}
		})
	}
}

func TestMissingRoutabilityRowStaleErrorUsesPublicCacheAndRequestTime(t *testing.T) {
	db, err := sql.Open("sqlite", ":memory:")
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if _, err := db.Exec(`CREATE TABLE stats_routability_current (
		singleton BOOLEAN PRIMARY KEY,
		generated_at TIMESTAMP NOT NULL,
		summary BLOB NOT NULL,
		models BLOB NOT NULL,
		providers BLOB NOT NULL
	)`); err != nil {
		t.Fatalf("create routability table: %v", err)
	}

	mux := NewMuxWithMetricsAndRateLimit(
		store.New(db),
		CORSConfig{},
		"",
		"",
		nil,
		zerolog.Nop(),
		nil,
		RateLimitConfig{MaxBuckets: 10, IdleTTL: time.Minute},
	)
	req := httptest.NewRequest(http.MethodGet, "/v1/stats/routability", nil)
	req.RemoteAddr = "203.0.113.10:443"
	rec := httptest.NewRecorder()

	mux.Handler().ServeHTTP(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d want 503 body=%s", rec.Code, rec.Body.String())
	}
	if got := rec.Header().Get("Cache-Control"); got != "public, max-age=30, s-maxage=30, stale-while-revalidate=60" {
		t.Fatalf("Cache-Control=%q want public routability error row", got)
	}
	if got := rec.Header().Get("Vary"); got != "Accept-Encoding, Origin" {
		t.Fatalf("Vary=%q want public vary row", got)
	}
	if got := rec.Header().Get("Retry-After"); got != "30" {
		t.Fatalf("Retry-After=%q want 30", got)
	}
	generatedAt := rec.Header().Get("X-Stats-Generated-At")
	parsed, err := time.Parse(time.RFC3339, generatedAt)
	if err != nil {
		t.Fatalf("X-Stats-Generated-At=%q is not RFC3339: %v", generatedAt, err)
	}
	if parsed.IsZero() || parsed.Year() == 1 {
		t.Fatalf("X-Stats-Generated-At=%q used zero time", generatedAt)
	}
	if got := mux.publicLimit.CountForTest("public|203.0.113.10|routability", time.Now().UTC()); got != 0 {
		t.Fatalf("public success limiter count=%d want 0 for stale precheck", got)
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
