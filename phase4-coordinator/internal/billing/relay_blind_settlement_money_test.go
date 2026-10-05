package billing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"strings"
	"testing"
)

type relayBlindMoneyFixture struct {
	store    *Store
	input    RelayBlindSettlementVerifyInput
	identity SettlementReceiptIdentity
	ledger   SettlementVerifyInput
}

// seedRelayBlindAttempt persists exactly what the coordinator persists for
// an R-13 attempt: the relay-blind route snapshot, the enforce ledger credit,
// and the attempt output carrying the response-body digest (no plaintext
// output hash). mutateSnapshot can make the snapshot plaintext.
func seedRelayBlindAttempt(t *testing.T, mutateSnapshot func(*RouteSnapshot)) relayBlindMoneyFixture {
	t.Helper()
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	input := relayBlindSignedInputWithSnapshot(t, mutateSnapshot, nil)
	if _, err := store.InsertRouteSnapshot(context.Background(), input.RouteSnapshot); err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256([]byte(relayBlindVectorNonStreamBody))
	bodyBytes := int64(len(relayBlindVectorNonStreamBody))
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), SettlementAttemptOutput{
		AccountScope: input.AccountScope, RequestID: input.RequestID, AttemptN: input.AttemptN, ProviderID: input.ProviderID,
		Output: SettlementOutput{Available: true, OutputPrefixEndByte: bodyBytes, TerminalState: TerminalStateNormalDone,
			TerminalStateTSUnixMS: input.TerminalStateTSUnixMS, RelayBlindResponseSHA256: hex.EncodeToString(sum[:])},
		OutputAvailable: true, UsageSource: UsageSourceCoordinatorObserved, TerminalStateTSUnixMS: input.TerminalStateTSUnixMS,
		Usage: SettlementUsage{BillableInputTokens: 37, BillableOutputTokens: 9, ObservedInputTokens: 37, ObservedOutputTokens: 9, DeliveredOutputBytes: bodyBytes},
	}); err != nil {
		t.Fatal(err)
	}
	ledger := SettlementVerifyInput{RequestID: input.RequestID, AttemptN: input.AttemptN, ProviderID: input.ProviderID, AccountScope: input.AccountScope,
		TerminalStateTSUnixMS: input.TerminalStateTSUnixMS, RouteSnapshot: input.RouteSnapshot,
		ExpectedUsage: SettlementUsage{BillableInputTokens: 37, BillableOutputTokens: 9}}
	insertSPEC022LedgerCredit(t, store.db, ledger, 600)
	// Rates high enough that the receipt-bound credit sync (which recomputes
	// the credit from the bound usage) yields a visible amount: 37 + 9 tokens
	// at 1e9 credits per Mtok is 46000.
	if _, err := store.db.Exec(`UPDATE ledger_request_credits SET prompt_rate_per_mtok = 1000000000, completion_rate_per_mtok = 1000000000`); err != nil {
		t.Fatal(err)
	}
	return relayBlindMoneyFixture{store: store, input: input, ledger: ledger, identity: SettlementReceiptIdentity{
		AccountScope: input.AccountScope, RequestID: input.RequestID, AttemptN: input.AttemptN, ProviderID: input.ProviderID}}
}

func (f relayBlindMoneyFixture) ingest(t *testing.T, envelope string) SettlementReceiptState {
	t.Helper()
	state, err := f.store.IngestRelayBlindSettlementReceipt(context.Background(), RelayBlindSettlementReceiptIngestionInput{
		SettlementReceiptIdentity: f.identity, Envelope: envelope, ProviderReceiptPubkey: f.input.ProviderReceiptPubkey, Dispatch: f.input.Dispatch,
	}.WithReceivedAt(f.input.ReceiptReceivedUnixMS))
	if err != nil {
		t.Fatal(err)
	}
	return state
}

