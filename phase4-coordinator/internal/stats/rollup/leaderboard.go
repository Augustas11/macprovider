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
// {"24h", "7d", "30d", "all"}.
//
// Round-1 fixes absorbed:
//
//   - CRITICAL: rewards aggregation now JOINs `provider_tokens`
//     so rewards-only providers absent from the authenticated
//     trust source cannot enter the leaderboard storage
//     (SECURITY r1 CRIT-1 + ARCH r1 CRIT-1).
//   - CRITICAL: missing rewards default → `big.NewRat(0,1)` —
//     no nil-pointer panic for work-only providers (CODE r1
//     CRIT-1).
//   - HIGH: aggregate queries now apply `[start, end)` bounds
//     with `now` as the exclusive upper bound; future-dated
//     rows cannot leak in (CODE r1 HIGH 1).
//   - HIGH: provider_visibility left-join is read (default
//     tuple `mode='bucketed' AND blocked=FALSE` for absent
//     rows) but the rollup MUST NOT branch on
//     `blocked_from_partner_projection` in v0.1 (§6.1 + §11
//     Q11 + BUILD §6 explicitly defer the partner-projection
//     suppression semantics to v0.2). The earlier round-1
//     draft skipped blocked providers from storage; round-2
//     reversed that — blocked providers STILL appear in v0.1
//     leaderboard storage. v0.2 will pin the suppression
//     contract (ARCH r1 HIGH 3 + r2 unanimous HIGH 1 fix).
//   - HIGH: single tick-time `now` value used for every row
//     and the health update — Step 3's handler/ETag/staleness
//     derivation will see one consistent generated_at per
//     window (CODE r1 HIGH 3).
//
// Per BUILD §C.1, the leaderboard rebuild MAY use the Step 1
// non-Shape-C path (per-window UPSERT each tick). The Shape C
// single-tx DELETE+INSERT atomicity across BOTH 30d AND all
// is required for the nightly full rebuild — see rebuild.go.
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
		if err := insertLeaderboardRow(ctx, tx, table, r, now); err != nil {
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

	// 30d / all also detect late events for the nightly rebuild
	// to reconcile. This runs AFTER the tick commits so a
	// retention failure doesn't roll back the tick.
	if window == "30d" || window == "all" {
		if err := detectLateEvents(ctx, db, cfg, window, now); err != nil {
			// Non-fatal: late-event detection failure is logged
			// upstream via stats_components_health; the next
			// nightly rebuild will reconcile from OLTP truth
			// regardless. We return the error so the caller
			// surfaces it.
			return fmt.Errorf("leaderboard %s late events: %w", window, err)
		}
	}
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

// computeLeaderboardRows aggregates the OLTP source for one
// window with `now` as the exclusive upper bound (`[start, end)`).
// Both work and rewards aggregates JOIN `provider_tokens` so the
// only `provider_id` values that can enter `stats_leaderboard_*`
// storage are SPEC-002 v1.4 §7 authenticated.
//
// The function loads `provider_visibility` (the §6.1 left-join
// data) for join-evidence completeness, but per the round-2
// audit fix the rollup MUST NOT branch on
// `blocked_from_partner_projection` in v0.1 — SPEC §6.1 + §11
// Q11 + BUILD §6 defer that suppression semantic to v0.2.
// The `mode` column is read but not persisted — Step 3's
// handler reads it directly from `provider_visibility` for the
// public/partner projection split (with default tuple bucketed
// via COALESCE).
func computeLeaderboardRows(ctx context.Context, db *sql.DB, cfg Config, window string, now time.Time) ([]leaderboardRow, error) {
	since := windowStart(window, now, cfg.PartialHistorySinceUnix)
	endUnix := now.Unix()

	work, err := aggregateWorkPerProvider(ctx, db, since, endUnix)
	if err != nil {
		return nil, fmt.Errorf("work aggregate: %w", err)
	}
	rewards, err := aggregateRewardsPerProvider(ctx, db, since, endUnix)
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

	zeroRat := big.NewRat(0, 1)
	rows := make([]leaderboardRow, 0, len(providerIDs))
	for pid := range providerIDs {
		// Round-2 ARCH/CODE/SECURITY r2 unanimous HIGH 1 fix:
		// v0.1 §6.1 + §11 Q11 + BUILD §6 explicitly forbid
		// branching on `blocked_from_partner_projection`. The
		// rollup MAY load the column for join-evidence (left-
		// join semantics demonstration) but MUST NOT remove
		// the provider from leaderboard storage based on it.
		// SPEC v0.2 will define the partner-projection
		// suppression semantics; v0.1 ships the column as a
		// stub only. Reading the value into `_` keeps the
		// load-bearing default-tuple coverage from r1 while
		// honoring the v0.1 contract.
		_ = visibility[pid] // intentional read; do NOT branch on .Blocked in v0.1

		w, hasWork := work[pid]
		workUSD := usdFromCredits(w.credits, cfg.UsdPerMillionCredits)

		r, hasRewards := rewards[pid]
		rewardsUSD := zeroRat
		if hasRewards && r.amount != nil {
			rewardsUSD = r.amount
		}

		totalUSD := new(big.Rat).Add(workUSD, rewardsUSD)
		bucket, err := Bucket(window, totalUSD)
		if err != nil {
			return nil, fmt.Errorf("bucket %s: %w", pid, err)
		}

		_ = hasWork // explicit: w defaults to zero workAgg if no work rows; rewardsUSD captures rewards-only providers
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

// aggregateWorkPerProvider sums work-side counters per provider
// within the half-open window `[since, end)`. JOIN on
// `provider_tokens` is the Step 1 trust-source enforcement —
// any ledger row for a provider not in `provider_tokens` is
// silently dropped.
func aggregateWorkPerProvider(ctx context.Context, db *sql.DB, sinceUnix, endUnix int64) (map[string]workAgg, error) {
	// CODE r3 HIGH 1: effective-token semantic (byte_estimated
	// path). The earlier `prompt_tokens + completion_tokens`
	// turned NULL completion_tokens (byte_estimated rows) into a
	// NULL sum, silently dropping their contribution.
	q := `
        SELECT pt.provider_id,
               COALESCE(SUM(lrc.provider_credits), 0)::BIGINT AS credits,
               COALESCE(SUM(` + effectivePromptTokensSQL("lrc") + ` + ` + effectiveCompletionTokensSQL("lrc") + `), 0)::BIGINT AS tokens,
               COUNT(DISTINCT lrc.request_id)::BIGINT AS jobs,
               MIN(lrc.ts_utc) AS first_seen,
               MAX(lrc.ts_utc) AS last_seen
          FROM ledger_request_credits lrc
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE ($1 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $1)
           AND EXTRACT(EPOCH FROM lrc.ts_utc) < $2
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
         GROUP BY pt.provider_id
    `
	rows, err := db.QueryContext(ctx, q, sinceUnix, endUnix)
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

// aggregateRewardsPerProvider sums `provider_rewards_ledger`
// per provider within `[since, end)`. JOIN on `provider_tokens`
// enforces the Step 1 trust-source decision — a rewards-only
// provider absent from `provider_tokens` CANNOT enter the
// leaderboard. SECURITY r1 CRIT-1 + ARCH r1 CRIT-1.
func aggregateRewardsPerProvider(ctx context.Context, db *sql.DB, sinceUnix, endUnix int64) (map[string]rewardsAgg, error) {
	const q = `
        SELECT prl.provider_id,
               COALESCE(SUM(prl.amount_usd), 0) AS amount
          FROM provider_rewards_ledger prl
          JOIN provider_tokens pt ON pt.provider_id = prl.provider_id
         WHERE ($1 = 0 OR prl.unix_ts >= $1)
           AND prl.unix_ts < $2
         GROUP BY prl.provider_id
    `
	rows, err := db.QueryContext(ctx, q, sinceUnix, endUnix)
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
		return partialHistorySinceUnix
	}
	return 0
}

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

// insertLeaderboardRow writes a single row using the tick's
// shared `now` for `generated_at`. CODE r1 HIGH 3 fix: every
// row in a single tick has the SAME generated_at, equal to the
// stats_components_health row for the window. Step 3's
// handler/ETag/staleness derivation can rely on that.
func insertLeaderboardRow(ctx context.Context, db sqlExecer, table string, r leaderboardRow, generatedAt time.Time) error {
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
		r.ProviderID, r.Pseudonym, generatedAt,
		r.RankEarnings, r.RankTokens, r.RankJobs,
		r.EarningsTotalUSD.FloatString(2),
		r.EarningsWorkUSD.FloatString(2),
		r.EarningsRewardsUSD.FloatString(2),
		r.Bucket, r.Tokens, r.Jobs,
		r.FirstSeenAt, r.LastSeenAt,
	)
	return err
}
