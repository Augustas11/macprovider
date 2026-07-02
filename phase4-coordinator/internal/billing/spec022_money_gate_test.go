package billing

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestSPEC022PayableCreditGateRequiresVerifiedReceipt(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithNegativeVariant(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 600)

	windowStart, windowEnd := settlementWindowForInput(input)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
		t.Fatalf("payable rows before receipt=%d want 0", got)
	}
	if err := store.RunSettlement(context.Background(), cfg, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
		t.Fatalf("payout rows before receipt=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT SUM(provider_credits) FROM spec022_payable_request_credits`); got != 0 {
		t.Fatalf("payable provider credits before receipt=%d want 0", got)
	}

	markSPEC022ReceiptVerified(t, store.db, input)
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 1 {
		t.Fatalf("payable rows after verified receipt=%d want 1", got)
	}
	if err := store.RunSettlement(context.Background(), cfg, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 600 {
		t.Fatalf("verified payout provider credits=%d want 600", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
		t.Fatalf("settled verified rows=%d want 1", got)
	}

	if err := store.RunSettlement(context.Background(), cfg, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 1 {
		t.Fatalf("duplicate receipt payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 600 {
		t.Fatalf("duplicate receipt payout provider credits=%d want 600", got)
	}
}

func TestSPEC022DuplicateVerifiedReceiptAfterSettlementDoesNotDoublePay(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.RouteSnapshot.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
		tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
		tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
		tuple["route_snapshot_digest"] = routeDigest
	})
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	receiptBoundCredits := insertSPEC022ReceiptBoundLedgerCredit(t, store.db, input, 0)
	id := SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}

	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	first, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if first.SettlementOutcome != SettlementOutcomeVerified || first.IdempotencyStatus != settlementReceiptIDFirstTerminal {
		t.Fatalf("first receipt state=%#v, want first terminal verified", first)
	}
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}

	duplicate, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: id,
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS + 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	if duplicate.IdempotencyStatus != settlementReceiptIDTerminalNoop || duplicate.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("duplicate receipt state=%#v, want terminal noop verified", duplicate)
	}
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE request_id = ?`, input.RequestID); got != 1 {
		t.Fatalf("receipt verdict rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 1 {
		t.Fatalf("payout rows after duplicate receipt=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("payout provider credits after duplicate=%d want %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
		t.Fatalf("settled rows after duplicate receipt=%d want 1", got)
	}
}

func TestSPEC022ConcurrentSettlementWorkersSettleVerifiedRowOnce(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	receiptBoundCredits := insertSPEC022ReceiptBoundLedgerCredit(t, store.db, input, 0)
	markSPEC022ReceiptVerified(t, store.db, input)
	windowStart, windowEnd := settlementWindowForInput(input)
	cfg := SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}

	start := make(chan struct{})
	errs := make(chan error, 2)
	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			errs <- store.RunSettlement(context.Background(), cfg, windowStart, windowEnd)
		}()
	}
	close(start)
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 1 {
		t.Fatalf("concurrent payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("concurrent payout provider credits=%d want %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
		t.Fatalf("concurrent settled rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(DISTINCT settlement_id) FROM ledger_request_credits WHERE request_id = ? AND settlement_id IS NOT NULL`, input.RequestID); got != 1 {
		t.Fatalf("concurrent settlement IDs=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT source_credit_count FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 1 {
		t.Fatalf("concurrent source count=%d want 1", got)
	}
}