func relayBlindVerifiedOnlyCount(t *testing.T, db *sql.DB) int64 {
	t.Helper()
	// The literal predicate every verified-work consumer uses (rewards
	// unlock, referral serving, provider receipt summaries).
	return scalar(t, db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE closed = 1 AND settlement_outcome = 'verified' AND receipt_result = 'valid'`)
}

// AC-022-67: a valid relay-blind receipt closes relay_blind_settled; the
// provider credit is payable through the view, the weekly sweep, and the
// recovery check; finality debits the same usage; verified counts, rewards,
// and referral predicates do not move.
func TestRelayBlindSettledIsPayableOnlyThroughTheBinding(t *testing.T) {
	f := seedRelayBlindAttempt(t, nil)
	ctx := context.Background()
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
		t.Fatalf("payable before receipt=%d", got)
	}
	state := f.ingest(t, f.input.Envelope)
	if state.SettlementOutcome != SettlementOutcomeRelayBlindSettled || !state.Closed || state.ReceiptProfile != RelayBlindSettlementReceiptVersion || state.ReceiptVersion != RelayBlindSettlementReceiptVersion {
		t.Fatalf("state=%+v", state)
	}
	if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 1 {
		t.Fatalf("payable after relay_blind_settled=%d want 1", got)
	}
	windowStart, windowEnd := settlementWindowForInput(f.ledger)
	if err := f.store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, f.store.db, `SELECT provider_credits FROM ledger_request_credits WHERE request_id = ?`, f.identity.RequestID); got != 46000 {
		t.Fatalf("receipt-bound credit sync provider credits=%d want 46000", got)
	}
	if got := scalar(t, f.store.db, `SELECT provider_credits FROM ledger_payout_ready WHERE provider_id = ?`, f.identity.ProviderID); got != 46000 {
		t.Fatalf("payout provider credits=%d want 46000", got)
	}
	finality, found, err := f.store.RequestSettlementFinality(ctx, f.identity.AccountScope, f.identity.RequestID, f.input.ReceiptReceivedUnixMS)
	if err != nil || !found || finality.Outcome != SettlementOutcomeRelayBlindSettled || !finality.Closed || finality.VerifiedAttempts != 0 ||
		finality.RelayBlindSettledAttempts != 1 || finality.PromptTokens != 37 || finality.CompletionTokens != 9 || finality.TotalTokens != 46 {
		t.Fatalf("finality=%+v found=%v err=%v", finality, found, err)
	}
	if got := relayBlindVerifiedOnlyCount(t, f.store.db); got != 0 {
		t.Fatalf("verified-only consumers saw %d rows", got)
	}
	counters, err := (&handler{store: f.store}).settlementVerdictCounters(ctx)
	if err != nil || len(counters) != 1 || counters[0].RelayBlindSettledCount != 1 || counters[0].VerifiedCount != 0 || counters[0].LegacyReceiptCount != 0 {
		t.Fatalf("counters=%+v err=%v", counters, err)
	}
	if string(mustScalarString(t, f.store.db, `SELECT output_hash FROM settlement_attempt_outputs`)) != f.input.ResponseBodySHA256 {
		t.Fatal("attempt output hash is not the response-body digest")
	}
}

func TestRelayBlindRecoveryAndUndeliveredGuardAdmitBoundSettlement(t *testing.T) {
	f := seedRelayBlindAttempt(t, nil)
	ctx := context.Background()
	f.ingest(t, f.input.Envelope)
	id := scalar(t, f.store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, f.identity.RequestID)
	tx, err := f.store.db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(37), int64(9)
	_, has, err := verifiedReceiptExpectedCreditTx(ctx, tx, id, HotPathInput{PromptTokens: &prompt, CompletionTokens: &completion}, sql.NullInt64{}, 1, 1, 1000000, 10000, FaultNone)
	_ = tx.Rollback()
	if err != nil || !has {
		t.Fatalf("recovery expected-credit check has=%v err=%v", has, err)
	}
	result, err := f.store.QuarantineUndeliveredSettlementCredit(ctx, f.identity.AccountScope, f.identity.RequestID, 0, f.identity.ProviderID, "settlement_record_failed_after_delivery")
	if err != nil || result != UndeliveredQuarantineRelayBlindSettled {
		t.Fatalf("undelivered guard result=%v err=%v", result, err)
	}
	if got := scalar(t, f.store.db, `SELECT quarantined FROM ledger_request_credits WHERE id = ?`, id); got != 0 {
		t.Fatal("bound relay_blind_settled credit was quarantined")
	}
}

// AC-022-69: a relay_blind_settled value without the entrypoint, basis, and
// profile binding is not payable anywhere, and finality refunds the buyer.
func TestRelayBlindSettledWithoutBindingIsNotPayable(t *testing.T) {
	for _, tc := range []struct {
		name      string
		plaintext bool
		unbind    string
	}{
		{name: "verdict profile", unbind: `UPDATE settlement_receipt_verdicts SET receipt_profile = 'spec015-v0.4'`},
		{name: "verdict receipt version", unbind: `UPDATE settlement_receipt_verdicts SET receipt_version = '4'`},
		{name: "verdict entrypoint", unbind: `UPDATE settlement_receipt_verdicts SET paid_entrypoint = 'coordinator_buyer_v1_chat_completions'`},
		// A plaintext snapshot cannot carry a relay-blind verdict through the
		// verifier (R-7.10), so this case forces the stored outcome.
		{name: "plaintext snapshot", plaintext: true, unbind: `UPDATE settlement_receipt_verdicts SET settlement_outcome = 'relay_blind_settled', receipt_result = 'valid', receipt_profile = 'relay-blind-settlement-v1', receipt_version = 'relay-blind-settlement-v1', paid_entrypoint = 'coordinator_buyer_v1_relay_blind_chat_completions', closed = 1`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var mutate func(*RouteSnapshot)
			if tc.plaintext {
				mutate = func(r *RouteSnapshot) {
					r.PaidEntrypoint, r.PromptHashBasis = PaidEntrypointCoordinatorBuyerChat, PromptHashBasisCoordinatorV1
				}
			}
			f := seedRelayBlindAttempt(t, mutate)
			ctx := context.Background()
			if state := f.ingest(t, f.input.Envelope); tc.plaintext && (state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != "relay_blind_receipt_on_plaintext_snapshot") {
				t.Fatalf("relay-blind receipt on plaintext snapshot: %+v", state)
			}
			if _, err := f.store.db.Exec(tc.unbind); err != nil {
				t.Fatal(err)
			}
			if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
				t.Fatalf("unbound relay_blind_settled payable=%d", got)
			}
			windowStart, windowEnd := settlementWindowForInput(f.ledger)
			if err := f.store.RunSettlement(ctx, SettlementConfig{CadenceDays: 7, MinPayoutCredits: 1}, windowStart, windowEnd); err != nil {
				t.Fatal(err)
			}
			if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM ledger_payout_ready`); got != 0 {
				t.Fatalf("unbound relay_blind_settled reached payout: %d", got)
			}
			finality, found, err := f.store.RequestSettlementFinality(ctx, f.identity.AccountScope, f.identity.RequestID, f.input.ReceiptReceivedUnixMS)
			if err != nil || !found || finality.Outcome == SettlementOutcomeRelayBlindSettled || finality.Outcome == SettlementOutcomeVerified {
				t.Fatalf("finality=%+v err=%v", finality, err)
			}
			result, err := f.store.QuarantineUndeliveredSettlementCredit(ctx, f.identity.AccountScope, f.identity.RequestID, 0, f.identity.ProviderID, "settlement_record_failed_after_delivery")
			if err != nil || result != UndeliveredQuarantineQuarantined {
				t.Fatalf("undelivered guard=%v err=%v", result, err)
			}
		})
	}
}

