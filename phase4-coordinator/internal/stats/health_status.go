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
	// SPEC §9.5 freshness SLA — verbatim per round-1 ARCH H5 /
	// CODE H4 fix:
	//
	//   /v1/stats/overview              30s  / 120s
	//   /v1/stats/leaderboard?window=24h 60s / 300s
	//   /v1/stats/leaderboard?window=7d  5m  / 30m   = 300s / 1800s
	//   /v1/stats/leaderboard?window=30d 30m / 4h    = 1800s / 14400s
	//   /v1/stats/leaderboard?window=all 6h  / 24h   = 21600s / 86400s
	//
	// timeseries_rpm/tpm are advisory components (no §9.5 row);
	// match the overview shape since they tick at the same
	// cadence.
	switch c {
	case "overview", "routability":
		return healthThresholds{targetSec: 30, budgetSec: 120}
	case "timeseries_rpm", "timeseries_tpm":
		return healthThresholds{targetSec: 30, budgetSec: 120}
	case "leaderboard_24h":
		return healthThresholds{targetSec: 60, budgetSec: 300}
	case "leaderboard_7d":
		return healthThresholds{targetSec: 300, budgetSec: 1800}
	case "leaderboard_30d":
		return healthThresholds{targetSec: 1800, budgetSec: 14400}
	case "leaderboard_all":
		return healthThresholds{targetSec: 21600, budgetSec: 86400}
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

func routabilityStaleFor503(now, generatedAt time.Time) bool {
	if generatedAt.IsZero() {
		return true
	}
	t := thresholdsForComponent("routability")
	return now.Sub(generatedAt).Seconds() > float64(t.budgetSec)
}
