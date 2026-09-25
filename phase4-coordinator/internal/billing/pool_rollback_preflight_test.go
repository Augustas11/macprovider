package billing

import (
	"context"
	"testing"
	"time"
)

func TestCheckPoolRollbackPreflightBlocksUntilPoolSettlementCloses(t *testing.T) {
	ctx := context.Background()
	pooled := r012SettlementInput(t, "receipt_tuple_v4_normal_done", true)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetPoolOperatorAttestationAuthority(&fakePoolAttestationAuthority{})
	seedSettlementReceiptEvidence(t, store, pooled)
	if _, err := store.db.Exec(`UPDATE settlement_attempt_outputs SET usage_source = ? WHERE request_id = ?`, UsageSourcePoolOperatorAttested, pooled.RequestID); err != nil {
		t.Fatal(err)
	}
	insertSPEC022LedgerCredit(t, store.db, pooled, 700)

	decision := time.UnixMilli(pooled.RouteSnapshot.RouteDecisionTSUnixMS)
	inWindow, err := CheckPoolRollbackPreflight(ctx, store.db, decision.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if !inWindow.RollbackBlocked || inWindow.InWindowNoVerdict != 1 || inWindow.PoolRouteSnapshots != 1 {
		t.Fatalf("in-window pool attempt without verdict: %+v, want blocked", inWindow)
	}

	routeHash, _, err := pooled.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	state, err := store.IngestPoolSettlementReceipt(ctx, SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(pooled),
		Header:                    pooled.Header,
		ProviderReceiptPubkey:     pooled.ProviderReceiptPubkey,
		PoolLabels:                matchingR012Labels(routeHash),
		receiptReceivedUnixMS:     pooled.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("outcome=%s reason=%s, want verified", state.SettlementOutcome, state.Reason)
	}
	settled, err := CheckPoolRollbackPreflight(ctx, store.db, decision.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if settled.RollbackBlocked || settled.OpenPoolVerdicts != 0 || settled.InWindowNoVerdict != 0 {
		t.Fatalf("closed pool verdict: %+v, want clear", settled)
	}

	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts SET closed = 0, settlement_outcome = 'pending' WHERE request_id = ?`, pooled.RequestID); err != nil {
		t.Fatal(err)
	}
	open, err := CheckPoolRollbackPreflight(ctx, store.db, decision.Add(24*time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	if !open.RollbackBlocked || open.OpenPoolVerdicts != 1 {
		t.Fatalf("open pool verdict past the window: %+v, want blocked", open)
	}
}

func TestCheckPoolRollbackPreflightIgnoresNativeAndExpiredAttempts(t *testing.T) {
	ctx := context.Background()
	native := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, native)
	decision := time.UnixMilli(native.RouteSnapshot.RouteDecisionTSUnixMS)
	got, err := CheckPoolRollbackPreflight(ctx, store.db, decision.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if got.RollbackBlocked || got.PoolRouteSnapshots != 0 {
		t.Fatalf("native attempt: %+v, want clear", got)
	}

	pooled := r012SettlementInput(t, "receipt_tuple_v4_buyer_cancel_prefix", true)
	seedSettlementReceiptEvidence(t, store, pooled)
	expired := time.UnixMilli(pooled.RouteSnapshot.RouteDecisionTSUnixMS).Add(time.Duration(pooled.RouteSnapshot.PendingDeadlineSeconds)*time.Second + time.Second)
	got, err = CheckPoolRollbackPreflight(ctx, store.db, expired)
	if err != nil {
		t.Fatal(err)
	}
	if got.RollbackBlocked || got.PoolRouteSnapshots != 1 {
		t.Fatalf("pool attempt past its receipt window with no verdict: %+v, want clear", got)
	}
}