// AC-022-69: tampered or missing receipts quarantine (after the deadline for
// a missing one) and nothing is payable.
func TestRelayBlindTamperedOrMissingReceiptIsNotPayable(t *testing.T) {
	t.Run("tampered", func(t *testing.T) {
		f := seedRelayBlindAttempt(t, nil)
		tampered := relayBlindSignedInput(t, func(m map[string]any) { m["response_body_sha256"] = strings.Repeat("8", 64) })
		state := f.ingest(t, tampered.Envelope)
		if state.SettlementOutcome != SettlementOutcomeQuarantined || !state.Closed {
			t.Fatalf("state=%+v", state)
		}
		if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
			t.Fatalf("payable=%d", got)
		}
		again := f.ingest(t, f.input.Envelope)
		if again.SettlementOutcome != SettlementOutcomeQuarantined {
			t.Fatalf("a later valid receipt reopened a quarantined attempt: %+v", again)
		}
	})
	t.Run("missing", func(t *testing.T) {
		f := seedRelayBlindAttempt(t, nil)
		ctx := context.Background()
		state, err := f.store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{SettlementReceiptIdentity: f.identity, NowUnixMS: f.input.TerminalStateTSUnixMS + 1000})
		if err != nil || state.SettlementOutcome != SettlementOutcomePending || state.ReceiptProfile != RelayBlindSettlementReceiptVersion {
			t.Fatalf("state=%+v err=%v", state, err)
		}
		state, err = f.store.RecordMissingSettlementReceipt(ctx, SettlementReceiptMissingInput{SettlementReceiptIdentity: f.identity, NowUnixMS: f.input.TerminalStateTSUnixMS + 301000})
		if err != nil || state.SettlementOutcome != SettlementOutcomeQuarantined || !state.Closed {
			t.Fatalf("after deadline state=%+v err=%v", state, err)
		}
		if got := scalar(t, f.store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
			t.Fatalf("payable=%d", got)
		}
	})
	t.Run("v0.4 receipt on relay-blind attempt", func(t *testing.T) {
		f := seedRelayBlindAttempt(t, nil)
		state, err := f.store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
			SettlementReceiptIdentity: f.identity, Header: syntheticRelayBlindV04Header(), ProviderReceiptPubkey: f.input.ProviderReceiptPubkey,
		}.WithReceivedAt(f.input.ReceiptReceivedUnixMS))
		if err != nil || state.SettlementOutcome != SettlementOutcomeQuarantined || state.Reason != "v04_receipt_on_relay_blind_snapshot" {
			t.Fatalf("state=%+v err=%v", state, err)
		}
	})
}

