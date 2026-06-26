//go:build integration

package stats_test

// SPEC-017 v0.1.8 Step 3 — handler integration tests against a
// real Postgres via testcontainers-go. Reuses the per-test
// container helpers from integration_test.go (same package +
// build tag) and the rollup helpers from
// rollup_integration_test.go so each test starts a fresh
// ephemeral DB.
//
// The tests seed `stats_overview_current` / `stats_components_health`
// directly via the admin DSN to get a fresh `generated_at` —
// the rollup runner could populate via a tick, but for handler-
// side ACs we want deterministic snapshot times.

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/stats"
	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// setupStatsHandler wires the Step 3 mux against the per-test
// Postgres fixture, applies the Step 1 schema, and seeds fresh
// snapshot rows so the freshness pre-check doesn't trip 503 on
// every test.
func setupStatsHandler(t *testing.T) (http.Handler, *sql.DB) {
	t.Helper()
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	readerDB := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(readerDB),
		stats.CORSConfig{
			AccessControlMaxAgeSeconds: 60,
			PartnerOriginAllowlist: []string{
				"https://console.streamvc.live",
				"https://portal.streamvc.live",
			},
		},
		"partial",
		"2026-06-01T00:00:00Z",
		nil,
		zerolog.Nop(),
	)
	return mux.Handler(), adminDB
}

