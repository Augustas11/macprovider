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

// runLeaderboardIncrementalTick implements the SPEC §9.3 v0.1
// incremental-merge cadence semantic for the `stats_leaderboard_30d`
// and `stats_leaderboard_all` windows. Round-3 ARCH r3 HIGH 1 fix:
//
// SPEC §9.3: "For 30d and all windows — full recompute is too
// expensive. The rollup job MUST scan a configurable look-back
// of last_processed_at - 48h to now and merge corrections into
// the existing snapshot. Late events older than 48h are recorded
// in a stats_late_events table for periodic full-rebuild
// operator action."
//
// Behavior:
//
//  1. BOOTSTRAP (first tick — `stats_components_health.last_ok_at`
//     equals the epoch sentinel from migration 002): do a full
//     recompute via `runLeaderboardTick`. This populates the
//     live snapshot for the first time.
//
//  2. SUBSEQUENT TICKS (incremental):
//     a. Identify providers with NEW activity in the lookback
//        window `[lastOK - lookback_hours, now)`.
//     b. For each such active provider, recompute their FULL
//        window aggregate and UPSERT (covers corrections + new
//        rows in the lookback).
//     c. Providers in the snapshot whose last_seen_at falls out
//        of the window length get DELETEd (drop-out detection).
//     d. Re-rank the snapshot deterministically.
//     e. Update stats_components_health.last_ok_at.
//
//  3. LATE EVENTS: `detectLateEvents` runs after every tick,
//     recording OLTP rows older than the lookback boundary.
//     With incremental semantics, those rows DON'T fold into
//     the live snapshot — they land in `stats_late_events` for
//     the nightly Shape C rebuild to reconcile.
//
// The 24h and 7d windows continue to full-recompute every tick
// (cheap, no incremental needed); `runLeaderboardTick` is the
// path for those.
func runLeaderboardIncrementalTick(ctx context.Context, db *sql.DB, cfg Config, window string) error {
	now := time.Now().UTC()
	comp := componentForWindow(window)
	table := leaderboardTableForWindow(window)
	if table == "" {
		return fmt.Errorf("rollup: incremental tick unknown window %q", window)
	}

	var lastOK time.Time
	if err := db.QueryRowContext(ctx,
		`SELECT last_ok_at FROM stats_components_health WHERE component = $1`,
		string(comp),
	).Scan(&lastOK); err != nil {
		return fmt.Errorf("incremental %s read last_ok_at: %w", window, err)
	}

	// Epoch sentinel — set by migration 002's bootstrap row.
	// Cast through Unix(0,0) UTC for deterministic comparison.
	epoch := time.Unix(0, 0).UTC()
	if lastOK.Equal(epoch) || lastOK.Before(epoch.Add(1*time.Second)) {
		// Bootstrap path: full recompute. The full-tick code
		// also runs detectLateEvents internally for 30d/all.
		return runLeaderboardTick(ctx, db, cfg, window)
	}

	// Incremental path.
	if err := runIncrementalLeaderboardUpdate(ctx, db, cfg, window, now, lastOK); err != nil {
		return err
	}

	// Late events run AFTER the tick commits (matches §9.3:
	// older-than-lookback rows that arrived since last_ok_at
	// are recorded for nightly reconciliation but do NOT fold
	// into the live snapshot — which is exactly what the
	// incremental path guarantees).
	if err := detectLateEvents(ctx, db, cfg, window, now); err != nil {
		return fmt.Errorf("incremental %s late events: %w", window, err)
	}
	return nil
}

