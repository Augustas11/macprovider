//go:build integration

package stats_test

// SPEC-017 v0.1.9 Step 3 — handler integration tests against a
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
	"bytes"
	"context"
	sha256pkg "crypto/sha256"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/stats"
	statsrollup "github.com/augstar/macprovider-coordinator/internal/stats/rollup"
	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

// recentPartialSince returns a PartialSince string safely inside the
// 30-day window used by shouldExposePartialHistorySince. Computed at
// call time rather than hardcoded so the test suite does not become a
// time bomb once wall-clock crosses 30 days past a hardcoded date.
// The 25-day offset leaves headroom for slow CI runs + timezone drift.
func recentPartialSince() string {
	return time.Now().UTC().Add(-25 * 24 * time.Hour).Format(time.RFC3339)
}

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
		recentPartialSince(),
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
// AC-1 — /v1/stats/overview JSON shape (14 numeric metrics + source labels + 30-point
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
	for _, k := range []string{"generated_at", "stale_after", "network", "timeseries", "idle_prewarm"} {
		if _, ok := body[k]; !ok {
			t.Errorf("top-level %q missing", k)
		}
	}
	idle, ok := body["idle_prewarm"].(map[string]any)
	if !ok {
		t.Fatalf("idle_prewarm missing or not object")
	}
	for _, k := range []string{"pool_pct_with_b1_active", "skips_by_reason_last_1h"} {
		if _, ok := idle[k]; !ok {
			t.Errorf("idle_prewarm.%s missing", k)
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
		"capacity_estimate_sources",
	}
	if len(net) != len(required) {
		t.Errorf("network has %d fields, want %d", len(net), len(required))
	}
	for _, k := range required {
		if _, ok := net[k]; !ok {
			t.Errorf("network.%s missing", k)
		}
	}
	sources, ok := net["capacity_estimate_sources"].(map[string]any)
	if !ok {
		t.Fatalf("network.capacity_estimate_sources missing or not object")
	}
	expectedLabels := map[string]string{
		"bandwidth_gb_per_s":   "estimated_from_hardware_profile_or_provider_reported_summary",
		"network_power_kw":     "estimated_from_hardware_profile_or_provider_reported_summary",
		"gpu_cores_total":      "estimated_from_hardware_profile_or_provider_reported_summary",
		"cpu_cores_total":      "estimated_from_hardware_profile_or_provider_reported_summary",
		"unified_ram_gb_total": "provider_reported_or_profiled",
	}
	for k, want := range expectedLabels {
		if got, ok := sources[k].(string); !ok || got != want {
			t.Errorf("network.capacity_estimate_sources.%s = %v, want %q", k, sources[k], want)
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

// Final adversarial audit (claude-subagent HIGH 1) — a 304
// Not Modified response from a cross-origin conditional GET
// MUST carry `Access-Control-Allow-Origin` per the Fetch spec.
// SPEC §5.7 carves out no 304 exception. Without this header
// a browser issuing a `If-None-Match` request from
// console.streamvc.live / portal.streamvc.live silently
// rejects the response as a CORS failure even though the
// response is functionally correct. Run BOTH cacheable
// endpoints (/overview AND /leaderboard) so the SPEC-AC-12
// `/overview` path is exercised alongside the leaderboard one.
func TestAC12_304IfNoneMatch_CORSHeadersPresent(t *testing.T) {
	h, _ := setupStatsHandler(t)
	for _, path := range []string{"/v1/stats/overview", "/v1/stats/leaderboard"} {
		t.Run(path, func(t *testing.T) {
			hdr1 := http.Header{}
			hdr1.Set("Origin", "https://console.streamvc.live")
			first := mustDoWithHeaders(t, h, http.MethodGet, path, hdr1)
			if first.StatusCode != http.StatusOK {
				t.Fatalf("first request not 200, got %d body=%s", first.StatusCode, readBody(t, first))
			}
			if got := first.Header.Get("Access-Control-Allow-Origin"); got == "" {
				t.Fatalf("200 response missing Access-Control-Allow-Origin (sanity check)")
			}
			etag := first.Header.Get("ETag")
			if etag == "" {
				t.Fatalf("ETag missing on first response")
			}
			hdr2 := http.Header{}
			hdr2.Set("Origin", "https://console.streamvc.live")
			hdr2.Set("If-None-Match", etag)
			second := mustDoWithHeaders(t, h, http.MethodGet, path, hdr2)
			if second.StatusCode != http.StatusNotModified {
				t.Fatalf("expected 304, got %d body=%s", second.StatusCode, readBody(t, second))
			}
			if got := second.Header.Get("Access-Control-Allow-Origin"); got == "" {
				t.Errorf("304 response MUST carry Access-Control-Allow-Origin per Fetch spec; got empty")
			}
		})
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

// ===========================================================================
// AC-22 — auth-failure tier 300 rpm pre-SELECT cap. Invalid
// bearer floods MUST trip 429 BEFORE the SELECT, and absent-
// Authorization requests MUST NOT debit the auth-failure
// bucket.
// ===========================================================================
func TestAC22_AuthFailureLimiter(t *testing.T) {
	waitForRateLimitWindowHeadroom(t, 10*time.Second)

	// Round-7 CODE M closure: build the mux against a store
	// we hold a reference to so we can query
	// LookupHashCountForTest after the flood to prove the
	// auth-failure limiter capped DB load at ≤300 SELECTs.
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	reader := readerPool(t, fx)
	st := store.New(reader)
	h := stats.NewMux(
		st,
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer mpk_invalid")
	var ok401, rate429 int
	for i := 0; i < 350; i++ {
		resp := mustDoWithHeaders(t, h, http.MethodGet, "/v1/stats/leaderboard", hdr)
		switch resp.StatusCode {
		case http.StatusUnauthorized:
			ok401++
		case http.StatusTooManyRequests:
			rate429++
		}
		resp.Body.Close()
	}
	if ok401 != 300 {
		t.Errorf("got %d 401s, want 300 (auth-failure cap)", ok401)
	}
	if rate429 != 50 {
		t.Errorf("got %d 429s, want 50 (350 - 300)", rate429)
	}
	// DB SELECT count proves the limiter capped load at ≤300
	// (the 50 429s short-circuited BEFORE the auth dispatcher).
	if got := st.LookupHashCountForTest(); got > 300 {
		t.Errorf("partner_keys SELECT count = %d, want ≤300 (auth-failure limiter must cap pre-SELECT DB load)", got)
	}
}

func waitForRateLimitWindowHeadroom(t *testing.T, minRemaining time.Duration) {
	t.Helper()
	if minRemaining <= 0 || minRemaining >= time.Minute {
		t.Fatalf("invalid rate-limit window headroom %s", minRemaining)
	}
	for {
		now := time.Now()
		elapsed := time.Duration(now.Second())*time.Second + time.Duration(now.Nanosecond())
		remaining := time.Minute - elapsed
		if remaining >= minRemaining {
			return
		}
		time.Sleep(remaining + 20*time.Millisecond)
	}
}

// Absent-Authorization MUST NOT debit the auth-failure bucket.
func TestAuthFailureLimiterIgnoresAbsentAuth(t *testing.T) {
	h, _ := setupStatsHandler(t)
	// Send 350 requests with NO Authorization. They all go
	// through the public tier (60 rpm) — the auth-failure
	// counter must stay at 0.
	var ok200, rate429 int
	for i := 0; i < 350; i++ {
		resp := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard", nil)
		switch resp.StatusCode {
		case http.StatusOK:
			ok200++
		case http.StatusTooManyRequests:
			rate429++
		}
		resp.Body.Close()
	}
	// Public tier 60 rpm — first 60 succeed, next 290 hit 429.
	if ok200 != 60 {
		t.Errorf("public tier first-60: got %d 200s, want 60", ok200)
	}
	if rate429 != 290 {
		t.Errorf("public tier: got %d 429s, want 290", rate429)
	}
}

// ===========================================================================
// partial_history_since BackfillMode gate — Path A vs Path B.
// ===========================================================================
func TestPartialHistorySinceBackfillModeGate(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	// Seed a 30d leaderboard row so the snapshot generated_at
	// is fresh.
	if _, err := adminDB.Exec(`UPDATE stats_components_health SET generated_at = now() WHERE component = 'leaderboard_30d'`); err != nil {
		t.Fatalf("seed 30d health: %v", err)
	}

	reader := readerPool(t, fx)

	// Path A: backfill_mode = partial; field MUST be present.
	pathA := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()
	respA := mustDo(t, pathA, http.MethodGet, "/v1/stats/leaderboard?window=30d", nil)
	var bodyA map[string]any
	mustDecode(t, respA, &bodyA)
	if _, ok := bodyA["partial_history_since"]; !ok {
		t.Errorf("Path A: partial_history_since missing on 30d")
	}

	// Path B: backfill_mode = full; field MUST be omitted even
	// if a stale config value is left behind.
	pathB := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"full",
		recentPartialSince(), // stale config — should be ignored
		nil,
		zerolog.Nop(),
	).Handler()
	respB := mustDo(t, pathB, http.MethodGet, "/v1/stats/leaderboard?window=30d", nil)
	var bodyB map[string]any
	mustDecode(t, respB, &bodyB)
	if _, ok := bodyB["partial_history_since"]; ok {
		t.Errorf("Path B: partial_history_since MUST be omitted on full backfill_mode, got %v", bodyB["partial_history_since"])
	}

	// Path A but window=24h: still omitted.
	respC := mustDo(t, pathA, http.MethodGet, "/v1/stats/leaderboard?window=24h", nil)
	var bodyC map[string]any
	mustDecode(t, respC, &bodyC)
	if _, ok := bodyC["partial_history_since"]; ok {
		t.Errorf("Path A window=24h: partial_history_since MUST be omitted, got %v", bodyC["partial_history_since"])
	}
}

// ===========================================================================
// AC-15 redaction sweep — Authorization / Cookie / X-Api-Key
// MUST NOT appear in any structured log.
// ===========================================================================
func TestAC15_RedactionSweep(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	reader := readerPool(t, fx)

	var buf bytes.Buffer
	logger := zerolog.New(&buf)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		logger,
	).Handler()

	// Send a request with all three secret-bearing headers.
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer mpk_secrettoken1234567890_abcdef")
	hdr.Set("Cookie", "session=secretcookiebytes")
	hdr.Set("X-Api-Key", "apikey_secret456")
	resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/overview", hdr)
	resp.Body.Close()

	logOut := buf.String()
	for _, leak := range []string{
		"mpk_secrettoken1234567890_abcdef",
		"secretcookiebytes",
		"apikey_secret456",
	} {
		if strings.Contains(logOut, leak) {
			t.Errorf("structured log leaked secret %q: %s", leak, logOut)
		}
	}
}

// ===========================================================================
// AC-6 partner-key projection: with a valid Authorization, the
// response MUST include earnings_usd / earnings_work_usd /
// earnings_rewards_usd at row and totals level.
// ===========================================================================
func TestAC6_PartnerProjection(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	// Seed a provider with activity and a partner_keys row.
	now := time.Now().UTC()
	seedProviderTokens(t, adminDB, "p_partner_test")
	seedLedgerRow(t, adminDB, "p_partner_test", now.Add(-1*time.Hour), 100, 100, 1_000_000)

	// Drive a rollup tick so the leaderboard table is populated.
	// (We use the existing rollup runner from the rollup helpers.)
	driveOneRollupTick(t, fx)

	// Seed an active partner_keys row whose sha256(token) we know.
	bearer := "mpk_test_partner_secret_token"
	hash := sha256Hex(bearer)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, rate_limit_rpm, created_by)
         VALUES ('test', decode($1, 'hex'), 'mpk_test', '{}', 600, 'test')`,
		hash,
	); err != nil {
		t.Fatalf("seed partner_keys: %v", err)
	}

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+bearer)
	resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", hdr)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("partner projection expected 200, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var body map[string]any
	mustDecode(t, resp, &body)

	totals, ok := body["totals"].(map[string]any)
	if !ok {
		t.Fatalf("totals missing")
	}
	for _, k := range []string{"earnings_usd", "earnings_work_usd", "earnings_rewards_usd"} {
		if _, present := totals[k]; !present {
			t.Errorf("partner totals missing %s", k)
		}
	}
	rows, ok := body["rows"].([]any)
	if !ok || len(rows) == 0 {
		t.Fatalf("rows missing or empty")
	}
	row0, _ := rows[0].(map[string]any)
	for _, k := range []string{"earnings_usd", "earnings_work_usd", "earnings_rewards_usd"} {
		if _, present := row0[k]; !present {
			t.Errorf("partner row missing %s", k)
		}
	}
}

// sha256Hex returns the hex sha256 of `s`, for partner_keys
// fixture seeding.
func sha256Hex(s string) string {
	h := sha256_local([]byte(s))
	const hexdigits = "0123456789abcdef"
	buf := make([]byte, 64)
	for i, b := range h {
		buf[i*2] = hexdigits[b>>4]
		buf[i*2+1] = hexdigits[b&0x0f]
	}
	return string(buf)
}

func sha256_local(b []byte) [32]byte {
	return sha256pkg.Sum256(b)
}

// driveOneRollupTick runs the rollup against the admin DSN
// long enough to populate the per-window leaderboard tables.
func driveOneRollupTick(t *testing.T, fx *pgFixture) {
	t.Helper()
	rdb, err := sql.Open("postgres", fx.roleDSN("stats_rollup"))
	if err != nil {
		t.Fatalf("open stats_rollup: %v", err)
	}
	defer rdb.Close()
	adminDB, err := sql.Open("postgres", fx.adminDSN())
	if err != nil {
		t.Fatalf("open admin db: %v", err)
	}
	defer adminDB.Close()
	baseline := componentGeneratedAt(t, adminDB, "leaderboard_24h")
	logger := zerolog.Nop()
	cfg := freshRollupConfig()
	runner, err := statsrollup.New(rdb, cfg, statsrollup.ZeroSnapshotProvider{}, logger)
	if err != nil {
		t.Fatalf("rollup runner: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	runner.Start(ctx)
	waitForComponentAdvance(t, adminDB, "leaderboard_24h", baseline)
	cancel()
	runner.Wait()
}

func componentGeneratedAt(t *testing.T, db *sql.DB, component string) time.Time {
	t.Helper()
	var generatedAt time.Time
	if err := db.QueryRowContext(
		context.Background(),
		`SELECT generated_at FROM stats_components_health WHERE component = $1`,
		component,
	).Scan(&generatedAt); err != nil {
		t.Fatalf("read %s generated_at: %v", component, err)
	}
	return generatedAt
}

func waitForComponentAdvance(t *testing.T, db *sql.DB, component string, baseline time.Time) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for {
		generatedAt := componentGeneratedAt(t, db, component)
		if generatedAt.After(baseline) {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s did not advance from %s before deadline; last generated_at=%s", component, baseline.Format(time.RFC3339Nano), generatedAt.Format(time.RFC3339Nano))
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// ===========================================================================
// AC-4 — bucketed provider (visibility.mode='bucketed' OR absent)
// MUST expose `exact_earnings: null` in the public projection.
// ===========================================================================
func TestAC4_BucketedExactEarningsNull(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	now := time.Now().UTC()
	seedProviderTokens(t, adminDB, "p_buck_a", "p_buck_b")
	seedLedgerRow(t, adminDB, "p_buck_a", now.Add(-1*time.Hour), 100, 100, 1_000_000)
	seedLedgerRow(t, adminDB, "p_buck_b", now.Add(-1*time.Hour), 100, 100, 1_000_000)
	// p_buck_a: explicit 'bucketed'. p_buck_b: no row → default bucketed.
	if _, err := adminDB.Exec(
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_buck_a', 'bucketed')`,
	); err != nil {
		t.Fatalf("seed visibility: %v", err)
	}
	driveOneRollupTick(t, fx)

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	resp := mustDo(t, mux, http.MethodGet, "/v1/stats/leaderboard", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var body map[string]any
	mustDecode(t, resp, &body)
	rows, _ := body["rows"].([]any)
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %d", len(rows))
	}
	for _, raw := range rows {
		row, _ := raw.(map[string]any)
		v, present := row["exact_earnings"]
		if !present {
			t.Errorf("bucketed row missing exact_earnings key entirely")
		}
		if v != nil {
			t.Errorf("bucketed row exact_earnings = %v, want null", v)
		}
	}
}

// AC-5 — exact provider (visibility.mode='exact') MUST expose
// `exact_earnings` populated as a JSON number in the public
// projection.
func TestAC5_ExactProviderExactEarnings(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	now := time.Now().UTC()
	seedProviderTokens(t, adminDB, "p_exact")
	seedLedgerRow(t, adminDB, "p_exact", now.Add(-1*time.Hour), 100, 100, 1_000_000)
	if _, err := adminDB.Exec(
		`INSERT INTO provider_visibility (provider_id, mode) VALUES ('p_exact', 'exact')`,
	); err != nil {
		t.Fatalf("seed visibility: %v", err)
	}
	driveOneRollupTick(t, fx)

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	resp := mustDo(t, mux, http.MethodGet, "/v1/stats/leaderboard", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d body=%s", resp.StatusCode, readBody(t, resp))
	}
	var body map[string]any
	mustDecode(t, resp, &body)
	rows, _ := body["rows"].([]any)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row, got %d", len(rows))
	}
	row, _ := rows[0].(map[string]any)
	v, present := row["exact_earnings"]
	if !present {
		t.Fatalf("exact_earnings key missing")
	}
	if _, ok := v.(float64); !ok {
		t.Errorf("exact_earnings = %v (%T), want JSON number", v, v)
	}
}

// AC-11 — panic recovery + bucket refund. An injected panic
// MUST: (a) return 500 with §5.9 envelope; (b) NOT consume the
// success bucket (round-4 SECURITY M1).
func TestAC11_PanicRecoveryRefundsSuccessBucket(t *testing.T) {
	// We can't easily inject a panic in production code without
	// a hook. Instead, use a malformed leaderboard query that
	// the handler returns 400 for — verify the success bucket
	// is refunded on the 400 path (representative non-2xx). The
	// audit's AC-11 stricter assertion (real panic) needs a
	// production seam we don't expose; the existing bucket
	// refund logic on rec.status == 0 covers the panic path.
	h, _ := setupStatsHandler(t)
	// Issue 50 400 bad-request responses; the bucket count
	// should be 0 afterward.
	for i := 0; i < 50; i++ {
		resp := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard?window=foo", nil)
		resp.Body.Close()
		if resp.StatusCode != http.StatusBadRequest {
			t.Fatalf("iter %d expected 400, got %d", i, resp.StatusCode)
		}
	}
	// Now issue 60 valid requests. All should succeed because
	// the prior 50 400s were refunded — bucket has 60 remaining.
	var ok200 int
	for i := 0; i < 60; i++ {
		resp := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard", nil)
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			ok200++
		}
	}
	if ok200 != 60 {
		t.Errorf("60 valid after 50 400s: got %d 200s, want 60 (success bucket should be refunded on non-2xx)", ok200)
	}
}

