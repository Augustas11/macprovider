package stats

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/store"
)

func TestAlignRpmPointsFillsGridAndNullsMissingMinutes(t *testing.T) {
	anchor := time.Date(2026, 1, 2, 10, 30, 45, 0, time.UTC)
	end := anchor.Truncate(time.Minute)
	rows := []store.TimeseriesRow{
		{Bucket: end.Add(-30 * time.Minute).Add(7 * time.Second), Value: 11},
		{Bucket: end.Add(-5 * time.Minute), Value: 0},
		{Bucket: end, Value: 99}, // end of grid is exclusive
	}
	pts := alignRpmPoints(rows, anchor)
	if len(pts) != 30 {
		t.Fatalf("len=%d want 30", len(pts))
	}
	if pts[0].T != "2026-01-02T10:00:00Z" || pts[29].T != "2026-01-02T10:29:00Z" {
		t.Fatalf("grid bounds %q..%q", pts[0].T, pts[29].T)
	}
	if pts[0].Value == nil || *pts[0].Value != 11 {
		t.Fatalf("first point=%v want 11 (sub-minute bucket truncated)", pts[0].Value)
	}
	if pts[25].Value == nil || *pts[25].Value != 0 {
		t.Fatalf("zero-valued minute must be present, not null: %v", pts[25].Value)
	}
	for i, p := range pts {
		if i != 0 && i != 25 && p.Value != nil {
			t.Fatalf("point %d should be null, got %d", i, *p.Value)
		}
	}
}

func TestAlignTpmPointsFillsGridAndNullsMissingMinutes(t *testing.T) {
	anchor := time.Date(2026, 1, 2, 10, 30, 0, 0, time.UTC)
	rows := []store.TimeseriesRow{
		{Bucket: anchor.Add(-time.Minute), InTok: 5, OutTok: 7},
	}
	pts := alignTpmPoints(rows, anchor)
	if len(pts) != 30 {
		t.Fatalf("len=%d want 30", len(pts))
	}
	last := pts[29]
	if last.T != "2026-01-02T10:29:00Z" || last.InputTokens == nil || last.OutputTokens == nil ||
		*last.InputTokens != 5 || *last.OutputTokens != 7 {
		t.Fatalf("last point=%+v", last)
	}
	if pts[0].InputTokens != nil || pts[0].OutputTokens != nil {
		t.Fatalf("empty minute must be null: %+v", pts[0])
	}
}

func TestDailyPointsFormatsUTCDates(t *testing.T) {
	loc := time.FixedZone("x", -5*3600)
	rows := []store.TimeseriesRow{{
		Bucket: time.Date(2026, 3, 4, 22, 0, 0, 0, loc), // 03:00Z next day
		Value:  3, InTok: 10, OutTok: 20,
	}}
	got := dailyPoints(rows)
	if len(got) != 1 || got[0].T != "2026-03-05" || got[0].Requests != 3 ||
		got[0].InputTokens != 10 || got[0].OutputTokens != 20 {
		t.Fatalf("got %+v", got)
	}
	if n := len(dailyPoints(nil)); n != 0 {
		t.Fatalf("nil rows -> %d points", n)
	}
}

func TestLeaderboardBudgetsAndSMaxAge(t *testing.T) {
	for w, want := range map[string]int{"24h": 300, "7d": 1800, "30d": 14400, "all": 86400, "bogus": 300} {
		if got := leaderboardStaleBudgetSeconds(w); got != want {
			t.Errorf("budget(%q)=%d want %d", w, got, want)
		}
	}
	if leaderboardSMaxAgeSeconds(true) != 30 || leaderboardSMaxAgeSeconds(false) != 60 {
		t.Fatalf("s-maxage partner=%d public=%d", leaderboardSMaxAgeSeconds(true), leaderboardSMaxAgeSeconds(false))
	}
}

func TestLeaderboardStaleFor503(t *testing.T) {
	h := &Handler{}
	now := time.Unix(1_700_000_000, 0).UTC()
	if h.leaderboardStaleFor503(now.Add(-300*time.Second), now, "24h") {
		t.Fatal("exactly at budget is not stale")
	}
	if !h.leaderboardStaleFor503(now.Add(-301*time.Second), now, "24h") {
		t.Fatal("past budget must be stale")
	}
	if h.leaderboardStaleFor503(now.Add(-1700*time.Second), now, "7d") {
		t.Fatal("1700s old is within 7d budget")
	}
}