func runIncrementalLeaderboardUpdate(ctx context.Context, db *sql.DB, cfg Config, window string, now, lastOK time.Time) error {
	lookbackStart := lastOK.Add(-time.Duration(cfg.LateEventsLookbackHours) * time.Hour).Unix()
	endUnix := now.Unix()
	winStart := windowStart(window, now, cfg.PartialHistorySinceUnix)

	// Step 1a: find providers with new activity in
	// `[lookback_start, now)`. These are "lookback-active":
	// corrections + new rows have arrived for them.
	activeProvs, err := queryActiveProvidersInLookback(ctx, db, lookbackStart, endUnix)
	if err != nil {
		return fmt.Errorf("incremental %s active providers: %w", window, err)
	}

	// Step 1b — round-4 ARCH r4 HIGH 1 fix: also recompute
	// providers whose contributing rows just AGED OUT of the
	// window. The "aging-out slice" is
	// `[winStart - tickInterval, winStart)` — rows that crossed
	// the window boundary between the previous tick and now.
	// Without this, a provider with no new lookback activity
	// but whose old rows just expired would carry an inflated
	// total in the live snapshot until the nightly rebuild.
	//
	// `all` window has no aging-out (partial_history_since is
	// fixed); skip for that case.
	if window == "30d" {
		tickInterval := cfg.Leaderboard30dInterval
		agingStart := winStart - int64(tickInterval.Seconds()) - int64(cfg.LateEventsLookbackHours)*3600 // generous: include up to lastOK's age too
		agingEnd := winStart
		if agingStart < 0 {
			agingStart = 0
		}
		agingProvs, err := queryActiveProvidersInLookback(ctx, db, agingStart, agingEnd)
		if err != nil {
			return fmt.Errorf("incremental %s aging-out providers: %w", window, err)
		}
		// Merge into activeProvs (de-duplicate).
		seen := make(map[string]struct{}, len(activeProvs))
		for _, p := range activeProvs {
			seen[p] = struct{}{}
		}
		for _, p := range agingProvs {
			if _, ok := seen[p]; !ok {
				activeProvs = append(activeProvs, p)
				seen[p] = struct{}{}
			}
		}
	}

	// Step 2: for each active provider, recompute the full
	// window aggregate (provider-scoped).
	updates := make([]leaderboardRow, 0, len(activeProvs))
	visibility, err := loadProviderVisibility(ctx, db)
	if err != nil {
		return fmt.Errorf("incremental %s visibility load: %w", window, err)
	}
	for _, pid := range activeProvs {
		row, ok, perr := computeLeaderboardRowForProvider(ctx, db, cfg, window, pid, winStart, endUnix)
		if perr != nil {
			return fmt.Errorf("incremental %s provider %s: %w", window, pid, perr)
		}
		// Read provider_visibility but do NOT branch on .Blocked
		// (round-2 audit fix — v0.1 stub-only). v0.2 will pin
		// suppression semantic.
		_ = visibility[pid]
		if !ok {
			// Provider had no data in the window — drop them by
			// emitting a tombstone row with the zero bucket;
			// we'll actually DELETE in step 3.
			continue
		}
		updates = append(updates, row)
	}

	// Step 3: open the transaction. UPSERT updated providers,
	// DELETE drop-outs (providers in snapshot but not in
	// active set AND not in OLTP for the full window).
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("incremental %s begin: %w", window, err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()

	// Delete drop-outs FIRST: providers in the snapshot whose
	// last_seen_at is older than the window-start boundary
	// AND not in our update set.
	updatedSet := make(map[string]struct{}, len(updates))
	for _, u := range updates {
		updatedSet[u.ProviderID] = struct{}{}
	}
	if err := deleteDropOuts(ctx, tx, leaderboardTableForWindow(window), winStart, updatedSet); err != nil {
		return fmt.Errorf("incremental %s delete drop-outs: %w", window, err)
	}

	// UPSERT each updated provider's row (without ranks; we
	// recompute ranks after).
	table := leaderboardTableForWindow(window)
	for _, r := range updates {
		if err := upsertLeaderboardRowSansRank(ctx, tx, table, r, now); err != nil {
			return fmt.Errorf("incremental %s upsert %s: %w", window, r.ProviderID, err)
		}
	}

	// Re-rank: read all rows, sort by each axis, UPDATE ranks.
	if err := recomputeRanksInTx(ctx, tx, table); err != nil {
		return fmt.Errorf("incremental %s rerank: %w", window, err)
	}

	if err := healthOK(ctx, tx, componentForWindow(window), now); err != nil {
		return fmt.Errorf("incremental %s health: %w", window, err)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("incremental %s commit: %w", window, err)
	}
	committed = true
	return nil
}

// queryActiveProvidersInLookback returns provider_ids with any
// authenticated OLTP row in `[lookback_start, end)` — either
// work-side or rewards-side. These are the providers whose
// snapshot rows MAY have changed and need recomputation.
func queryActiveProvidersInLookback(ctx context.Context, db *sql.DB, lookbackStart, endUnix int64) ([]string, error) {
	const q = `
        SELECT DISTINCT pt.provider_id
          FROM provider_tokens pt
         WHERE EXISTS (
             SELECT 1 FROM ledger_request_credits lrc
              WHERE lrc.provider_id = pt.provider_id
                AND EXTRACT(EPOCH FROM lrc.ts_utc) >= $1
                AND EXTRACT(EPOCH FROM lrc.ts_utc) < $2
                AND lrc.fault_flag = 'none'
                AND lrc.quarantined = FALSE
         )
         OR EXISTS (
             SELECT 1 FROM provider_rewards_ledger prl
              WHERE prl.provider_id = pt.provider_id
                AND prl.unix_ts >= $1
                AND prl.unix_ts < $2
         )
    `
	rows, err := db.QueryContext(ctx, q, lookbackStart, endUnix)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			return nil, err
		}
		out = append(out, pid)
	}
	return out, rows.Err()
}

