package billing

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"
)

func TestSweepExpiredPoolSettlementVerdictsUnblocksRollbackPreflight(t *testing.T) {
	ctx := context.Background()
	pooled := r012SettlementInput(t, "receipt_tuple_v4_normal_done", true)
	native := r012SettlementInput(t, "receipt_tuple_v4_buyer_cancel_prefix", false)
	if pooled.RequestID == native.RequestID {
		t.Fatalf("fixture request ids collide: %s", pooled.RequestID)
	}
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetPoolOperatorAttestationAuthority(&fakePoolAttestationAuthority{})
	seedSettlementReceiptEvidence(t, store, pooled)
	seedSettlementReceiptEvidence(t, store, native)
	insertSPEC022LedgerCredit(t, store.db, pooled, 700)

	// The gateway-retry shape: a pending verdict opened in-window that no
	// later finality read will reach.
	openPending := func(in SettlementVerifyInput) int64 {
		t.Helper()
		deadline := in.TerminalStateTSUnixMS + in.RouteSnapshot.PendingDeadlineSeconds*1000
		state, err := store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: settlementIdentityFromInput(in),
			NowUnixMS:                 deadline - 100,
		})
		if err != nil {
			t.Fatal(err)
		}
		if state.Closed || state.SettlementOutcome != SettlementOutcomePending {
			t.Fatalf("in-window missing receipt: %+v, want open pending", state)
		}
		return deadline
	}
	deadline := openPending(pooled)
	nativeDeadline := openPending(native)

	verdictRows := func() int64 {
		return scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts`)
	}
	auditRows := func() int64 {
		return scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox`)
	}
	poolClosed := func() int64 {
		return scalar(t, store.db, `SELECT closed FROM settlement_receipt_verdicts WHERE request_id = ?`, pooled.RequestID)
	}

	// Unexpired: nothing is swept, nothing is written, preflight still blocks.
	beforeVerdicts, beforeAudit := verdictRows(), auditRows()
	n, err := store.SweepExpiredPoolSettlementVerdicts(ctx, deadline-50, 0)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 || poolClosed() != 0 || verdictRows() != beforeVerdicts || auditRows() != beforeAudit {
		t.Fatalf("unexpired sweep closed=%d pool_closed=%d, want no change", n, poolClosed())
	}
	blocked, err := CheckPoolRollbackPreflight(ctx, store.db, time.UnixMilli(deadline+time.Hour.Milliseconds()))
	if err != nil {
		t.Fatal(err)
	}
	if !blocked.RollbackBlocked || blocked.OpenPoolVerdicts != 1 {
		t.Fatalf("expired open pool verdict before sweep: %+v, want blocked", blocked)
	}

	// Expired: the pool verdict is finalized as a finality read would, and
	// preflight clears. The expired native verdict is left to its own reader.
	sweepAt := max(deadline, nativeDeadline) + 1000
	n, err = store.SweepExpiredPoolSettlementVerdicts(ctx, sweepAt, 0)
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 || poolClosed() != 1 {
		t.Fatalf("expired sweep closed=%d pool_closed=%d, want 1/1", n, poolClosed())
	}
	if got := scalar(t, store.db, `SELECT closed FROM settlement_receipt_verdicts WHERE request_id = ?`, native.RequestID); got != 0 {
		t.Fatalf("native verdict closed=%d, want untouched", got)
	}
	var outcome string
	if err := store.db.QueryRow(`SELECT settlement_outcome FROM settlement_receipt_verdicts WHERE request_id = ?`, pooled.RequestID).Scan(&outcome); err != nil {
		t.Fatal(err)
	}
	if outcome == SettlementOutcomePending || outcome == SettlementOutcomeVerified {
		t.Fatalf("swept pool verdict outcome=%s, want a terminal missing-receipt outcome", outcome)
	}
	clear, err := CheckPoolRollbackPreflight(ctx, store.db, time.UnixMilli(sweepAt))
	if err != nil {
		t.Fatal(err)
	}
	if clear.RollbackBlocked || clear.OpenPoolVerdicts != 0 {
		t.Fatalf("after sweep: %+v, want clear", clear)
	}

	// Idempotent: a second pass selects nothing and writes nothing.
	afterVerdicts, afterAudit := verdictRows(), auditRows()
	n, err = store.SweepExpiredPoolSettlementVerdicts(ctx, sweepAt+time.Hour.Milliseconds(), 0)
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 || verdictRows() != afterVerdicts || auditRows() != afterAudit {
		t.Fatalf("second sweep closed=%d verdicts %d->%d audit %d->%d, want no change", n, afterVerdicts, verdictRows(), afterAudit, auditRows())
	}

	// The swept outcome matches what a finality read would have produced.
	finality, found, err := store.RequestSettlementFinality(ctx, pooled.AccountScope, pooled.RequestID, sweepAt)
	if err != nil || !found {
		t.Fatalf("finality found=%v err=%v", found, err)
	}
	if !finality.Closed || finality.PendingAttempts != 0 {
		t.Fatalf("finality after sweep: %+v, want closed", finality)
	}
}

