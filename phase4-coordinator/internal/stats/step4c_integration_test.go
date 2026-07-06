//go:build integration

package stats_test

// SPEC-017 v0.1.8 Step 4.C round-1 + round-3 fixes — wired-mux
// observability tests (ARCH M1 / CODE M1) + new event emission
// tests (CODE H5 + round-3 CODE M3).
//
// Reuses the testcontainers fixtures from integration_test.go /
// rollup_integration_test.go / handlers_integration_test.go (same
// package + build tag).

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/rs/zerolog"

	"github.com/augstar/macprovider-coordinator/internal/stats"
	statsmetrics "github.com/augstar/macprovider-coordinator/internal/stats/metrics"
	statsrollup "github.com/augstar/macprovider-coordinator/internal/stats/rollup"
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

	// Round-4 ARCH M1 / CODE M1 fix: use a SPEC-shaped 47-char
	// token (`mpk_` + 43 base64url chars) so any future regression
	// that lets the raw token or its 43-char body land in a metric
	// label is caught by both the 43-char body-shape regex AND the
	// expanded denylist below.
	const tokenBody = "AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwX" // 47 chars total mpk_... bytes
	bearer := "mpk_" + tokenBody[:43]
	prefix := bearer[:8]
	hash := sha256Hex(bearer)
	// Seed ledger + token data BEFORE the partner request so the
	// rollup tick produces a leaderboard_24h row and the partner
	// projection returns 200 (round-4 CODE M1 fix direction —
	// "assert the partner request returns 200").
	seedProviderTokens(t, adminDB, "p_step4c")
	seedLedgerRow(t, adminDB, "p_step4c", time.Now().UTC().Add(-1*time.Hour), 100, 100, 1_000_000)
	driveOneRollupTick(t, fx)
	if _, err := adminDB.Exec(
		`INSERT INTO partner_keys (label, token_hash, prefix, allowed_origins, rate_limit_rpm, created_by)
         VALUES ('step4c-wired', decode($1, 'hex'), $2, '{}', 600, 'test')`,
		hash, prefix,
	); err != nil {
		t.Fatalf("seed partner_keys: %v", err)
	}
	if got := doReq("/v1/stats/leaderboard?window=24h", bearer, ""); got != http.StatusOK {
		t.Fatalf("partner leaderboard expected 200, got %d", got)
	}

	// Round-2 CODE M1 fix: exercise all five required metric
	// families. The public-tier 60 rpm limiter fires on the
	// 61st `/v1/stats/overview` request from the same IP; drive
	// 65 to land at least one row in `stats_rate_limit_exceeded_total`.
	for i := 0; i < 65; i++ {
		_ = doReq("/v1/stats/overview", "", "")
	}

	// Round-3 ARCH M1 / CODE M2 fix: drive `stats_rollup_lag_seconds`
	// through the real production observer (one synchronous pass
	// over the §9.5 components against the reader DB) instead of a
	// synthetic Set() call.
	statsrollup.ObserveRollupLagOnce(context.Background(), readerDB, m)

	// Round-3 ARCH M1 / CODE M2 fix: drive `stats_rollup_errors_total`
	// through the real Runner.runOne error-path metric emit (NOT a
	// synthetic Inc()). Use an admin-DSN DB so healthFail can write
	// to stats_components_health for the failed tick.
	adminRollupDB := rollupDB(t, fx)
	runner, err := statsrollup.New(adminRollupDB, freshRollupConfig(), nil, zerolog.Nop())
	if err != nil {
		t.Fatalf("rollup.New: %v", err)
	}
	runner.WithMetrics(m)
	runner.RunTickOnceForTest(
		context.Background(),
		"leaderboard_24h", "leaderboard_24h",
		func(ctx context.Context) error { return errors.New("synthetic step4c tick error") },
	)
	m.IncIdlePrewarmEvent("idle_prewarm_fired", "")
	m.IncIdlePrewarmEvent("idle_prewarm_skipped", "not_idle_yet")

	families, err := reg.Gather()
	if err != nil {
		t.Fatalf("gather: %v", err)
	}
	// Round-4 ARCH M1 / CODE M1 fix: assert ALL five required
	// metric families landed at least one sample. Catches a future
	// regression that stops emitting one of them — the prior
	// "scan whatever is gathered" loop would silently pass when a
	// family was missing.
	requiredFamilies := []string{
		"stats_request_total",
		"stats_partner_key_request_total",
		"stats_rollup_lag_seconds",
		"stats_rollup_errors_total",
		"stats_rate_limit_exceeded_total",
		"stats_idle_prewarm_event_total",
	}
	seenFamilies := map[string]int{}
	for _, mf := range families {
		seenFamilies[mf.GetName()] = len(mf.GetMetric())
	}
	for _, req := range requiredFamilies {
		if seenFamilies[req] == 0 {
			t.Errorf("required metric family %q not present in gather (or had 0 samples); seen=%v",
				req, seenFamilies)
		}
	}

	bodyShape := regexp.MustCompile(`[A-Za-z0-9_-]{43}`)
	// Round-4 ARCH M1 / CODE M1 fix: deny list now includes the
	// actual seeded raw token + its 8-char prefix + the generic
	// `mpk_` fragment so a regression that places ANY token-
	// derived string in a label (e.g. labeling
	// stats_partner_key_request_total with partner_keys.prefix
	// instead of partner_keys.id) is caught.
	deny := []string{
		bearer, prefix, "mpk_",
		"mpk_garbage", "garbage", "evil.streamvc.live",
		"Bearer ", "token_hash",
	}
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