// computeLeaderboardRowForProvider computes a single provider's
// full-window aggregate. Returns (row, true, nil) if the
// provider has any data in the window; (row, false, nil) if
// there's no data (caller should treat as drop-out).
func computeLeaderboardRowForProvider(ctx context.Context, db *sql.DB, cfg Config, window, pid string, winStart, endUnix int64) (leaderboardRow, bool, error) {
	// Work aggregate for ONE provider.
	const workQ = `
        SELECT COALESCE(SUM(lrc.provider_credits), 0)::BIGINT AS credits,
               COALESCE(SUM(` + `COALESCE(lrc.prompt_tokens, 0) + (CASE lrc.usage_source WHEN 'byte_estimated' THEN COALESCE(lrc.estimated_completion_tokens, 0) WHEN 'null_error' THEN 0 ELSE COALESCE(lrc.completion_tokens, 0) END)` + `), 0)::BIGINT AS tokens,
               COUNT(DISTINCT lrc.request_id)::BIGINT AS jobs,
               MIN(lrc.ts_utc) AS first_seen,
               MAX(lrc.ts_utc) AS last_seen
          FROM ledger_request_credits lrc
          JOIN provider_tokens pt ON pt.provider_id = lrc.provider_id
         WHERE pt.provider_id = $1
           AND ($2 = 0 OR EXTRACT(EPOCH FROM lrc.ts_utc) >= $2)
           AND EXTRACT(EPOCH FROM lrc.ts_utc) < $3
           AND lrc.fault_flag = 'none'
           AND lrc.quarantined = FALSE
    `
	var w workAgg
	var first, last sql.NullTime
	if err := db.QueryRowContext(ctx, workQ, pid, winStart, endUnix).Scan(&w.credits, &w.tokens, &w.jobs, &first, &last); err != nil {
		return leaderboardRow{}, false, err
	}
	if first.Valid {
		t := first.Time
		w.firstSeen = &t
	}
	if last.Valid {
		t := last.Time
		w.lastSeen = &t
	}

	// Rewards aggregate for ONE provider.
	const rewardsQ = `
        SELECT COALESCE(SUM(prl.amount_usd), 0) AS amount,
               MAX(prl.unix_ts) AS last_unix_ts
          FROM provider_rewards_ledger prl
          JOIN provider_tokens pt ON pt.provider_id = prl.provider_id
         WHERE pt.provider_id = $1
           AND ($2 = 0 OR prl.unix_ts >= $2)
           AND prl.unix_ts < $3
    `
	var amtStr string
	var rewardsLastUnixTs sql.NullInt64
	if err := db.QueryRowContext(ctx, rewardsQ, pid, winStart, endUnix).Scan(&amtStr, &rewardsLastUnixTs); err != nil {
		return leaderboardRow{}, false, err
	}
	rewardsUSD, _ := new(big.Rat).SetString(amtStr)
	if rewardsUSD == nil {
		rewardsUSD = big.NewRat(0, 1)
	}

	// No activity at all → drop-out.
	if w.jobs == 0 && rewardsUSD.Sign() == 0 {
		return leaderboardRow{}, false, nil
	}

	// Round-4 ARCH r4 fix: last_seen_at combines work + rewards.
	// Earlier draft used only work.last_seen_at; a rewards-only
	// provider had NULL last_seen_at and the drop-out query
	// missed them.
	if rewardsLastUnixTs.Valid {
		rewardsTime := time.Unix(rewardsLastUnixTs.Int64, 0).UTC()
		if w.lastSeen == nil || rewardsTime.After(*w.lastSeen) {
			w.lastSeen = &rewardsTime
		}
		if w.firstSeen == nil {
			fs := rewardsTime
			w.firstSeen = &fs
		}
	}

	workUSD := usdFromCredits(w.credits, cfg.UsdPerMillionCredits)
	totalUSD := new(big.Rat).Add(workUSD, rewardsUSD)
	bucket, err := Bucket(window, totalUSD)
	if err != nil {
		return leaderboardRow{}, false, err
	}
	return leaderboardRow{
		ProviderID:         pid,
		Pseudonym:          pseudonymizeRow(pid),
		EarningsTotalUSD:   totalUSD,
		EarningsWorkUSD:    workUSD,
		EarningsRewardsUSD: rewardsUSD,
		Tokens:             w.tokens,
		Jobs:               w.jobs,
		FirstSeenAt:        w.firstSeen,
		LastSeenAt:         w.lastSeen,
		Bucket:             bucket,
	}, true, nil
}