func TestSPEC022NonStreamingVerifiedReceiptCreatesBuyerFinalityAndProviderPayout(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.RouteSnapshot.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
		tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
		tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
		tuple["route_snapshot_digest"] = routeDigest
	})

	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	receiptBoundCredits := insertSPEC022ReceiptBoundLedgerCredit(t, store.db, input, 100)
	if receiptBoundCredits.ProviderCredits <= 0 {
		t.Fatalf("receipt-bound provider credits=%d want positive", receiptBoundCredits.ProviderCredits)
	}

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != 0 {
		t.Fatalf("payable rows before receipt=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits+100 {
		t.Fatalf("pre-receipt provider credits=%d want inflated seed %d", got, receiptBoundCredits.ProviderCredits+100)
	}

	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified || state.ReceiptResult != SettlementReceiptResultValid || !state.Closed {
		t.Fatalf("state=%#v, want terminal verified receipt", state)
	}
	if state.RouteSnapshotMode != RouteSnapshotModeEnforce ||
		state.RouteSnapshotPolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
		state.CatalogID != input.RouteSnapshot.CatalogID ||
		state.ModelHash != input.RouteSnapshot.ExpectedCatalogModelHash {
		t.Fatalf("state route/catalog binding=%#v, want enforce catalog-matching receipt", state)
	}

	finality, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("settlement finality not found")
	}
	if finality.Outcome != SettlementOutcomeVerified ||
		finality.ReceiptResult != SettlementReceiptResultValid ||
		!finality.Closed ||
		finality.Mode != RouteSnapshotModeEnforce ||
		finality.PolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
		finality.TokenSource != UsageSourceCoordinatorObserved {
		t.Fatalf("finality=%#v, want enforce verified buyer-debit finality", finality)
	}
	if finality.PromptTokens != input.ExpectedUsage.BillableInputTokens ||
		finality.CompletionTokens != input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens != input.ExpectedUsage.BillableInputTokens+input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens <= 0 {
		t.Fatalf("finality tokens=%#v, want positive billable usage %#v", finality, input.ExpectedUsage)
	}

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != 1 {
		t.Fatalf("payable rows after verified receipt=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("payable provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("ledger provider credits after receipt=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("payout provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 1 {
		t.Fatalf("settled request credit rows=%d want 1", got)
	}
}

func TestSPEC022StreamingVerifiedReceiptCreatesBuyerFinalityAndProviderPayout(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := settlementTupleByID(t, fixtures, "receipt_tuple_v4_streaming_tool_call_nonzero_prefix")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.RouteSnapshot.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
		tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
		tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
		tuple["route_snapshot_digest"] = routeDigest
	})
	if input.OutputPrefixEndByte <= input.OutputPrefixStartByte {
		t.Fatalf("streaming fixture output prefix [%d,%d) must be non-empty", input.OutputPrefixStartByte, input.OutputPrefixEndByte)
	}
	if input.ExpectedUsage.BillableOutputTokens <= 0 || input.ExpectedUsage.DeliveredOutputBytes <= 0 {
		t.Fatalf("streaming fixture usage=%#v, want partial output usage", input.ExpectedUsage)
	}

	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	receiptBoundCredits := insertSPEC022ReceiptBoundLedgerCreditWithStream(t, store.db, input, 100, true)
	if receiptBoundCredits.ProviderCredits <= 0 {
		t.Fatalf("receipt-bound provider credits=%d want positive", receiptBoundCredits.ProviderCredits)
	}

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != 0 {
		t.Fatalf("streaming payable rows before receipt=%d want 0", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ? AND stream = 1`, input.RequestID); got != receiptBoundCredits.ProviderCredits+100 {
		t.Fatalf("streaming pre-receipt provider credits=%d want inflated seed %d", got, receiptBoundCredits.ProviderCredits+100)
	}

	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified || state.ReceiptResult != SettlementReceiptResultValid || !state.Closed {
		t.Fatalf("state=%#v, want terminal verified streaming receipt", state)
	}

	finality, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	if !found {
		t.Fatal("streaming settlement finality not found")
	}
	if finality.Outcome != SettlementOutcomeVerified ||
		finality.ReceiptResult != SettlementReceiptResultValid ||
		!finality.Closed ||
		finality.Mode != RouteSnapshotModeEnforce ||
		finality.PolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
		finality.TokenSource != UsageSourceCoordinatorObserved {
		t.Fatalf("finality=%#v, want enforce verified streaming buyer-debit finality", finality)
	}
	if finality.PromptTokens != input.ExpectedUsage.BillableInputTokens ||
		finality.CompletionTokens != input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens != input.ExpectedUsage.BillableInputTokens+input.ExpectedUsage.BillableOutputTokens ||
		finality.TotalTokens <= 0 {
		t.Fatalf("finality tokens=%#v, want streaming billable usage %#v", finality, input.ExpectedUsage)
	}

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ? AND stream = 1`, input.RequestID); got != 1 {
		t.Fatalf("streaming payable rows after verified receipt=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("streaming payable provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("streaming ledger provider credits after receipt=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("streaming payout provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND stream = 1 AND settled = 1`, input.RequestID); got != 1 {
		t.Fatalf("streaming settled request credit rows=%d want 1", got)
	}
}

func TestSPEC022StreamingPartialTerminalReceiptsCreateReceiptBoundSettlement(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	for _, tc := range []struct {
		name          string
		tupleID       string
		terminalState string
	}{
		{
			name:          "provider-error-prefix",
			tupleID:       "receipt_tuple_v4_provider_error_prefix",
			terminalState: TerminalStateProviderError,
		},
		{
			name:          "buyer-cancel-prefix",
			tupleID:       "receipt_tuple_v4_buyer_cancel_prefix",
			terminalState: TerminalStateBuyerCancel,
		},
		{
			name:          "gateway-timeout-prefix",
			tupleID:       "receipt_tuple_v4_gateway_timeout_prefix",
			terminalState: TerminalStateGatewayTimeout,
		},
		{
			name:          "upstream-disconnect-prefix",
			tupleID:       "receipt_tuple_v4_upstream_disconnect_prefix",
			terminalState: TerminalStateUpstreamTransportDisconnect,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			tuple := settlementTupleByID(t, fixtures, tc.tupleID)
			input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
			input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
			input.RouteSnapshot.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
			routeDigest, _, err := input.RouteSnapshot.Digest()
			if err != nil {
				t.Fatal(err)
			}
			input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
				tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
				tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
				tuple["route_snapshot_digest"] = routeDigest
			})
			if input.TerminalState != tc.terminalState {
				t.Fatalf("terminal_state=%q want %q", input.TerminalState, tc.terminalState)
			}
			if input.OutputPrefixEndByte <= input.OutputPrefixStartByte {
				t.Fatalf("partial terminal fixture output prefix [%d,%d) must be non-empty", input.OutputPrefixStartByte, input.OutputPrefixEndByte)
			}
			if input.ExpectedUsage.BillableOutputTokens <= 0 || input.ExpectedUsage.DeliveredOutputBytes <= 0 {
				t.Fatalf("partial terminal usage=%#v, want delivered output usage", input.ExpectedUsage)
			}

			_, store := newRequestAndBillingStores(t)
			createSettlementReceiptAuditLog(t, store.db)
			seedSettlementReceiptEvidence(t, store, input)
			receiptBoundCredits := insertSPEC022ReceiptBoundLedgerCreditWithStream(t, store.db, input, 100, true)
			if receiptBoundCredits.ProviderCredits <= 0 {
				t.Fatalf("receipt-bound provider credits=%d want positive", receiptBoundCredits.ProviderCredits)
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != 0 {
				t.Fatalf("partial terminal payable rows before receipt=%d want 0", got)
			}
			if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ? AND stream = 1`, input.RequestID); got != receiptBoundCredits.ProviderCredits+100 {
				t.Fatalf("partial terminal pre-receipt provider credits=%d want inflated seed %d", got, receiptBoundCredits.ProviderCredits+100)
			}

			setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
			state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
				SettlementReceiptIdentity: settlementIdentityFromInput(input),
				Header:                    input.Header,
				ProviderReceiptPubkey:     pubkey,
				receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
			})
			if err != nil {
				t.Fatal(err)
			}
			if state.SettlementOutcome != SettlementOutcomeVerified ||
				state.ReceiptResult != SettlementReceiptResultValid ||
				!state.Closed ||
				state.TerminalState != tc.terminalState {
				t.Fatalf("state=%#v, want terminal verified partial streaming receipt", state)
			}

			finality, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, input.ReceiptReceivedUnixMS)
			if err != nil {
				t.Fatal(err)
			}
			if !found {
				t.Fatal("partial terminal settlement finality not found")
			}
			if finality.Outcome != SettlementOutcomeVerified ||
				finality.ReceiptResult != SettlementReceiptResultValid ||
				!finality.Closed ||
				finality.Mode != RouteSnapshotModeEnforce ||
				finality.PolicyVersion != input.RouteSnapshot.RouteSnapshotPolicyVersion ||
				finality.TokenSource != UsageSourceCoordinatorObserved {
				t.Fatalf("finality=%#v, want enforce verified partial streaming buyer-debit finality", finality)
			}
			if finality.PromptTokens != input.ExpectedUsage.BillableInputTokens ||
				finality.CompletionTokens != input.ExpectedUsage.BillableOutputTokens ||
				finality.TotalTokens != input.ExpectedUsage.BillableInputTokens+input.ExpectedUsage.BillableOutputTokens ||
				finality.TotalTokens <= 0 {
				t.Fatalf("finality tokens=%#v, want partial streaming billable usage %#v", finality, input.ExpectedUsage)
			}

			if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id = ? AND stream = 1`, input.RequestID); got != 1 {
				t.Fatalf("partial terminal payable rows after verified receipt=%d want 1", got)
			}
			if got := scalar(t, store.db, `SELECT provider_credits FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
				t.Fatalf("partial terminal payable provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
			}
			if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
				t.Fatalf("partial terminal ledger provider credits after receipt=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
			}

			windowStart, windowEnd := settlementWindowForInput(input)
			if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
				t.Fatal(err)
			}
			if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != receiptBoundCredits.ProviderCredits {
				t.Fatalf("partial terminal payout provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND stream = 1 AND settled = 1`, input.RequestID); got != 1 {
				t.Fatalf("partial terminal settled request credit rows=%d want 1", got)
			}
		})
	}
}