func mustScalarString(t *testing.T, db *sql.DB, query string, args ...any) string {
	t.Helper()
	var out string
	if err := db.QueryRow(query, args...).Scan(&out); err != nil {
		t.Fatal(err)
	}
	return out
}

// SPEC-022 R-13.8 migration: a populated pre-v0.3.0 database is widened in
// place; existing verdicts are untouched, relay_blind_settled and the
// relay-blind profile become storable, and the compat floor moves to 3.
func TestRelayBlindSettlementOutcomeMigrationOnPopulatedDatabase(t *testing.T) {
	f := seedRelayBlindAttempt(t, nil)
	ctx := context.Background()
	f.ingest(t, f.input.Envelope)
	db := f.store.db
	if _, err := db.Exec(`UPDATE settlement_receipt_verdicts SET settlement_outcome = 'verified', receipt_profile = 'spec015-v0.4'`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE settlement_receipt_audit_outbox SET settlement_outcome = 'verified'`); err != nil {
		t.Fatal(err)
	}
	var reverse []schemaCheckWidening
	for _, w := range relayBlindSettlementOutcomeWidenings {
		reverse = append(reverse, schemaCheckWidening{table: w.table, from: w.to, to: w.from})
	}
	if err := f.store.widenSchemaChecks(ctx, reverse); err != nil {
		t.Fatalf("restore legacy schema: %v", err)
	}
	if _, err := db.Exec(`UPDATE billing_compat_floor SET contract = 2`); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`UPDATE settlement_receipt_verdicts SET settlement_outcome = 'relay_blind_settled'`); err == nil {
		t.Fatal("legacy CHECK accepted relay_blind_settled")
	}
	before := mustScalarString(t, db, `SELECT settlement_outcome || '|' || receipt_profile || '|' || created_at_utc || '|' || reason FROM settlement_receipt_verdicts`)
	if _, err := NewStore(db); err != nil {
		t.Fatalf("NewStore over populated legacy schema: %v", err)
	}
	if after := mustScalarString(t, db, `SELECT settlement_outcome || '|' || receipt_profile || '|' || created_at_utc || '|' || reason FROM settlement_receipt_verdicts`); after != before {
		t.Fatalf("existing verdict changed: %q -> %q", before, after)
	}
	for _, table := range []string{"settlement_receipt_verdicts", "settlement_receipt_audit_outbox"} {
		definition := mustScalarString(t, db, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?`, table)
		if !strings.Contains(definition, settlementOutcomeCheckV2) || strings.Contains(definition, settlementOutcomeCheckV1) {
			t.Fatalf("%s not widened: %s", table, definition)
		}
	}
	if _, err := db.Exec(`UPDATE settlement_receipt_verdicts SET settlement_outcome = 'relay_blind_settled', receipt_profile = 'relay-blind-settlement-v1'`); err != nil {
		t.Fatalf("widened CHECK rejected relay_blind_settled: %v", err)
	}
	if _, err := db.Exec(`UPDATE settlement_receipt_audit_outbox SET settlement_outcome = 'relay_blind_settled'`); err != nil {
		t.Fatalf("widened outbox CHECK rejected relay_blind_settled: %v", err)
	}
	if _, err := db.Exec(`UPDATE settlement_receipt_verdicts SET settlement_outcome = 'settled'`); err == nil {
		t.Fatal("widened CHECK accepted an outcome outside the vocabulary")
	}
	if _, err := db.Exec(`UPDATE settlement_receipt_verdicts SET receipt_profile = 'relay-blind-settlement-v2'`); err == nil {
		t.Fatal("widened CHECK accepted an unknown profile")
	}
	if got := scalar(t, db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != 3 {
		t.Fatalf("compat floor=%d want 3", got)
	}
	if got := scalar(t, db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 1 {
		t.Fatalf("payable after migration=%d want 1", got)
	}
	if _, err := NewStore(db); err != nil {
		t.Fatalf("second NewStore: %v", err)
	}
}
