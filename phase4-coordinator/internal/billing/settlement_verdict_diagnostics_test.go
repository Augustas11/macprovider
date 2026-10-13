package billing

import (
	"context"
	"testing"
)

// SPEC-022 R-15.10: a verdict row stores {} in verifier_diagnostics_json; its
// former members are typed columns, and facts_json still holds the receipt
// facts no typed column carries.
func TestSettlementVerdictStoresEmptyDiagnosticsAndKeepsFacts(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	if _, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                input.Header,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: input.ReceiptReceivedUnixMS,
	}); err != nil {
		t.Fatal(err)
	}
	var diagnostics, receiptResult, outcome, idempotency string
	var closed int
	var facts *string
	if err := store.db.QueryRow(`
SELECT verifier_diagnostics_json, facts_json, receipt_result, settlement_outcome, idempotency_status, closed
  FROM settlement_receipt_verdicts WHERE request_id = ?`, input.RequestID).Scan(&diagnostics, &facts, &receiptResult, &outcome, &idempotency, &closed); err != nil {
		t.Fatal(err)
	}
	if diagnostics != "{}" {
		t.Fatalf("verifier_diagnostics_json=%q want {}", diagnostics)
	}
	if facts == nil || *facts == "" {
		t.Fatal("facts_json missing")
	}
	if receiptResult == "" || outcome == "" || idempotency == "" || closed != 1 {
		t.Fatalf("typed columns result=%q outcome=%q idempotency=%q closed=%d", receiptResult, outcome, idempotency, closed)
	}
}