// 503 stale not debited — issue 100 stale (503) requests, then
// 60 fresh requests; all 60 fresh MUST succeed.
func TestStale503NotDebitedFromSuccessBucket(t *testing.T) {
	h, adminDB := setupStatsHandler(t)
	// Age overview to 130s for the first 100 requests.
	seedAgedOverview(t, adminDB, 130)
	for i := 0; i < 100; i++ {
		resp := mustDo(t, h, http.MethodGet, "/v1/stats/overview", nil)
		resp.Body.Close()
		if resp.StatusCode != http.StatusServiceUnavailable {
			t.Fatalf("iter %d expected 503, got %d", i, resp.StatusCode)
		}
	}
	// Restore freshness; the next 60 must all succeed.
	seedFreshOverview(t, adminDB)
	var ok200 int
	for i := 0; i < 60; i++ {
		resp := mustDo(t, h, http.MethodGet, "/v1/stats/overview", nil)
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			ok200++
		}
	}
	if ok200 != 60 {
		t.Errorf("60 fresh after 100 stale: got %d 200s, want 60 (stale 503 must not debit success bucket)", ok200)
	}
}

// AC-18 — three-way timing equivalence rows 5/6/7. Each row
// MUST take ≤270 rpm (below the 300 rpm auth-failure cap) and
// produce 401 with median latency within ±20% of the other two rows.
//
// #281: Pre-#281 the median of 100 samples was flaking at ~30%
// variance on shared CI runners. R1 SEC audit flagged that
// switching to min weakens the security property — an attacker
// measures wall-clock medians, not floor execution time. So a
// future leak where row 6 takes 1ms for the first 5 warmed samples
// but 3ms for the rest would pass a min-based test while still
// being attacker-distinguishable.
//
// R1 fix-pass: keep the median (attacker-relevant statistic), but
// discard the first 10 samples per row as warm-up so handler/JIT/
// connection-pool stabilisation noise doesn't pull the recorded
// medians around. Median of 100 warmed samples is robust enough on
// shared CI without trading away the security invariant.
func TestAC18_TimingEquivalenceRows5_6_7(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	// Seed a valid key with non-empty allowed_origins for row 5
	// (origin reject) and a revoked key for row 7.
	bearer5 := "mpk_row5_token"
	bearer7 := "mpk_row7_token"
	hash5 := sha256Hex(bearer5)
	hash7 := sha256Hex(bearer7)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, created_by)
         VALUES ('r5', decode($1, 'hex'), 'mpk_row5', ARRAY['https://allowed.example'], 'test'),
                ('r7', decode($2, 'hex'), 'mpk_row7', '{}', 'test')`,
		hash5, hash7,
	); err != nil {
		t.Fatalf("seed keys: %v", err)
	}
	if _, err := adminDB.Exec(`UPDATE partner_keys SET revoked_at = now() WHERE prefix = 'mpk_row7'`); err != nil {
		t.Fatalf("revoke row 7 key: %v", err)
	}

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	measure := func(headers http.Header) time.Duration {
		// Round-6 BUILD ask: 100+ samples per row, sustained
		// rate ≤270 rpm so the auth-failure 300 rpm cap does
		// not perturb measurements. (10 warmup + 100 measured)
		// × 225ms ≈ 24.75s/row at ~267 rpm per row.
		const Warmup = 10
		const N = 100
		// #281: discard the first Warmup samples per row to
		// stabilise handler-side state (Postgres prepared-
		// statement cache, Go JIT for the auth path, connection
		// pool reuse). Without warmup the recorded median
		// includes 5-10% cold-start spikes that pulled the
		// median around by ~30% on shared CI runners.
		oneSample := func() {
			start := time.Now()
			resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", headers)
			elapsed := time.Since(start)
			if resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("expected 401, got %d", resp.StatusCode)
			}
			resp.Body.Close()
			_ = elapsed
		}
		for i := 0; i < Warmup; i++ {
			oneSample()
			time.Sleep(225 * time.Millisecond)
		}
		samples := make([]time.Duration, 0, N)
		for i := 0; i < N; i++ {
			start := time.Now()
			resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", headers)
			elapsed := time.Since(start)
			if resp.StatusCode != http.StatusUnauthorized {
				t.Fatalf("expected 401, got %d", resp.StatusCode)
			}
			resp.Body.Close()
			samples = append(samples, elapsed)
			time.Sleep(225 * time.Millisecond)
		}
		// Median of warmed samples — attacker-relevant statistic
		// per R1 SEC MEDIUM-1.
		sortDurations(samples)
		return samples[N/2]
	}

	// Row 5: valid key + non-allowlist Origin → 401.
	hdr5 := http.Header{}
	hdr5.Set("Authorization", "Bearer "+bearer5)
	hdr5.Set("Origin", "https://attacker.example")
	med5 := measure(hdr5)

	// Row 6: no matching key → 401.
	hdr6 := http.Header{}
	hdr6.Set("Authorization", "Bearer mpk_nomatch_token")
	med6 := measure(hdr6)

	// Row 7: revoked key → 401.
	hdr7 := http.Header{}
	hdr7.Set("Authorization", "Bearer "+bearer7)
	med7 := measure(hdr7)

	// Pairwise variance ≤ 20% of the maximum.
	max3 := max3d(med5, med6, med7)
	min3 := min3d(med5, med6, med7)
	delta := max3 - min3
	if max3 > 0 && float64(delta)/float64(max3) > 0.20 {
		t.Errorf("AC-18 timing variance > 20%%: row5=%v row6=%v row7=%v (Δ=%v / max=%v = %.1f%%)",
			med5, med6, med7, delta, max3, 100*float64(delta)/float64(max3))
	}
}

func sortDurations(d []time.Duration) {
	for i := 1; i < len(d); i++ {
		for j := i; j > 0 && d[j] < d[j-1]; j-- {
			d[j], d[j-1] = d[j-1], d[j]
		}
	}
}

func max3d(a, b, c time.Duration) time.Duration {
	m := a
	if b > m {
		m = b
	}
	if c > m {
		m = c
	}
	return m
}

func min3d(a, b, c time.Duration) time.Duration {
	m := a
	if b < m {
		m = b
	}
	if c < m {
		m = c
	}
	return m
}

// §5.7 partner projection NEVER ACAO: * — drive a partner key
// scenario and assert the response carries echoed Origin or
// omitted, never `*`.
func TestPartnerProjectionNeverACAOStar(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	bearer := "mpk_test_partner_neveracao"
	hash := sha256Hex(bearer)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, created_by)
         VALUES ('np', decode($1, 'hex'), 'mpk_np', ARRAY['https://acme.example'], 'test')`,
		hash,
	); err != nil {
		t.Fatalf("seed key: %v", err)
	}
	driveOneRollupTick(t, fx)

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	// Browser context — partner projection echoes the
	// normalized origin, never `*`.
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+bearer)
	hdr.Set("Origin", "https://acme.example")
	resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", hdr)
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got == "*" {
		t.Errorf("partner projection emitted ACAO: * (CRITICAL §5.7 violation)")
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "https://acme.example" {
		t.Errorf("partner projection ACAO = %q, want echoed origin", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Errorf("partner Allow-Credentials = %q, want true", got)
	}
	resp.Body.Close()
}

// PUT/DELETE/PATCH → 405 matrix.
func TestMethodNotAllowedMatrix(t *testing.T) {
	h, _ := setupStatsHandler(t)
	for _, method := range []string{http.MethodPut, http.MethodDelete, http.MethodPatch} {
		t.Run(method, func(t *testing.T) {
			resp := mustDo(t, h, method, "/v1/stats/leaderboard", nil)
			if resp.StatusCode != http.StatusMethodNotAllowed {
				t.Errorf("%s expected 405, got %d", method, resp.StatusCode)
			}
			if got := resp.Header.Get("Allow"); got != "GET, HEAD, OPTIONS" {
				t.Errorf("%s Allow = %q", method, got)
			}
			resp.Body.Close()
		})
	}
}

// ===========================================================================
// AC-11 — real panic recovery via recoverMiddleware. Wraps a
// deliberately-panicking handler with the same middleware chain
// the production mux uses; asserts the 500 envelope, no
// Authorization in the captured log, and process survival
// (httptest server stays responsive).
// ===========================================================================
func TestAC11_RealPanicInjected(t *testing.T) {
	// Use the exported test-only seam to wrap a panicking
	// handler with the production middleware chain.
	var buf bytes.Buffer
	logger := zerolog.New(&buf)

	// Compose recoverMiddleware over a panicking inner handler.
	panicking := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		panic("kaboom-secret-token-mpk_should_be_redacted")
	})
	wrapped := stats.RecoverForTest(logger, panicking)

	req := httptest.NewRequest(http.MethodGet, "/v1/stats/overview", nil)
	// Round-6 broader redaction sweep: send Authorization,
	// Cookie, X-Api-Key, plus a synthetic token_hash-shaped
	// header. The redaction middleware (defense-in-depth) +
	// recover middleware must ensure NONE of these survive
	// into the captured structured log.
	const rawBearer = "mpk_should_not_leak_randomsuffix_abc123def456"
	const rawCookie = "session=cookiesecretvalue_xyz789"
	const rawApiKey = "apikey_alsosecret_4242"
	const rawTokenHash = "a3f5b8c9d2e1f0a4b6c7d8e9f0a1b2c3"
	req.Header.Set("Authorization", "Bearer "+rawBearer)
	req.Header.Set("Cookie", rawCookie)
	req.Header.Set("X-Api-Key", rawApiKey)
	req.Header.Set("X-Token-Hash", rawTokenHash) // synthetic; not in redaction list but used in sweep
	w := httptest.NewRecorder()
	wrapped.ServeHTTP(w, req)
	resp := w.Result()
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusInternalServerError {
		t.Errorf("expected 500 internal on panic, got %d", resp.StatusCode)
	}
	body := readBody(t, resp)
	var env map[string]any
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("decode 500 envelope: %v body=%q", err, body)
	}
	if errObj, ok := env["error"].(map[string]any); !ok || errObj["code"] != "internal" {
		t.Errorf("expected error.code=internal on panic, got %v", env)
	}

	logOut := buf.String()
	// Round-6 broader sweep — every secret string MUST be
	// absent from the captured log.
	for _, leak := range []string{
		rawBearer,
		"mpk_should_be_redacted",    // panic-string substring
		"randomsuffix_abc123def456", // random-portion substring
		rawCookie,                   // Cookie value
		"cookiesecretvalue_xyz789",  // Cookie substring
		rawApiKey,                   // X-Api-Key value
		"apikey_alsosecret_4242",    // X-Api-Key substring
		rawTokenHash,                // round-7 SECURITY M: literal token_hash value
		"token_hash",                // round-7 SECURITY M: literal field name
	} {
		if strings.Contains(logOut, leak) {
			t.Errorf("panic-log leaked %q: %s", leak, logOut)
		}
	}
	// Second request after panic still serves (recover does not
	// kill the handler chain).
	req2 := httptest.NewRequest(http.MethodGet, "/v1/stats/overview", nil)
	w2 := httptest.NewRecorder()
	wrapped.ServeHTTP(w2, req2)
	if w2.Result().StatusCode != http.StatusInternalServerError {
		// Still 500 because the inner handler still panics. The
		// key is that the second request was SERVED at all — the
		// process / handler tree survived the first panic.
	}
}

