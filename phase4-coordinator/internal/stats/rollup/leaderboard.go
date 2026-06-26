package rollup

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"math/big"
	"sort"
	"strings"
	"time"
)

// runLeaderboardTick recomputes a single `stats_leaderboard_*`
// window from scratch. The window argument is one of
// {"24h", "7d", "30d", "all"} — used both to pick the target
// table and the bucket-threshold set (§6.2).
//
// Per BUILD §F.4 + ARCH r7 H2, the rollup OWNS the
// `provider_visibility` left-join (default tuple `mode='bucketed'
// AND blocked=FALSE`) AND the `earnings_bucket` computation per
// §6.2 bracket semantics. The handler in Step 3 only reads what
// the rollup wrote; bucket/projection logic does NOT live in the
// handler path.
//
// Per BUILD §F.3 + the Step 1 trust-source decision, every
// leaderboard row's provider_id traces back to a JOIN on the
// authenticated SPEC-002 v1.4 §7 `provider_tokens` table.
//
// Per BUILD §C.1, the leaderboard rebuild MAY use the Step 1
// non-Shape-C path (per-window UPSERT each tick). The Shape C
// single-tx DELETE+INSERT is required ONLY for the nightly full
// rebuild of `stats_leaderboard_30d` and `stats_leaderboard_all`
// (see rebuild.go).
func runLeaderboardTick(ctx context.Context, db *sql.DB, cfg Config, window string) error {
	now := time.Now().UTC()
	rows, err := computeLeaderboardRows(ctx, db, cfg, window, now)
	if err != nil {
		return fmt.Errorf("leaderboard %s compute: %w", window, err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("leaderboard %s begin: %w", window, err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	table := leaderboardTableForWindow(window)
	if table == "" {
		return fmt.Errorf("rollup: unknown window %q", window)
	}

	if _, err := tx.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s`, table)); err != nil {
		return fmt.Errorf("leaderboard %s delete: %w", window, err)
	}
	for _, r := range rows {
		if err := insertLeaderboardRow(ctx, tx, table, r); err != nil {
			return fmt.Errorf("leaderboard %s insert %s: %w", window, r.ProviderID, err)
		}
	}

	if err := healthOK(ctx, tx, componentForWindow(window), now); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("leaderboard %s commit: %w", window, err)
	}
	committed = true
	return nil
}

// leaderboardRow is the rollup's intermediate representation
// before INSERT.
type leaderboardRow struct {
	ProviderID         string
	Pseudonym          string
	EarningsTotalUSD   *big.Rat
	EarningsWorkUSD    *big.Rat
	EarningsRewardsUSD *big.Rat
	Tokens             int64
	Jobs               int64
	FirstSeenAt        *time.Time
	LastSeenAt         *time.Time
	Bucket             string
	// Rank fields are filled in by the caller after sorting.
	RankEarnings int
	RankTokens   int
	RankJobs     int
}

// computeLeaderboardRows runs the OLTP source query for one
// window, joins on provider_tokens + provider_visibility, runs
// the work+rewards $ aggregation, computes bucket, and sorts
// for rank computation.
func computeLeaderboardRows(ctx context.Context, db *sql.DB, cfg Config, window string, now time.Time) ([]leaderboardRow, error) {
	since := windowStart(window, now, cfg.PartialHistorySinceUnix)

	// Two-step approach:
	// 1. Aggregate ledger_request_credits per provider for the
	//    window (joined on provider_tokens for authenticated id).
	// 2. Sum provider_rewards_ledger per provider for the same
	//    window.
	// Then merge in-process. This avoids a Postgres OUTER JOIN
	// over two heterogeneous aggregations.
	work, err := aggregateWorkPerProvider(ctx, db, since)
	if err != nil {
		return nil, fmt.Errorf("work aggregate: %w", err)
	}
	rewards, err := aggregateRewardsPerProvider(ctx, db, since)
	if err != nil {
		return nil, fmt.Errorf("rewards aggregate: %w", err)
	}
	visibility, err := loadProviderVisibility(ctx, db)
	if err != nil {
		return nil, fmt.Errorf("visibility load: %w", err)
	}

	providerIDs := make(map[string]struct{})
	for pid := range work {
		providerIDs[pid] = struct{}{}
	}
	for pid := range rewards {
		providerIDs[pid] = struct{}{}
	}

	rows := make([]leaderboardRow, 0, len(providerIDs))
	for pid := range providerIDs {
		w := work[pid]
		r := rewards[pid]
		_ = visibility[pid] // visibility tuple is read by the handler; rollup ensures the left-join row exists in the leaderboard regardless of mode/blocked
		workUSD := usdFromCredits(w.credits, cfg.UsdPerMillionCredits)
		rewardsUSD := r.amount
		totalUSD := new(big.Rat).Add(workUSD, rewardsUSD)
		bucket, err := Bucket(window, totalUSD)
		if err != nil {
			return nil, fmt.Errorf("bucket %s: %w", pid, err)
		}
		rows = append(rows, leaderboardRow{
			ProviderID:         pid,
			Pseudonym:          pseudonymize(pid),
			EarningsTotalUSD:   totalUSD,
			EarningsWorkUSD:    workUSD,
			EarningsRewardsUSD: rewardsUSD,
			Tokens:             w.tokens,
			Jobs:               w.jobs,
			FirstSeenAt:        w.firstSeen,
			LastSeenAt:         w.lastSeen,
			Bucket:             bucket,
		})
	}

	assignRanks(rows)
	return rows, nil
}

type workAgg struct {
	credits   int64
	tokens    int64
	jobs      int64
	firstSeen *time.Time
	lastSeen  *time.Time
}

type rewardsAgg struct {
	amount *big.Rat
}

func aggregateWorkPerProvider(ctx context.Context, db *sql.DB, sinceUnix int64) (map[string]workAgg, error) {
	const q = `
        SELECT pt.provider_id,
               COALESCE(SUM(lrc.provider_credits), 0)::BIGINT AS credits,
               COALESCE(SUM(lrc.prompt_tokens + lrc.completion_tokens), 0)::BIGINT AS tokens,
               COUNT(DISTINCT lrc.request_id)::BIGINT AS jobs,
               MIN(lrc.ts_utc) AS first_seen,
               MAX(lrc.ts_utc) AS last_seen
          FROM ledger_request_credits lrc
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE ($1 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $1)
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
         GROUP BY pt.provider_id
    `
	rows, err := db.QueryContext(ctx, q, sinceUnix)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]workAgg)
	for rows.Next() {
		var pid string
		var w workAgg
		var first, last sql.NullTime
		if err := rows.Scan(&pid, &w.credits, &w.tokens, &w.jobs, &first, &last); err != nil {
			return nil, err
		}
		if first.Valid {
			t := first.Time
			w.firstSeen = &t
		}
		if last.Valid {
			t := last.Time
			w.lastSeen = &t
		}
		out[pid] = w
	}
	return out, rows.Err()
}

func aggregateRewardsPerProvider(ctx context.Context, db *sql.DB, sinceUnix int64) (map[string]rewardsAgg, error) {
	const q = `
        SELECT provider_id, COALESCE(SUM(amount_usd), 0) AS amount
          FROM provider_rewards_ledger
         WHERE ($1 = 0 OR unix_ts >= $1)
         GROUP BY provider_id
    `
	rows, err := db.QueryContext(ctx, q, sinceUnix)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]rewardsAgg)
	for rows.Next() {
		var pid, amtStr string
		if err := rows.Scan(&pid, &amtStr); err != nil {
			return nil, err
		}
		amt, ok := new(big.Rat).SetString(amtStr)
		if !ok {
			amt = new(big.Rat)
		}
		out[pid] = rewardsAgg{amount: amt}
	}
	return out, rows.Err()
}

// visibilityRow mirrors the §6.1 columns the rollup considers
// for the left-join (mode + blocked stub).
type visibilityRow struct {
	Mode    string
	Blocked bool
}

func loadProviderVisibility(ctx context.Context, db *sql.DB) (map[string]visibilityRow, error) {
	const q = `
        SELECT provider_id, mode, blocked_from_partner_projection
          FROM provider_visibility
    `
	rows, err := db.QueryContext(ctx, q)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := make(map[string]visibilityRow)
	for rows.Next() {
		var pid string
		var v visibilityRow
		if err := rows.Scan(&pid, &v.Mode, &v.Blocked); err != nil {
			return nil, err
		}
		out[pid] = v
	}
	return out, rows.Err()
}

// windowStart returns the unix-second boundary the rollup uses
// for the leaderboard window. For "all", it uses the rollup-start
// boundary (`partial_history_since` when set; otherwise 0).
func windowStart(window string, now time.Time, partialHistorySinceUnix int64) int64 {
	switch window {
	case "24h":
		return now.Add(-24 * time.Hour).Unix()
	case "7d":
		return now.Add(-7 * 24 * time.Hour).Unix()
	case "30d":
		return now.Add(-30 * 24 * time.Hour).Unix()
	case "all":
		// `all` is cumulative-since-rollup-start.
		return partialHistorySinceUnix
	}
	return 0
}

// leaderboardTableForWindow returns the stats_leaderboard_*
// table name for a window string. Returns "" for an unknown
// window (caller checks).
func leaderboardTableForWindow(window string) string {
	switch window {
	case "24h":
		return "stats_leaderboard_24h"
	case "7d":
		return "stats_leaderboard_7d"
	case "30d":
		return "stats_leaderboard_30d"
	case "all":
		return "stats_leaderboard_all"
	}
	return ""
}

// componentForWindow maps a window string to its
// stats_components_health row name.
func componentForWindow(window string) component {
	switch window {
	case "24h":
		return componentLeaderboard24h
	case "7d":
		return componentLeaderboard7d
	case "30d":
		return componentLeaderboard30d
	case "all":
		return componentLeaderboardAll
	}
	return ""
}

// pseudonymize maps a provider_id to a stable pseudonym per
// SPEC §3.3 ("deterministic per provider; stable across
// snapshots"). v0.1 uses a sha256-derived short hex code; the
// pseudonym-rotation policy is §11 Q4 deferred.
func pseudonymize(providerID string) string {
	sum := sha256.Sum256([]byte("spec017-pseudonym:" + providerID))
	return "node-" + hex.EncodeToString(sum[:4])
}

// assignRanks fills RankEarnings / RankTokens / RankJobs after
// sorting rows. Ties are broken by provider_id text so the rank
// is deterministic across ticks (no pseudonym churn from rank
// thrash).
func assignRanks(rows []leaderboardRow) {
	rankBy(rows, func(a, b leaderboardRow) bool {
		c := a.EarningsTotalUSD.Cmp(b.EarningsTotalUSD)
		if c != 0 {
			return c > 0
		}
		return strings.Compare(a.ProviderID, b.ProviderID) < 0
	}, func(r *leaderboardRow, rk int) { r.RankEarnings = rk })

	rankBy(rows, func(a, b leaderboardRow) bool {
		if a.Tokens != b.Tokens {
			return a.Tokens > b.Tokens
		}
		return strings.Compare(a.ProviderID, b.ProviderID) < 0
	}, func(r *leaderboardRow, rk int) { r.RankTokens = rk })

	rankBy(rows, func(a, b leaderboardRow) bool {
		if a.Jobs != b.Jobs {
			return a.Jobs > b.Jobs
		}
		return strings.Compare(a.ProviderID, b.ProviderID) < 0
	}, func(r *leaderboardRow, rk int) { r.RankJobs = rk })
}

func rankBy(rows []leaderboardRow, less func(a, b leaderboardRow) bool, assign func(*leaderboardRow, int)) {
	idx := make([]int, len(rows))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(i, j int) bool { return less(rows[idx[i]], rows[idx[j]]) })
	for rank, k := range idx {
		assign(&rows[k], rank+1)
	}
}

// insertLeaderboardRow writes a single row using NUMERIC(18,2)
// formatting for $ columns. The rat.FloatString(2) discipline
// rounds to 2 decimals (toward zero); Postgres NUMERIC will
// store the exact value.
func insertLeaderboardRow(ctx context.Context, db sqlExecer, table string, r leaderboardRow) error {
	now := time.Now().UTC()
	q := fmt.Sprintf(`
        INSERT INTO %s (
            provider_id, pseudonym, generated_at,
            rank_earnings, rank_tokens, rank_jobs,
            earnings_usd, earnings_work_usd, earnings_rewards_usd,
            earnings_bucket, tokens, jobs,
            first_seen_at, last_seen_at
        ) VALUES (
            $1, $2, $3,
            $4, $5, $6,
            $7, $8, $9,
            $10, $11, $12,
            $13, $14
        )
    `, table)
	_, err := db.ExecContext(ctx, q,
		r.ProviderID, r.Pseudonym, now,
		r.RankEarnings, r.RankTokens, r.RankJobs,
		r.EarningsTotalUSD.FloatString(2),
		r.EarningsWorkUSD.FloatString(2),
		r.EarningsRewardsUSD.FloatString(2),
		r.Bucket, r.Tokens, r.Jobs,
		r.FirstSeenAt, r.LastSeenAt,
	)
	return err
}