func TestSPEC022ReceiptBeforeHotPathLedgerStillPaysReceiptBoundCredits(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.RouteSnapshot.RouteSnapshotPolicyVersion = RouteSnapshotPolicyVersion
	routeDigest, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	input.Header = settlementHeaderWithCanonicalMutationAndTestSignature(t, input.Header, func(tuple map[string]any) {
		tuple["route_snapshot_mode"] = RouteSnapshotModeEnforce
		tuple["route_snapshot_policy_version"] = RouteSnapshotPolicyVersion
		tuple["route_snapshot_digest"] = routeDigest
	})

	reqStore, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	setSettlementReceiptNow(store, input.ReceiptReceivedUnixMS)
	if _, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     pubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != 0 {
		t.Fatalf("ledger rows before hotpath=%d want 0", got)
	}

	prompt := input.ExpectedUsage.BillableInputTokens
	completion := input.ExpectedUsage.BillableOutputTokens
	receiptBoundCredits := ComputeCredits(
		&prompt,
		&completion,
		nil,
		UsageProviderReported,
		FaultNone,
		RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000},
		1000000,
		10000,
	)
	inflatedPrompt := prompt + 1000000
	inflatedCompletion := completion + 1000000
	hotPathInput := HotPathInput{
		RequestID:                  input.RequestID,
		AttemptN:                   int(input.AttemptN),
		ProviderAssignedID:         "assigned",
		ProviderID:                 input.ProviderID,
		Model:                      input.RouteSnapshot.ModelID,
		Status:                     200,
		Stream:                     false,
		TSUtc:                      time.UnixMilli(input.TerminalStateTSUnixMS).UTC(),
		PromptTokens:               &inflatedPrompt,
		CompletionTokens:           &inflatedCompletion,
		ErrorCode:                  "",
		FaultFlag:                  FaultNone,
		RateEntry:                  RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000},
		MultiplierPPM:              1000000,
		ProviderShareBps:           10000,
		SettlementAccountScopeHash: SettlementAccountScopeHash(input.AccountScope),
		SettlementPolicyMode:       RouteSnapshotModeEnforce,
		SettlementPolicyVersion:    input.RouteSnapshot.RouteSnapshotPolicyVersion,
	}
	if err := store.WriteHotPath(context.Background(), reqStore, requestLogRow(hotPathInput), hotPathInput); err != nil {
		t.Fatal(err)
	}

	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("post-receipt hotpath provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	if got := scalar(t, store.db, `SELECT prompt_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != prompt {
		t.Fatalf("post-receipt hotpath prompt tokens=%d want receipt-bound %d", got, prompt)
	}
	if got := scalar(t, store.db, `SELECT completion_tokens FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != completion {
		t.Fatalf("post-receipt hotpath completion tokens=%d want receipt-bound %d", got, completion)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM spec022_payable_request_credits WHERE request_id = ?`, input.RequestID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("payable provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != receiptBoundCredits.ProviderCredits {
		t.Fatalf("payout provider credits=%d want receipt-bound %d", got, receiptBoundCredits.ProviderCredits)
	}
}