func readerPool(t *testing.T, fx *pgFixture) *sql.DB {
	t.Helper()
	db, err := sql.Open("postgres", fx.roleDSN("stats_reader"))
	if err != nil {
		t.Fatalf("open stats_reader: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	return db
}

// seedFreshOverview UPSERTs a fresh stats_overview_current row.
// generated_at = now(), every counter zero.
func seedFreshOverview(t *testing.T, adminDB *sql.DB) {
	t.Helper()
	const q = `
        INSERT INTO stats_overview_current
            (singleton, generated_at,
             tokens_in, tokens_out, requests,
             nodes_online, nodes_hardware_attested,
             bandwidth_gb_per_s, network_power_kw,
             network_utilization_pct,
             gpu_cores_total, cpu_cores_total,
             unified_ram_gb_total, models_serving)
        VALUES (TRUE, now(),
                0, 0, 0,
                0, 0,
                0, 0,
                0,
                0, 0,
                0, 0)
        ON CONFLICT (singleton) DO UPDATE SET generated_at = now()
    `
	if _, err := adminDB.Exec(q); err != nil {
		t.Fatalf("seed fresh overview: %v", err)
	}
}

// seedFreshHealthAll updates every stats_components_health row's
// generated_at to now so the §5.3 status derives to "ok".
func seedFreshHealthAll(t *testing.T, adminDB *sql.DB) {
	t.Helper()
	const q = `UPDATE stats_components_health SET generated_at = now(), last_ok_at = now()`
	if _, err := adminDB.Exec(q); err != nil {
		t.Fatalf("seed fresh health: %v", err)
	}
}

// seedAgedOverview backdates `stats_overview_current.generated_at`
// for the AC-14 503 fixture.
func seedAgedOverview(t *testing.T, adminDB *sql.DB, ageSeconds int) {
	t.Helper()
	if _, err := adminDB.Exec(
		`UPDATE stats_overview_current SET generated_at = now() - ($1::text || ' seconds')::interval`,
		fmt.Sprintf("%d", ageSeconds),
	); err != nil {
		t.Fatalf("age overview: %v", err)
	}
}

// ===========================================================================
// AC-1 — /v1/stats/overview JSON shape (14 network fields + 30-point
//
//	rpm_30m.points / tpm_30m.points with `t` timestamps).
//
// ===========================================================================
func TestAC1_OverviewJSONShape(t *testing.T) {
	h, _ := setupStatsHandler(t)
	resp := mustDo(t, h, http.MethodGet, "/v1/stats/overview", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var body map[string]any
	mustDecode(t, resp, &body)
	for _, k := range []string{"generated_at", "stale_after", "network", "timeseries"} {
		if _, ok := body[k]; !ok {
			t.Errorf("top-level %q missing", k)
		}
	}
	net, ok := body["network"].(map[string]any)
	if !ok {
		t.Fatalf("network missing or not object")
	}
	required := []string{
		"tokens_served_total", "tokens_in_total", "tokens_out_total",
		"requests_total", "nodes_online", "nodes_hardware_attested",
		"bandwidth_gb_per_s", "network_power_kw",
		"network_utilization_pct", "gpu_cores_total", "cpu_cores_total",
		"unified_ram_gb_total", "avg_tokens_per_request", "models_serving",
	}
	if len(net) != len(required) {
		t.Errorf("network has %d fields, want %d", len(net), len(required))
	}
	for _, k := range required {
		if _, ok := net[k]; !ok {
			t.Errorf("network.%s missing", k)
		}
	}
	ts, ok := body["timeseries"].(map[string]any)
	if !ok {
		t.Fatalf("timeseries missing")
	}
	for _, k := range []string{"rpm_30m", "tpm_30m"} {
		sub, ok := ts[k].(map[string]any)
		if !ok {
			t.Errorf("timeseries.%s missing or not object", k)
			continue
		}
		pts, ok := sub["points"].([]any)
		if !ok {
			t.Errorf("timeseries.%s.points missing or not array", k)
			continue
		}
		if len(pts) != 30 {
			t.Errorf("timeseries.%s.points len = %d, want 30", k, len(pts))
		}
	}
}

// ===========================================================================
// AC-2 — window default 24h + invalid window → 400.
// ===========================================================================
func TestAC2_LeaderboardWindowValidation(t *testing.T) {
	h, _ := setupStatsHandler(t)
	resp := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("default window expected 200, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var body map[string]any
	mustDecode(t, resp, &body)
	if body["window"] != "24h" {
		t.Errorf("default window = %v, want 24h", body["window"])
	}
	resp = mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard?window=foo", nil)
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("invalid window expected 400, got %d", resp.StatusCode)
	}
	var ev map[string]any
	mustDecode(t, resp, &ev)
	if errObj, ok := ev["error"].(map[string]any); !ok || errObj["code"] != "bad_request" {
		t.Errorf("expected error.code=bad_request, got %v", ev)
	}
}

// ===========================================================================
// AC-3 — invalid Bearer → 401.
// ===========================================================================
func TestAC3_InvalidBearer401(t *testing.T) {
	h, _ := setupStatsHandler(t)
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer mpk_invalid_xyz")
	resp := mustDoWithHeaders(t, h, http.MethodGet, "/v1/stats/leaderboard", hdr)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", resp.StatusCode)
	}
	var ev map[string]any
	mustDecode(t, resp, &ev)
	if errObj, ok := ev["error"].(map[string]any); !ok || errObj["code"] != "unauthorized" {
		t.Errorf("expected error.code=unauthorized, got %v", ev)
	}
}

// Malformed Authorization (NOT starting with `Bearer `) → 401.
func TestMalformedAuth401(t *testing.T) {
	h, _ := setupStatsHandler(t)
	hdr := http.Header{}
	hdr.Set("Authorization", "Basic dXNlcjpwYXNz")
	resp := mustDoWithHeaders(t, h, http.MethodGet, "/v1/stats/leaderboard", hdr)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("malformed Auth expected 401, got %d", resp.StatusCode)
	}
}

// ===========================================================================
// AC-13 — OPTIONS preflight returns 204 + Max-Age=60.
// ===========================================================================
func TestAC13_OptionsPreflight(t *testing.T) {
	h, _ := setupStatsHandler(t)
	resp := mustDo(t, h, http.MethodOptions, "/v1/stats/leaderboard", nil)
	if resp.StatusCode != http.StatusNoContent {
		t.Errorf("expected 204, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Max-Age"); got != "60" {
		t.Errorf("Access-Control-Max-Age = %q, want 60", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Methods"); got != "GET, HEAD, OPTIONS" {
		t.Errorf("Access-Control-Allow-Methods = %q", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Headers"); got != "Authorization, Content-Type" {
		t.Errorf("Access-Control-Allow-Headers = %q", got)
	}
}

// ===========================================================================
// AC-14 — overview generated_at > 120s → 503 + Retry-After.
// ===========================================================================
func TestAC14_OverviewStale503(t *testing.T) {
	h, adminDB := setupStatsHandler(t)
	seedAgedOverview(t, adminDB, 130)
	resp := mustDo(t, h, http.MethodGet, "/v1/stats/overview", nil)
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Errorf("expected 503, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	if got := resp.Header.Get("Retry-After"); got != "30" {
		t.Errorf("Retry-After = %q, want 30", got)
	}
	var ev map[string]any
	mustDecode(t, resp, &ev)
	if errObj, ok := ev["error"].(map[string]any); !ok || errObj["code"] != "stats_stale" {
		t.Errorf("expected error.code=stats_stale, got %v", ev)
	}
	if errObj, ok := ev["error"].(map[string]any); ok {
		if r, ok := errObj["retry_after_seconds"].(float64); !ok || int(r) != 30 {
			t.Errorf("expected retry_after_seconds=30, got %v", errObj["retry_after_seconds"])
		}
	}
}

// ===========================================================================
// AC-21 — POST → 405 with Allow + method_not_allowed envelope.
// ===========================================================================
func TestAC21_MethodNotAllowed(t *testing.T) {
	h, _ := setupStatsHandler(t)
	resp := mustDo(t, h, http.MethodPost, "/v1/stats/overview", nil)
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Errorf("expected 405, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Allow"); got != "GET, HEAD, OPTIONS" {
		t.Errorf("Allow = %q", got)
	}
	var ev map[string]any
	mustDecode(t, resp, &ev)
	if errObj, ok := ev["error"].(map[string]any); !ok || errObj["code"] != "method_not_allowed" {
		t.Errorf("expected error.code=method_not_allowed, got %v", ev)
	}
}

// HEAD support — same headers as GET, empty body.
func TestHEADReturnsSameHeadersEmptyBody(t *testing.T) {
	h, _ := setupStatsHandler(t)
	for _, path := range []string{"/v1/stats/leaderboard", "/v1/stats/health", "/v1/stats/overview"} {
		t.Run(path, func(t *testing.T) {
			get := mustDo(t, h, http.MethodGet, path, nil)
			head := mustDo(t, h, http.MethodHead, path, nil)
			if head.StatusCode != get.StatusCode {
				t.Errorf("HEAD status %d != GET status %d", head.StatusCode, get.StatusCode)
			}
			for _, name := range []string{"Content-Type", "Cache-Control", "ETag", "Vary", "X-Stats-Generated-At"} {
				if got, want := head.Header.Get(name), get.Header.Get(name); got != want {
					t.Errorf("HEAD header %s = %q, GET = %q", name, got, want)
				}
			}
			if b := readBody(t, head); len(b) != 0 {
				t.Errorf("HEAD body length = %d, want 0", len(b))
			}
		})
	}
}

// Public projection: totals.earnings_* MUST NOT appear.
func TestPublicProjectionOmitsEarningsTotals(t *testing.T) {
	h, _ := setupStatsHandler(t)
	resp := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var body map[string]any
	mustDecode(t, resp, &body)
	totals, ok := body["totals"].(map[string]any)
	if !ok {
		t.Fatalf("totals missing")
	}
	for _, k := range []string{"earnings_usd", "earnings_work_usd", "earnings_rewards_usd"} {
		if _, present := totals[k]; present {
			t.Errorf("public projection has totals.%s — must be partner-only", k)
		}
	}
}

// 304 round-trip on If-None-Match.
func TestAC12_304IfNoneMatch(t *testing.T) {
	h, _ := setupStatsHandler(t)
	first := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard", nil)
	if first.StatusCode != http.StatusOK {
		t.Fatalf("first request not 200, got %d", first.StatusCode)
	}
	etag := first.Header.Get("ETag")
	if etag == "" {
		t.Fatalf("ETag missing on first response")
	}
	hdr := http.Header{}
	hdr.Set("If-None-Match", etag)
	second := mustDoWithHeaders(t, h, http.MethodGet, "/v1/stats/leaderboard", hdr)
	if second.StatusCode != http.StatusNotModified {
		t.Errorf("expected 304, got %d", second.StatusCode)
	}
	if got := second.Header.Get("X-Stats-Generated-At"); got != "" {
		t.Errorf("304 must NOT carry X-Stats-Generated-At, got %q", got)
	}
	if b := readBody(t, second); len(b) != 0 {
		t.Errorf("304 body must be empty, got %d bytes", len(b))
	}
}

// AC-7 — health 200 even when degraded.
func TestAC7_HealthAlways200(t *testing.T) {
	h, adminDB := setupStatsHandler(t)
	// Age overview to "down" range.
	if _, err := adminDB.Exec(
		`UPDATE stats_components_health SET generated_at = now() - interval '130 seconds' WHERE component = 'overview'`,
	); err != nil {
		t.Fatalf("age overview component: %v", err)
	}
	resp := mustDo(t, h, http.MethodGet, "/v1/stats/health", nil)
	if resp.StatusCode != http.StatusOK {
		t.Errorf("health expected 200 even when degraded, got %d", resp.StatusCode)
	}
	var body map[string]any
	mustDecode(t, resp, &body)
	if body["status"] != "down" {
		t.Errorf("status = %v, want down (overview > 120s)", body["status"])
	}
	if _, ok := body["rollup_lag_seconds"]; !ok {
		t.Errorf("rollup_lag_seconds missing from health")
	}
	comps, ok := body["components"].(map[string]any)
	if !ok || len(comps) != 7 {
		t.Errorf("components has %d keys, want 7: %v", len(comps), comps)
	}
}

// Test helpers
func mustDo(t *testing.T, h http.Handler, method, path string, hdr http.Header) *http.Response {
	t.Helper()
	if hdr == nil {
		hdr = http.Header{}
	}
	return mustDoWithHeaders(t, h, method, path, hdr)
}

func mustDoWithHeaders(t *testing.T, h http.Handler, method, path string, hdr http.Header) *http.Response {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	for k, v := range hdr {
		req.Header[k] = v
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, req)
	return w.Result()
}

func mustDecode(t *testing.T, resp *http.Response, into any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(into); err != nil {
		t.Fatalf("decode: %v", err)
	}
}

func readBody(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	return b
}

// Suppress unused-import warnings on helpers reserved for the
// adversarial-audit pass.
var _ = strings.HasPrefix
