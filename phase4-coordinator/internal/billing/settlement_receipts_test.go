package billing

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
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
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox WHERE drained_at_utc IS NULL`); got != 2 {
		t.Fatalf("pending audit outbox rows=%d want 2 before background drain", got)
	}
	var firstOutboxID int64
	var firstOutboxCreatedAt string
	if err := store.db.QueryRow(`
SELECT id, created_at_utc
FROM settlement_receipt_audit_outbox
WHERE event_type='settlement_receipt_verdict'
ORDER BY id ASC
LIMIT 1`).Scan(&firstOutboxID, &firstOutboxCreatedAt); err != nil {
		t.Fatal(err)
	}
	drainSettlementReceiptAuditOutboxToBillingAuditLog(t, store, 2)
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_ingested'`); got != 1 {
		t.Fatalf("ingested audit rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_verdict'`); got != 1 {
		t.Fatalf("verdict audit rows=%d want 1", got)
	}
	var auditTS string
	if err := store.db.QueryRow(`
SELECT ts_utc
FROM audit_log
WHERE settlement_receipt_audit_outbox_id = ?`, firstOutboxID).Scan(&auditTS); err != nil {
		t.Fatal(err)
	}
	if auditTS != firstOutboxCreatedAt {
		t.Fatalf("audit ts_utc=%s want outbox created_at_utc %s", auditTS, firstOutboxCreatedAt)
	}
	assertSettlementReceiptVerdictAuditContract(t, store.db, state)
	assertSettlementReceiptAuditRedacted(t, store.db, input.Header, fixtures.ProviderReceiptPubkeyB64)
	assertSettlementReceiptVerdictSchemaRedacted(t, store.db)
}

