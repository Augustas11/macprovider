package rollup

import (
	"math/big"
	"strings"
	"testing"
	"time"
)

func TestWindowStartBoundaries(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	cases := []struct {
		window  string
		partial int64
		want    int64
	}{
		{"24h", 99, now.Unix() - 24*3600},
		{"7d", 99, now.Unix() - 7*24*3600},
		{"30d", 99, now.Unix() - 30*24*3600},
		{"all", 12345, 12345},
		{"all", 0, 0},
		{"bogus", 99, 0},
	}
	for _, c := range cases {
		if got := windowStart(c.window, now, c.partial); got != c.want {
			t.Errorf("windowStart(%q)=%d want %d", c.window, got, c.want)
		}
	}
}

func TestLateEventBoundary(t *testing.T) {
	now := time.Unix(1_800_000_000, 0).UTC()
	if got, want := lateEventBoundary(now, 48), now.Unix()-48*3600; got != want {
		t.Fatalf("got %d want %d", got, want)
	}
	if got := lateEventBoundary(now, 0); got != now.Unix() {
		t.Fatalf("zero lookback: got %d", got)
	}
}

func TestWindowTableAndComponentMapping(t *testing.T) {
	tables := map[string]string{
		"24h": "stats_leaderboard_24h", "7d": "stats_leaderboard_7d",
		"30d": "stats_leaderboard_30d", "all": "stats_leaderboard_all", "x": "",
	}
	comps := map[string]component{
		"24h": componentLeaderboard24h, "7d": componentLeaderboard7d,
		"30d": componentLeaderboard30d, "all": componentLeaderboardAll, "x": "",
	}
	for w, want := range tables {
		if got := leaderboardTableForWindow(w); got != want {
			t.Errorf("table(%q)=%q want %q", w, got, want)
		}
	}
	for w, want := range comps {
		if got := componentForWindow(w); got != want {
			t.Errorf("component(%q)=%q want %q", w, got, want)
		}
	}
}

func TestPseudonymizeStableAndDistinct(t *testing.T) {
	a := pseudonymize("prov-a")
	if a != pseudonymize("prov-a") {
		t.Fatal("not deterministic")
	}
	if a == pseudonymize("prov-b") {
		t.Fatal("different providers collided")
	}
	if !strings.HasPrefix(a, "node-") || len(a) != len("node-")+8 {
		t.Fatalf("unexpected shape %q", a)
	}
	if pseudonymizeRow("prov-a") != a {
		t.Fatal("pseudonymizeRow must match pseudonymize")
	}
}

func TestAssignRanksOrderingAndTieBreak(t *testing.T) {
	rows := []leaderboardRow{
		{ProviderID: "b", EarningsTotalUSD: big.NewRat(500, 100), Tokens: 10, Jobs: 3},
		{ProviderID: "a", EarningsTotalUSD: big.NewRat(500, 100), Tokens: 30, Jobs: 3},
		{ProviderID: "c", EarningsTotalUSD: big.NewRat(900, 100), Tokens: 20, Jobs: 1},
	}
	assignRanks(rows)
	want := map[string][3]int{ // earnings, tokens, jobs
		"c": {1, 2, 3},
		"a": {2, 1, 1}, // earnings tie with b -> provider id asc; jobs tie -> id asc
		"b": {3, 3, 2},
	}
	for _, r := range rows {
		w := want[r.ProviderID]
		if r.RankEarnings != w[0] || r.RankTokens != w[1] || r.RankJobs != w[2] {
			t.Errorf("%s ranks=(%d,%d,%d) want %v", r.ProviderID, r.RankEarnings, r.RankTokens, r.RankJobs, w)
		}
	}
}

func TestRankIndexTieBreaksAndOrder(t *testing.T) {
	es := []entry{
		{pid: "z", tokens: 5},
		{pid: "y", tokens: 9},
		{pid: "x", tokens: 5},
	}
	got := rankIndex(es, func(a, b entry) bool {
		if a.tokens != b.tokens {
			return a.tokens > b.tokens
		}
		return a.pid < b.pid
	})
	want := map[string]int{"y": 1, "x": 2, "z": 3}
	for k, v := range want {
		if got[k] != v {
			t.Errorf("rank[%s]=%d want %d", k, got[k], v)
		}
	}
	if len(got) != 3 {
		t.Errorf("len=%d", len(got))
	}
}

func TestRatToFloat(t *testing.T) {
	if ratToFloat(nil) != 0 {
		t.Error("nil must be 0")
	}
	if got := ratToFloat(big.NewRat(5, 2)); got != 2.5 {
		t.Errorf("got %v", got)
	}
}

func TestEffectiveTokenSQLFragments(t *testing.T) {
	c := effectiveCompletionTokensSQL("x")
	for _, s := range []string{
		"x.usage_source",
		"WHEN 'byte_estimated' THEN COALESCE(x.estimated_completion_tokens, 0)",
		"WHEN 'null_error' THEN 0",
		"ELSE COALESCE(x.completion_tokens, 0)",
	} {
		if !strings.Contains(c, s) {
			t.Errorf("completion fragment missing %q: %s", s, c)
		}
	}
	if got := effectivePromptTokensSQL("x"); got != "COALESCE(x.prompt_tokens, 0)" {
		t.Errorf("prompt fragment %q", got)
	}
}
