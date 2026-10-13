package billing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

// routeSnapshotJournalTimeLayout is the strftime('%Y-%m-%dT%H:%M:%fZ') form
// of the journal's created_at_utc and mirrored_at_utc columns. A cutoff in the
// same fixed-width form compares correctly as text.
const routeSnapshotJournalTimeLayout = "2006-01-02T15:04:05.000Z"

// RouteSnapshotJournalPruneOptions bounds one SPEC-022 R-15.10 journal prune
// run: rows mirrored at least Grace ago, BatchSize rows per short journal
// transaction, BatchPause between batches, at most MaxBatches batches.
type RouteSnapshotJournalPruneOptions struct {
	Grace      time.Duration
	BatchSize  int
	BatchPause time.Duration
	MaxBatches int
}

// RouteSnapshotJournalPruneResult reports one prune run. Kept counts rows
// past the grace period that were not deleted because the primary row is
// missing or differs from the journal copy.
type RouteSnapshotJournalPruneResult struct {
	Scanned int64
	Deleted int64
	Kept    int64
}

type routeSnapshotJournalPruneRow struct {
	id         int64
	identity   SettlementReceiptIdentity
	digest     string
	rendered   string
	createdAt  string
	mirroredAt sql.NullString
}

// RouteSnapshotCanonicalJSON returns the digest preimage of a stored route
// snapshot. Rows that carry route_snapshot_canonical_json return it as
// stored; rows that store it empty (SPEC-022 R-15.10) recompute it from
// route_snapshot_json, which holds the same value.
func RouteSnapshotCanonicalJSON(storedCanonical, rendered string) ([]byte, error) {
	if storedCanonical != "" {
		return []byte(storedCanonical), nil
	}
	return canonicalRouteSnapshotFromRendered(rendered)
}

func canonicalRouteSnapshotFromRendered(rendered string) ([]byte, error) {
	dec := json.NewDecoder(strings.NewReader(rendered))
	dec.UseNumber()
	var value map[string]any
	if err := dec.Decode(&value); err != nil {
		return nil, fmt.Errorf("route snapshot json: %w", err)
	}
	if value == nil {
		return nil, fmt.Errorf("route snapshot json is not an object")
	}
	if _, err := dec.Token(); !errors.Is(err, io.EOF) {
		return nil, fmt.Errorf("route snapshot json has trailing data")
	}
	return CanonicalJSON(value)
}

// PruneMirroredRouteSnapshotJournal deletes route-snapshot journal rows that
// were mirrored at least opts.Grace ago and whose primary
// settlement_route_snapshots row carries the same digest and JSON, with the
// digest recomputing from the primary row's canonical preimage (SPEC-022
// R-15.10). An unmirrored row, a row still inside the grace period, and a
// row whose primary copy is missing or differs are never deleted. The scan
// walks the journal by id from a cursor kept across runs, so rows that stay
// behind never stop the walk; it restarts from the first row once it reaches
// rows inside the grace period.
func (s *Store) PruneMirroredRouteSnapshotJournal(ctx context.Context, opts RouteSnapshotJournalPruneOptions) (RouteSnapshotJournalPruneResult, error) {
	var result RouteSnapshotJournalPruneResult
	if s == nil {
		return result, fmt.Errorf("billing store is nil")
	}
	journalDB := s.routeSnapshotJournalDB.Load()
	if journalDB == nil {
		return result, nil
	}
	if opts.Grace <= 0 || opts.BatchSize <= 0 || opts.MaxBatches <= 0 {
		return result, fmt.Errorf("route snapshot journal prune options invalid")
	}
	cutoff := s.nowUTC().Add(-opts.Grace).Format(routeSnapshotJournalTimeLayout)
	s.routeSnapshotJournalPruneMu.Lock()
	defer s.routeSnapshotJournalPruneMu.Unlock()
	for batch := 0; batch < opts.MaxBatches; batch++ {
		if err := ctx.Err(); err != nil {
			return result, err
		}
		if batch > 0 && opts.BatchPause > 0 {
			timer := time.NewTimer(opts.BatchPause)
			select {
			case <-ctx.Done():
				timer.Stop()
				return result, ctx.Err()
			case <-timer.C:
			}
		}
		rows, err := loadRouteSnapshotJournalPruneBatch(ctx, journalDB, s.routeSnapshotJournalPruneCursor, opts.BatchSize)
		if err != nil {
			return result, err
		}
		reachedGrace := len(rows) < opts.BatchSize
		var candidates []routeSnapshotJournalPruneRow
		for _, row := range rows {
			if row.createdAt >= cutoff {
				// Ids follow insertion time: every later row is inside the
				// grace period too.
				reachedGrace = true
				break
			}
			result.Scanned++
			s.routeSnapshotJournalPruneCursor = row.id
			if row.mirroredAt.Valid && row.mirroredAt.String < cutoff {
				candidates = append(candidates, row)
			}
		}
		var verified []routeSnapshotJournalPruneRow
		for _, row := range candidates {
			ok, err := s.routeSnapshotJournalRowMatchesPrimary(ctx, row)
			if err != nil {
				return result, err
			}
			if ok {
				verified = append(verified, row)
			} else {
				result.Kept++
			}
		}
		deleted, err := deleteVerifiedRouteSnapshotJournalRows(ctx, journalDB, verified)
		result.Deleted += deleted
		if err != nil {
			return result, err
		}
		if reachedGrace {
			s.routeSnapshotJournalPruneCursor = 0
			return result, nil
		}
	}
	return result, nil
}