// poolSweepFailures counts the finalizations a pass attempted that failed:
// each failure is one joined error.
func poolSweepFailures(err error) int {
	if err == nil {
		return 0
	}
	if j, ok := err.(interface{ Unwrap() []error }); ok {
		return len(j.Unwrap())
	}
	return 1
}

// clonePoolVerdict copies the pooled attempt's snapshot and verdict under a
// new request id with no attempt evidence behind it, so finalizing it fails
// on every pass.
func clonePoolVerdict(t *testing.T, store *Store, from, requestID string, deadlineUnixMS int64) {
	t.Helper()
	columns := func(table string) []string {
		t.Helper()
		rows, err := store.db.Query(`SELECT name FROM pragma_table_info(?) WHERE name != 'id'`, table)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var out []string
		for rows.Next() {
			var name string
			if err := rows.Scan(&name); err != nil {
				t.Fatal(err)
			}
			out = append(out, name)
		}
		return out
	}
	clone := func(table string, overrides map[string]string, args ...any) {
		t.Helper()
		cols := columns(table)
		sel := make([]string, len(cols))
		for i, c := range cols {
			sel[i] = c
			if expr, ok := overrides[c]; ok {
				sel[i] = expr
			}
		}
		q := fmt.Sprintf(`INSERT INTO %s (%s) SELECT %s FROM %s WHERE request_id = ?`,
			table, strings.Join(cols, ", "), strings.Join(sel, ", "), table)
		if _, err := store.db.Exec(q, append(args, from)...); err != nil {
			t.Fatalf("clone %s: %v", table, err)
		}
	}
	clone("settlement_route_snapshots", map[string]string{"request_id": "?"}, requestID)
	clone("settlement_receipt_verdicts", map[string]string{"request_id": "?", "pending_deadline_unix_ms": "?"}, requestID, deadlineUnixMS)
}

