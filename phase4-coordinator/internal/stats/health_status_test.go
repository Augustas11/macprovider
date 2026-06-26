package stats

import (
	"testing"
	"time"
)

func TestStatusFromFreshness(t *testing.T) {
	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name      string
		component string
		ageSec    int
		want      string
	}{
		// AC-7 explicit fixtures (overview).
		{"overview_fresh", "overview", 5, "ok"},
		{"overview_degraded_45s", "overview", 45, "degraded"},
		{"overview_down_130s", "overview", 130, "down"},
		// Zero generated_at = down.
		{"timeseries_rpm_zero", "timeseries_rpm", -1, "down"},
		// Leaderboard 7d uses 300s target / 1800s budget per §9.5.
		{"leaderboard_7d_ok", "leaderboard_7d", 100, "ok"},
		{"leaderboard_7d_degraded", "leaderboard_7d", 400, "degraded"},
		{"leaderboard_7d_down", "leaderboard_7d", 2000, "down"},
		// Leaderboard 30d 1800s target / 14400s budget.
		{"leaderboard_30d_ok", "leaderboard_30d", 100, "ok"},
		{"leaderboard_30d_degraded", "leaderboard_30d", 3600, "degraded"},
		{"leaderboard_30d_down", "leaderboard_30d", 20000, "down"},
		// Leaderboard all 21600s / 86400s.
		{"leaderboard_all_ok", "leaderboard_all", 100, "ok"},
		{"leaderboard_all_degraded", "leaderboard_all", 30000, "degraded"},
		{"leaderboard_all_down", "leaderboard_all", 100000, "down"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			var gen time.Time
			if c.ageSec >= 0 {
				gen = now.Add(-time.Duration(c.ageSec) * time.Second)
			}
			got := statusFromFreshness(now, gen, c.component)
			if got != c.want {
				t.Errorf("got %q want %q", got, c.want)
			}
		})
	}
}

func TestOverviewStaleFor503(t *testing.T) {
	now := time.Date(2026, 6, 26, 12, 0, 0, 0, time.UTC)
	if !overviewStaleFor503(now, time.Time{}) {
		t.Errorf("zero generated_at must be stale")
	}
	if !overviewStaleFor503(now, now.Add(-130*time.Second)) {
		t.Errorf("130s old must be stale (AC-14)")
	}
	if overviewStaleFor503(now, now.Add(-30*time.Second)) {
		t.Errorf("30s old must not be stale")
	}
}
