package billing

import (
	"context"
	"database/sql"
	"errors"
	"testing"
	"time"
)

// A pool-authority read that cannot decide is retryable: it returns
// ErrPoolOperatorAttestationTransient and writes no verdict, instead of
// settling the attempt as un-cross-checked.
func TestIngestPoolSettlementReceiptTransientAuthorityErrorIsRetryable(t *testing.T) {
	input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", true)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetPoolOperatorAttestationAuthority(&fakePoolAttestationAuthority{err: errors.New("database is locked")})
	seedSettlementReceiptEvidence(t, store, input)
	if _, err := store.db.Exec(`UPDATE settlement_attempt_outputs SET usage_source = ? WHERE request_id = ?`, UsageSourcePoolOperatorAttested, input.RequestID); err != nil {
		t.Fatal(err)
	}
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	routeHash, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	_, err = store.IngestPoolSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		PoolLabels:                matchingR012Labels(routeHash),
	}.WithReceivedAt(input.ReceiptReceivedUnixMS))
	if !errors.Is(err, ErrPoolOperatorAttestationTransient) {
		t.Fatalf("err=%v, want ErrPoolOperatorAttestationTransient", err)
	}
	var verdicts int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE request_id = ?`, input.RequestID).Scan(&verdicts); err != nil {
		t.Fatal(err)
	}
	if verdicts != 0 {
		t.Fatalf("transient authority failure wrote %d verdicts, want 0", verdicts)
	}

	// The retry, once the authority answers, settles with the FIRST
	// observation time even though the store clock is now past the deadline.
	store.SetPoolOperatorAttestationAuthority(&fakePoolAttestationAuthority{})
	store.now = func() time.Time { return time.UnixMilli(input.ReceiptReceivedUnixMS).Add(24 * time.Hour) }
	state, err := store.IngestPoolSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		PoolLabels:                matchingR012Labels(routeHash),
	}.WithReceivedAt(input.ReceiptReceivedUnixMS))
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("retried receipt outcome=%s reason=%s, want verified at its first-observed time", state.SettlementOutcome, state.Reason)
	}
}

// A database recorded under a newer billing contract is refused at open, and
// a fresh open records this binary's floor.
func TestBillingCompatFloorRefusesNewerDatabase(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	var floor int64
	if err := store.db.QueryRow(`SELECT contract FROM billing_compat_floor WHERE id = 1`).Scan(&floor); err != nil {
		t.Fatal(err)
	}
	if floor != billingCompatContract {
		t.Fatalf("recorded floor=%d, want %d", floor, billingCompatContract)
	}
	if _, err := store.db.Exec(`UPDATE billing_compat_floor SET contract = ? WHERE id = 1`, billingCompatContract+1); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(store.db); !errors.Is(err, ErrBillingCompatFloor) {
		t.Fatalf("open under a newer floor: err=%v, want ErrBillingCompatFloor", err)
	}
	if _, err := store.db.Exec(`UPDATE billing_compat_floor SET contract = 1 WHERE id = 1`); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(store.db); err != nil {
		t.Fatalf("open under an older floor: %v", err)
	}
	if err := store.db.QueryRow(`SELECT contract FROM billing_compat_floor WHERE id = 1`).Scan(&floor); err != nil && !errors.Is(err, sql.ErrNoRows) {
		t.Fatal(err)
	}
	if floor != billingCompatContract {
		t.Fatalf("floor after re-open=%d, want raised to %d", floor, billingCompatContract)
	}
}