// pseudonymizeRow is the same deterministic pseudonym hash as in
// leaderboard.go's pseudonymize, duplicated here to avoid the
// internal cross-file coupling required to reach the unexported
// helper from another file (Go compiler is fine with both; this
// is for grep-readability).
func pseudonymizeRow(providerID string) string {
	sum := sha256.Sum256([]byte("spec017-pseudonym:" + providerID))
	return "node-" + hex.EncodeToString(sum[:4])
}

// deleteDropOuts deletes providers in the snapshot whose
// last_seen_at fell outside the window-start boundary AND who
// are NOT in the current update set.
//
// Round-4 ARCH r4 fix: also catches providers with NULL
// last_seen_at — those are rewards-only providers from earlier
// ticks whose rewards have aged out (computeLeaderboardRowForProvider
// now sets last_seen_at from rewards too, but pre-fix rows may
// still have NULL).
//
// `winStart == 0` means "all" window with no partial_history_since
// — in that case there are no drop-outs by time (the window is
// open-ended at the start); only providers we're actively
// updating get UPSERTed.
func deleteDropOuts(ctx context.Context, tx *sql.Tx, table string, winStart int64, updatedSet map[string]struct{}) error {
	if winStart == 0 {
		return nil
	}
	q := fmt.Sprintf(`
        SELECT provider_id FROM %s
         WHERE last_seen_at IS NULL
            OR EXTRACT(EPOCH FROM last_seen_at) < $1
    `, table)
	rows, err := tx.QueryContext(ctx, q, winStart)
	if err != nil {
		return err
	}
	var toDelete []string
	for rows.Next() {
		var pid string
		if err := rows.Scan(&pid); err != nil {
			rows.Close()
			return err
		}
		if _, ok := updatedSet[pid]; !ok {
			toDelete = append(toDelete, pid)
		}
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, pid := range toDelete {
		if _, err := tx.ExecContext(ctx,
			fmt.Sprintf(`DELETE FROM %s WHERE provider_id = $1`, table), pid,
		); err != nil {
			return err
		}
	}
	return nil
}

// upsertLeaderboardRowSansRank UPSERTs the per-provider row
// WITHOUT writing the rank fields. Ranks are recomputed across
// the whole table in `recomputeRanksInTx` after all UPSERTs.
func upsertLeaderboardRowSansRank(ctx context.Context, tx *sql.Tx, table string, r leaderboardRow, generatedAt time.Time) error {
	q := fmt.Sprintf(`
        INSERT INTO %s (
            provider_id, pseudonym, generated_at,
            rank_earnings, rank_tokens, rank_jobs,
            earnings_usd, earnings_work_usd, earnings_rewards_usd,
            earnings_bucket, tokens, jobs,
            first_seen_at, last_seen_at
        ) VALUES (
            $1, $2, $3,
            0, 0, 0,
            $4, $5, $6,
            $7, $8, $9,
            $10, $11
        )
        ON CONFLICT (provider_id) DO UPDATE SET
            pseudonym = EXCLUDED.pseudonym,
            generated_at = EXCLUDED.generated_at,
            earnings_usd = EXCLUDED.earnings_usd,
            earnings_work_usd = EXCLUDED.earnings_work_usd,
            earnings_rewards_usd = EXCLUDED.earnings_rewards_usd,
            earnings_bucket = EXCLUDED.earnings_bucket,
            tokens = EXCLUDED.tokens,
            jobs = EXCLUDED.jobs,
            first_seen_at = EXCLUDED.first_seen_at,
            last_seen_at = EXCLUDED.last_seen_at
    `, table)
	_, err := tx.ExecContext(ctx, q,
		r.ProviderID, r.Pseudonym, generatedAt,
		r.EarningsTotalUSD.FloatString(2),
		r.EarningsWorkUSD.FloatString(2),
		r.EarningsRewardsUSD.FloatString(2),
		r.Bucket, r.Tokens, r.Jobs,
		r.FirstSeenAt, r.LastSeenAt,
	)
	return err
}

// recomputeRanksInTx reads the whole table, sorts by each axis
// (earnings/tokens/jobs), then UPDATEs each row's rank_*
// columns. Tie-break by provider_id text so ranks stay stable
// across ticks.
func recomputeRanksInTx(ctx context.Context, tx *sql.Tx, table string) error {
	q := fmt.Sprintf(`SELECT provider_id, earnings_usd, tokens, jobs FROM %s`, table)
	rows, err := tx.QueryContext(ctx, q)
	if err != nil {
		return err
	}
	var es []entry
	for rows.Next() {
		var pid, amtStr string
		var tokens, jobs int64
		if err := rows.Scan(&pid, &amtStr, &tokens, &jobs); err != nil {
			rows.Close()
			return err
		}
		r, _ := new(big.Rat).SetString(amtStr)
		if r == nil {
			r = big.NewRat(0, 1)
		}
		es = append(es, entry{pid: pid, earnings: r, tokens: tokens, jobs: jobs})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	// Compute ranks per axis.
	earningsRank := rankIndex(es, func(a, b entry) bool {
		c := a.earnings.Cmp(b.earnings)
		if c != 0 {
			return c > 0
		}
		return strings.Compare(a.pid, b.pid) < 0
	})
	tokensRank := rankIndex(es, func(a, b entry) bool {
		if a.tokens != b.tokens {
			return a.tokens > b.tokens
		}
		return strings.Compare(a.pid, b.pid) < 0
	})
	jobsRank := rankIndex(es, func(a, b entry) bool {
		if a.jobs != b.jobs {
			return a.jobs > b.jobs
		}
		return strings.Compare(a.pid, b.pid) < 0
	})

	upd := fmt.Sprintf(`UPDATE %s SET rank_earnings = $1, rank_tokens = $2, rank_jobs = $3 WHERE provider_id = $4`, table)
	for _, e := range es {
		if _, err := tx.ExecContext(ctx, upd,
			earningsRank[e.pid], tokensRank[e.pid], jobsRank[e.pid], e.pid,
		); err != nil {
			return err
		}
	}
	return nil
}

func rankIndex(es []entry, less func(a, b entry) bool) map[string]int {
	idx := make([]int, len(es))
	for i := range idx {
		idx[i] = i
	}
	sort.SliceStable(idx, func(i, j int) bool { return less(es[idx[i]], es[idx[j]]) })
	out := make(map[string]int, len(es))
	for rank, k := range idx {
		out[es[k].pid] = rank + 1
	}
	return out
}

// entry is the in-memory row representation used by
// recomputeRanksInTx + rankIndex. Kept package-level so the
// generic-shape less-func parameter and the slice type match.
type entry struct {
	pid      string
	earnings *big.Rat
	tokens   int64
	jobs     int64
}