func TestSPEC022PayableCreditGateBlocksQuarantineAndOverlap(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	baseInput := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	baseInput.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce

	for _, tc := range []struct {
		name string
		mark func(t *testing.T, store *Store, input SettlementVerifyInput)
	}{
		{
			name: "deadline quarantine",
			mark: func(t *testing.T, store *Store, input SettlementVerifyInput) {
				t.Helper()
				deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
				state, err := store.RecordMissingSettlementReceipt(context.Background(), SettlementReceiptMissingInput{
					SettlementReceiptIdentity: settlementIdentityFromInput(input),
					NowUnixMS:                 deadline + 1,
				})
				if err != nil {
					t.Fatal(err)
				}
				if state.SettlementOutcome != SettlementOutcomeQuarantined {
					t.Fatalf("state=%#v want quarantined", state)
				}
			},
		},
		{
			name: "verified receipt later marked overlapping",
			mark: func(t *testing.T, store *Store, input SettlementVerifyInput) {
				t.Helper()
				markSPEC022ReceiptVerified(t, store.db, input)
				if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
   SET overlapping_or_duplicate = 1
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
					input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
				); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := baseInput
			input.RequestID = input.RequestID + "-" + tc.name
			input.RouteSnapshot.RequestID = input.RequestID
			_, store := newRequestAndBillingStores(t)
			createSettlementReceiptAuditLog(t, store.db)
			seedSettlementReceiptEvidence(t, store, input)
			insertSPEC022LedgerCredit(t, store.db, input, 700)
			tc.mark(t, store, input)
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
				t.Fatalf("payable rows=%d want 0", got)
			}
			windowStart, windowEnd := settlementWindowForInput(input)
			if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
				t.Fatal(err)
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
				t.Fatalf("payout rows=%d want 0", got)
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1`, input.RequestID); got != 0 {
				t.Fatalf("settled blocked rows=%d want 0", got)
			}
		})
	}
}

func TestSPEC022PayableCreditGateLeavesObserveRowsPayable(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeObserve
	_, store := newRequestAndBillingStores(t)
	insertSPEC022LedgerCreditWithMode(t, store.db, input, 500, RouteSnapshotModeObserve, "")

	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 1 {
		t.Fatalf("observe payable rows=%d want 1", got)
	}
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID); got != 500 {
		t.Fatalf("observe payout provider credits=%d want 500", got)
	}
}

func TestSPEC022PayableCreditGateBlocksMissingSnapshotAndAccountMismatch(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce

	t.Run("missing route snapshot", func(t *testing.T) {
		_, store := newRequestAndBillingStores(t)
		insertSPEC022LedgerCredit(t, store.db, input, 400)
		if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
			t.Fatalf("payable rows without route snapshot=%d want 0", got)
		}
	})

	t.Run("receipt for different account", func(t *testing.T) {
		accountMismatch := input
		accountMismatch.RequestID = accountMismatch.RequestID + "-account-mismatch"
		accountMismatch.RouteSnapshot.RequestID = accountMismatch.RequestID
		_, store := newRequestAndBillingStores(t)
		seedSettlementReceiptEvidence(t, store, accountMismatch)
		markSPEC022ReceiptVerified(t, store.db, accountMismatch)
		otherHash := SettlementAccountScopeHash("acct_sha256:other-account")
		insertSPEC022LedgerCreditWithMode(t, store.db, accountMismatch, 450, RouteSnapshotModeEnforce, otherHash)
		if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
			t.Fatalf("payable rows with account mismatch=%d want 0", got)
		}
	})
}

func TestSPEC022PayoutClaimRevalidatesSourceRows(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 800)
	markSPEC022ReceiptVerified(t, store.db, input)

	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID)
	if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
   SET overlapping_or_duplicate = 1
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 800, "external-after-overlap", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim succeeded after source row became non-payable")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
		t.Fatalf("voided payout rows after fully invalid revalidation=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
		t.Fatalf("immutable invalid source rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type='spec_007_claim' AND status='failed'`); got != 1 {
		t.Fatalf("failed claim audit rows=%d want 1", got)
	}
}

func TestSPEC022PayoutClaimRejectsManualReadyRowWithoutVerifiedSources(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	windowStart := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	windowEnd := windowStart.AddDate(0, 0, 7)
	now := windowStart.Add(time.Hour).Format(time.RFC3339Nano)
	res, err := store.db.Exec(`
INSERT INTO ledger_payout_ready (
    provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
    gross_credits, provider_credits, operator_credits, min_payout_credits,
    payout_currency, payout_external_id, status, idempotency_key, created_at_utc
) VALUES ('manual-provider', ?, ?, 7, 1, 900, 900, 0, 1, NULL, NULL, 'ready', 'manual-provider|source-less', ?)`,
		windowStart.Format(time.RFC3339Nano),
		windowEnd.Format(time.RFC3339Nano),
		now,
	)
	if err != nil {
		t.Fatal(err)
	}
	payoutID, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 900, "external-manual", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("manual source-less payout claim succeeded")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
		t.Fatalf("manual source-less voided payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type='spec_007_claim' AND status='failed'`); got != 1 {
		t.Fatalf("failed manual source-less claim audits=%d want 1", got)
	}
}

func TestSPEC022PayoutClaimRevalidatesReadyRowTotals(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 500)
	markSPEC022ReceiptVerified(t, store.db, input)
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID)
	if _, err := store.db.Exec(`
UPDATE ledger_payout_ready
   SET gross_credits = 900,
       provider_credits = 900,
       operator_credits = 0
 WHERE id = ?`, payoutID); err != nil {
		t.Fatal(err)
	}

	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 900, "external-inflated", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("inflated payout claim succeeded")
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE id = ? AND status = 'ready'`, payoutID); got != 500 {
		t.Fatalf("revalidated payout provider credits=%d want 500", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
		t.Fatalf("verified source rows after total revalidation=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type='spec_007_claim' AND status='failed'`); got != 1 {
		t.Fatalf("failed inflated claim audits=%d want 1", got)
	}

	claimed, err = store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-corrected", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if !claimed {
		t.Fatal("claim with corrected verified total failed")
	}
}

