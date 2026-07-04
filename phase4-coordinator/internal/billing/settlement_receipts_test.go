package billing

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestIngestSettlementReceiptPersistsVerifiedStateAndRedactedAudit(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                input.Header,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified || state.ReceiptResult != SettlementReceiptResultValid || !state.Closed {
		t.Fatalf("state=%#v, want terminal verified/valid", state)
	}
	if state.IdempotencyStatus != settlementReceiptIDFirstTerminal {
		t.Fatalf("idempotency_status=%s want %s", state.IdempotencyStatus, settlementReceiptIDFirstTerminal)
	}
	if state.UsageDigest != settlementUsageDigestFromTuple(t, tuple) {
		t.Fatalf("usage_digest=%s want %s", state.UsageDigest, settlementUsageDigestFromTuple(t, tuple))
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome='verified' AND closed=1`); got != 1 {
		t.Fatalf("verified verdict rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != 0 {
		t.Fatalf("ledger_request_credits rows=%d want 0; Step 5 must not create buyer debit/provider credit", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_operator_credits`); got != 0 {
		t.Fatalf("ledger_operator_credits rows=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("ledger_payout_ready rows=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_ingested'`); got != 1 {
		t.Fatalf("ingested audit rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_verdict'`); got != 1 {
		t.Fatalf("verdict audit rows=%d want 1", got)
	}
	assertSettlementReceiptVerdictAuditContract(t, store.db, state)
	assertSettlementReceiptAuditRedacted(t, store.db, input.Header, fixtures.ProviderReceiptPubkeyB64)
	assertSettlementReceiptVerdictSchemaRedacted(t, store.db)
}

func TestSyncVerifiedReceiptLedgerCreditUpdatesPromptSplitColumns(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, input)
	boundedPrompt := input.ExpectedUsage.BillableInputTokens - 1
	if boundedPrompt < 0 {
		t.Fatalf("fixture billable input tokens=%d too small for bounded prompt regression", input.ExpectedUsage.BillableInputTokens)
	}
	providerReportedPrompt := input.ExpectedUsage.BillableInputTokens + 500
	rateEntry := RateCardEntry{PromptCreditsPerMtok: 1, CompletionCreditsPerMtok: 1}
	stale := ComputeCredits(&boundedPrompt, nil, nil, UsageProviderReported, FaultNone, rateEntry, 1_000_000, 10_000)
	insertSPEC022LedgerCredit(t, store.db, input, stale.ProviderCredits)
	if _, err := store.db.Exec(`
	UPDATE ledger_request_credits
   SET prompt_tokens = ?,
       charged_prompt_tokens = ?,
       provider_reported_prompt_tokens = ?,
       gross_credits = ?,
	       provider_credits = ?
	 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`,
		stale.PromptTokens,
		stale.PromptTokens,
		providerReportedPrompt,
		stale.GrossCredits,
		stale.ProviderCredits,
		input.RequestID,
		input.AttemptN,
		input.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	markSPEC022ReceiptVerified(t, store.db, input)

	reason, err := syncVerifiedReceiptLedgerCreditForAttemptTx(context.Background(), store.db, input.RequestID, int64(input.AttemptN), input.ProviderID)
	if err != nil {
		t.Fatal(err)
	}
	if reason != "" {
		t.Fatalf("sync reason=%q want empty successful sync", reason)
	}
	var prompt, charged, reported int64
	if err := store.db.QueryRow(`
SELECT prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens
  FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.RequestID, input.AttemptN, input.ProviderID,
	).Scan(&prompt, &charged, &reported); err != nil {
		t.Fatal(err)
	}
	if prompt != boundedPrompt ||
		charged != boundedPrompt ||
		reported != providerReportedPrompt {
		t.Fatalf("prompt split=%d/%d/%d want charged %d and provider-reported %d",
			prompt, charged, reported, boundedPrompt, providerReportedPrompt)
	}
	finality, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("settlement finality not found")
	}
	if finality.Outcome != SettlementOutcomeVerified ||
		finality.PromptTokens != boundedPrompt ||
		finality.CompletionTokens != input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens != boundedPrompt+input.ExpectedUsage.BillableOutputTokens {
		t.Fatalf("finality=%#v want verified charged prompt %d", finality, boundedPrompt)
	}
}

func TestRecordMissingSettlementReceiptQuarantinesAfterDeadlineAndLateReceiptNoops(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000

	pending, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: id,
		NowUnixMS:                 deadline - 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if pending.SettlementOutcome != SettlementOutcomePending || pending.Closed {
		t.Fatalf("pending state=%#v, want open pending", pending)
	}

	quarantined, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: id,
		NowUnixMS:                 deadline + 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if quarantined.SettlementOutcome != SettlementOutcomeQuarantined || quarantined.Reason != "missing_receipt_deadline_elapsed" || !quarantined.Closed {
		t.Fatalf("quarantined state=%#v, want terminal deadline quarantine", quarantined)
	}

	late, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     deadline + 2,
	})
	if err != nil {
		t.Fatal(err)
	}
	if late.SettlementOutcome != SettlementOutcomeQuarantined || late.Reason != "missing_receipt_deadline_elapsed" || late.IdempotencyStatus != settlementReceiptIDTerminalNoop {
		t.Fatalf("late state=%#v, want original terminal quarantine as no-op", late)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome='verified'`); got != 0 {
		t.Fatalf("late valid receipt created verified rows=%d want 0", got)
	}
}

func TestSettlementReceiptPendingCanCloseWithValidReceiptBeforeDeadline(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	if _, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: id,
		NowUnixMS:                 deadline - 100,
	}); err != nil {
		t.Fatal(err)
	}
	verified, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     deadline - 50,
	})
	if err != nil {
		t.Fatal(err)
	}
	if verified.SettlementOutcome != SettlementOutcomeVerified || verified.IdempotencyStatus != settlementReceiptIDTerminalAfterPending || !verified.Closed {
		t.Fatalf("verified state=%#v, want terminal verified after pending", verified)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome='verified' AND idempotency_status='terminal_after_pending'`); got != 1 {
		t.Fatalf("terminal_after_pending rows=%d want 1", got)
	}
}

func TestRequestSettlementFinalityAggregatesVerifiedUsageAfterPending(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	if _, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: id,
		NowUnixMS:                 deadline - 100,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     deadline - 50,
	}); err != nil {
		t.Fatal(err)
	}

	finality, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, deadline-25)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("settlement finality not found")
	}
	if finality.Outcome != SettlementOutcomeVerified || finality.ReceiptResult != SettlementReceiptResultValid || !finality.Closed {
		t.Fatalf("finality=%#v, want closed verified finality", finality)
	}
	if finality.PromptTokens != input.ExpectedUsage.BillableInputTokens ||
		finality.CompletionTokens != input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens != input.ExpectedUsage.BillableInputTokens+input.ExpectedUsage.BillableOutputTokens ||
		finality.TokenSource != UsageSourceCoordinatorObserved {
		t.Fatalf("finality tokens=%#v, want coordinator observed billable usage %#v", finality, input.ExpectedUsage)
	}
}

func TestRequestSettlementFinalityForAccountResolvesGatewayExternalRequestID(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	accountID := "acct_spec022_external_finality"
	externalRequestID := "77777777-7777-4777-8777-777777777777"
	input.AccountScope = AccountScopeForSettlement(accountID)
	input.RouteSnapshot.AccountScope = input.AccountScope
	reqStore, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	markSPEC022ReceiptVerified(t, store.db, input)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              time.UnixMilli(input.TerminalStateTSUnixMS).UTC(),
		RequestID:          input.RequestID,
		ExternalRequestID:  externalRequestID,
		AccountID:          accountID,
		Model:              input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned",
		PromptTokens:       &input.ExpectedUsage.BillableInputTokens,
		CompletionTokens:   &input.ExpectedUsage.BillableOutputTokens,
		Status:             200,
		Stream:             true,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}

	finality, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, externalRequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("settlement finality not found through gateway external request id")
	}
	if finality.RequestID != externalRequestID {
		t.Fatalf("finality.request_id=%q want external request id %q", finality.RequestID, externalRequestID)
	}
	if finality.Outcome != SettlementOutcomeVerified ||
		finality.ReceiptResult != SettlementReceiptResultValid ||
		!finality.Closed ||
		finality.TokenSource != UsageSourceCoordinatorObserved {
		t.Fatalf("finality=%#v, want closed verified coordinator-observed finality", finality)
	}
	if finality.PromptTokens != input.ExpectedUsage.BillableInputTokens ||
		finality.CompletionTokens != input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens != input.ExpectedUsage.BillableInputTokens+input.ExpectedUsage.BillableOutputTokens {
		t.Fatalf("finality tokens=%#v, want receipt-bound usage %#v", finality, input.ExpectedUsage)
	}
}

func TestRequestSettlementFinalityForAccountReturnsExternalOverlapBlockedTerminal(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	accountID := "acct_spec022_external_overlap"
	externalRequestID := "99999999-9999-4999-8999-999999999999"
	input.AccountScope = AccountScopeForSettlement(accountID)
	input.RouteSnapshot.AccountScope = input.AccountScope
	reqStore, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	markSPEC022ReceiptVerified(t, store.db, input)
	if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
   SET overlapping_or_duplicate = 1
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              time.UnixMilli(input.TerminalStateTSUnixMS).UTC(),
		RequestID:          input.RequestID,
		ExternalRequestID:  externalRequestID,
		AccountID:          accountID,
		Model:              input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned",
		PromptTokens:       &input.ExpectedUsage.BillableInputTokens,
		CompletionTokens:   &input.ExpectedUsage.BillableOutputTokens,
		Status:             200,
		Stream:             true,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}

	finality, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, externalRequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("settlement finality not found through gateway external request id")
	}
	if finality.RequestID != externalRequestID ||
		finality.Outcome != SettlementOutcomeOverlapBlockedTerminal ||
		finality.ReceiptResult != SettlementReceiptResultValid ||
		!finality.Closed ||
		finality.TotalTokens != 0 ||
		finality.TokenSource != UsageSourceCoordinatorObserved ||
		finality.OverlappingBlockedTokens == 0 {
		t.Fatalf("finality=%#v, want closed external overlap-blocked zero-token finality", finality)
	}
}

func TestRequestSettlementFinalityForAccountIgnoresExternalRowsBeforeReservationStart(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	accountID := "acct_spec022_external_reuse"
	externalRequestID := "77777777-7777-4777-8777-777777777777"
	input.AccountScope = AccountScopeForSettlement(accountID)
	input.RouteSnapshot.AccountScope = input.AccountScope
	reqStore, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	markSPEC022ReceiptVerified(t, store.db, input)
	oldTS := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              oldTS,
		RequestID:          input.RequestID,
		ExternalRequestID:  externalRequestID,
		AccountID:          accountID,
		Model:              input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned-old",
		PromptTokens:       &input.ExpectedUsage.BillableInputTokens,
		CompletionTokens:   &input.ExpectedUsage.BillableOutputTokens,
		Status:             200,
		Stream:             true,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	newReservationTS := oldTS.Add(time.Hour)
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              newReservationTS,
		RequestID:          "88888888-8888-4888-8888-888888888888",
		ExternalRequestID:  externalRequestID,
		AccountID:          accountID,
		Model:              input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned-new",
		Status:             200,
		Stream:             true,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}

	finality, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, externalRequestID, newReservationTS.UnixMilli(), newReservationTS.UnixMilli())
	if err != nil {
		t.Fatal(err)
	}
	if found {
		t.Fatalf("finality=%#v found through stale external request id before current reservation start", finality)
	}
}

func TestRequestSettlementFinalityDeadlineQuarantinesOpenPending(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	if _, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: id,
		NowUnixMS:                 deadline - 100,
	}); err != nil {
		t.Fatal(err)
	}

	finality, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, deadline+1)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("settlement finality not found")
	}
	if finality.Outcome != SettlementOutcomeQuarantined || !finality.Closed || finality.Reason != "missing_receipt_deadline_elapsed" {
		t.Fatalf("finality=%#v, want deadline quarantine refund finality", finality)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome='quarantined' AND reason='missing_receipt_deadline_elapsed' AND closed=1`); got != 1 {
		t.Fatalf("deadline quarantine rows=%d want 1", got)
	}
}

