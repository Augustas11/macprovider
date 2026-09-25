package billing

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// DefaultPoolSettlementExpirySweepLimit bounds one sweep pass so a backlog
// never holds the money SQLite writer for long; the next pass continues. It is
// also the hard maximum: a larger caller limit is clamped to it.
const DefaultPoolSettlementExpirySweepLimit = 100

// A verdict whose finalization failed is not retried until its backoff
// expires: poolSweepBackoffBase after the first failure, doubling per
// consecutive failure up to poolSweepBackoffMax.
const (
	poolSweepBackoffBase = time.Minute
	poolSweepBackoffMax  = time.Hour
)

// poolSweepKey is the sweep's total order: (deadline, verdict id, snapshot
// id). The snapshot id is part of the key because one verdict can join
// snapshots from several account scopes, and a page must not split them.
type poolSweepKey struct {
	deadlineUnixMS int64
	verdictID      int64
	snapshotID     int64
}

type poolSweepBackoff struct {
	failures      int
	retryAtUnixMS int64
}

// poolSettlementSweepState is carried across passes, guarded by
// Store.poolSweepMu. A zero cursor means the start of the order.
type poolSettlementSweepState struct {
	cursor  poolSweepKey
	backoff map[int64]poolSweepBackoff // by settlement_receipt_verdicts.id
}

func poolSweepBackoffDelayMS(failures int) int64 {
	d := poolSweepBackoffBase
	for i := 1; i < failures && d < poolSweepBackoffMax; i++ {
		d *= 2
	}
	return min(d, poolSweepBackoffMax).Milliseconds()
}

// SweepExpiredPoolSettlementVerdicts closes open pending verdicts of pool
// attempts whose pending deadline has passed, exactly as a finality read
// would (RequestSettlementFinality calls RecordMissingSettlementReceipt for
// the same rows). A gateway retry can refund its reservation while the
// coordinator attempt stays pending; no later finality read reaches that
// attempt, so without this sweep its verdict never closes and
// pool-rollback-preflight blocks forever (SPEC-022-R012.8).
//
// Unexpired verdicts are never selected, and a verdict that is already closed
// is not selected again, so a pass is idempotent and changes nothing for an
// attempt still inside its receipt window. It returns how many verdicts the
// pass closed.
//
// A pass reads at most limit rows after a keyset cursor carried from the
// previous pass and wraps to the start once it reaches the end, so rows that
// keep failing cannot hold the selection window: every expired pool verdict
// is reached within a bounded number of passes. A failed verdict is skipped
// until its backoff expires, and a pass never attempts more than limit
// finalizations.
func (s *Store) SweepExpiredPoolSettlementVerdicts(ctx context.Context, nowUnixMS int64, limit int) (int, error) {
	if limit <= 0 || limit > DefaultPoolSettlementExpirySweepLimit {
		limit = DefaultPoolSettlementExpirySweepLimit
	}
	if nowUnixMS == 0 {
		nowUnixMS = s.nowUTC().UnixMilli()
	}
	s.poolSweepMu.Lock()
	defer s.poolSweepMu.Unlock()
	st := &s.poolSweep
	if st.backoff == nil {
		st.backoff = make(map[int64]poolSweepBackoff)
	}
	// Forget failures long past their retry time, so the map holds only
	// verdicts that failed recently (a verdict closed elsewhere drops out).
	for id, b := range st.backoff {
		if nowUnixMS-b.retryAtUnixMS >= poolSweepBackoffMax.Milliseconds() {
			delete(st.backoff, id)
		}
	}
	c := st.cursor
	rows, err := s.db.QueryContext(ctx, `
SELECT v.pending_deadline_unix_ms, v.id, rs.id,
       rs.account_scope, v.account_scope_hash, v.request_id, v.attempt_n, v.provider_id
  FROM settlement_receipt_verdicts v
  JOIN settlement_route_snapshots rs
    ON rs.request_id = v.request_id
   AND rs.attempt_n = v.attempt_n
   AND rs.provider_id = v.provider_id
 WHERE v.settlement_outcome = ? AND v.closed = 0
   AND v.pending_deadline_unix_ms > 0 AND v.pending_deadline_unix_ms <= ?
   AND rs.pool_id IS NOT NULL AND rs.pool_id != ''
   AND (v.pending_deadline_unix_ms, v.id, rs.id) > (?, ?, ?)
 ORDER BY v.pending_deadline_unix_ms ASC, v.id ASC, rs.id ASC
 LIMIT ?`, SettlementOutcomePending, nowUnixMS, c.deadlineUnixMS, c.verdictID, c.snapshotID, limit)
	if err != nil {
		return 0, err
	}
	type candidate struct {
		key    poolSweepKey
		id     SettlementReceiptIdentity
		ownRow bool
	}
	var page []candidate
	for rows.Next() {
		var accountScope, scopeHash string
		var cand candidate
		if err := rows.Scan(&cand.key.deadlineUnixMS, &cand.key.verdictID, &cand.key.snapshotID,
			&accountScope, &scopeHash, &cand.id.RequestID, &cand.id.AttemptN, &cand.id.ProviderID); err != nil {
			_ = rows.Close()
			return 0, err
		}
		// The join is on the request tuple; the verdict stores only the scope
		// hash, so a snapshot from another account scope is not this attempt.
		cand.ownRow = SettlementAccountScopeHash(accountScope) == scopeHash
		cand.id.AccountScope = accountScope
		page = append(page, cand)
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	// One attempt that cannot be finalized must not starve the rest of the
	// pass; its verdict stays open (preflight keeps blocking) and is retried
	// after its backoff.
	closed := 0
	var errs []error
	processed := 0
	for _, cand := range page {
		if err := ctx.Err(); err != nil {
			errs = append(errs, err)
			break
		}
		processed++
		if !cand.ownRow {
			continue
		}
		if b, ok := st.backoff[cand.key.verdictID]; ok && nowUnixMS < b.retryAtUnixMS {
			continue
		}
		state, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: cand.id,
			NowUnixMS:                 nowUnixMS,
		})
		if err != nil {
			b := st.backoff[cand.key.verdictID]
			b.failures++
			b.retryAtUnixMS = nowUnixMS + poolSweepBackoffDelayMS(b.failures)
			st.backoff[cand.key.verdictID] = b
			errs = append(errs, fmt.Errorf("sweep expired pool settlement verdict %s attempt %d: %w", cand.id.RequestID, cand.id.AttemptN, err))
			continue
		}
		delete(st.backoff, cand.key.verdictID)
		if state.Closed {
			closed++
		}
	}
	switch {
	case processed == len(page) && len(page) < limit:
		// Reached the end of the expired set: the next pass starts over.
		st.cursor = poolSweepKey{}
	case processed > 0:
		st.cursor = page[processed-1].key
	}
	return closed, errors.Join(errs...)
}
