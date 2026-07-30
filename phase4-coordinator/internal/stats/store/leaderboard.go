package store

import (
	"context"
	"database/sql"
	"fmt"
	"time"
)

// LeaderboardRow is one provider's row from
// `stats_leaderboard_<window>` LEFT JOINed against
// `provider_visibility`. The LEFT JOIN defaults `mode` to
// 'bucketed' and `blocked_from_partner_projection` to FALSE
// when no `provider_visibility` row exists (§6.1 + AC-19).
//
// EarningsTotalUSD / EarningsWorkUSD / EarningsRewardsUSD are
// kept as strings so the handler's JSON marshal can emit them
// as JSON numbers WITHOUT float-rounding the NUMERIC(18,2)
// stored value.
type LeaderboardRow struct {
	ProviderID         string
	Pseudonym          string
	GeneratedAt        time.Time
	RankEarnings       int
	RankTokens         int
	RankJobs           int
	EarningsTotalUSD   string
	EarningsWorkUSD    string
	EarningsRewardsUSD string
	Bucket             string
	Tokens             int64
	Jobs               int64
	FirstSeenAt        sql.NullTime
	LastSeenAt         sql.NullTime
	VisibilityMode     string
	VisibilityBlocked  bool
}

// Leaderboard reads the per-window leaderboard table sorted by
// `sort` ∈ {"earnings", "tokens", "jobs"} and limited to
// `limit` rows. Window ∈ {"24h", "7d", "30d", "all"}.
//
// The handler validates `window` / `sort` / `limit` BEFORE
// calling this method; the method itself errors on invalid
// values rather than silently substituting defaults.
func (s *Store) Leaderboard(ctx context.Context, window, sort string, limit int) ([]LeaderboardRow, error) {
	table, ok := leaderboardTable(window)
	if !ok {
		return nil, fmt.Errorf("leaderboard: unknown window %q", window)
	}
	orderCol, ok := leaderboardOrder(sort)
	if !ok {
		return nil, fmt.Errorf("leaderboard: unknown sort %q", sort)
	}

	q := fmt.Sprintf(`
        SELECT lb.provider_id, lb.pseudonym, lb.generated_at,
               lb.rank_earnings, lb.rank_tokens, lb.rank_jobs,
               lb.earnings_usd, lb.earnings_work_usd, lb.earnings_rewards_usd,
               lb.earnings_bucket, lb.tokens, lb.jobs,
               lb.first_seen_at, lb.last_seen_at,
               COALESCE(pv.mode, 'bucketed') AS visibility_mode,
               COALESCE(pv.blocked_from_partner_projection, FALSE) AS visibility_blocked
          FROM %s lb
          LEFT JOIN provider_visibility pv ON pv.provider_id = lb.provider_id
         ORDER BY lb.%s ASC, lb.provider_id ASC
         LIMIT $1
    `, table, orderCol)
	rows, err := s.db.QueryContext(ctx, q, limit)
	if err != nil {
		return nil, fmt.Errorf("leaderboard select: %w", err)
	}
	defer rows.Close()
	var out []LeaderboardRow
	for rows.Next() {
		var r LeaderboardRow
		if err := rows.Scan(
			&r.ProviderID, &r.Pseudonym, &r.GeneratedAt,
			&r.RankEarnings, &r.RankTokens, &r.RankJobs,
			&r.EarningsTotalUSD, &r.EarningsWorkUSD, &r.EarningsRewardsUSD,
			&r.Bucket, &r.Tokens, &r.Jobs,
			&r.FirstSeenAt, &r.LastSeenAt,
			&r.VisibilityMode, &r.VisibilityBlocked,
		); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}

func (s *Store) LeaderboardProvider(ctx context.Context, window, providerID string) (*LeaderboardRow, error) {
	table, ok := leaderboardTable(window)
	if !ok {
		return nil, fmt.Errorf("leaderboard provider: unknown window %q", window)
	}
	q := fmt.Sprintf(`
        SELECT lb.provider_id, lb.pseudonym, lb.generated_at,
               lb.rank_earnings, lb.rank_tokens, lb.rank_jobs,
               lb.earnings_usd, lb.earnings_work_usd, lb.earnings_rewards_usd,
               lb.earnings_bucket, lb.tokens, lb.jobs,
               lb.first_seen_at, lb.last_seen_at,
               COALESCE(pv.mode, 'bucketed') AS visibility_mode,
               COALESCE(pv.blocked_from_partner_projection, FALSE) AS visibility_blocked
          FROM %s lb
          LEFT JOIN provider_visibility pv ON pv.provider_id = lb.provider_id
         WHERE lb.provider_id = $1
         LIMIT 1
    `, table)
	var r LeaderboardRow
	if err := s.db.QueryRowContext(ctx, q, providerID).Scan(
		&r.ProviderID, &r.Pseudonym, &r.GeneratedAt,
		&r.RankEarnings, &r.RankTokens, &r.RankJobs,
		&r.EarningsTotalUSD, &r.EarningsWorkUSD, &r.EarningsRewardsUSD,
		&r.Bucket, &r.Tokens, &r.Jobs,
		&r.FirstSeenAt, &r.LastSeenAt,
		&r.VisibilityMode, &r.VisibilityBlocked,
	); err != nil {
		if err == sql.ErrNoRows {
			return nil, nil
		}
		return nil, fmt.Errorf("leaderboard provider select: %w", err)
	}
	return &r, nil
}

// LeaderboardTotals returns the per-window aggregate counters.
// `active_accounts` = number of rows in the leaderboard table
// (one row per authenticated provider with activity in the
// window). `tokens` / `jobs` are SUM aggregates over the same
// rows. `earnings_*` totals are computed but the handler
// projection layer decides whether to expose them (partner
// projection only per §5.2 + AC-6).
type LeaderboardTotals struct {
	ActiveAccounts int64
	Tokens         int64
	Jobs           int64
	EarningsUSD    string
	EarningsWork   string
	EarningsReward string
	GeneratedAt    time.Time
}

func (s *Store) LeaderboardTotals(ctx context.Context, window string) (*LeaderboardTotals, error) {
	table, ok := leaderboardTable(window)
	if !ok {
		return nil, fmt.Errorf("leaderboard totals: unknown window %q", window)
	}
	q := fmt.Sprintf(`
        SELECT COUNT(*)::BIGINT AS active_accounts,
               COALESCE(SUM(tokens), 0)::BIGINT AS tokens,
               COALESCE(SUM(jobs), 0)::BIGINT AS jobs,
               COALESCE(SUM(earnings_usd), 0)::NUMERIC(18,2) AS earnings_usd,
               COALESCE(SUM(earnings_work_usd), 0)::NUMERIC(18,2) AS earnings_work_usd,
               COALESCE(SUM(earnings_rewards_usd), 0)::NUMERIC(18,2) AS earnings_rewards_usd,
               COALESCE(MAX(generated_at), 'epoch'::TIMESTAMPTZ) AS generated_at
          FROM %s
    `, table)
	var t LeaderboardTotals
	if err := s.db.QueryRowContext(ctx, q).Scan(
		&t.ActiveAccounts, &t.Tokens, &t.Jobs,
		&t.EarningsUSD, &t.EarningsWork, &t.EarningsReward,
		&t.GeneratedAt,
	); err != nil {
		return nil, fmt.Errorf("leaderboard totals select: %w", err)
	}
	return &t, nil
}

// RewardsPopulated reads the §9.1a-derived boolean Step 2
// pre-computed into `stats_rewards_populated` for the given
// window. Returns FALSE on no row (the empty-ledger semantic
// per Step 2's bootstrap default).
//
// Round-1 ARCH H3 / CODE H3 fix: column name is
// `rewards_populated` (NOT `populated`) per Step 2 migration
// 001_stats_tables.up.sql.
func (s *Store) RewardsPopulated(ctx context.Context, window string) (bool, error) {
	const q = `
        SELECT rewards_populated
          FROM stats_rewards_populated
         WHERE window_label = $1
         LIMIT 1
    `
	var p bool
	if err := s.db.QueryRowContext(ctx, q, window).Scan(&p); err != nil {
		if err == sql.ErrNoRows {
			return false, nil
		}
		return false, fmt.Errorf("rewards_populated select: %w", err)
	}
	return p, nil
}

func leaderboardTable(window string) (string, bool) {
	switch window {
	case "24h":
		return "stats_leaderboard_24h", true
	case "7d":
		return "stats_leaderboard_7d", true
	case "30d":
		return "stats_leaderboard_30d", true
	case "all":
		return "stats_leaderboard_all", true
	}
	return "", false
}

func leaderboardOrder(sort string) (string, bool) {
	switch sort {
	case "earnings":
		return "rank_earnings", true
	case "tokens":
		return "rank_tokens", true
	case "jobs":
		return "rank_jobs", true
	}
	return "", false
}