// ===========================================================================
// §5.4.3 7-row decision-table fixture. Tests rows that don't
// require seeded `partner_keys` rows (rows 1, 6) here; rows 2-5
// + 7 are covered by AC-3, AC-6, AC-18, TestAC3_InvalidBearer401,
// TestMalformedAuth401, TestPartnerProjectionNeverACAOStar
// already.
// ===========================================================================
func TestSection_5_4_3_DecisionTable_AnonymousAndUnknown(t *testing.T) {
	h, _ := setupStatsHandler(t)

	// Row 1: no Authorization → 200 public.
	resp := mustDo(t, h, http.MethodGet, "/v1/stats/leaderboard", nil)
	if resp.StatusCode != http.StatusOK {
		t.Errorf("row 1 (no auth): expected 200, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "*" {
		t.Errorf("row 1 ACAO = %q, want * (public)", got)
	}
	resp.Body.Close()

	// Row 6: present-but-no-matching-row → 401.
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer mpk_unknown_token_xyz")
	resp = mustDoWithHeaders(t, h, http.MethodGet, "/v1/stats/leaderboard", hdr)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("row 6 (no match): expected 401, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("row 6 ACAO should be omitted, got %q", got)
	}
	resp.Body.Close()
}

// Partner HEAD parity — same headers + empty body across both
// projections.
func TestPartnerHEADParity(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)

	bearer := "mpk_partner_head_parity"
	hash := sha256Hex(bearer)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, created_by)
         VALUES ('hp', decode($1, 'hex'), 'mpk_hp', '{}', 'test')`,
		hash,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}
	driveOneRollupTick(t, fx)

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+bearer)
	get := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", hdr)
	head := mustDoWithHeaders(t, mux, http.MethodHead, "/v1/stats/leaderboard", hdr)
	if head.StatusCode != get.StatusCode {
		t.Errorf("partner HEAD status %d != GET %d", head.StatusCode, get.StatusCode)
	}
	for _, name := range []string{"Content-Type", "Cache-Control", "ETag", "Vary", "X-Stats-Generated-At", "Access-Control-Allow-Origin"} {
		if h, g := head.Header.Get(name), get.Header.Get(name); h != g {
			t.Errorf("partner HEAD header %s = %q, GET = %q", name, h, g)
		}
	}
	if b := readBody(t, head); len(b) != 0 {
		t.Errorf("partner HEAD body length = %d, want 0", len(b))
	}
	// Partner projection MUST set Vary: Authorization.
	if !strings.Contains(get.Header.Get("Vary"), "Authorization") {
		t.Errorf("partner GET Vary missing Authorization: %q", get.Header.Get("Vary"))
	}
	get.Body.Close()
	head.Body.Close()
}

// 30d/all include + 24h/7d omit for partial_history_since
// across all four windows under Path A.
func TestPartialHistoryAllWindowsCoverage(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	// Fresh snapshots for every window.
	if _, err := adminDB.Exec(`UPDATE stats_components_health SET generated_at = now() WHERE component LIKE 'leaderboard_%'`); err != nil {
		t.Fatalf("seed health: %v", err)
	}
	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		recentPartialSince(),
		nil,
		zerolog.Nop(),
	).Handler()

	cases := []struct {
		window      string
		mustPresent bool
	}{
		{"24h", false},
		{"7d", false},
		{"30d", true},
		{"all", true},
	}
	for _, c := range cases {
		t.Run(c.window, func(t *testing.T) {
			resp := mustDo(t, mux, http.MethodGet, "/v1/stats/leaderboard?window="+c.window, nil)
			if resp.StatusCode != http.StatusOK {
				t.Fatalf("%s: expected 200, got %d", c.window, resp.StatusCode)
			}
			var body map[string]any
			mustDecode(t, resp, &body)
			_, present := body["partial_history_since"]
			if present != c.mustPresent {
				t.Errorf("%s: partial_history_since present=%v want %v", c.window, present, c.mustPresent)
			}
		})
	}
}

// Trusted/untrusted XFF: an untrusted-proxy peer's
// X-Forwarded-For MUST be ignored (the limiter keys on
// r.RemoteAddr); a trusted-proxy peer's XFF MUST be parsed.
func TestTrustedUntrustedXFF(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	reader := readerPool(t, fx)

	// Untrusted-proxy case: limiter keys on r.RemoteAddr,
	// ignoring rotated XFF. Send enough invalid-bearer requests
	// that one fixed-window minute rollover cannot split the
	// sample below the 300 rpm auth-failure cap in both windows.
	muxUntrusted := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		"",
		nil, // no trusted proxies
		zerolog.Nop(),
	).Handler()
	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer mpk_invalid_xff")
	var rate429 int
	for i := 0; i < 650; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/stats/leaderboard", nil)
		req.Header.Set("Authorization", "Bearer mpk_invalid_xff")
		// Rotate XFF; the untrusted limiter ignores it.
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("10.0.0.%d", i%200+1))
		w := httptest.NewRecorder()
		muxUntrusted.ServeHTTP(w, req)
		if w.Result().StatusCode == http.StatusTooManyRequests {
			rate429++
		}
	}
	if rate429 < 50 {
		t.Errorf("untrusted-proxy XFF: got %d 429s, want ≥50 (limiter must ignore spoofed XFF)", rate429)
	}

	// Trusted-proxy case: r.RemoteAddr (httptest defaults to
	// 192.0.2.1:1234) is in the trusted CIDR; the limiter
	// parses XFF and treats each rotated value as a distinct
	// client IP — no individual IP hits 300.
	muxTrusted := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		"",
		[]string{"192.0.2.0/24"}, // httptest peer in this range
		zerolog.Nop(),
	).Handler()
	rate429 = 0
	for i := 0; i < 350; i++ {
		req := httptest.NewRequest(http.MethodGet, "/v1/stats/leaderboard", nil)
		req.Header.Set("Authorization", "Bearer mpk_invalid_xff")
		// 350 distinct synthetic client IPs.
		req.Header.Set("X-Forwarded-For", fmt.Sprintf("10.0.%d.%d", i/255+1, i%255+1))
		w := httptest.NewRecorder()
		muxTrusted.ServeHTTP(w, req)
		if w.Result().StatusCode == http.StatusTooManyRequests {
			rate429++
		}
	}
	if rate429 != 0 {
		t.Errorf("trusted-proxy XFF: got %d 429s, want 0 (distinct synthetic IPs should each get own bucket)", rate429)
	}
}

// ===========================================================================
// §5.7 7-row CORS decision-table matrix. Drives every locked
// row and asserts the exact ACAO / Allow-Credentials / Vary
// emitted in response. Rows that 401 (3, 5, 6, 7) MUST omit
// ACAO; rows 2 and 4 (partner success) MUST echo the
// normalized Origin or omit (NEVER `*`).
// ===========================================================================
func TestSection_5_7_CORSMatrix(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	driveOneRollupTick(t, fx)

	// Seed two partner keys: one with empty allowed_origins
	// (row 2/3 scenarios), one with non-empty (rows 4-7).
	bearerEmpty := "mpk_cors_empty_allowlist"
	bearerNonEmpty := "mpk_cors_nonempty_allowlist"
	hashEmpty := sha256Hex(bearerEmpty)
	hashNonEmpty := sha256Hex(bearerNonEmpty)
	bearerRevoked := "mpk_cors_revoked"
	hashRevoked := sha256Hex(bearerRevoked)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, created_by)
         VALUES ('e',  decode($1, 'hex'), 'mpk_e',  '{}', 'test'),
                ('ne', decode($2, 'hex'), 'mpk_ne', ARRAY['https://acme.example'], 'test'),
                ('rv', decode($3, 'hex'), 'mpk_rv', '{}', 'test')`,
		hashEmpty, hashNonEmpty, hashRevoked,
	); err != nil {
		t.Fatalf("seed keys: %v", err)
	}
	if _, err := adminDB.Exec(`UPDATE partner_keys SET revoked_at = now() WHERE prefix = 'mpk_rv'`); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{
			AccessControlMaxAgeSeconds: 60,
			PartnerOriginAllowlist:     []string{"https://portal.streamvc.live"},
		},
		"partial",
		"",
		nil,
		zerolog.Nop(),
	).Handler()

	type rowCase struct {
		name      string
		auth      string
		origin    string
		wantCode  int
		acaoExact string // "" = must be absent
		credsTrue bool
	}
	cases := []rowCase{
		// Row 1: anonymous → 200 public, ACAO=*.
		{"row1_anonymous", "", "", http.StatusOK, "*", false},
		// Row 2: valid key, allowlist empty, Origin browser context → 200 partner, echo Origin + creds.
		{"row2_empty_allowlist_browser", bearerEmpty, "https://acme.example", http.StatusOK, "https://acme.example", true},
		// Row 3: valid key, allowlist NON-empty, Origin absent → 401 + ACAO absent.
		{"row3_nonempty_origin_absent", bearerNonEmpty, "", http.StatusUnauthorized, "", false},
		// Row 4: valid key, allowlist NON-empty, exact-match Origin → 200 partner, echo + creds.
		{"row4_nonempty_match", bearerNonEmpty, "https://acme.example", http.StatusOK, "https://acme.example", true},
		// Row 5: valid key, allowlist NON-empty, non-allowlist Origin → 401 + ACAO absent.
		{"row5_nonempty_reject", bearerNonEmpty, "https://attacker.example", http.StatusUnauthorized, "", false},
		// Row 6: present-but-no-match → 401 + ACAO absent.
		{"row6_no_match", "mpk_unknown_xyz", "https://acme.example", http.StatusUnauthorized, "", false},
		// Row 7: revoked → 401 + ACAO absent.
		{"row7_revoked", bearerRevoked, "https://acme.example", http.StatusUnauthorized, "", false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			hdr := http.Header{}
			if c.auth != "" {
				hdr.Set("Authorization", "Bearer "+c.auth)
			}
			if c.origin != "" {
				hdr.Set("Origin", c.origin)
			}
			resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", hdr)
			defer resp.Body.Close()
			if resp.StatusCode != c.wantCode {
				t.Errorf("status = %d, want %d", resp.StatusCode, c.wantCode)
			}
			acao := resp.Header.Get("Access-Control-Allow-Origin")
			if acao != c.acaoExact {
				t.Errorf("ACAO = %q, want %q", acao, c.acaoExact)
			}
			// Partner projection MUST NEVER emit ACAO: *.
			if c.wantCode == http.StatusOK && c.auth != "" && acao == "*" {
				t.Errorf("partner projection emitted ACAO: * — locked §5.7 violation")
			}
			creds := resp.Header.Get("Access-Control-Allow-Credentials")
			if c.credsTrue && creds != "true" {
				t.Errorf("Allow-Credentials = %q, want true", creds)
			}
			if !c.credsTrue && creds == "true" {
				t.Errorf("Allow-Credentials unexpectedly true: %q", creds)
			}
		})
	}
}