func TestSweepExpiredPoolSettlementVerdictsFailingBacklogCannotStarve(t *testing.T) {
	ctx := context.Background()
	pooled := r012SettlementInput(t, "receipt_tuple_v4_normal_done", true)
	native := r012SettlementInput(t, "receipt_tuple_v4_buyer_cancel_prefix", false)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetPoolOperatorAttestationAuthority(&fakePoolAttestationAuthority{})
	seedSettlementReceiptEvidence(t, store, pooled)
	seedSettlementReceiptEvidence(t, store, native)
	insertSPEC022LedgerCredit(t, store.db, pooled, 700)
	openPending := func(in SettlementVerifyInput) int64 {
		t.Helper()
		deadline := in.TerminalStateTSUnixMS + in.RouteSnapshot.PendingDeadlineSeconds*1000
		if _, err := store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{
			SettlementReceiptIdentity: settlementIdentityFromInput(in),
			NowUnixMS:                 deadline - 100,
		}); err != nil {
			t.Fatal(err)
		}
		return deadline
	}
	deadline := openPending(pooled)
	nativeDeadline := openPending(native)
	sweepAt := max(deadline, nativeDeadline) + 1000

	// 150 permanently failing expired pool verdicts ordered ahead of the
	// valid one, and one unexpired pool verdict.
	const failing = 150
	for i := range failing {
		clonePoolVerdict(t, store, pooled.RequestID, fmt.Sprintf("%s-fail-%03d", pooled.RequestID, i), deadline-1)
	}
	unexpiredID := pooled.RequestID + "-unexpired"
	clonePoolVerdict(t, store, pooled.RequestID, unexpiredID, sweepAt+10*time.Hour.Milliseconds())
	rowState := func(requestID string) string {
		t.Helper()
		var closed, received int64
		var outcome string
		var updated sql.NullString
		if err := store.db.QueryRow(`SELECT closed, settlement_outcome, received_at_unix_ms, updated_at_utc FROM settlement_receipt_verdicts WHERE request_id = ?`, requestID).Scan(&closed, &outcome, &received, &updated); err != nil {
			t.Fatal(err)
		}
		return fmt.Sprintf("closed=%d outcome=%s received=%d updated=%v", closed, outcome, received, updated)
	}
	nativeBefore, unexpiredBefore := rowState(native.RequestID), rowState(unexpiredID)
	pooledClosed := func() int64 {
		return scalar(t, store.db, `SELECT closed FROM settlement_receipt_verdicts WHERE request_id = ?`, pooled.RequestID)
	}
	pass := func(now int64, limit int) (int, int) {
		t.Helper()
		n, err := store.SweepExpiredPoolSettlementVerdicts(ctx, now, limit)
		f := poolSweepFailures(err)
		if n+f > DefaultPoolSettlementExpirySweepLimit {
			t.Fatalf("pass attempted %d finalizations, hard cap is %d", n+f, DefaultPoolSettlementExpirySweepLimit)
		}
		return n, f
	}

	// Pass 1: the first 100 failing rows fill the window, and a caller limit
	// above the hard cap is clamped.
	if n, f := pass(sweepAt, 1000); n != 0 || f != DefaultPoolSettlementExpirySweepLimit || pooledClosed() != 0 {
		t.Fatalf("pass 1 closed=%d failed=%d pooled_closed=%d, want 0/100/0", n, f, pooledClosed())
	}
	// Pass 2: the cursor moves past them, so the valid verdict finalizes.
	if n, f := pass(sweepAt, 0); n != 1 || f != failing-DefaultPoolSettlementExpirySweepLimit || pooledClosed() != 1 {
		t.Fatalf("pass 2 closed=%d failed=%d pooled_closed=%d, want 1/50/1", n, f, pooledClosed())
	}
	// Pass 3: the cursor wrapped, but every failed row is in backoff.
	if n, f := pass(sweepAt+1, 0); n != 0 || f != 0 {
		t.Fatalf("pass 3 closed=%d failed=%d, want 0/0 during backoff", n, f)
	}
	// After the first backoff expires the failed rows are retried (the cursor
	// resumes after the 100 rows pass 3 skipped, then wraps).
	retryAt := sweepAt + poolSweepBackoffBase.Milliseconds() + 1
	if n, f := pass(retryAt, 0); n != 0 || f != failing-DefaultPoolSettlementExpirySweepLimit {
		t.Fatalf("pass 4 closed=%d failed=%d, want 0/50 after backoff", n, f)
	}
	if n, f := pass(retryAt, 0); n != 0 || f != DefaultPoolSettlementExpirySweepLimit {
		t.Fatalf("pass 5 closed=%d failed=%d, want 0/100 after backoff", n, f)
	}
	// The second failure doubles the backoff: one base interval later they
	// are still skipped.
	if n, f := pass(retryAt+poolSweepBackoffBase.Milliseconds()+1, 0); n != 0 || f != 0 {
		t.Fatalf("pass 6 closed=%d failed=%d, want 0/0 in doubled backoff", n, f)
	}

	// Non-pool and unexpired rows were never touched.
	if got := rowState(native.RequestID); got != nativeBefore {
		t.Fatalf("native verdict changed: %s -> %s", nativeBefore, got)
	}
	if got := rowState(unexpiredID); got != unexpiredBefore {
		t.Fatalf("unexpired pool verdict changed: %s -> %s", unexpiredBefore, got)
	}
}
