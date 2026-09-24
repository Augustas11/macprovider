package billing

import (
	"context"
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