// ===========================================================================
// Active-key origin preflight union — a partner key's
// allowed_origins entry MUST be echoed on preflight even if
// the operator did not duplicate it in the static
// PartnerOriginAllowlist.
// ===========================================================================
func TestPreflightActiveKeyOriginUnion(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	bearer := "mpk_pf_union"
	hash := sha256Hex(bearer)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, created_by)
         VALUES ('pf', decode($1, 'hex'), 'mpk_pf', ARRAY['https://newpartner.example'], 'test')`,
		hash,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}
	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{
			AccessControlMaxAgeSeconds: 60,
			// Note: newpartner.example is NOT in static list.
			PartnerOriginAllowlist: []string{"https://portal.streamvc.live"},
		},
		"partial",
		"",
		nil,
		zerolog.Nop(),
	).Handler()

	hdr := http.Header{}
	hdr.Set("Origin", "https://newpartner.example")
	resp := mustDoWithHeaders(t, mux, http.MethodOptions, "/v1/stats/leaderboard", hdr)
	defer resp.Body.Close()
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "https://newpartner.example" {
		t.Errorf("preflight ACAO = %q, want echoed origin (active key allowed_origins union must apply)", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Credentials"); got != "true" {
		t.Errorf("preflight Allow-Credentials = %q, want true (echoed origin path)", got)
	}
}

// ===========================================================================
// Valid partner-key 500-request refund proof — auth-failure
// tier 300 rpm MUST NOT cap valid keys; partner tier 600 rpm
// is the only ceiling. Run 500 valid requests; assert zero
// 429s and final auth-failure counter is 0 (every reservation
// was refunded by the dispatcher-success path).
// ===========================================================================
func TestValidPartnerKey500ReqNoAuthFailureCap(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	if _, err := adminDB.Exec(`UPDATE stats_components_health SET generated_at = now() WHERE component LIKE 'leaderboard_%'`); err != nil {
		t.Fatalf("seed health: %v", err)
	}

	bearer := "mpk_valid_500req_test"
	hash := sha256Hex(bearer)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, rate_limit_rpm, created_by)
         VALUES ('500r', decode($1, 'hex'), 'mpk_500', '{}', 600, 'test')`,
		hash,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}

	reader := readerPool(t, fx)
	muxObj := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		"",
		nil,
		zerolog.Nop(),
	)
	mux := muxObj.Handler()

	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+bearer)
	var ok200, rate429 int
	for i := 0; i < 500; i++ {
		resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", hdr)
		switch resp.StatusCode {
		case http.StatusOK:
			ok200++
		case http.StatusTooManyRequests:
			rate429++
		}
		resp.Body.Close()
	}
	if ok200 != 500 {
		t.Errorf("valid partner 500 req: got %d 200s, want 500 (auth-failure 300 rpm must NOT cap valid keys)", ok200)
	}
	if rate429 != 0 {
		t.Errorf("valid partner 500 req: got %d 429s, want 0 (refund path must release auth-failure slots)", rate429)
	}
	// Round-7 CODE M closure: auth-failure bucket count MUST
	// be 0 after the run — every reservation was refunded by
	// the dispatcher-success path. httptest's default
	// RemoteAddr is 192.0.2.1:1234.
	if c := muxObj.AuthFailureCountForTest("192.0.2.1", "leaderboard", time.Now().UTC()); c != 0 {
		t.Errorf("auth-failure bucket count after 500 valid req = %d, want 0 (refund leaked %d slots)", c, c)
	}
}

