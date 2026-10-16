package billing

import (
	"context"
	"errors"
	"time"
)

// maxCreatorEarningsIDs bounds each IN list of the creator earnings read.
const maxCreatorEarningsIDs = 1000

// CreatorPoolEarnings is one pool's payable provider credits for a
// SPEC-043-R010 0.3.0 creator earnings read.
type CreatorPoolEarnings struct {
	PoolID          string
	PayableRequests int64
	ProviderCredits int64
}

// CreatorPoolEarnings sums payable provider credits (the SPEC-022 payable
// view) earned by providerIDs on requests whose immutable settlement route
// snapshot carries one of poolIDs, optionally limited to [from, to). It is a
// read-only display aggregate on the read pool: provider earnings, never a
// creator revenue split.
func (s *Store) CreatorPoolEarnings(ctx context.Context, providerIDs, poolIDs []string, from, to time.Time) ([]CreatorPoolEarnings, error) {
	if s == nil {
		return nil, errors.New("billing: store unavailable")
	}
	if len(providerIDs) == 0 || len(poolIDs) == 0 {
		return nil, nil
	}
	if len(providerIDs) > maxCreatorEarningsIDs || len(poolIDs) > maxCreatorEarningsIDs {
		return nil, errors.New("billing: creator earnings id list too large")
	}
	args := make([]any, 0, len(providerIDs)+len(poolIDs)+2)
	for _, id := range providerIDs {
		args = append(args, id)
	}
	rangeSQL := ""
	if !from.IsZero() || !to.IsZero() {
		if from.IsZero() || to.IsZero() || !to.After(from) {
			return nil, errors.New("billing: invalid creator earnings range")
		}
		rangeSQL = " AND " + sqliteTimeRange("p.ts_utc")
		args = append(args, sqliteTimeText(from), sqliteTimeText(to))
	}
	for _, id := range poolIDs {
		args = append(args, id)
	}
	// The route snapshot is the immutable pool binding of a settled attempt
	// (SPEC-043-R010); a credit without a pool-bound snapshot is not pool
	// earnings.
	// SPEC-022 R-15.6/R-15.11 (#1793): an archived credit keeps its pool
	// binding on its tombstone, and a rolled-up credit in its rollup row.
	rollupRange := ""
	var rollupArgs []any
	if rangeSQL != "" {
		rollupRange = " AND hour_utc >= ? AND hour_utc < ?"
		// Rollup hours wholly inside [from, to).
		lo := from.UTC().Truncate(time.Hour)
		if lo.Before(from.UTC()) {
			lo = lo.Add(time.Hour)
		}
		rollupArgs = append(rollupArgs, earningsHourKey(lo), earningsHourKey(to.UTC().Truncate(time.Hour)))
	}
	for _, id := range providerIDs {
		rollupArgs = append(rollupArgs, id)
	}
	for _, id := range poolIDs {
		rollupArgs = append(rollupArgs, id)
	}
	args = append(args, rollupArgs...)
	query := `
SELECT pool_id, SUM(n), COALESCE(SUM(provider_credits), 0)
  FROM (
    SELECT pool_id, COUNT(*) AS n, COALESCE(SUM(provider_credits), 0) AS provider_credits
      FROM (
        SELECT p.provider_credits AS provider_credits,
               COALESCE((SELECT srs.pool_id
                  FROM settlement_route_snapshots srs
                 WHERE srs.request_id = p.request_id
                   AND srs.attempt_n = p.attempt_n
                   AND srs.provider_id = p.provider_id
                   AND srs.pool_id IS NOT NULL
                 ORDER BY srs.id
                 LIMIT 1),
                 (SELECT a.pool_id FROM settlement_evidence_archived_credits a
                   WHERE a.request_credit_id = p.id)) AS pool_id
          FROM spec022_payable_request_credits p
         WHERE p.provider_id IN (` + sqlPlaceholders(len(providerIDs)) + `)` + rangeSQL + `
      )
     WHERE pool_id IN (` + sqlPlaceholders(len(poolIDs)) + `)
     GROUP BY pool_id
    UNION ALL
    SELECT pool_id, SUM(credit_count), SUM(provider_credits)
      FROM ledger_settled_rollups
     WHERE pool_id != ''` + rollupRange + `
       AND provider_id IN (` + sqlPlaceholders(len(providerIDs)) + `)
       AND pool_id IN (` + sqlPlaceholders(len(poolIDs)) + `)
     GROUP BY pool_id
  )
 GROUP BY pool_id
 ORDER BY pool_id`
	rows, err := s.reader().QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []CreatorPoolEarnings
	for rows.Next() {
		var row CreatorPoolEarnings
		if err := rows.Scan(&row.PoolID, &row.PayableRequests, &row.ProviderCredits); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
}