// TestStep4C_StatsHandlerPanicEvent — locked field set per BUILD
// §2 Step 4.C: `request_id`, `route`. NO `panic_type`, NO
// `_stack` event tag, NO `path`, NO `method`.
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
	// Round-2 ARCH M2: the panic event itself MUST NOT carry
	// extra fields beyond {route, request_id}. The debug-stack
	// log line (untagged) MAY carry panic_type; we filter the
	// Error-level line out of `out` by counting only stat-event
	// occurrences.
	statsEventLines := strings.Count(out, `"event":"stats_handler_panic"`)
	if statsEventLines != 1 {
		t.Fatalf("expected exactly 1 stats_handler_panic event; got %d: %q", statsEventLines, out)
	}
	// Extract the error-level line containing the event tag.
	for _, line := range strings.Split(out, "\n") {
		if !strings.Contains(line, `"event":"stats_handler_panic"`) {
			continue
		}
		if strings.Contains(line, `"panic_type"`) {
			t.Errorf("stats_handler_panic event contains forbidden panic_type field: %q", line)
		}
		if strings.Contains(line, `"method"`) {
			t.Errorf("stats_handler_panic event contains forbidden method field: %q", line)
		}
		if strings.Contains(line, `"path"`) {
			t.Errorf("stats_handler_panic event contains forbidden path field: %q", line)
		}
	}
}

// TestStep4C_StatsRollupTickCompletedEvent — round-3 CODE r3
// MEDIUM 3 fix: direct landing assertion that the success path of
// Runner.runOne emits `stats_rollup_tick_completed` with the
// locked field set {component, generated_at, duration_ms}.
func TestStep4C_StatsRollupTickCompletedEvent(t *testing.T) {
	fx, _ := setupRollupFixture(t)
	rdb := rollupDB(t, fx)

	var buf bytes.Buffer
	logger := zerolog.New(&buf)

	runner, err := statsrollup.New(rdb, freshRollupConfig(), nil, logger)
	if err != nil {
		t.Fatalf("rollup.New: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	// Drive a successful tick on a real §9.5 component.
	runner.RunTickOnceForTest(ctx, "overview", "overview",
		func(c context.Context) error { return nil })

	out := buf.String()
	if !strings.Contains(out, `"event":"stats_rollup_tick_completed"`) {
		t.Errorf("missing stats_rollup_tick_completed event: %q", out)
	}
	for _, want := range []string{
		`"component":"overview"`,
		`"generated_at"`,
		`"duration_ms"`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("event missing field %s: %q", want, out)
		}
	}
	// The rewards_populated tick (c == "") must NOT emit a
	// stats_rollup_tick_completed event per round-1 CODE H3 fix.
	buf.Reset()
	runner.RunTickOnceForTest(ctx, "rewards_populated", "",
		func(c context.Context) error { return nil })
	if strings.Contains(buf.String(), `"event":"stats_rollup_tick_completed"`) {
		t.Errorf("rewards_populated tick (c=\"\") MUST NOT emit stats_rollup_tick_completed; got %q", buf.String())
	}
}