func loadRouteSnapshotJournalPruneBatch(ctx context.Context, db *sql.DB, afterID int64, limit int) ([]routeSnapshotJournalPruneRow, error) {
	rows, err := db.QueryContext(ctx, `
SELECT id, account_scope, request_id, attempt_n, provider_id,
       route_snapshot_digest, route_snapshot_json, created_at_utc, mirrored_at_utc
  FROM settlement_route_snapshot_journal
 WHERE id > ?
 ORDER BY id
 LIMIT ?`, afterID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []routeSnapshotJournalPruneRow
	for rows.Next() {
		var row routeSnapshotJournalPruneRow
		if err := rows.Scan(&row.id, &row.identity.AccountScope, &row.identity.RequestID, &row.identity.AttemptN,
			&row.identity.ProviderID, &row.digest, &row.rendered, &row.createdAt, &row.mirroredAt); err != nil {
			return nil, err
		}
		out = append(out, row)
	}
	return out, rows.Err()
}

// routeSnapshotJournalRowMatchesPrimary reports whether the primary row of
// the journal row's attempt holds the same digest and JSON and its canonical
// preimage hashes to that digest.
func (s *Store) routeSnapshotJournalRowMatchesPrimary(ctx context.Context, row routeSnapshotJournalPruneRow) (bool, error) {
	var digest, rendered, canonical string
	err := s.reader().QueryRowContext(ctx, `
SELECT route_snapshot_digest, route_snapshot_json, route_snapshot_canonical_json
  FROM settlement_route_snapshots
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		row.identity.AccountScope, row.identity.RequestID, row.identity.AttemptN, row.identity.ProviderID,
	).Scan(&digest, &rendered, &canonical)
	if errors.Is(err, sql.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if digest != row.digest || rendered != row.rendered {
		return false, nil
	}
	preimage, err := RouteSnapshotCanonicalJSON(canonical, rendered)
	if err != nil {
		return false, nil
	}
	sum := sha256.Sum256(preimage)
	return hex.EncodeToString(sum[:]) == digest, nil
}

func deleteVerifiedRouteSnapshotJournalRows(ctx context.Context, db *sql.DB, rows []routeSnapshotJournalPruneRow) (int64, error) {
	if len(rows) == 0 {
		return 0, nil
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer func() { _ = tx.Rollback() }()
	var deleted int64
	for _, row := range rows {
		res, err := tx.ExecContext(ctx, `
DELETE FROM settlement_route_snapshot_journal
 WHERE id = ? AND route_snapshot_digest = ? AND mirrored_at_utc IS NOT NULL`, row.id, row.digest)
		if err != nil {
			return 0, err
		}
		n, err := res.RowsAffected()
		if err != nil {
			return 0, err
		}
		deleted += n
	}
	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return deleted, nil
}
