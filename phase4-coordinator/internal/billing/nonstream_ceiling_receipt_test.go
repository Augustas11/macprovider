package billing

import (
	"context"
	"database/sql"
	"testing"
)

// SPEC-005 §5.3 / SPEC-022 R-12.4: verified-receipt re-pricing credits the
// receipt-bound completion count whenever the ledger's completion ceiling is
// at or above it (a non-streaming body-bytes ceiling, or no ceiling at all),
// and still clamps to a smaller ceiling.
func TestVerifiedReceiptRepricingHonoursNonStreamCeiling(t *testing.T) {
	probe := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
	receipt := probe.ExpectedUsage.BillableOutputTokens
	if receipt <= 1 {
		t.Fatalf("fixture completion %d too small to show the clamp", receipt)
	}
	for _, tc := range []struct {
		name         string
		ceiling      sql.NullInt64
		wantGross    int64
		wantUsage    string
		wantEstimate sql.NullInt64
	}{
		{name: "body-bytes ceiling above the receipt credits the receipt", ceiling: sql.NullInt64{Int64: receipt * 4, Valid: true}, wantGross: receipt, wantUsage: UsageProviderReported},
		{name: "ceiling equal to the receipt credits the receipt", ceiling: sql.NullInt64{Int64: receipt, Valid: true}, wantGross: receipt, wantUsage: UsageProviderReported},
		{name: "no ledger ceiling credits the receipt", wantGross: receipt, wantUsage: UsageProviderReported},
		{name: "ceiling below the receipt still clamps", ceiling: sql.NullInt64{Int64: receipt - 1, Valid: true}, wantGross: receipt - 1, wantUsage: UsageByteEstimated, wantEstimate: sql.NullInt64{Int64: receipt - 1, Valid: true}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
			_, store := newRequestAndBillingStores(t)
			createSettlementReceiptAuditLog(t, store.db)
			seedSettlementReceiptEvidence(t, store, input)
			insertSPEC022LedgerCredit(t, store.db, input, 700)
			// One credit per completion token, none for the prompt.
			if _, err := store.db.Exec(`UPDATE ledger_request_credits
   SET prompt_rate_per_mtok = 0, completion_rate_per_mtok = 1000000, estimated_completion_tokens = ?
 WHERE request_id = ?`, tc.ceiling, input.RequestID); err != nil {
				t.Fatal(err)
			}
			state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
				SettlementReceiptIdentity: settlementIdentityFromInput(input),
				Header:                    input.Header,
				ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
				receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
			})
			if err != nil {
				t.Fatal(err)
			}
			if state.SettlementOutcome != SettlementOutcomeVerified {
				t.Fatalf("outcome=%s reason=%s, want verified", state.SettlementOutcome, state.Reason)
			}
			var gross, completion int64
			var usage string
			var estimate sql.NullInt64
			if err := store.db.QueryRow(`SELECT gross_credits, completion_tokens, usage_source, estimated_completion_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID).
				Scan(&gross, &completion, &usage, &estimate); err != nil {
				t.Fatal(err)
			}
			// completion_tokens keeps the receipt count; a clamp bills the
			// ceiling and keeps it as the estimate.
			if gross != tc.wantGross || completion != receipt || usage != tc.wantUsage || estimate != tc.wantEstimate {
				t.Fatalf("gross=%d completion=%d usage=%s estimate=%v, want %d/%d/%s/%v", gross, completion, usage, estimate, tc.wantGross, receipt, tc.wantUsage, tc.wantEstimate)
			}
		})
	}
}
