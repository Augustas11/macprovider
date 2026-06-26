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
		// Leaderboard 7d uses a longer band.
		{"leaderboard_7d_ok", "leaderboard_7d", 100, "ok"},
		{"leaderboard_7d_degraded", "leaderboard_7d", 400, "degraded"},
		{"leaderboard_7d_down", "leaderboard_7d", 1000, "down"},
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