func TestSettlementReceiptReceivedAfterDeadlineQuarantinesEvenWithValidHeader(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	setSettlementReceiptNow(store, deadline+1)

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                input.Header,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: deadline + 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != "receipt_after_deadline" || !state.Closed {
		t.Fatalf("state=%#v, want receipt_after_deadline quarantine", state)
	}
}

func TestSettlementReceiptResubmissionCannotChangeClosedOutcome(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	if input.RouteSnapshot.ProviderSessionID == nil || input.RouteSnapshot.ProviderGenerationID == nil {
		t.Fatal("fixture missing provider session/generation ids")
	}
	sessionID := *input.RouteSnapshot.ProviderSessionID
	generationID := *input.RouteSnapshot.ProviderGenerationID
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	first, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("first outcome=%s want verified", first.SettlementOutcome)
	}

	changedHeader := firstNegativeReceiptForBase(t, fixtures, tuple.ID)
	second, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    changedHeader,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS + 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if second.SettlementOutcome != SettlementOutcomeVerified || second.Reason != "verified_settlement" || second.IdempotencyStatus != settlementReceiptIDTerminalNoop {
		t.Fatalf("second state=%#v, want original verified terminal no-op", second)
	}
	payload := latestSettlementReceiptVerdictPayload(t, store.db)
	if payload["idempotency_status"] != settlementReceiptIDTerminalNoop ||
		payload["settlement_outcome"] != SettlementOutcomeVerified ||
		payload["reason"] != "verified_settlement" ||
		payload["provider_session_id"] != sessionID ||
		payload["provider_generation_id"] != generationID ||
		int64(payload["attempted_received_at_unix_ms"].(float64)) != input.ReceiptReceivedUnixMS+1 {
		t.Fatalf("terminal no-op audit payload=%#v, want complete verdict fields and attempted receive time", payload)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts`); got != 1 {
		t.Fatalf("verdict rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE reason='verified_settlement'`); got != 1 {
		t.Fatalf("verified reason rows=%d want 1", got)
	}
}