func TestSettlementReceiptAuditOutboxSurvivesPostCommitDrainFailure(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	_, store := newRequestAndBillingStores(t)
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
		t.Fatalf("post-commit audit drain failure must not fail receipt ingestion: %v", err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified || state.ReceiptResult != SettlementReceiptResultValid || !state.Closed {
		t.Fatalf("state=%#v, want committed terminal verified state", state)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome='verified' AND closed=1`); got != 1 {
		t.Fatalf("verified verdict rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox WHERE drained_at_utc IS NULL`); got != 2 {
		t.Fatalf("pending outbox rows=%d want 2", got)
	}

	drainSettlementReceiptAuditOutboxToBillingAuditLog(t, store, 2)
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox WHERE drained_at_utc IS NULL`); got != 0 {
		t.Fatalf("pending outbox rows after drain=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_ingested'`); got != 1 {
		t.Fatalf("ingested audit rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_verdict'`); got != 1 {
		t.Fatalf("verdict audit rows=%d want 1", got)
	}
	if _, err := store.db.Exec(`UPDATE settlement_receipt_audit_outbox SET drained_at_utc = NULL`); err != nil {
		t.Fatal(err)
	}
	drained, err := store.DrainSettlementReceiptAuditOutbox(context.Background(), settlementReceiptTestAuditSink{db: store.db}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if drained != 2 {
		t.Fatalf("retry drain rows=%d want 2 marked after idempotent sink replay", drained)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_ingested'`); got != 1 {
		t.Fatalf("ingested audit rows after replay=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type='settlement_receipt_verdict'`); got != 1 {
		t.Fatalf("verdict audit rows after replay=%d want 1", got)
	}
	drained, err = store.DrainSettlementReceiptAuditOutbox(context.Background(), settlementReceiptTestAuditSink{db: store.db}, 10)
	if err != nil {
		t.Fatal(err)
	}
	if drained != 0 {
		t.Fatalf("second drain rows=%d want 0", drained)
	}
	assertSettlementReceiptVerdictAuditContract(t, store.db, state)
	assertSettlementReceiptAuditRedacted(t, store.db, input.Header, fixtures.ProviderReceiptPubkeyB64)
}

func TestSettlementReceiptAuditOutboxContinuesAfterFailureAndPrunesDrainedRows(t *testing.T) {
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
	var failOutboxID, healthyOutboxID int64
	if err := store.db.QueryRow(`
SELECT MIN(id), MAX(id)
FROM settlement_receipt_audit_outbox
WHERE drained_at_utc IS NULL`).Scan(&failOutboxID, &healthyOutboxID); err != nil {
		t.Fatal(err)
	}

	drained, err := store.DrainSettlementReceiptAuditOutbox(context.Background(), failingSettlementReceiptAuditSink{
		failOutboxID: failOutboxID,
		next:         settlementReceiptTestAuditSink{db: store.db},
	}, 10)
	if err == nil {
		t.Fatal("drain err=nil want first row failure")
	}
	if drained != 1 {
		t.Fatalf("drained rows=%d want healthy row drained despite first-row failure", drained)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox WHERE id = ? AND drained_at_utc IS NULL`, failOutboxID); got != 1 {
		t.Fatalf("failed row pending count=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox WHERE id = ? AND drained_at_utc IS NOT NULL`, healthyOutboxID); got != 1 {
		t.Fatalf("healthy row drained count=%d want 1", got)
	}

	if _, err := store.db.Exec(`UPDATE settlement_receipt_audit_outbox SET drained_at_utc = ? WHERE id = ?`, time.Now().UTC().AddDate(0, 0, -10).Format(time.RFC3339Nano), healthyOutboxID); err != nil {
		t.Fatal(err)
	}
	pruned, err := store.PruneSettlementReceiptAuditOutbox(context.Background(), time.Now().UTC().AddDate(0, 0, -7), 10)
	if err != nil {
		t.Fatal(err)
	}
	if pruned != 1 {
		t.Fatalf("pruned rows=%d want 1", pruned)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_audit_outbox`); got != 1 {
		t.Fatalf("remaining outbox rows=%d want only failed pending row", got)
	}
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
	pending, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
		SettlementReceiptIdentity: id,
		NowUnixMS:                 deadline - 100,
	})
	if err != nil {
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
	mutatedPromptHash := strings.Repeat("f", 64)
	if _, err := store.db.Exec(`
UPDATE settlement_receipt_verdicts
   SET route_snapshot_policy_version = 'mutated-policy',
       paid_entrypoint = 'mutated-entrypoint',
       model_id = 'mutated-model',
       prompt_hash = ?
 WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		mutatedPromptHash, redactedAccountScopeHash(id.AccountScope), id.RequestID, id.AttemptN, id.ProviderID); err != nil {
		t.Fatal(err)
	}
	drainSettlementReceiptAuditOutboxToBillingAuditLog(t, store, 3)
	payloads := settlementReceiptVerdictPayloads(t, store.db)
	if len(payloads) != 2 {
		t.Fatalf("settlement_receipt_verdict audit payloads=%d want 2", len(payloads))
	}
	if got := payloads[0]["settlement_outcome"]; got != SettlementOutcomePending {
		t.Fatalf("first verdict settlement_outcome=%v want pending", got)
	}
	if got := payloads[0]["idempotency_status"]; got != settlementReceiptIDPending {
		t.Fatalf("first verdict idempotency_status=%v want pending", got)
	}
	if got := payloads[0]["route_snapshot_policy_version"]; got != pending.RouteSnapshotPolicyVersion {
		t.Fatalf("first verdict route_snapshot_policy_version=%v want %s", got, pending.RouteSnapshotPolicyVersion)
	}
	if got := payloads[0]["paid_entrypoint"]; got != pending.PaidEntrypoint {
		t.Fatalf("first verdict paid_entrypoint=%v want %s", got, pending.PaidEntrypoint)
	}
	if got := payloads[0]["model_id"]; got != pending.ModelID {
		t.Fatalf("first verdict model_id=%v want %s", got, pending.ModelID)
	}
	if got := payloads[0]["prompt_hash"]; got != pending.PromptHash {
		t.Fatalf("first verdict prompt_hash=%v want %s", got, pending.PromptHash)
	}
	if got := payloads[1]["settlement_outcome"]; got != SettlementOutcomeVerified {
		t.Fatalf("second verdict settlement_outcome=%v want verified", got)
	}
	if got := payloads[1]["idempotency_status"]; got != settlementReceiptIDTerminalAfterPending {
		t.Fatalf("second verdict idempotency_status=%v want terminal_after_pending", got)
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
	drainSettlementReceiptAuditOutboxToBillingAuditLog(t, store, 3)
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
	drainSettlementReceiptAuditOutboxToBillingAuditLog(t, store, 2)
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
    settlement_receipt_audit_outbox_id INTEGER NULL,
    payload_json TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);
CREATE UNIQUE INDEX IF NOT EXISTS idx_audit_log_settlement_receipt_outbox
    ON audit_log(settlement_receipt_audit_outbox_id)
    WHERE settlement_receipt_audit_outbox_id IS NOT NULL;
`); err != nil {
		t.Fatal(err)
	}
}

type settlementReceiptTestAuditSink struct {
	db *sql.DB
}

func (s settlementReceiptTestAuditSink) InsertSettlementReceiptOutbox(ctx context.Context, ts time.Time, eventType, providerID, payloadJSON string, outboxID int64) (bool, error) {
	res, err := s.db.ExecContext(ctx, `
INSERT OR IGNORE INTO audit_log (ts_utc, event_type, provider_id, settlement_receipt_audit_outbox_id, payload_json)
VALUES (?, ?, ?, ?, ?)`,
		ts.UTC().Format(time.RFC3339Nano), eventType, providerID, outboxID, payloadJSON)
	if err != nil {
		return false, err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return false, err
	}
	return n > 0, nil
}

type failingSettlementReceiptAuditSink struct {
	failOutboxID int64
	next         settlementReceiptTestAuditSink
}

func (s failingSettlementReceiptAuditSink) InsertSettlementReceiptOutbox(ctx context.Context, ts time.Time, eventType, providerID, payloadJSON string, outboxID int64) (bool, error) {
	if outboxID == s.failOutboxID {
		return false, errors.New("forced outbox sink failure")
	}
	return s.next.InsertSettlementReceiptOutbox(ctx, ts, eventType, providerID, payloadJSON, outboxID)
}

func drainSettlementReceiptAuditOutboxToBillingAuditLog(t *testing.T, store *Store, want int) {
	t.Helper()
	createSettlementReceiptAuditLog(t, store.db)
	drained, err := store.DrainSettlementReceiptAuditOutbox(context.Background(), settlementReceiptTestAuditSink{db: store.db}, 100)
	if err != nil {
		t.Fatal(err)
	}
	if drained != want {
		t.Fatalf("drained rows=%d want %d", drained, want)
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

func settlementReceiptVerdictPayloads(t *testing.T, db *sql.DB) []map[string]any {
	t.Helper()
	rows, err := db.Query(`
SELECT payload_json
FROM audit_log
WHERE event_type='settlement_receipt_verdict'
ORDER BY id ASC`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	var payloads []map[string]any
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			t.Fatal(err)
		}
		var payload map[string]any
		if err := json.Unmarshal([]byte(raw), &payload); err != nil {
			t.Fatal(err)
		}
		payloads = append(payloads, payload)
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	return payloads
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