func TestSPEC022SettledSourceMoneyFieldsAreImmutable(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 500)
	markSPEC022ReceiptVerified(t, store.db, input)
	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID)

	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET gross_credits = 900,
       provider_credits = 900
 WHERE request_id = ?`, input.RequestID); err == nil {
		t.Fatal("settled source money update succeeded")
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); got != 500 {
		t.Fatalf("settled source provider credits=%d want 500", got)
	}
	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET settlement_id = settlement_id + 100
 WHERE request_id = ?`, input.RequestID); err == nil {
		t.Fatal("settled source settlement link update succeeded")
	}
	manualPayoutID := insertSPEC022ManualPayoutReady(t, store.db, input.ProviderID, windowStart.AddDate(0, 0, 7), windowEnd.AddDate(0, 0, 7), 1, 500, 500, "repoint-settled-source")
	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET settlement_id = ?
 WHERE request_id = ?`, manualPayoutID, input.RequestID); err == nil {
		t.Fatal("settled source repoint succeeded")
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 900, "external-mutated-source", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim with mutated source amount succeeded")
	}
	claimed, err = store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-verified-source", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if !claimed {
		t.Fatal("claim with original verified source amount failed")
	}
}

func TestSPEC022SettlementTransitionCannotMutateMoney(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.RequestID = input.RequestID + "-transition-mutation"
	input.RouteSnapshot.RequestID = input.RequestID
	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 500)
	markSPEC022ReceiptVerified(t, store.db, input)
	windowStart, windowEnd := settlementWindowForInput(input)
	payoutID := insertSPEC022ManualPayoutReady(t, store.db, input.ProviderID, windowStart, windowEnd, 1, 900, 900, "transition-mutation")

	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET settled = 1,
       settlement_id = ?,
       gross_credits = 900,
       provider_credits = 900
 WHERE request_id = ?`, payoutID, input.RequestID); err == nil {
		t.Fatal("settlement transition with money mutation succeeded")
	}
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ? AND settled = 0 AND settlement_id IS NULL`, input.RequestID); got != 500 {
		t.Fatalf("unsettled source provider credits after failed transition=%d want 500", got)
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 900, "external-transition-mutation", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim with failed forged transition succeeded")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
		t.Fatalf("voided transition-mutation payout rows=%d want 1", got)
	}
}

func TestSPEC022PayoutClaimRejectsForgedSourceRows(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")

	for _, tc := range []struct {
		name           string
		payoutProvider string
		linkSource     func(t *testing.T, store *Store, input SettlementVerifyInput, payoutID int64)
	}{
		{
			name: "unsettled linked source",
			linkSource: func(t *testing.T, store *Store, input SettlementVerifyInput, payoutID int64) {
				t.Helper()
				if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settlement_id = ? WHERE request_id = ?`, payoutID, input.RequestID); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name:           "wrong provider linked source",
			payoutProvider: "provider-forged",
			linkSource: func(t *testing.T, store *Store, input SettlementVerifyInput, payoutID int64) {
				t.Helper()
				if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settled = 1, settlement_id = ? WHERE request_id = ?`, payoutID, input.RequestID); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
			input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
			input.RequestID = input.RequestID + "-" + strings.ReplaceAll(tc.name, " ", "-")
			input.RouteSnapshot.RequestID = input.RequestID
			_, store := newRequestAndBillingStores(t)
			seedSettlementReceiptEvidence(t, store, input)
			insertSPEC022LedgerCredit(t, store.db, input, 500)
			markSPEC022ReceiptVerified(t, store.db, input)
			windowStart, windowEnd := settlementWindowForInput(input)
			providerID := input.ProviderID
			if tc.payoutProvider != "" {
				providerID = tc.payoutProvider
			}
			payoutID := insertSPEC022ManualPayoutReady(t, store.db, providerID, windowStart, windowEnd, 1, 500, 500, "forged-"+tc.name)
			tc.linkSource(t, store, input, payoutID)

			claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-forged", "USDC")
			if err != nil {
				t.Fatal(err)
			}
			if claimed {
				t.Fatal("forged source payout claim succeeded")
			}
			if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
				t.Fatalf("voided forged source payout rows=%d want 1", got)
			}
			if tc.payoutProvider == "" {
				if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 0 AND settlement_id IS NULL`, input.RequestID); got != 1 {
					t.Fatalf("released unsettled forged source rows=%d want 1", got)
				}
			} else {
				if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
					t.Fatalf("immutable settled forged source rows=%d want 1", got)
				}
			}
		})
	}
}

func TestSPEC022PayoutClaimRevalidatesObserveSourceRows(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeObserve
	_, store := newRequestAndBillingStores(t)
	insertSPEC022LedgerCreditWithMode(t, store.db, input, 500, RouteSnapshotModeObserve, "")

	windowStart, windowEnd := settlementWindowForInput(input)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, input.ProviderID)
	if _, err := store.db.Exec(`
UPDATE ledger_request_credits
   SET quarantined = 1,
       quarantine_reason = 'post-ready manual quarantine'
 WHERE request_id = ?`,
		input.RequestID,
	); err != nil {
		t.Fatal(err)
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-after-quarantine", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim succeeded after observe source row became non-payable")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
		t.Fatalf("voided payout rows after observe revalidation=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, input.RequestID, payoutID); got != 1 {
		t.Fatalf("immutable observe source rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type='spec_007_claim' AND status='failed'`); got != 1 {
		t.Fatalf("failed observe claim audit rows=%d want 1", got)
	}
}

