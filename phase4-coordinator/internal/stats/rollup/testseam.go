package rollup

import (
	"context"
	"database/sql"
	"time"
)

// LeaderboardRowForTest is the exported shape of `leaderboardRow`
// for integration-test assertions. The integration suite lives
// outside this package and cannot reach unexported types, so this
// is the narrow seam used by Shape C content-equality tests and
// visibility-default fixtures.
//
// USD fields use the same FloatString(2) format the rollup writes
// to Postgres so tests can compare strings rather than re-parsing
// big.Rat. Tokens / Jobs / RankX mirror the storage columns.
//
// Round-5 CODE r5 MEDIUM 1 fix (Shape C content-equality) and
// ARCH r5 HIGH 1 fix (visibility seam) both consume this.
type LeaderboardRowForTest struct {
	ProviderID         string
	Pseudonym          string
	EarningsTotalUSD   string
	EarningsWorkUSD    string
	EarningsRewardsUSD string
	Tokens             int64
	Jobs               int64
	Bucket             string
	RankEarnings       int
	RankTokens         int
	RankJobs           int
	VisibilityMode     string
	VisibilityBlocked  bool
}

// ComputeLeaderboardRowsForTest runs the production `compute…`
// path and returns its deterministic output for assertion. Tests
// use this to prove the rebuild's post-commit storage equals
// the recompute output column-for-column.
//
// `now` must be the same value the production rebuild would use
// (`time.Now().UTC()` at tick time). Production callers MUST NOT
// invoke this — use the package-private `runNightlyRebuild` /
// `runLeaderboardTick` instead.
func ComputeLeaderboardRowsForTest(ctx context.Context, db *sql.DB, cfg Config, window string, now time.Time) ([]LeaderboardRowForTest, error) {
	rows, err := computeLeaderboardRows(ctx, db, cfg, window, now)
	if err != nil {
		return nil, err
	}
	out := make([]LeaderboardRowForTest, 0, len(rows))
	for _, r := range rows {
		out = append(out, LeaderboardRowForTest{
			ProviderID:         r.ProviderID,
			Pseudonym:          r.Pseudonym,
			EarningsTotalUSD:   r.EarningsTotalUSD.FloatString(2),
			EarningsWorkUSD:    r.EarningsWorkUSD.FloatString(2),
			EarningsRewardsUSD: r.EarningsRewardsUSD.FloatString(2),
			Tokens:             r.Tokens,
			Jobs:               r.Jobs,
			Bucket:             r.Bucket,
			RankEarnings:       r.RankEarnings,
			RankTokens:         r.RankTokens,
			RankJobs:           r.RankJobs,
			VisibilityMode:     r.VisibilityMode,
			VisibilityBlocked:  r.VisibilityBlocked,
		})
	}
	return out, nil
}