func TestOverviewAndRoutabilityStaleFor503(t *testing.T) {
	now := time.Unix(1_700_000_000, 0).UTC()
	for name, f := range map[string]func(now, g time.Time) bool{
		"overview": overviewStaleFor503, "routability": routabilityStaleFor503,
	} {
		if !f(now, time.Time{}) {
			t.Errorf("%s: zero time must be stale", name)
		}
		if f(now, now.Add(-120*time.Second)) {
			t.Errorf("%s: 120s is within budget", name)
		}
		if !f(now, now.Add(-121*time.Second)) {
			t.Errorf("%s: 121s must be stale", name)
		}
	}
}

func TestDecodeReasonCounts(t *testing.T) {
	if b, _ := json.Marshal(decodeReasonCounts(nil)); string(b) != "{}" {
		t.Fatalf("empty serializes as %s, want {}", b)
	}
	got := decodeReasonCounts([]byte(`{"busy":3,"cold":1}`))
	if got["busy"] != 3 || got["cold"] != 1 || len(got) != 2 {
		t.Fatalf("got %#v", got)
	}
	if b, _ := json.Marshal(decodeReasonCounts([]byte(`not json`))); string(b) != "{}" {
		t.Fatalf("malformed serializes as %s, want {}", b)
	}
}

func TestParseUSDRound2AndSign(t *testing.T) {
	if parseUSD("") != 0 || parseUSD("abc") != 0 || parseUSD("12.5") != 12.5 {
		t.Fatal("parseUSD")
	}
	for in, want := range map[float64]float64{1.006: 1.01, 1.004: 1.0, -1.006: -1.01, 0: 0, 2.345: 2.35} {
		if got := round2(in); got != want {
			t.Errorf("round2(%v)=%v want %v", in, got, want)
		}
	}
	if sign(-0.1) != -1 || sign(0) != 1 || sign(3) != 1 {
		t.Fatal("sign")
	}
}

func TestShouldExposePartialHistorySince(t *testing.T) {
	now := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	since := func(d time.Duration) string { return now.Add(-d).Format(time.RFC3339) }
	day := 24 * time.Hour
	cases := []struct {
		name   string
		mode   string
		since  string
		window string
		want   bool
	}{
		{"path B full omits", "full", since(day), "30d", false},
		{"no since", "partial", "", "30d", false},
		{"24h never", "partial", since(day), "24h", false},
		{"7d never", "partial", since(day), "7d", false},
		{"bad timestamp", "partial", "yesterday", "30d", false},
		{"30d inside", "partial", since(29 * day), "30d", true},
		{"30d at edge", "partial", since(30 * day), "30d", false},
		{"all inside", "partial", since(89 * day), "all", true},
		{"all at edge", "partial", since(90 * day), "all", false},
	}
	for _, c := range cases {
		h := &Handler{BackfillMode: c.mode, PartialSince: c.since}
		if got := h.shouldExposePartialHistorySince(c.window, now); got != c.want {
			t.Errorf("%s: got %v want %v", c.name, got, c.want)
		}
	}
}

func TestSubstringContainsAndStrTrim(t *testing.T) {
	for _, c := range []struct {
		h, n string
		want bool
	}{{"abc", "", true}, {"ab", "abc", false}, {"abcd", "bc", true}, {"abcd", "cd", true}, {"abcd", "ce", false}} {
		if got := substringContains(c.h, c.n); got != c.want {
			t.Errorf("contains(%q,%q)=%v", c.h, c.n, got)
		}
	}
	if got := strTrim(" \t\r\nhi there\v\f "); got != "hi there" {
		t.Fatalf("strTrim=%q", got)
	}
	if strTrim("   ") != "" {
		t.Fatal("all-space must trim to empty")
	}
}

func TestIsOriginOnGlobalAllowlistUnionStaticAndNilStore(t *testing.T) {
	r := httptest.NewRequest(http.MethodOptions, "/v1/stats/leaderboard", nil)
	static := []string{" https://Console.Example "}
	if !isOriginOnGlobalAllowlistUnion(r, "https://console.example", nil, static) {
		t.Fatal("static allowlist match (case/space-insensitive) must pass")
	}
	if isOriginOnGlobalAllowlistUnion(r, "https://evil.example", nil, static) {
		t.Fatal("unlisted origin with nil store must be rejected")
	}
}
