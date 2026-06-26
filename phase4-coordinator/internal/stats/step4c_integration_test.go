//go:build integration

package stats_test

// SPEC-017 v0.1.8 Step 4.C round-1 fixes — wired-mux observability
// tests (ARCH M1 / CODE M1) + new event emission tests (CODE H5).
//
// Reuses the testcontainers fixtures from integration_test.go /
// rollup_integration_test.go / handlers_integration_test.go (same
// package + build tag).

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/stats"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// TestStep4C_WiredMux_MetricLabelHygiene drives real requests
// through stats.NewMuxWithMetrics + a coordinator-owned registry,
// scrapes via reg.Gather, and asserts no label value contains
// attacker-controlled material (raw token, body shape, Origin
// fragment, Authorization fragment, token_hash).
func TestStep4C_WiredMux_MetricLabelHygiene(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	readerDB := readerPool(t, fx)

	reg := prometheus.NewRegistry()
	m := statsmetrics.New(reg)
	mux := stats.NewMuxWithMetrics(
		store.New(readerDB),
		stats.CORSConfig{},
		"partial", "2026-06-01T00:00:00Z", nil,
		zerolog.Nop(), m,
	).Handler()

	doReq := func(path, auth, origin string) int {
		req := httptest.NewRequest(http.MethodGet, path, nil)
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		rec := httptest.NewRecorder()
		mux.ServeHTTP(rec, req)
		return rec.Code
	}

	for i := 0; i < 3; i++ {
		_ = doReq("/v1/stats/overview", "", "")
	}
	_ = doReq("/v1/stats/leaderboard?window=24h", "garbage", "")
	_ = doReq("/v1/stats/overview", "", "https://evil.streamvc.live")

	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	bodyShape := regexp.MustCompile(`[A-Za-z0-9_-]{43}`)
	deny := []string{"mpk_garbage", "garbage", "evil.streamvc.live", "Bearer ", "token_hash"}
	for _, mf := range families {
		for _, mt := range mf.GetMetric() {
			for _, lp := range mt.GetLabel() {
				val := lp.GetValue()
				if bodyShape.MatchString(val) {
					t.Errorf("metric %s label %s value %q matches 43-char body shape",
						mf.GetName(), lp.GetName(), val)
				}
				for _, bad := range deny {
					if strings.Contains(val, bad) {
						t.Errorf("metric %s label %s value %q contains forbidden substring %q",
							mf.GetName(), lp.GetName(), val, bad)
					}
				}
			}
		}
	}
}

// TestStep4C_StatsRequestServedEvent asserts the locked field set
// on the access-log middleware event.
func TestStep4C_StatsRequestServedEvent(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	readerDB := readerPool(t, fx)

	var buf bytes.Buffer
	logger := zerolog.New(&buf)

	mux := stats.NewMux(
		store.New(readerDB),
		stats.CORSConfig{},
		"partial", "2026-06-01T00:00:00Z", nil,
		logger,
	).Handler()

	req := httptest.NewRequest(http.MethodGet, "/v1/stats/overview", nil)
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	if rec.Code != 200 {
		t.Fatalf("expected 200, got %d body=%s", rec.Code, rec.Body.String())
	}
	out := buf.String()
	if !strings.Contains(out, `"event":"stats_request_served"`) {
		t.Errorf("log missing stats_request_served event: %q", out)
	}
	for _, field := range []string{
		`"endpoint":"overview"`,
		`"status":200`,
		`"latency_ms"`,
		`"generated_at_age_ms"`,
		`"partner_key_id":0`,
	} {
		if !strings.Contains(out, field) {
			t.Errorf("log missing field %s in event: %q", field, out)
		}
	}
	for _, banned := range []string{"Bearer ", "mpk_", "token_hash"} {
		if strings.Contains(out, banned) {
			t.Errorf("stats_request_served event contains forbidden substring %q: %q", banned, out)
		}
	}
}

// TestStep4C_StatsHandlerPanicEvent — locked field set: route +
// request_id + panic_type. No `path`, no `_stack` event tag.
func TestStep4C_StatsHandlerPanicEvent(t *testing.T) {
	var buf bytes.Buffer
	logger := zerolog.New(&buf)

	panicker := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("synthetic test panic")
	})
	h := stats.RecoverForTest(logger, panicker)

	req := httptest.NewRequest(http.MethodGet, "/v1/stats/leaderboard", nil)
	req.Header.Set("X-Request-Id", "rid-test-123")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	out := buf.String()
	if !strings.Contains(out, `"event":"stats_handler_panic"`) {
		t.Errorf("missing stats_handler_panic event: %q", out)
	}
	if !strings.Contains(out, `"route":"leaderboard"`) {
		t.Errorf("missing route=leaderboard: %q", out)
	}
	if !strings.Contains(out, `"request_id":"rid-test-123"`) {
		t.Errorf("missing request_id: %q", out)
	}
	if strings.Contains(out, `"event":"stats_handler_panic_stack"`) {
		t.Errorf("forbidden stats_handler_panic_stack event still emitted: %q", out)
	}
}
