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
	// The unrecorded relay-blind pass walks settlement_route_snapshots by
	// its INTEGER PRIMARY KEY: every snapshot id at or below
	// unrecordedCursor is settled for that pass. The cursor is positioned
	// once per process (unrecordedPositioned). Attempts whose close failed
	// are retried by snapshot id after their backoff.
	unrecordedCursor     int64
	unrecordedPositioned bool
	unrecordedRetry      map[int64]unrecordedRetry
}

type unrecordedRetry struct {
	poolSweepBackoff
	id SettlementReceiptIdentity
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

// unrecordedRelayBlindSweepScanFactor sizes the unrecorded pass's snapshot
// id window: one pass examines at most limit * factor snapshot rows, by
// primary key, and closes at most limit attempts.
const unrecordedRelayBlindSweepScanFactor = 10

// unrecordedRelayBlindSweepLookback is how far back, by route decision time,
// a newly started process begins its walk. An older unrecorded attempt is
// still closed by any finality read that asks for it (R-14.10).
const unrecordedRelayBlindSweepLookback = 7 * 24 * time.Hour

// unrecordedRelayBlindSweepSQL reads the enforce relay-blind snapshots in one
// primary-key window. It uses only the INTEGER PRIMARY KEY of
// settlement_route_snapshots, so it examines at most the window's rows and
// needs no extra index on the large money database. Arguments: the timeout,
// now, the window's exclusive lower and inclusive upper snapshot id.
const unrecordedRelayBlindSweepSQL = `
SELECT rs.id, rs.account_scope, rs.request_id, rs.attempt_n, rs.provider_id,
       rs.route_decision_ts_unix_ms + ? + rs.pending_deadline_seconds * 1000 < ?,
       EXISTS (SELECT 1 FROM settlement_attempt_outputs sao
                WHERE sao.account_scope = rs.account_scope AND sao.request_id = rs.request_id
                  AND sao.attempt_n = rs.attempt_n AND sao.provider_id = rs.provider_id)
       OR EXISTS (SELECT 1 FROM ledger_request_credits lrc
                   WHERE lrc.request_id = rs.request_id AND lrc.attempt_n = rs.attempt_n
                     AND lrc.provider_id = rs.provider_id)
  FROM settlement_route_snapshots rs
 WHERE rs.id > ? AND rs.id <= ?
   AND rs.paid_entrypoint = '` + PaidEntrypointRelayBlindChat + `' AND rs.route_snapshot_mode = '` + RouteSnapshotModeEnforce + `'
 ORDER BY rs.id ASC`

// positionUnrecordedRelayBlindSweep returns the snapshot id a new process
// starts after: the last snapshot whose route decision is older than the
// lookback. Snapshot ids follow insertion order, which follows route
// decision time, so a binary search over primary-key probes finds it
// without a scan.
func (s *Store) positionUnrecordedRelayBlindSweep(ctx context.Context, maxID, floorUnixMS int64) (int64, error) {
	lo, hi := int64(0), maxID
	for lo < hi {
		mid := lo + (hi-lo+1)/2
		var id, decision int64
		err := s.reader().QueryRowContext(ctx, `
SELECT id, route_decision_ts_unix_ms FROM settlement_route_snapshots
 WHERE id >= ? ORDER BY id ASC LIMIT 1`, mid).Scan(&id, &decision)
		if err != nil {
			return 0, err
		}
		if decision < floorUnixMS {
			lo = id
		} else {
			hi = mid - 1
		}
	}
	return lo, nil
}

// sweepUnrecordedRelayBlindAttempts closes, in bounded passes, every enforce
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
//
// A pass examines one primary-key window of at most limit *
// unrecordedRelayBlindSweepScanFactor snapshot rows after the cursor and
// closes at most limit attempts. The cursor stops before the first
// relay-blind attempt still inside its deadline, so that attempt is examined
// again; an attempt whose close failed moves to the retry set instead of
// holding the cursor.
func (s *Store) sweepUnrecordedRelayBlindAttempts(ctx context.Context, st *poolSettlementSweepState, nowUnixMS int64, limit int) (int, error) {
	if st.unrecordedRetry == nil {
		st.unrecordedRetry = make(map[int64]unrecordedRetry)
	}
	var maxID int64
	if err := s.reader().QueryRowContext(ctx, `SELECT COALESCE(MAX(id), 0) FROM settlement_route_snapshots`).Scan(&maxID); err != nil {
		return 0, err
	}
	if !st.unrecordedPositioned {
		cursor, err := s.positionUnrecordedRelayBlindSweep(ctx, maxID, nowUnixMS-unrecordedRelayBlindSweepLookback.Milliseconds())
		if err != nil {
			return 0, err
		}
		st.unrecordedCursor, st.unrecordedPositioned = cursor, true
	}
	closed := 0
	attempted := 0
	var errs []error
	// retry keeps a failed attempt for a later pass after its backoff.
	retry := func(snapshotID int64, id SettlementReceiptIdentity, err error) {
		r := st.unrecordedRetry[snapshotID]
		r.id = id
		r.failures++
		r.retryAtUnixMS = nowUnixMS + poolSweepBackoffDelayMS(r.failures)
		st.unrecordedRetry[snapshotID] = r
		errs = append(errs, fmt.Errorf("sweep unrecorded relay-blind attempt %s attempt %d: %w", id.RequestID, id.AttemptN, err))
	}
	// finalize closes one attempt; it reports whether the attempt is done
	// (closed, already decided, or now owned by the ordinary paths).
	finalize := func(snapshotID int64, id SettlementReceiptIdentity) bool {
		// An attempt already closed here stays a relay-blind snapshot
		// without output or credit; skip it without a write.
		var hasVerdict bool
		if err := s.reader().QueryRowContext(ctx, `
SELECT EXISTS (SELECT 1 FROM settlement_receipt_verdicts
                WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?)`,
			SettlementAccountScopeHash(id.AccountScope), id.RequestID, id.AttemptN, id.ProviderID).Scan(&hasVerdict); err != nil {
			retry(snapshotID, id, err)
			return false
		}
		if hasVerdict {
			return true
		}
		attempted++
		state, err := s.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: id,
			NowUnixMS:                 nowUnixMS,
		})
		// An attempt whose output or credit committed after the window was
		// read is no longer unrecorded; the ordinary paths own it.
		if errors.Is(err, errSettlementAttemptOutputMissing) {
			return true
		}
		if err != nil {
			retry(snapshotID, id, err)
			return false
		}
		if state.Closed {
			closed++
		}
		return true
	}
	for snapshotID, r := range st.unrecordedRetry {
		if attempted >= limit || ctx.Err() != nil {
			break
		}
		if nowUnixMS < r.retryAtUnixMS {
			continue
		}
		if finalize(snapshotID, r.id) {
			delete(st.unrecordedRetry, snapshotID)
		}
	}
	lower := st.unrecordedCursor
	upper := min(lower+int64(limit)*unrecordedRelayBlindSweepScanFactor, maxID)
	if upper <= lower {
		return closed, errors.Join(errs...)
	}
	timeoutMS := s.RelayBlindAttemptTimeout().Milliseconds()
	rows, err := s.reader().QueryContext(ctx, unrecordedRelayBlindSweepSQL, timeoutMS, nowUnixMS, lower, upper)
	if err != nil {
		return closed, errors.Join(append(errs, err)...)
	}
	type candidate struct {
		snapshotID int64
		id         SettlementReceiptIdentity
		expired    bool
		recorded   bool
	}
	var window []candidate
	for rows.Next() {
		var cand candidate
		if err := rows.Scan(&cand.snapshotID, &cand.id.AccountScope, &cand.id.RequestID, &cand.id.AttemptN, &cand.id.ProviderID,
			&cand.expired, &cand.recorded); err != nil {
			_ = rows.Close()
			return closed, errors.Join(append(errs, err)...)
		}
		window = append(window, cand)
	}
	if err := rows.Close(); err != nil {
		return closed, errors.Join(append(errs, err)...)
	}
	if err := rows.Err(); err != nil {
		return closed, errors.Join(append(errs, err)...)
	}
	next := upper
	for _, cand := range window {
		if err := ctx.Err(); err != nil {
			errs = append(errs, err)
			next = min(next, cand.snapshotID-1)
			break
		}
		if !cand.expired {
			next = min(next, cand.snapshotID-1)
			continue
		}
		if cand.recorded {
			continue
		}
		if _, retrying := st.unrecordedRetry[cand.snapshotID]; retrying {
			continue
		}
		if attempted >= limit {
			next = min(next, cand.snapshotID-1)
			break
		}
		finalize(cand.snapshotID, cand.id)
	}
	st.unrecordedCursor = next
	return closed, errors.Join(errs...)
}

// SweepExpiredPoolSettlementVerdicts is retained for callers compiled against
// the v0.2.0 pool-specific API. Deadline quarantine is now route-agnostic.
func (s *Store) SweepExpiredPoolSettlementVerdicts(ctx context.Context, nowUnixMS int64, limit int) (int, error) {
	return s.SweepExpiredSettlementVerdicts(ctx, nowUnixMS, limit)
}
