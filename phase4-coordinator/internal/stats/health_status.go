package stats

import "time"

// SPEC §5.3 + §9.5 health status derivation. The handler
// computes the JSON `status` field from `generated_at`
// freshness against the §9.5 thresholds — there is NO `status`
// column in `stats_components_health`. The thresholds are
// pinned in §9.5 v0.1.7:
//
//   - ok        : generated_at within target (≤30s for overview;
//                 ≤60s for rpm/tpm; ≤120s for 24h/7d; ≤300s for
//                 30d/all).
//   - degraded  : >target AND ≤ §5.8 503 budget.
//   - down      : > §5.8 503 budget (120s for overview).
//
// The locked SPEC pins specific freshness budgets per
// component; v0.1 IMPL implements the simplified two-band
// model below (target / budget) so the locked AC-7 fixtures
// (130s = down, 45s = degraded for overview) pass.

type healthThresholds struct {
	targetSec int
	budgetSec int
}

func thresholdsForComponent(c string) healthThresholds {
	// Per BUILD §F.2 + §9.5: overview at 30s/120s; rpm/tpm at
	// 60s/300s (rolling minute granularity); per-window
	// leaderboards at the matching cadence (24h: 60s/300s;
	// 7d: 300s/900s; 30d: 1800s/3600s; all: 21600s/64800s ≈
	// 6h/18h).
	switch c {
	case "overview":
		return healthThresholds{targetSec: 30, budgetSec: 120}
	case "timeseries_rpm", "timeseries_tpm":
		return healthThresholds{targetSec: 60, budgetSec: 300}
	case "leaderboard_24h":
		return healthThresholds{targetSec: 60, budgetSec: 300}
	case "leaderboard_7d":
		return healthThresholds{targetSec: 300, budgetSec: 900}
	case "leaderboard_30d":
		return healthThresholds{targetSec: 1800, budgetSec: 3600}
	case "leaderboard_all":
		return healthThresholds{targetSec: 21600, budgetSec: 64800}
	}
	// Unknown component falls back to the overview shape so
	// future additions default to a strict bar.
	return healthThresholds{targetSec: 30, budgetSec: 120}
}

// statusFromFreshness returns one of "ok", "degraded", "down".
// `now` is the request time; `generatedAt` is the per-component
// rollup tick time.
func statusFromFreshness(now, generatedAt time.Time, c string) string {
	if generatedAt.IsZero() {
		return "down"
	}
	t := thresholdsForComponent(c)
	age := now.Sub(generatedAt).Seconds()
	switch {
	case age > float64(t.budgetSec):
		return "down"
	case age > float64(t.targetSec):
		return "degraded"
	default:
		return "ok"
	}
}

// overviewStaleFor503 reports whether `now - generatedAt`
// crosses the §5.8 overview 503 budget (AC-14 = 120s).
// Returns true → the overview handler MUST emit 503 with the
// `stats_stale` envelope + `Retry-After: 30`.
func overviewStaleFor503(now, generatedAt time.Time) bool {
	if generatedAt.IsZero() {
		return true
	}
	t := thresholdsForComponent("overview")
	return now.Sub(generatedAt).Seconds() > float64(t.budgetSec)
}