func TestSettlementReceiptRejectsCallerControlledReceiveTime(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	setSettlementReceiptNow(store, deadline+1)

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                input.Header,
		ProviderReceiptPubkey: pubkey,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != "receipt_after_deadline" {
		t.Fatalf("state=%#v, want coordinator-stamped late receipt quarantine", state)
	}
}

func TestSettlementReceiptPersistsCoordinatorEvidenceForMismatchedSignedReceipt(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	base, negative := firstSettlementTupleWithNegativeFailure(t, fixtures, "normal_done", "output_hash_mismatch")
	input := settlementVerifierInputFromFixture(t, fixtures, base, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)

	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{
			AccountScope: input.AccountScope,
			RequestID:    input.RequestID,
			AttemptN:     input.AttemptN,
			ProviderID:   input.ProviderID,
		},
		Header:                negative.WireReceipt,
		ProviderReceiptPubkey: pubkey,
		receiptReceivedUnixMS: input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != "output_hash_mismatch" {
		t.Fatalf("state=%#v, want output_hash_mismatch quarantine", state)
	}
	wantUsageHash, _, err := input.ExpectedUsage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	var modelHash, outputHash, usageDigest string
	if err := store.db.QueryRow(`
SELECT model_hash, output_hash, usage_digest
FROM settlement_receipt_verdicts
WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		redactedAccountScopeHash(input.AccountScope), input.RequestID, input.AttemptN, input.ProviderID,
	).Scan(&modelHash, &outputHash, &usageDigest); err != nil {
		t.Fatal(err)
	}
	if modelHash != input.RouteSnapshot.ProviderReportedModelHash || outputHash != input.OutputHash || usageDigest != wantUsageHash {
		t.Fatalf("persisted hashes model=%s output=%s usage=%s, want coordinator evidence %s/%s/%s",
			modelHash, outputHash, usageDigest, input.RouteSnapshot.ProviderReportedModelHash, input.OutputHash, wantUsageHash)
	}
	payload := latestSettlementReceiptVerdictPayload(t, store.db)
	for key, want := range map[string]string{
		"model_hash":                   input.RouteSnapshot.ProviderReportedModelHash,
		"provider_reported_model_hash": input.RouteSnapshot.ProviderReportedModelHash,
		"output_hash":                  input.OutputHash,
		"usage_digest":                 wantUsageHash,
	} {
		if got := payload[key]; got != want {
			t.Fatalf("audit %s=%v want %s", key, got, want)
		}
	}
}

func TestSettlementReceiptAuthorizationRejectsLaterOverlapBackfill(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
	if _, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	}); err != nil {
		t.Fatal(err)
	}
	auth, found, err := store.GetSettlementReceiptAuthorization(context.Background(), id)
	if err != nil || !found {
		t.Fatalf("authorization found=%v err=%v", found, err)
	}
	if !auth.PositiveSettlementCandidate {
		t.Fatalf("authorization=%#v, want positive settlement candidate before overlap", auth)
	}
	if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
SET overlapping_or_duplicate = 1
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	auth, found, err = store.GetSettlementReceiptAuthorization(context.Background(), id)
	if err != nil || !found {
		t.Fatalf("authorization found=%v err=%v", found, err)
	}
	if auth.PositiveSettlementCandidate || auth.CandidateBlockedReason != "overlapping_or_duplicate_output" {
		t.Fatalf("authorization=%#v, want blocked candidate after overlap backfill", auth)
	}
}

func seedSettlementReceiptEvidence(t *testing.T, store *Store, input SettlementVerifyInput) {
	t.Helper()
	routeDigest, err := store.InsertRouteSnapshot(context.Background(), input.RouteSnapshot)
	if err != nil {
		t.Fatal(err)
	}
	if routeDigest == "" {
		t.Fatal("empty route digest")
	}
	usageHash, usageCanonical, err := input.ExpectedUsage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
INSERT INTO settlement_attempt_outputs (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_available, output_prefix_start_byte, output_prefix_end_byte,
    output_hash, usage_hash, usage_canonical_json, usage_source,
    overlapping_or_duplicate, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
		input.TerminalState, input.TerminalStateTSUnixMS, 1,
		input.OutputPrefixStartByte, input.OutputPrefixEndByte, input.OutputHash,
		usageHash, string(usageCanonical), UsageSourceCoordinatorObserved,
		0, "2026-01-01T00:00:00Z",
	); err != nil {
		t.Fatal(err)
	}
}

func createSettlementReceiptAuditLog(t *testing.T, db *sql.DB) {
	t.Helper()
	if _, err := db.Exec(`
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc TEXT NOT NULL,
    event_type TEXT NOT NULL,
    provider_id TEXT,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
`); err != nil {
		t.Fatal(err)
	}
}

func firstSettlementTupleWithTerminal(t *testing.T, fixtures settlementVerifierFixtures, terminal string) settlementVerifierTupleFixture {
	t.Helper()
	for _, tuple := range fixtures.ReceiptTuples {
		if settlementTupleString(t, tuple, "terminal_state") == terminal {
			return tuple
		}
	}
	t.Fatalf("no tuple with terminal_state=%s", terminal)
	return settlementVerifierTupleFixture{}
}

func settlementTupleByID(t *testing.T, fixtures settlementVerifierFixtures, id string) settlementVerifierTupleFixture {
	t.Helper()
	for _, tuple := range fixtures.ReceiptTuples {
		if tuple.ID == id {
			return tuple
		}
	}
	t.Fatalf("no settlement tuple with id=%s", id)
	return settlementVerifierTupleFixture{}
}

func firstNegativeReceiptForBase(t *testing.T, fixtures settlementVerifierFixtures, baseID string) string {
	t.Helper()
	for _, negative := range fixtures.NegativeReceipts {
		if negative.BaseTupleID == baseID {
			return negative.WireReceipt
		}
	}
	t.Fatalf("no negative receipt for base tuple %s", baseID)
	return ""
}

func firstSettlementTupleWithNegativeFailure(t *testing.T, fixtures settlementVerifierFixtures, terminal, expectedFailure string) (settlementVerifierTupleFixture, settlementVerifierTupleFixture) {
	t.Helper()
	tuples := settlementReceiptTuplesByID(fixtures)
	for _, negative := range fixtures.NegativeReceipts {
		if negative.ExpectedFailure != expectedFailure {
			continue
		}
		tuple := tuples[negative.BaseTupleID]
		if tuple.ID != "" && settlementTupleString(t, tuple, "terminal_state") == terminal {
			return tuple, negative
		}
	}
	t.Fatalf("no %s tuple with negative failure %s", terminal, expectedFailure)
	return settlementVerifierTupleFixture{}, settlementVerifierTupleFixture{}
}

func firstSettlementTupleWithNegativeVariant(t *testing.T, fixtures settlementVerifierFixtures, terminal string) settlementVerifierTupleFixture {
	t.Helper()
	tuples := settlementReceiptTuplesByID(fixtures)
	for _, negative := range fixtures.NegativeReceipts {
		tuple := tuples[negative.BaseTupleID]
		if tuple.ID != "" && settlementTupleString(t, tuple, "terminal_state") == terminal {
			return tuple
		}
	}
	t.Fatalf("no %s tuple with a negative receipt variant", terminal)
	return settlementVerifierTupleFixture{}
}

func assertSettlementReceiptAuditRedacted(t *testing.T, db *sql.DB, rawReceipt, pubkeyB64 string) {
	t.Helper()
	rows, err := db.Query(`SELECT payload_json FROM audit_log WHERE event_type IN ('settlement_receipt_ingested', 'settlement_receipt_verdict')`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	rawPubkey, err := base64.StdEncoding.DecodeString(pubkeyB64)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var payload string
		if err := rows.Scan(&payload); err != nil {
			t.Fatal(err)
		}
		for _, forbidden := range []string{
			rawReceipt,
			pubkeyB64,
			string(rawPubkey),
			"provider_receipt_public_key",
			"raw_receipt",
			"receipt_envelope",
			"bearer",
			"\"account_scope\":",
		} {
			if forbidden != "" && strings.Contains(payload, forbidden) {
				t.Fatalf("audit payload contains forbidden material %q: %s", forbidden, payload)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
}

func assertSettlementReceiptVerdictSchemaRedacted(t *testing.T, db *sql.DB) {
	t.Helper()
	rows, err := db.Query(`PRAGMA table_info(settlement_receipt_verdicts)`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	columns := map[string]bool{}
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			t.Fatal(err)
		}
		lower := strings.ToLower(name)
		columns[lower] = true
		for _, forbidden := range []string{"raw", "signature", "public_key", "bearer", "prompt_text", "output_text", "provider_session_id", "provider_generation_id"} {
			if strings.Contains(lower, forbidden) {
				t.Fatalf("settlement_receipt_verdicts column %q contains forbidden raw-material marker %q", name, forbidden)
			}
		}
		if lower == "account_scope" {
			t.Fatalf("settlement_receipt_verdicts column %q contains raw account scope", name)
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if !columns["account_scope_hash"] {
		t.Fatal("settlement_receipt_verdicts missing account_scope_hash")
	}
}

func setSettlementReceiptNow(store *Store, unixMS int64) {
	store.now = func() time.Time { return time.UnixMilli(unixMS).UTC() }
}

func latestSettlementReceiptVerdictPayload(t *testing.T, db *sql.DB) map[string]any {
	t.Helper()
	var raw string
	if err := db.QueryRow(`
SELECT payload_json
FROM audit_log
WHERE event_type='settlement_receipt_verdict'
ORDER BY id DESC
LIMIT 1`).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(raw), &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func assertSettlementReceiptVerdictAuditContract(t *testing.T, db *sql.DB, state SettlementReceiptState) {
	t.Helper()
	payload := latestSettlementReceiptVerdictPayload(t, db)
	wantStrings := map[string]string{
		"request_id":                       state.RequestID,
		"provider_id":                      state.ProviderID,
		"receipt_result":                   state.ReceiptResult,
		"receipt_verification_outcome":     state.SettlementOutcome,
		"settlement_outcome":               state.SettlementOutcome,
		"reason":                           state.Reason,
		"route_snapshot_policy_version":    state.RouteSnapshotPolicyVersion,
		"route_snapshot_mode":              state.RouteSnapshotMode,
		"paid_entrypoint":                  state.PaidEntrypoint,
		"spec008_hash_status":              state.Spec008HashStatus,
		"provider_reported_model_hash":     state.ProviderReportedModelHash,
		"model_hash":                       state.ModelHash,
		"expected_catalog_model_hash":      state.ExpectedCatalogModelHash,
		"catalog_id":                       state.CatalogID,
		"catalog_body_digest":              state.CatalogBodyDigest,
		"provider_receipt_key_fingerprint": state.ProviderReceiptKeyFingerprint,
		"receipt_profile":                  settlementReceiptProfileV04,
		"buyer_debit_outcome":              settlementReceiptNoMoneyMovementStep5,
		"provider_settlement_outcome":      settlementReceiptNoMoneyMovementStep5,
		"payout_exclusion_outcome":         settlementReceiptPayoutExcludedUntil022,
	}
	if state.ProviderSessionID != "" {
		wantStrings["provider_session_id"] = state.ProviderSessionID
	}
	if state.ProviderGenerationID != "" {
		wantStrings["provider_generation_id"] = state.ProviderGenerationID
	}
	for key, want := range wantStrings {
		if got := payload[key]; got != want {
			t.Fatalf("audit %s=%v want %s", key, got, want)
		}
	}
	if _, ok := payload["account_scope"]; ok {
		t.Fatalf("audit payload contains raw account_scope: %#v", payload)
	}
	if got := payload["account_scope_hash"]; got != redactedAccountScopeHash(state.AccountScope) {
		t.Fatalf("audit account_scope_hash=%v want redacted hash", got)
	}
	if got := int64(payload["attempt_n"].(float64)); got != state.AttemptN {
		t.Fatalf("audit attempt_n=%d want %d", got, state.AttemptN)
	}
	if got := payload["attempt_id"]; got != settlementReceiptAttemptID(state) {
		t.Fatalf("audit attempt_id=%v want %s", got, settlementReceiptAttemptID(state))
	}
	if got := int64(payload["pending_deadline_unix_ms"].(float64)); got != state.PendingDeadlineUnixMS {
		t.Fatalf("audit pending_deadline_unix_ms=%d want %d", got, state.PendingDeadlineUnixMS)
	}
	if state.SettlementOutcome == SettlementOutcomeQuarantined || state.SettlementOutcome == SettlementOutcomeZeroSettled {
		if got := payload["quarantine_zero_settle_reason"]; got != state.Reason {
			t.Fatalf("audit quarantine_zero_settle_reason=%v want %s", got, state.Reason)
		}
	}
}