func TestSPEC022PayoutClaimRecomputesMixedSources(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	first := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	first.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	second := first
	second.RequestID = second.RequestID + "-valid"
	second.RouteSnapshot.RequestID = second.RequestID

	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, first)
	insertSPEC022LedgerCredit(t, store.db, first, 800)
	markSPEC022ReceiptVerified(t, store.db, first)
	seedSettlementReceiptEvidence(t, store, second)
	insertSPEC022LedgerCredit(t, store.db, second, 500)
	markSPEC022ReceiptVerified(t, store.db, second)

	windowStart, windowEnd := settlementWindowForInput(first)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, first.ProviderID)
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE id = ?`, payoutID); got != 1300 {
		t.Fatalf("initial payout provider credits=%d want 1300", got)
	}
	if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
   SET overlapping_or_duplicate = 1
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		first.AccountScope, first.RequestID, first.AttemptN, first.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET settlement_policy_mode='legacy' WHERE request_id=?`, first.RequestID); err == nil {
		t.Fatal("settled policy downgrade succeeded")
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 1300, "external-old-total", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim succeeded with stale mixed total")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
		t.Fatalf("voided mixed-source payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, first.RequestID, payoutID); got != 1 {
		t.Fatalf("immutable invalid mixed source rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id = ? AND settled = 1 AND settlement_id = ?`, second.RequestID, payoutID); got != 1 {
		t.Fatalf("valid source retained rows=%d want 1", got)
	}
	claimed, err = store.ClaimPayoutReady(context.Background(), payoutID, 500, "external-valid-total", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim with voided mixed-source payout succeeded")
	}
}

func TestSPEC022PayoutClaimReleasesRemainderBelowMinimum(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	first := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	first.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	second := first
	second.RequestID = second.RequestID + "-below-min"
	second.RouteSnapshot.RequestID = second.RequestID

	_, store := newRequestAndBillingStores(t)
	seedSettlementReceiptEvidence(t, store, first)
	insertSPEC022LedgerCredit(t, store.db, first, 800)
	markSPEC022ReceiptVerified(t, store.db, first)
	seedSettlementReceiptEvidence(t, store, second)
	insertSPEC022LedgerCredit(t, store.db, second, 500)
	markSPEC022ReceiptVerified(t, store.db, second)

	windowStart, windowEnd := settlementWindowForInput(first)
	if err := store.RunSettlement(context.Background(), SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1000}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	payoutID := scalar(t, store.db, `SELECT id FROM ledger_payout_ready WHERE provider_id = ?`, first.ProviderID)
	if got := scalar(t, store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE id = ?`, payoutID); got != 1300 {
		t.Fatalf("initial payout provider credits=%d want 1300", got)
	}
	if _, err := store.db.Exec(`
UPDATE settlement_attempt_outputs
   SET overlapping_or_duplicate = 1
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		first.AccountScope, first.RequestID, first.AttemptN, first.ProviderID,
	); err != nil {
		t.Fatal(err)
	}
	claimed, err := store.ClaimPayoutReady(context.Background(), payoutID, 1300, "external-old-total", "USDC")
	if err != nil {
		t.Fatal(err)
	}
	if claimed {
		t.Fatal("claim succeeded with stale below-minimum remainder")
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_payout_ready WHERE id = ? AND status='voided'`, payoutID); got != 1 {
		t.Fatalf("voided below-minimum payout rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id IN (?, ?) AND settled = 1 AND settlement_id = ?`, first.RequestID, second.RequestID, payoutID); got != 2 {
		t.Fatalf("immutable below-minimum source rows=%d want 2", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_reconciliation_runs WHERE run_type='spec_007_claim' AND status='failed'`); got != 1 {
		t.Fatalf("failed below-minimum claim audit rows=%d want 1", got)
	}
}

func TestSPEC022RecoveryPreservesEnforcePolicyFromRouteSnapshot(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RequestID = "recover-spec022-enforce"
	input.RouteSnapshot.RequestID = input.RequestID
	input.RouteSnapshot.AccountScope = AccountScopeForSettlement("buyer-recovery")
	input.AccountScope = input.RouteSnapshot.AccountScope
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.AttemptN = 0
	input.RouteSnapshot.AttemptN = 0

	reqStore, store := newRequestAndBillingStores(t)
	if _, err := store.InsertConfigSnapshot(context.Background(), testRewards(), time.Unix(100, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(1000), int64(1000)
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              ts,
		RequestID:          input.RequestID,
		AccountID:          "buyer-recovery",
		Model:              input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned-recovery",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertRouteSnapshot(context.Background(), input.RouteSnapshot); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc
) VALUES (?, 0, 'assigned-recovery', ?, 'pool_entry', ?)`,
		input.RequestID, input.ProviderID, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=? AND settlement_policy_mode='enforce' AND settlement_account_scope_hash=?`, input.RequestID, SettlementAccountScopeHash(input.AccountScope)); got != 1 {
		t.Fatalf("recovered enforce policy rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits WHERE request_id=?`, input.RequestID); got != 0 {
		t.Fatalf("recovered payable rows without verified receipt=%d want 0", got)
	}
}

func TestSPEC022RecoveryDoesNotUseOtherAccountRouteSnapshot(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	input.RequestID = "recover-spec022-account-collision"
	input.RouteSnapshot.RequestID = input.RequestID
	input.RouteSnapshot.AccountScope = AccountScopeForSettlement("other-buyer")
	input.AccountScope = input.RouteSnapshot.AccountScope
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
	input.AttemptN = 0
	input.RouteSnapshot.AttemptN = 0

	reqStore, store := newRequestAndBillingStores(t)
	if _, err := store.InsertConfigSnapshot(context.Background(), testRewards(), time.Unix(100, 0).UTC()); err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(1000), int64(1000)
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	if err := reqStore.Insert(context.Background(), requestlog.Row{
		TSUtc:              ts,
		RequestID:          input.RequestID,
		AccountID:          "ledger-buyer",
		Model:              input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned-collision",
		PromptTokens:       &prompt,
		CompletionTokens:   &completion,
		Status:             200,
		BuyerIP:            "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.InsertRouteSnapshot(context.Background(), input.RouteSnapshot); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
INSERT INTO ledger_provider_identity_snapshots (
    request_id, attempt_n, provider_assigned_id, provider_id, resolved_from, created_at_utc
) VALUES (?, 0, 'assigned-collision', ?, 'pool_entry', ?)`,
		input.RequestID, input.ProviderID, ts.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	if err := store.RecoverLedger(context.Background(), RecoverInput{ScanFrom: ts.Add(-time.Minute), ScanTo: ts.Add(time.Minute), Source: "startup_scan"}); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=? AND settlement_policy_mode='legacy' AND settlement_account_scope_hash=?`, input.RequestID, SettlementAccountScopeHashForAccountID("ledger-buyer")); got != 1 {
		t.Fatalf("recovered legacy ledger-account rows=%d want 1", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits WHERE request_id=? AND settlement_account_scope_hash=?`, input.RequestID, SettlementAccountScopeHash(input.RouteSnapshot.AccountScope)); got != 0 {
		t.Fatalf("recovered rows bound to other account snapshot=%d want 0", got)
	}
}

func TestSPEC022MigratedDBEnforcesSettlementPolicyGuards(t *testing.T) {
	path := filepath.Join(t.TempDir(), "legacy.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	createRequestLogForTest(t, db)
	if _, err := db.Exec(`
CREATE TABLE ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK(attempt_n >= 0),
    provider_id TEXT NOT NULL,
    provider_assigned_id TEXT NULL,
    ts_utc TEXT NOT NULL,
    model TEXT NOT NULL,
    status INTEGER NOT NULL,
    stream INTEGER NOT NULL CHECK(stream IN (0,1)),
    prompt_tokens INTEGER NULL CHECK(prompt_tokens IS NULL OR prompt_tokens >= 0),
    completion_tokens INTEGER NULL CHECK(completion_tokens IS NULL OR completion_tokens >= 0),
    estimated_completion_tokens INTEGER NULL CHECK(estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0),
    usage_source TEXT NOT NULL CHECK(usage_source IN ('provider_reported','byte_estimated','null_error')),
    prompt_rate_per_mtok INTEGER NOT NULL CHECK(prompt_rate_per_mtok >= 0),
    completion_rate_per_mtok INTEGER NOT NULL CHECK(completion_rate_per_mtok >= 0),
    global_multiplier_ppm INTEGER NOT NULL CHECK(global_multiplier_ppm >= 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    provider_share_bps INTEGER NOT NULL CHECK(provider_share_bps BETWEEN 0 AND 10000),
    provider_credits INTEGER NOT NULL CHECK(provider_credits >= 0),
    fault_flag TEXT NOT NULL DEFAULT 'none' CHECK(fault_flag IN ('none','breaker_qualifying','null_usage_error')),
    attestation_class TEXT NULL,
    settled INTEGER NOT NULL DEFAULT 0 CHECK(settled IN (0,1)),
    settlement_id INTEGER NULL,
    quarantined INTEGER NOT NULL DEFAULT 0 CHECK(quarantined IN (0,1)),
    quarantine_reason TEXT NULL,
    recovery_source TEXT NOT NULL DEFAULT 'hot_path' CHECK(recovery_source IN ('hot_path','startup_scan','nightly_reconcile')),
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    UNIQUE(request_id, attempt_n, provider_id),
    CHECK(usage_source != 'null_error' OR gross_credits = 0)
)`); err != nil {
		t.Fatal(err)
	}
	store, err := NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	_ = store
	ts := time.Unix(200, 0).UTC().Format(time.RFC3339Nano)
	insertSQL := `
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, settlement_account_scope_hash, settlement_policy_mode,
    settlement_policy_version, recovery_source, created_at_utc
) VALUES (?, 0, 'provider-a', 'assigned-a', ?, 'model-a', 200, 0,
          'provider_reported', 1, 1, 1000000, 100, 10000, 100,
          'none', ?, ?, 'spec022-policy-v1', 'hot_path', ?)`
	if _, err := db.Exec(insertSQL, "bad-mode", ts, SettlementAccountScopeHash("legacy_direct"), "shadow", ts); err == nil {
		t.Fatal("invalid settlement policy mode inserted on migrated DB")
	}
	if _, err := db.Exec(insertSQL, "bad-hash", ts, "not-a-hash", RouteSnapshotModeEnforce, ts); err == nil {
		t.Fatal("invalid settlement account hash inserted on migrated DB")
	}
	if _, err := db.Exec(insertSQL, "valid", ts, SettlementAccountScopeHash("legacy_direct"), RouteSnapshotModeEnforce, ts); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE ledger_request_credits SET settlement_policy_mode='legacy' WHERE request_id='valid'`); err == nil {
		t.Fatal("settlement policy update succeeded on migrated DB")
	}
}

func insertSPEC022LedgerCredit(t *testing.T, db *sql.DB, input SettlementVerifyInput, providerCredits int64) {
	t.Helper()
	insertSPEC022LedgerCreditWithMode(t, db, input, providerCredits, RouteSnapshotModeEnforce, "")
}

func insertSPEC022ManualPayoutReady(t *testing.T, db *sql.DB, providerID string, windowStart, windowEnd time.Time, sourceCount, grossCredits, providerCredits int64, idempotencySuffix string) int64 {
	t.Helper()
	now := windowStart.Add(time.Hour).Format(time.RFC3339Nano)
	res, err := db.Exec(`
INSERT INTO ledger_payout_ready (
    provider_id, window_start_utc, window_end_utc, cadence_days, source_credit_count,
    gross_credits, provider_credits, operator_credits, min_payout_credits,
    payout_currency, payout_external_id, status, idempotency_key, created_at_utc
) VALUES (?, ?, ?, 7, ?, ?, ?, ?, 1, NULL, NULL, 'ready', ?, ?)`,
		providerID,
		windowStart.Format(time.RFC3339Nano),
		windowEnd.Format(time.RFC3339Nano),
		sourceCount,
		grossCredits,
		providerCredits,
		grossCredits-providerCredits,
		providerID+"|"+idempotencySuffix,
		now,
	)
	if err != nil {
		t.Fatal(err)
	}
	id, err := res.LastInsertId()
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func insertSPEC022LedgerCreditWithMode(t *testing.T, db *sql.DB, input SettlementVerifyInput, providerCredits int64, mode, accountScopeHash string) {
	t.Helper()
	if accountScopeHash == "" {
		accountScopeHash = SettlementAccountScopeHash(input.AccountScope)
	}
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	_, err := db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, settlement_account_scope_hash, settlement_policy_mode,
    settlement_policy_version, recovery_source, created_at_utc
) VALUES (?, ?, ?, 'assigned', ?, ?, 200, 0, 'provider_reported', 1, 1, 1000000, ?, 10000, ?, 'none', ?, ?, ?, 'hot_path', ?)`,
		input.RequestID, input.AttemptN, input.ProviderID, ts.Format(time.RFC3339Nano), input.RouteSnapshot.ModelID,
		providerCredits, providerCredits, accountScopeHash, mode, input.RouteSnapshot.RouteSnapshotPolicyVersion, ts.Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`, input.RequestID, input.AttemptN, input.ProviderID)
	_, err = db.Exec(`
INSERT INTO ledger_operator_credits (
    request_credit_id, request_id, attempt_n, provider_id, ts_utc,
    gross_credits, operator_share_bps, operator_credits, fault_flag, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 'none', ?)`,
		requestCreditID, input.RequestID, input.AttemptN, input.ProviderID, ts.Format(time.RFC3339Nano), providerCredits, ts.Format(time.RFC3339Nano))
	if err != nil {
		t.Fatal(err)
	}
}

func insertSPEC022ReceiptBoundLedgerCredit(t *testing.T, db *sql.DB, input SettlementVerifyInput, providerCreditInflation int64) BilledRow {
	t.Helper()
	return insertSPEC022ReceiptBoundLedgerCreditWithStream(t, db, input, providerCreditInflation, false)
}

func insertSPEC022ReceiptBoundLedgerCreditWithStream(t *testing.T, db *sql.DB, input SettlementVerifyInput, providerCreditInflation int64, stream bool) BilledRow {
	t.Helper()
	prompt := input.ExpectedUsage.BillableInputTokens
	completion := input.ExpectedUsage.BillableOutputTokens
	result := ComputeCredits(
		&prompt,
		&completion,
		nil,
		UsageProviderReported,
		FaultNone,
		RateCardEntry{PromptCreditsPerMtok: 1000000, CompletionCreditsPerMtok: 1000000},
		1000000,
		10000,
	)
	inflatedProviderCredits := result.ProviderCredits + providerCreditInflation
	if inflatedProviderCredits < result.ProviderCredits {
		t.Fatalf("provider credit inflation overflow: base=%d inflation=%d", result.ProviderCredits, providerCreditInflation)
	}
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	streamInt := 0
	if stream {
		streamInt = 1
	}
	_, err := db.Exec(`
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model,
    status, stream, prompt_tokens, completion_tokens, estimated_completion_tokens,
    usage_source, prompt_rate_per_mtok, completion_rate_per_mtok,
    global_multiplier_ppm, gross_credits, provider_share_bps, provider_credits,
    fault_flag, settlement_account_scope_hash, settlement_policy_mode,
    settlement_policy_version, recovery_source, created_at_utc
) VALUES (?, ?, ?, 'assigned', ?, ?, 200, ?, ?, ?, NULL, 'provider_reported',
          1000000, 1000000, 1000000, ?, 10000, ?, 'none', ?, 'enforce', ?, 'hot_path', ?)`,
		input.RequestID,
		input.AttemptN,
		input.ProviderID,
		ts.Format(time.RFC3339Nano),
		input.RouteSnapshot.ModelID,
		streamInt,
		prompt,
		completion,
		inflatedProviderCredits,
		inflatedProviderCredits,
		SettlementAccountScopeHash(input.AccountScope),
		input.RouteSnapshot.RouteSnapshotPolicyVersion,
		ts.Format(time.RFC3339Nano),
	)
	if err != nil {
		t.Fatal(err)
	}
	requestCreditID := scalar(t, db, `SELECT id FROM ledger_request_credits WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`, input.RequestID, input.AttemptN, input.ProviderID)
	_, err = db.Exec(`
INSERT INTO ledger_operator_credits (
    request_credit_id, request_id, attempt_n, provider_id, ts_utc,
    gross_credits, operator_share_bps, operator_credits, fault_flag, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, 0, 0, 'none', ?)`,
		requestCreditID,
		input.RequestID,
		input.AttemptN,
		input.ProviderID,
		ts.Format(time.RFC3339Nano),
		inflatedProviderCredits,
		ts.Format(time.RFC3339Nano),
	)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func markSPEC022ReceiptVerified(t *testing.T, db *sql.DB, input SettlementVerifyInput) {
	t.Helper()
	var routeDigest string
	if err := db.QueryRow(`
SELECT route_snapshot_digest
  FROM settlement_route_snapshots
 WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		input.AccountScope, input.RequestID, input.AttemptN, input.ProviderID,
	).Scan(&routeDigest); err != nil {
		t.Fatal(err)
	}
	usageDigest, _, err := input.ExpectedUsage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	deadline := input.TerminalStateTSUnixMS + input.RouteSnapshot.PendingDeadlineSeconds*1000
	_, err = db.Exec(`
INSERT INTO settlement_receipt_verdicts (
    account_scope_hash, request_id, attempt_n, provider_id,
    receipt_present, receipt_version, receipt_result, settlement_outcome,
    reason, idempotency_status, closed, terminal_state, terminal_state_ts_unix_ms,
    pending_deadline_unix_ms, received_at_unix_ms, route_snapshot_digest,
    route_snapshot_policy_version, route_snapshot_mode, paid_entrypoint,
    spec008_hash_status, provider_reported_model_hash, provider_receipt_key_fingerprint,
    catalog_id, catalog_body_digest, expected_catalog_model_hash, model_id, model_hash,
    receipt_profile, buyer_debit_outcome, provider_settlement_outcome,
    payout_exclusion_outcome, prompt_hash, output_hash, usage_digest,
    receipt_tuple_canonical_sha256, checks_json, verifier_diagnostics_json,
    facts_json, created_at_utc
) VALUES (?, ?, ?, ?, 1, 'spec015-v0.4', 'valid', 'verified',
          'verified_settlement', 'first_terminal', 1, ?, ?, ?, ?, ?, ?, ?, ?,
          ?, ?, ?, ?, ?, ?, ?, NULL, 'spec015-v0.4', 'no_money_movement_step5',
          'no_money_movement_step5', 'excluded_until_spec022_verified',
          ?, ?, ?, NULL, '{}', '{}', NULL, ?)`,
		SettlementAccountScopeHash(input.AccountScope),
		input.RequestID,
		input.AttemptN,
		input.ProviderID,
		input.TerminalState,
		input.TerminalStateTSUnixMS,
		deadline,
		input.ReceiptReceivedUnixMS,
		routeDigest,
		input.RouteSnapshot.RouteSnapshotPolicyVersion,
		input.RouteSnapshot.RouteSnapshotMode,
		input.RouteSnapshot.PaidEntrypoint,
		input.RouteSnapshot.Spec008HashStatus,
		input.RouteSnapshot.ProviderReportedModelHash,
		input.RouteSnapshot.ProviderReceiptKeyID,
		input.RouteSnapshot.CatalogID,
		input.RouteSnapshot.CatalogBodyDigest,
		input.RouteSnapshot.ExpectedCatalogModelHash,
		input.RouteSnapshot.ModelID,
		input.RouteSnapshot.PromptHash,
		input.OutputHash,
		usageDigest,
		time.UnixMilli(input.ReceiptReceivedUnixMS).UTC().Format(time.RFC3339Nano),
	)
	if err != nil {
		t.Fatal(err)
	}
}

func settlementHeaderWithCanonicalMutationAndTestSignature(t *testing.T, header string, mutate func(map[string]any)) string {
	t.Helper()
	parts := strings.Split(header, ".")
	if len(parts) != 2 {
		t.Fatalf("receipt envelope parts=%d, want 2", len(parts))
	}
	raw, err := base64.StdEncoding.DecodeString(parts[0])
	if err != nil {
		t.Fatalf("decode tuple: %v", err)
	}
	var tuple map[string]any
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	if err := dec.Decode(&tuple); err != nil {
		t.Fatalf("decode tuple JSON: %v", err)
	}
	mutate(tuple)
	canonical, err := CanonicalJSON(tuple)
	if err != nil {
		t.Fatalf("canonicalize mutated tuple: %v", err)
	}
	// Match phase7-verify/testdata/generator/v04's deterministic fixture key.
	priv := ed25519.NewKeyFromSeed(settlementFixtureTestSeed(32))
	sig := ed25519.Sign(priv, canonical)
	return base64.StdEncoding.EncodeToString(canonical) + "." + base64.StdEncoding.EncodeToString(sig)
}

func settlementFixtureTestSeed(n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = byte(i)
	}
	return out
}

func settlementIdentityFromInput(input SettlementVerifyInput) SettlementReceiptIdentity {
	return SettlementReceiptIdentity{
		AccountScope: input.AccountScope,
		RequestID:    input.RequestID,
		AttemptN:     input.AttemptN,
		ProviderID:   input.ProviderID,
	}
}

func settlementWindowForInput(input SettlementVerifyInput) (time.Time, time.Time) {
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	start := time.Date(ts.Year(), ts.Month(), ts.Day(), 0, 0, 0, 0, time.UTC)
	return start.AddDate(0, 0, -1), start.AddDate(0, 0, 8)
}
