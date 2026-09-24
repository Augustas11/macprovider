package billing

import (
	"context"
	"database/sql"
	"time"
)

// PoolRollbackPreflight reports whether a downgrade to a coordinator that
// predates the SPEC-022 v0.2.0 pool settlement path (#1690) can strand pool
// settlement. Such a binary rejects usage_source pool_operator_attested and
// recomputes pool route-snapshot digests without the SPEC-042-R006 labels,
// so any pool attempt that can still reach receipt ingestion or a verdict
// update would be left unverifiable, pending, or quarantined. Closed verdicts
// are final (credit syncs inside the verdict transaction), and an attempt
// with no verdict whose pending deadline has passed can no longer receive a
// receipt, so neither blocks.
type PoolRollbackPreflight struct {
	PoolRouteSnapshots int   `json:"pool_route_snapshots"`
	OpenPoolVerdicts   int   `json:"open_pool_verdicts"`
	InWindowNoVerdict  int   `json:"in_window_pool_attempts_without_verdict"`
	RollbackBlocked    bool  `json:"rollback_blocked"`
	EarliestSafeUnixMS int64 `json:"earliest_safe_unix_ms,omitempty"`
}

// CheckPoolRollbackPreflight is read-only: it runs plain SELECTs against the
// request-log/billing database and never migrates it.
func CheckPoolRollbackPreflight(ctx context.Context, db *sql.DB, now time.Time) (PoolRollbackPreflight, error) {
	var out PoolRollbackPreflight
	rows, err := db.QueryContext(ctx, `
SELECT account_scope, request_id, attempt_n, provider_id, route_decision_ts_unix_ms, pending_deadline_seconds
  FROM settlement_route_snapshots
 WHERE pool_id IS NOT NULL AND pool_id != ''`)
	if err != nil {
		return out, err
	}
	type poolAttempt struct {
		accountScope, requestID, providerID  string
		attemptN, routeDecisionMS, deadlineS int64
	}
	var attempts []poolAttempt
	for rows.Next() {
		var a poolAttempt
		if err := rows.Scan(&a.accountScope, &a.requestID, &a.attemptN, &a.providerID, &a.routeDecisionMS, &a.deadlineS); err != nil {
			_ = rows.Close()
			return out, err
		}
		attempts = append(attempts, a)
	}
	if err := rows.Close(); err != nil {
		return out, err
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	nowMS := now.UTC().UnixMilli()
	for _, a := range attempts {
		out.PoolRouteSnapshots++
		var closed int64
		err := db.QueryRowContext(ctx, `
SELECT closed FROM settlement_receipt_verdicts
 WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
			redactedAccountScopeHash(a.accountScope), a.requestID, a.attemptN, a.providerID).Scan(&closed)
		switch {
		case err == sql.ErrNoRows:
			deadlineMS := a.routeDecisionMS + a.deadlineS*1000
			if nowMS < deadlineMS {
				out.InWindowNoVerdict++
				if deadlineMS > out.EarliestSafeUnixMS {
					out.EarliestSafeUnixMS = deadlineMS
				}
			}
		case err != nil:
			return out, err
		case closed != 1:
			out.OpenPoolVerdicts++
		}
	}
	out.RollbackBlocked = out.OpenPoolVerdicts > 0 || out.InWindowNoVerdict > 0
	if out.OpenPoolVerdicts > 0 {
		// An open verdict closes on a receipt, a finality read, or the
		// coordinator's expiry sweep after its deadline; an undecidable
		// one may stay open, so no time bound is reported.
		out.EarliestSafeUnixMS = 0
	}
	return out, nil
}
