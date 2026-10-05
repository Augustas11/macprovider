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
	// The unrecorded relay-blind pass has its own keyset cursor over
	// (route decision, snapshot id) and backoff by snapshot id.
	unrecordedCursor  unrecordedSweepKey
	unrecordedBackoff map[int64]poolSweepBackoff
}

type unrecordedSweepKey struct {
	routeDecisionUnixMS int64
	snapshotID          int64
}

func poolSweepBackoffDelayMS(failures int) int64 {
	d := poolSweepBackoffBase
	for i := 1; i < failures && d < poolSweepBackoffMax; i++ {
		d *= 2
	}
	return min(d, poolSweepBackoffMax).Milliseconds()
}

// SweepExpiredSettlementVerdicts closes every open pending verdict whose
// pinned deadline has passed, exactly as a finality read would
// (RequestSettlementFinality calls RecordMissingSettlementReceipt for the
// same row). This completes SPEC-022-R008 independently of whether a gateway
// retries finality or the route belonged to a provider pool.
//
// Unexpired verdicts are never selected, and a verdict that is already closed
// is not selected again, so a pass is idempotent and changes nothing for an
// attempt still inside its receipt window. It returns how many verdicts the
// pass closed.
//
// The same pass then closes enforce relay-blind attempts that have no verdict
// row at all (SPEC-022 R-14.10): see sweepUnrecordedRelayBlindAttempts.
//
// A pass reads at most limit rows after a keyset cursor carried from the
// previous pass and wraps to the start once it reaches the end, so rows that
// keep failing cannot hold the selection window: every expired pool verdict
// is reached within a bounded number of passes. A failed verdict is skipped
// until its backoff expires, and a pass never attempts more than limit
// finalizations.
func (s *Store) SweepExpiredSettlementVerdicts(ctx context.Context, nowUnixMS int64, limit int) (int, error) {
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
	rows, err := s.reader().QueryContext(ctx, `
SELECT v.pending_deadline_unix_ms, v.id, rs.id,
       rs.account_scope, v.account_scope_hash, v.request_id, v.attempt_n, v.provider_id
  FROM settlement_receipt_verdicts v
	  JOIN settlement_route_snapshots rs
	    ON rs.route_snapshot_digest = v.route_snapshot_digest
	   AND rs.request_id = v.request_id
	   AND rs.attempt_n = v.attempt_n
	   AND rs.provider_id = v.provider_id
	 WHERE v.settlement_outcome = ? AND v.closed = 0
	   AND v.pending_deadline_unix_ms > 0 AND v.pending_deadline_unix_ms < ?
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
	if ctx.Err() == nil {
		unrecorded, err := s.sweepUnrecordedRelayBlindAttempts(ctx, st, nowUnixMS, limit)
		closed += unrecorded
		if err != nil {
			errs = append(errs, err)
		}
	}
	return closed, errors.Join(errs...)
}

// relayBlindUnrecordedIndexSQL indexes only enforce relay-blind snapshots, so
// the unrecorded pass never scans ordinary route snapshots. The literals in
// its WHERE clause are repeated verbatim in the sweep query, which lets the
// SQLite planner use the partial index.
const relayBlindUnrecordedIndexSQL = `CREATE INDEX IF NOT EXISTS idx_srs_relay_blind_enforce_decision
    ON settlement_route_snapshots(route_decision_ts_unix_ms, id)
 WHERE paid_entrypoint = '` + PaidEntrypointRelayBlindChat + `' AND route_snapshot_mode = '` + RouteSnapshotModeEnforce + `'`

func (s *Store) ensureRelayBlindUnrecordedAttemptIndex(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, relayBlindUnrecordedIndexSQL)
	return err
}

// unrecordedRelayBlindSweepSQL pages enforce relay-blind snapshots past their
// R-14.10 deadline that have no attempt output and no credit. Arguments: the
// coarse decision bound (now - timeout), the timeout, now, the cursor, and the
// page limit.
const unrecordedRelayBlindSweepSQL = `
SELECT rs.route_decision_ts_unix_ms, rs.id, rs.account_scope, rs.request_id, rs.attempt_n, rs.provider_id
  FROM settlement_route_snapshots rs
 WHERE rs.paid_entrypoint = '` + PaidEntrypointRelayBlindChat + `' AND rs.route_snapshot_mode = '` + RouteSnapshotModeEnforce + `'
   AND rs.route_decision_ts_unix_ms < ?
   AND rs.route_decision_ts_unix_ms + ? + rs.pending_deadline_seconds * 1000 < ?
   AND (rs.route_decision_ts_unix_ms, rs.id) > (?, ?)
   AND NOT EXISTS (SELECT 1 FROM settlement_attempt_outputs sao
                    WHERE sao.account_scope = rs.account_scope AND sao.request_id = rs.request_id
                      AND sao.attempt_n = rs.attempt_n AND sao.provider_id = rs.provider_id)
   AND NOT EXISTS (SELECT 1 FROM ledger_request_credits lrc
                    WHERE lrc.request_id = rs.request_id AND lrc.attempt_n = rs.attempt_n
                      AND lrc.provider_id = rs.provider_id)
 ORDER BY rs.route_decision_ts_unix_ms ASC, rs.id ASC
 LIMIT ?`

// sweepUnrecordedRelayBlindAttempts closes, in bounded pages, every enforce
// relay-blind attempt whose snapshot committed before dispatch but which has
// no attempt output, no credit, and no verdict, once its SPEC-022 R-14.10
// deadline (route decision + relay-blind dispatch timeout +
// pending_deadline_seconds) is strictly past. Each attempt is revalidated and
// closed by the ordinary per-row missing-receipt writer, so it becomes closed
// quarantined with nothing payable even when no finality read ever asks.
//
// Only enforce relay-blind snapshots are selected. Other snapshot-only
// attempts are left as they are: an ordinary route has no pre-dispatch
// snapshot authority (its finality needs a credit or an attempt output), and
// observe and off modes keep their existing finality (R-14.6).
func (s *Store) sweepUnrecordedRelayBlindAttempts(ctx context.Context, st *poolSettlementSweepState, nowUnixMS int64, limit int) (int, error) {
	if st.unrecordedBackoff == nil {
		st.unrecordedBackoff = make(map[int64]poolSweepBackoff)
	}
	for id, b := range st.unrecordedBackoff {
		if nowUnixMS-b.retryAtUnixMS >= poolSweepBackoffMax.Milliseconds() {
			delete(st.unrecordedBackoff, id)
		}
	}
	timeoutMS := s.RelayBlindAttemptTimeout().Milliseconds()
	c := st.unrecordedCursor
	rows, err := s.reader().QueryContext(ctx, unrecordedRelayBlindSweepSQL, nowUnixMS-timeoutMS, timeoutMS, nowUnixMS, c.routeDecisionUnixMS, c.snapshotID, limit)
	if err != nil {
		return 0, err
	}
	type candidate struct {
		key unrecordedSweepKey
		id  SettlementReceiptIdentity
	}
	var page []candidate
	for rows.Next() {
		var cand candidate
		if err := rows.Scan(&cand.key.routeDecisionUnixMS, &cand.key.snapshotID,
			&cand.id.AccountScope, &cand.id.RequestID, &cand.id.AttemptN, &cand.id.ProviderID); err != nil {
			_ = rows.Close()
			return 0, err
		}
		page = append(page, cand)
	}
	if err := rows.Close(); err != nil {
		return 0, err
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	closed := 0
	processed := 0
	var errs []error
	for _, cand := range page {
		if err := ctx.Err(); err != nil {
			errs = append(errs, err)
			break
		}
		processed++
		// An attempt already closed here keeps matching the page filter;
		// skip it without a write.
		var hasVerdict bool
		if err := s.reader().QueryRowContext(ctx, `
SELECT EXISTS (SELECT 1 FROM settlement_receipt_verdicts
                WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?)`,
			SettlementAccountScopeHash(cand.id.AccountScope), cand.id.RequestID, cand.id.AttemptN, cand.id.ProviderID).Scan(&hasVerdict); err != nil {
			errs = append(errs, err)
			continue
		}
		if hasVerdict {
			continue
		}
		if b, ok := st.unrecordedBackoff[cand.key.snapshotID]; ok && nowUnixMS < b.retryAtUnixMS {
			continue
		}
		state, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: cand.id,
			NowUnixMS:                 nowUnixMS,
		})
		if err != nil {
			b := st.unrecordedBackoff[cand.key.snapshotID]
			b.failures++
			b.retryAtUnixMS = nowUnixMS + poolSweepBackoffDelayMS(b.failures)
			st.unrecordedBackoff[cand.key.snapshotID] = b
			// An attempt whose output or credit committed after the page
			// was read is no longer unrecorded; the ordinary paths own it.
			if !errors.Is(err, errSettlementAttemptOutputMissing) {
				errs = append(errs, fmt.Errorf("sweep unrecorded relay-blind attempt %s attempt %d: %w", cand.id.RequestID, cand.id.AttemptN, err))
			}
			continue
		}
		delete(st.unrecordedBackoff, cand.key.snapshotID)
		if state.Closed {
			closed++
		}
	}
	switch {
	case processed == len(page) && len(page) < limit:
		st.unrecordedCursor = unrecordedSweepKey{}
	case processed > 0:
		st.unrecordedCursor = page[processed-1].key
	}
	return closed, errors.Join(errs...)
}

// SweepExpiredPoolSettlementVerdicts is retained for callers compiled against
// the v0.2.0 pool-specific API. Deadline quarantine is now route-agnostic.
func (s *Store) SweepExpiredPoolSettlementVerdicts(ctx context.Context, nowUnixMS int64, limit int) (int, error) {
	return s.SweepExpiredSettlementVerdicts(ctx, nowUnixMS, limit)
}