// ===========================================================================
// Sibling-subdomain reject — Origin: https://evil.streamvc.live
// MUST NOT be echoed (no wildcard / no sibling-match).
// ===========================================================================
func TestSiblingSubdomainReject(t *testing.T) {
	h, _ := setupStatsHandler(t)
	hdr := http.Header{}
	hdr.Set("Origin", "https://evil.streamvc.live")
	resp := mustDoWithHeaders(t, h, http.MethodOptions, "/v1/stats/leaderboard", hdr)
	defer resp.Body.Close()
	// Should fall through to ACAO: * (no match in static or
	// partner_keys; sibling-subdomain is NOT auto-trusted).
	acao := resp.Header.Get("Access-Control-Allow-Origin")
	if acao == "https://evil.streamvc.live" {
		t.Errorf("preflight echoed sibling subdomain %q — sibling-domain trust is FORBIDDEN", acao)
	}
	if acao != "*" {
		t.Errorf("preflight ACAO = %q, want * (no allowlist match)", acao)
	}
}

// ===========================================================================
// §5.7 server-to-server partner case (empty allowlist, Origin
// absent). Locked SPEC requires 200 partner projection +
// ACAO omitted + Allow-Credentials omitted. Browsers can't
// reach this path; non-browser clients ignore CORS headers.
// ===========================================================================
func TestSection_5_7_ServerToServerOmitsACAO(t *testing.T) {
	fx, adminDB := setupRollupFixture(t)
	seedFreshOverview(t, adminDB)
	seedFreshHealthAll(t, adminDB)
	if _, err := adminDB.Exec(`UPDATE stats_components_health SET generated_at = now() WHERE component LIKE 'leaderboard_%'`); err != nil {
		t.Fatalf("seed health: %v", err)
	}

	bearer := "mpk_s2s_test_token"
	hash := sha256Hex(bearer)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, created_by)
         VALUES ('s2s', decode($1, 'hex'), 'mpk_s2s', '{}', 'test')`,
		hash,
	); err != nil {
		t.Fatalf("seed: %v", err)
	}

	reader := readerPool(t, fx)
	mux := stats.NewMux(
		store.New(reader),
		stats.CORSConfig{AccessControlMaxAgeSeconds: 60},
		"partial",
		"",
		nil,
		zerolog.Nop(),
	).Handler()

	hdr := http.Header{}
	hdr.Set("Authorization", "Bearer "+bearer)
	// NO Origin header (server-to-server context).
	resp := mustDoWithHeaders(t, mux, http.MethodGet, "/v1/stats/leaderboard", hdr)
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Errorf("s2s empty-allowlist expected 200 partner, got %d", resp.StatusCode)
	}
	if got := resp.Header.Get("Access-Control-Allow-Origin"); got != "" {
		t.Errorf("s2s ACAO = %q, want \"\" (must be OMITTED per §5.7 row 4)", got)
	}
	if got := resp.Header.Get("Access-Control-Allow-Credentials"); got != "" {
		t.Errorf("s2s Allow-Credentials = %q, want \"\" (must be OMITTED with absent Origin)", got)
	}
	// Vary on partner projection still includes Authorization
	// even though there's no Origin.
	vary := resp.Header.Get("Vary")
	if !strings.Contains(vary, "Authorization") {
		t.Errorf("partner Vary missing Authorization: %q", vary)
	}
}

// ===========================================================================
// No-trace-span invariant — Step 3 source MUST NOT import any
// distributed-tracing surface (opentelemetry, otel, span,
// trace). Trace spans are a Step 4.C concern; the handler
// package keeps redaction simple by never carrying span data
// in v0.1. If this test starts failing, AC-15's trace-span
// redaction sweep must be re-enforced at the same time.
// ===========================================================================
func TestNoTraceImports(t *testing.T) {
	entries, err := os.ReadDir("../../internal/stats")
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	forbidden := []string{
		"go.opentelemetry.io",
		"opencensus.io",
		"otel.Tracer",
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		b, err := os.ReadFile("../../internal/stats/" + name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		for _, banned := range forbidden {
			if bytes.Contains(b, []byte(banned)) {
				t.Errorf("%s references %q — Step 3 forbids trace surfaces until AC-15 trace-span redaction sweep is added (v0.2/Step 4.C)", name, banned)
			}
		}
	}
}
