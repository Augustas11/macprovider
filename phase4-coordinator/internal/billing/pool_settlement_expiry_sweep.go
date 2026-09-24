package billing

import (
	"context"
	"errors"
	"fmt"
)

// DefaultPoolSettlementExpirySweepLimit bounds one sweep pass so a backlog
// never holds the money SQLite writer for long; the next pass continues.
const DefaultPoolSettlementExpirySweepLimit = 100

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
func (s *Store) SweepExpiredPoolSettlementVerdicts(ctx context.Context, nowUnixMS int64, limit int) (int, error) {
	if limit <= 0 {
		limit = DefaultPoolSettlementExpirySweepLimit
	}
	if nowUnixMS == 0 {
		nowUnixMS = s.nowUTC().UnixMilli()
	}
	rows, err := s.db.QueryContext(ctx, `
SELECT rs.account_scope, v.account_scope_hash, v.request_id, v.attempt_n, v.provider_id
  FROM settlement_receipt_verdicts v
  JOIN settlement_route_snapshots rs
    ON rs.request_id = v.request_id
   AND rs.attempt_n = v.attempt_n
   AND rs.provider_id = v.provider_id
 WHERE v.settlement_outcome = ? AND v.closed = 0
   AND v.pending_deadline_unix_ms > 0 AND v.pending_deadline_unix_ms <= ?
   AND rs.pool_id IS NOT NULL AND rs.pool_id != ''
 ORDER BY v.pending_deadline_unix_ms ASC, v.id ASC
 LIMIT ?`, SettlementOutcomePending, nowUnixMS, limit)
	if err != nil {
		return 0, err
	}
	var due []SettlementReceiptIdentity
	for rows.Next() {
		var accountScope, scopeHash string
		var id SettlementReceiptIdentity
		if err := rows.Scan(&accountScope, &scopeHash, &id.RequestID, &id.AttemptN, &id.ProviderID); err != nil {
			_ = rows.Close()
			return 0, err
		}
		// The join is on the request tuple; the verdict stores only the scope
		// hash, so a snapshot from another account scope is not this attempt.
		if SettlementAccountScopeHash(accountScope) != scopeHash {
			continue
		}
		id.AccountScope = accountScope
		due = append(due, id)
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	// One attempt that cannot be finalized must not starve the rest of the
	// pass; its verdict stays open (preflight keeps blocking) and is retried.
	closed := 0
	var errs []error
	for _, id := range due {
		if err := ctx.Err(); err != nil {
			errs = append(errs, err)
			break
		}
		state, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: id,
			NowUnixMS:                 nowUnixMS,
		})
		if err != nil {
			errs = append(errs, fmt.Errorf("sweep expired pool settlement verdict %s attempt %d: %w", id.RequestID, id.AttemptN, err))
			continue
		}
		if state.Closed {
			closed++
		}
	}
	return closed, errors.Join(errs...)
}
