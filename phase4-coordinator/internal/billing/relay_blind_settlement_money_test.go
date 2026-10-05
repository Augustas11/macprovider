package billing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

type relayBlindMoneyFixture struct {
	store    *Store
	input    RelayBlindSettlementVerifyInput
	identity SettlementReceiptIdentity
	ledger   SettlementVerifyInput
}

// seedRelayBlindAttempt persists exactly what the coordinator persists for
// an R-14 attempt: the relay-blind route snapshot, the enforce ledger credit,
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
					r.RelayBlindProviderBindingDigest = ""
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

// SPEC-022 R-14.8 migration: a populated pre-v0.3.0 database is widened in
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
	if err := f.store.widenSchemaChecks(ctx, reverse, 0); err != nil {
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

// SPEC-022 R-14.6 / R-14.10: an enforce relay-blind snapshot committed before
// dispatch is the coordinator's authority even when the coordinator never
// wrote the request log, credit, or attempt output. The bound lookup by
// internal id finds it: pending through the deadline measured from the latest
// terminal the dispatch timeout allows, then closed quarantined (refund) by
// the missing-receipt writer, never payable, and a late receipt cannot reopen
// it.
func TestRelayBlindSnapshotOnlyAttemptFinality(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetRelayBlindAttemptTimeout(15 * time.Minute)
	ctx := context.Background()
	accountID := "relay-blind-account"
	input := relayBlindSignedInputWithSnapshot(t, func(r *RouteSnapshot) { r.AccountScope = AccountScopeForSettlement(accountID) }, nil)
	if _, err := store.InsertRouteSnapshot(ctx, input.RouteSnapshot); err != nil {
		t.Fatal(err)
	}
	internalID := input.RouteSnapshot.RequestID
	deadline := input.RouteSnapshot.RouteDecisionTSUnixMS + (15 * time.Minute).Milliseconds() + input.RouteSnapshot.PendingDeadlineSeconds*1000

	for _, now := range []int64{deadline - 1, deadline} {
		finality, found, err := store.RequestSettlementFinalityForAccountBound(ctx, accountID, "gateway-request-id", internalID, now, input.RouteSnapshot.RequestStartTSUnixMS)
		if err != nil || !found || finality.Mode != RouteSnapshotModeEnforce || finality.Outcome != SettlementOutcomePending || finality.Closed ||
			finality.PendingDeadlineUnixMS != deadline || finality.RequestID != "gateway-request-id" || finality.RequiredInternalRequestID != internalID {
			t.Fatalf("now=deadline%+d finality=%+v found=%v err=%v", now-deadline, finality, found, err)
		}
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts`); got != 0 {
		t.Fatalf("verdicts before deadline=%d", got)
	}
	finality, found, err := store.RequestSettlementFinalityForAccountBound(ctx, accountID, "gateway-request-id", internalID, deadline+1, input.RouteSnapshot.RequestStartTSUnixMS)
	if err != nil || !found || finality.Outcome != SettlementOutcomeQuarantined || !finality.Closed || finality.Reason != RelayBlindAttemptUnrecordedReason {
		t.Fatalf("after deadline finality=%+v found=%v err=%v", finality, found, err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE closed = 1 AND settlement_outcome = 'quarantined' AND reason = ?`, RelayBlindAttemptUnrecordedReason); got != 1 {
		t.Fatalf("persisted closed verdicts=%d want 1", got)
	}
	// A plaintext request id without a request log stays not found.
	if _, found, err := store.RequestSettlementFinalityForAccountBound(ctx, accountID, "gateway-request-id", "other-internal-id", deadline+1, input.RouteSnapshot.RequestStartTSUnixMS); err != nil || found {
		t.Fatalf("unknown internal id found=%v err=%v", found, err)
	}
	// The closed verdict is terminal: a valid receipt arriving afterwards
	// does not make the attempt payable.
	late, err := store.IngestRelayBlindSettlementReceipt(ctx, RelayBlindSettlementReceiptIngestionInput{
		SettlementReceiptIdentity: SettlementReceiptIdentity{AccountScope: input.RouteSnapshot.AccountScope, RequestID: internalID, AttemptN: input.AttemptN, ProviderID: input.ProviderID},
		Envelope:                  input.Envelope, ProviderReceiptPubkey: input.ProviderReceiptPubkey, Dispatch: input.Dispatch,
	}.WithReceivedAt(deadline+2))
	if err != nil || late.SettlementOutcome != SettlementOutcomeQuarantined || !late.Closed || late.IdempotencyStatus != settlementReceiptIDTerminalNoop {
		t.Fatalf("late receipt state=%+v err=%v", late, err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE settlement_outcome = 'relay_blind_settled'`); got != 0 {
		t.Fatalf("relay_blind_settled after closure=%d", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
		t.Fatalf("payable=%d", got)
	}
}

// SPEC-022 R-8.3 / R-14.10: the bounded background sweep closes an enforce
// relay-blind attempt that has a snapshot and nothing else, with no finality
// read, through the missing-receipt writer, strictly after its deadline. It
// leaves alone an attempt with an attempt output, an observe or ordinary
// snapshot, and one still inside its deadline, and never closes twice.
func TestSweepClosesUnrecordedRelayBlindAttempts(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	store.SetRelayBlindAttemptTimeout(15 * time.Minute)
	ctx := context.Background()
	base := relayBlindSignedInputWithSnapshot(t, nil, nil)
	deadline := base.RouteSnapshot.RouteDecisionTSUnixMS + (15 * time.Minute).Milliseconds() + base.RouteSnapshot.PendingDeadlineSeconds*1000
	insert := func(requestID string, mutate func(*RouteSnapshot)) RouteSnapshot {
		snapshot := base.RouteSnapshot
		snapshot.RequestID = requestID
		if mutate != nil {
			mutate(&snapshot)
		}
		if _, err := store.InsertRouteSnapshot(ctx, snapshot); err != nil {
			t.Fatalf("insert %s: %v", requestID, err)
		}
		return snapshot
	}
	unrecorded := insert("unrecorded", nil)
	later := insert("later", func(r *RouteSnapshot) { r.RouteDecisionTSUnixMS += 60_000; r.RequestStartTSUnixMS += 60_000 })
	observe := insert("observe", func(r *RouteSnapshot) { r.RouteSnapshotMode = RouteSnapshotModeObserve })
	withOutput := insert("with-output", nil)
	sum := sha256.Sum256([]byte(relayBlindVectorNonStreamBody))
	if _, err := store.InsertSettlementAttemptOutput(ctx, SettlementAttemptOutput{
		AccountScope: withOutput.AccountScope, RequestID: withOutput.RequestID, AttemptN: withOutput.AttemptN, ProviderID: withOutput.ProviderID,
		Output: SettlementOutput{Available: true, OutputPrefixEndByte: int64(len(relayBlindVectorNonStreamBody)), TerminalState: TerminalStateNormalDone,
			TerminalStateTSUnixMS: base.TerminalStateTSUnixMS, RelayBlindResponseSHA256: hex.EncodeToString(sum[:])},
		OutputAvailable: true, UsageSource: UsageSourceCoordinatorObserved, TerminalStateTSUnixMS: base.TerminalStateTSUnixMS,
		Usage: SettlementUsage{BillableInputTokens: 37, BillableOutputTokens: 9, ObservedInputTokens: 37, ObservedOutputTokens: 9,
			DeliveredOutputBytes: int64(len(relayBlindVectorNonStreamBody))},
	}); err != nil {
		t.Fatal(err)
	}
	verdicts := func(requestID string) int64 {
		return scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE request_id = ?`, requestID)
	}

	// At the exact deadline nothing closes.
	if closed, err := store.SweepExpiredSettlementVerdicts(ctx, deadline, 0); err != nil || closed != 0 {
		t.Fatalf("at deadline closed=%d err=%v", closed, err)
	}
	if closed, err := store.SweepExpiredSettlementVerdicts(ctx, deadline+1, 0); err != nil || closed != 1 {
		t.Fatalf("after deadline closed=%d err=%v", closed, err)
	}
	var closedFlag, pendingDeadline int64
	var outcome, reason, terminal string
	if err := store.db.QueryRow(`SELECT closed, settlement_outcome, reason, terminal_state, pending_deadline_unix_ms
  FROM settlement_receipt_verdicts WHERE request_id = ?`, unrecorded.RequestID).Scan(&closedFlag, &outcome, &reason, &terminal, &pendingDeadline); err != nil ||
		closedFlag != 1 || outcome != SettlementOutcomeQuarantined || reason != RelayBlindAttemptUnrecordedReason ||
		terminal != TerminalStateUpstreamTransportDisconnect || pendingDeadline != deadline {
		t.Fatalf("unrecorded verdict closed=%d outcome=%s reason=%s terminal=%s deadline=%d err=%v", closedFlag, outcome, reason, terminal, pendingDeadline, err)
	}
	for _, id := range []string{later.RequestID, observe.RequestID, withOutput.RequestID} {
		if got := verdicts(id); got != 0 {
			t.Fatalf("%s verdicts=%d want 0", id, got)
		}
	}
	// Repeated passes neither close it again nor write audit rows for it.
	audits := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log`)
	if closed, err := store.SweepExpiredSettlementVerdicts(ctx, deadline+2, 0); err != nil || closed != 0 {
		t.Fatalf("repeat closed=%d err=%v", closed, err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM audit_log`); got != audits {
		t.Fatalf("repeat pass wrote audit rows: %d -> %d", audits, got)
	}
	// The later attempt closes once its own deadline passes.
	if closed, err := store.SweepExpiredSettlementVerdicts(ctx, deadline+60_001, 0); err != nil || closed != 1 {
		t.Fatalf("later closed=%d err=%v", closed, err)
	}
	if got := verdicts(unrecorded.RequestID) + verdicts(later.RequestID); got != 2 {
		t.Fatalf("closed verdicts=%d want 2", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM spec022_payable_request_credits`); got != 0 {
		t.Fatalf("payable=%d", got)
	}
}

// The unrecorded pass reads settlement_route_snapshots only through its
// INTEGER PRIMARY KEY (no index is built for it), and one pass examines at
// most one primary-key window, so it stays cheap on a large money database.
func TestUnrecordedRelayBlindSweepUsesPrimaryKeyWindow(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	plan := func(query string, args ...any) string {
		t.Helper()
		rows, err := store.db.Query(`EXPLAIN QUERY PLAN `+query, args...)
		if err != nil {
			t.Fatal(err)
		}
		defer rows.Close()
		var details []string
		for rows.Next() {
			var id, parent, notused int
			var detail string
			if err := rows.Scan(&id, &parent, &notused, &detail); err != nil {
				t.Fatal(err)
			}
			details = append(details, detail)
		}
		return strings.Join(details, "; ")
	}
	if got := plan(unrecordedRelayBlindSweepSQL, 1, 1, 0, 10); !strings.Contains(got, "SEARCH rs USING INTEGER PRIMARY KEY (rowid>? AND rowid<?)") || strings.Contains(got, "SCAN ") {
		t.Fatalf("window plan=%s", got)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_srs_relay_blind_enforce_decision'`); got != 0 {
		t.Fatalf("startup built the relay-blind sweep index")
	}

	// 3 windows of ordinary snapshots with expired, unrecorded enforce
	// relay-blind snapshots spread through them.
	const limit = 2
	window := int64(limit * unrecordedRelayBlindSweepScanFactor)
	store.SetRelayBlindAttemptTimeout(time.Minute)
	ctx := context.Background()
	base := relayBlindSignedInputWithSnapshot(t, nil, nil)
	var relayBlindIDs []string
	for i := int64(1); i <= 3*window; i++ {
		snapshot := base.RouteSnapshot
		snapshot.RequestID = fmt.Sprintf("snapshot-%03d", i)
		if i%7 == 0 {
			relayBlindIDs = append(relayBlindIDs, snapshot.RequestID)
		} else {
			snapshot.PaidEntrypoint, snapshot.PromptHashBasis, snapshot.RelayBlindProviderBindingDigest = PaidEntrypointCoordinatorBuyerChat, PromptHashBasisCoordinatorV1, ""
		}
		if _, err := store.InsertRouteSnapshot(ctx, snapshot); err != nil {
			t.Fatal(err)
		}
	}
	now := base.RouteSnapshot.RouteDecisionTSUnixMS + time.Minute.Milliseconds() + base.RouteSnapshot.PendingDeadlineSeconds*1000 + 1
	closedVerdicts := func() int64 {
		return scalar(t, store.db, `SELECT COUNT(*) FROM settlement_receipt_verdicts WHERE reason = ?`, RelayBlindAttemptUnrecordedReason)
	}
	// One pass examines one window: it closes the relay-blind attempts
	// inside it (at most limit) and leaves the rest for later passes.
	if _, err := store.SweepExpiredSettlementVerdicts(ctx, now, limit); err != nil {
		t.Fatal(err)
	}
	if got := closedVerdicts(); got != limit {
		t.Fatalf("first pass closed=%d want %d", got, limit)
	}
	if store.poolSweep.unrecordedCursor > window {
		t.Fatalf("first pass cursor=%d beyond window %d", store.poolSweep.unrecordedCursor, window)
	}
	for pass := 0; pass < 10; pass++ {
		if _, err := store.SweepExpiredSettlementVerdicts(ctx, now, limit); err != nil {
			t.Fatal(err)
		}
	}
	if got := closedVerdicts(); got != int64(len(relayBlindIDs)) {
		t.Fatalf("closed=%d want %d", got, len(relayBlindIDs))
	}
	if store.poolSweep.unrecordedCursor != 3*window {
		t.Fatalf("cursor=%d want tail %d", store.poolSweep.unrecordedCursor, 3*window)
	}
}

// A new process starts its unrecorded walk after the last snapshot older
// than the lookback, found by primary-key probes, never by a scan.
func TestUnrecordedRelayBlindSweepPositionsByPrimaryKey(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	if got, err := store.positionUnrecordedRelayBlindSweep(ctx, 0, 1); err != nil || got != 0 {
		t.Fatalf("empty table position=%d err=%v", got, err)
	}
	base := relayBlindSignedInputWithSnapshot(t, nil, nil).RouteSnapshot
	const rows = 37
	for i := int64(1); i <= rows; i++ {
		snapshot := base
		snapshot.RequestID = fmt.Sprintf("snapshot-%03d", i)
		snapshot.RouteDecisionTSUnixMS = base.RouteDecisionTSUnixMS + i*1000
		snapshot.RequestStartTSUnixMS = snapshot.RouteDecisionTSUnixMS
		if _, err := store.InsertRouteSnapshot(ctx, snapshot); err != nil {
			t.Fatal(err)
		}
	}
	for floor := int64(0); floor <= rows+1; floor++ {
		got, err := store.positionUnrecordedRelayBlindSweep(ctx, rows, base.RouteDecisionTSUnixMS+floor*1000)
		want := max(min(floor-1, rows), 0)
		if err != nil || got != want {
			t.Fatalf("floor=%d position=%d want %d err=%v", floor, got, want, err)
		}
	}
	if got := strings.Join(func() []string {
		r, err := store.db.Query(`EXPLAIN QUERY PLAN SELECT id, route_decision_ts_unix_ms FROM settlement_route_snapshots WHERE id >= ? ORDER BY id ASC LIMIT 1`, 1)
		if err != nil {
			t.Fatal(err)
		}
		defer r.Close()
		var out []string
		for r.Next() {
			var id, parent, notused int
			var detail string
			if err := r.Scan(&id, &parent, &notused, &detail); err != nil {
				t.Fatal(err)
			}
			out = append(out, detail)
		}
		return out
	}(), "; "); !strings.Contains(got, "USING INTEGER PRIMARY KEY") || strings.Contains(got, "SCAN ") {
		t.Fatalf("probe plan=%s", got)
	}
}

// SPEC-022 R-14.8: contract 3 is recorded only with the relay-blind outcome
// widening. A relay-blind migration that fails leaves the floor at 2, so a
// contract-2 coordinator is still a valid rollback target; a later
// successful migration records 3.
func TestBillingCompatFloorStaysAtTwoWhenRelayBlindMigrationFails(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	ctx := context.Background()
	db := store.db
	if got := scalar(t, db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != 3 {
		t.Fatalf("fresh floor=%d want 3", got)
	}
	var reverse []schemaCheckWidening
	for _, w := range relayBlindSettlementOutcomeWidenings {
		reverse = append(reverse, schemaCheckWidening{table: w.table, from: w.to, to: w.from})
	}
	if err := store.widenSchemaChecks(ctx, reverse, 0); err != nil {
		t.Fatalf("restore contract-2 schema: %v", err)
	}
	if _, err := db.Exec(`UPDATE billing_compat_floor SET contract = 2`); err != nil {
		t.Fatal(err)
	}
	// An outbox CHECK the widening does not recognize makes the relay-blind
	// migration fail.
	unexpected := "CHECK(settlement_outcome IN ('pending','verified','quarantined','zero_settled','unexpected'))"
	if err := store.widenSchemaChecks(ctx, []schemaCheckWidening{{table: "settlement_receipt_audit_outbox", from: settlementOutcomeCheckV1, to: unexpected}}, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(db); err == nil {
		t.Fatal("NewStore succeeded over an unrecognized outbox CHECK")
	}
	if got := scalar(t, db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != 2 {
		t.Fatalf("floor after failed relay-blind migration=%d want 2", got)
	}
	if definition := mustScalarString(t, db, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'settlement_receipt_verdicts'`); strings.Contains(definition, settlementOutcomeCheckV2) {
		t.Fatal("failed migration widened settlement_receipt_verdicts")
	}
	if err := store.widenSchemaChecks(ctx, []schemaCheckWidening{{table: "settlement_receipt_audit_outbox", from: unexpected, to: settlementOutcomeCheckV1}}, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(db); err != nil {
		t.Fatalf("NewStore after repair: %v", err)
	}
	if got := scalar(t, db, `SELECT contract FROM billing_compat_floor WHERE id = 1`); got != 3 {
		t.Fatalf("floor after relay-blind migration=%d want 3", got)
	}
}

// SPEC-022 R-14.8: contract 3 is recorded only together with a revalidated
// relay-blind widening. A database already widened but still at floor 2 is
// repaired inside a BEGIN IMMEDIATE transaction that rereads every target
// definition on its own connection; a partially widened database whose
// remaining CHECK is unrecognized advances nothing.
func TestBillingCompatFloorRepairRevalidatesWideningInTransaction(t *testing.T) {
	ctx := context.Background()
	open := func(t *testing.T) (string, *Store) {
		t.Helper()
		path := filepath.Join(t.TempDir(), "coordinator.db")
		reqStore, err := requestlog.OpenStore(path)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = reqStore.Close() })
		store, err := NewStore(reqStore.DB())
		if err != nil {
			t.Fatal(err)
		}
		return path, store
	}
	floor := func(t *testing.T, db *sql.DB) int64 {
		t.Helper()
		return scalar(t, db, `SELECT contract FROM billing_compat_floor WHERE id = 1`)
	}
	unexpected := "CHECK(settlement_outcome IN ('pending','verified','quarantined','zero_settled','unexpected'))"

	t.Run("already widened at floor 2 records 3", func(t *testing.T) {
		_, store := open(t)
		if _, err := store.db.Exec(`UPDATE billing_compat_floor SET contract = 2`); err != nil {
			t.Fatal(err)
		}
		if err := store.ensureRelayBlindSettlementOutcomeVocabulary(ctx); err != nil {
			t.Fatal(err)
		}
		if got := floor(t, store.db); got != 3 {
			t.Fatalf("floor=%d want 3", got)
		}
	})

	t.Run("partially widened with an unrecognized CHECK stays at 2", func(t *testing.T) {
		_, store := open(t)
		if err := store.widenSchemaChecks(ctx, []schemaCheckWidening{{table: "settlement_receipt_audit_outbox", from: settlementOutcomeCheckV2, to: unexpected}}, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := store.db.Exec(`UPDATE billing_compat_floor SET contract = 2`); err != nil {
			t.Fatal(err)
		}
		if err := store.ensureRelayBlindSettlementOutcomeVocabulary(ctx); err == nil {
			t.Fatal("repair succeeded over an unrecognized outbox CHECK")
		}
		if got := floor(t, store.db); got != 2 {
			t.Fatalf("floor=%d want 2", got)
		}
		if definition := mustScalarString(t, store.db, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'settlement_receipt_audit_outbox'`); !strings.Contains(definition, unexpected) {
			t.Fatalf("outbox definition changed: %s", definition)
		}
	})

	t.Run("partially widened with the legacy CHECK widens and records 3 together", func(t *testing.T) {
		_, store := open(t)
		if err := store.widenSchemaChecks(ctx, []schemaCheckWidening{{table: "settlement_receipt_audit_outbox", from: settlementOutcomeCheckV2, to: settlementOutcomeCheckV1}}, 0); err != nil {
			t.Fatal(err)
		}
		if _, err := store.db.Exec(`UPDATE billing_compat_floor SET contract = 2`); err != nil {
			t.Fatal(err)
		}
		if err := store.ensureRelayBlindSettlementOutcomeVocabulary(ctx); err != nil {
			t.Fatal(err)
		}
		if got := floor(t, store.db); got != 3 {
			t.Fatalf("floor=%d want 3", got)
		}
		if definition := mustScalarString(t, store.db, `SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'settlement_receipt_audit_outbox'`); !strings.Contains(definition, settlementOutcomeCheckV2) {
			t.Fatalf("outbox not widened: %s", definition)
		}
	})

	// The definitions are read inside the repair's own write transaction: a
	// writer that narrows a CHECK while the repair waits for the lock makes
	// the repair fail instead of recording 3 over a schema it never checked.
	t.Run("a concurrent narrowing is seen by the repair", func(t *testing.T) {
		path, store := open(t)
		if _, err := store.db.Exec(`UPDATE billing_compat_floor SET contract = 2`); err != nil {
			t.Fatal(err)
		}
		other, err := sql.Open("sqlite", sqliteutil.WithPragmas(path))
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = other.Close() })
		conn, err := other.Conn(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer conn.Close()
		var schemaVersion int64
		for _, stmt := range []string{`BEGIN IMMEDIATE`, `PRAGMA writable_schema = ON`} {
			if _, err := conn.ExecContext(ctx, stmt); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := conn.ExecContext(ctx, `UPDATE sqlite_master SET sql = replace(sql, ?, ?) WHERE type = 'table' AND name = 'settlement_receipt_audit_outbox'`, settlementOutcomeCheckV2, unexpected); err != nil {
			t.Fatal(err)
		}
		if err := conn.QueryRowContext(ctx, `PRAGMA schema_version`).Scan(&schemaVersion); err != nil {
			t.Fatal(err)
		}
		for _, stmt := range []string{fmt.Sprintf(`PRAGMA schema_version = %d`, schemaVersion+1), `PRAGMA writable_schema = OFF`} {
			if _, err := conn.ExecContext(ctx, stmt); err != nil {
				t.Fatal(err)
			}
		}
		done := make(chan error, 1)
		go func() { done <- store.ensureRelayBlindSettlementOutcomeVocabulary(ctx) }()
		time.Sleep(200 * time.Millisecond)
		if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
			t.Fatal(err)
		}
		if err := <-done; err == nil {
			t.Fatal("repair recorded contract 3 over a narrowed CHECK")
		}
		if got := floor(t, store.db); got != 2 {
			t.Fatalf("floor=%d want 2", got)
		}
	})
}
