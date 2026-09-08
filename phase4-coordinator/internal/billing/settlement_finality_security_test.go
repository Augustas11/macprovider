package billing

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

func TestRequestSettlementFinalityMissingCurrentVerdictInvalidatesEveryPriorOutcome(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	for _, mode := range []string{RouteSnapshotModeObserve, RouteSnapshotModeEnforce} {
		for _, outcome := range []string{SettlementOutcomeVerified, SettlementOutcomeQuarantined, SettlementOutcomeZeroSettled, SettlementOutcomePending} {
			t.Run(mode+"/"+outcome, func(t *testing.T) {
				input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
				accountID := "acct_finality_scope"
				externalID := "external-finality-scope"
				input.AccountScope = AccountScopeForSettlement(accountID)
				input.RouteSnapshot.AccountScope = input.AccountScope
				input.RouteSnapshot.RouteSnapshotMode = mode
				reqStore, store := newRequestAndBillingStores(t)
				seedFinalitySecurityVerdict(t, store, input, outcome)
				now := input.TerminalStateTSUnixMS + 1

				direct, found, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, now)
				if err != nil || !found || !direct.ModeScopeComplete || direct.Mode != mode || direct.Outcome != outcome {
					t.Fatalf("direct finality=%+v found=%v err=%v", direct, found, err)
				}
				assertFinalityModeScopeJSON(t, direct, true)
				insertExternalFinalityRequestLog(t, reqStore, input, accountID, externalID, input.RequestID, now)
				complete, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, externalID, now, now)
				if err != nil || !found || !complete.ModeScopeComplete || complete.Outcome != outcome {
					t.Fatalf("complete external finality=%+v found=%v err=%v", complete, found, err)
				}

				// A later request log entry is known, but its verdict has not been
				// persisted. Earlier observe authority must not cover this gap.
				insertExternalFinalityRequestLog(t, reqStore, input, accountID, externalID, input.RequestID+"-later", now+1)
				ledgerRows := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`)
				finality, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, externalID, now+2, now)
				if err != nil || !found {
					t.Fatalf("missing-current lookup found=%v err=%v", found, err)
				}
				if finality.ModeScopeComplete || finality.Closed || finality.Mode != mode ||
					finality.Outcome != SettlementOutcomePending ||
					finality.ReceiptResult != SettlementReceiptResultInconclusive ||
					finality.Reason != "missing_current_settlement_finality" ||
					finality.PendingAttempts != complete.PendingAttempts+1 {
					t.Fatalf("missing current verdict retained earlier authority: %+v", finality)
				}
				if finality.TokenSource != "" || finality.PromptTokens != 0 || finality.CompletionTokens != 0 || finality.TotalTokens != 0 {
					t.Fatalf("incomplete finality retained billable usage: %+v", finality)
				}
				assertFinalityModeScopeJSON(t, finality, false)
				if got := scalar(t, store.db, `SELECT COUNT(*) FROM ledger_request_credits`); got != ledgerRows {
					t.Fatalf("finality lookup changed ledger rows: got %d want %d", got, ledgerRows)
				}
			})
		}
	}
}

func TestRequestSettlementFinalityMixedModeScopeIsIncomplete(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	for _, lookup := range []string{"direct", "external"} {
		t.Run(lookup, func(t *testing.T) {
			input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
			accountID := "acct_mixed_finality_scope"
			externalID := "external-mixed-finality-scope"
			input.AccountScope = AccountScopeForSettlement(accountID)
			input.RouteSnapshot.AccountScope = input.AccountScope
			input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeObserve
			reqStore, store := newRequestAndBillingStores(t)
			seedFinalitySecurityVerdict(t, store, input, SettlementOutcomeQuarantined)
			now := input.TerminalStateTSUnixMS + 1
			insertExternalFinalityRequestLog(t, reqStore, input, accountID, externalID, input.RequestID, now)
			second := input
			second.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
			if lookup == "direct" {
				second.AttemptN++
				second.RouteSnapshot.AttemptN = second.AttemptN
			} else {
				second.RequestID += "-later"
				second.RouteSnapshot.RequestID = second.RequestID
				insertExternalFinalityRequestLog(t, reqStore, second, accountID, externalID, second.RequestID, now+1)
			}
			seedFinalitySecurityVerdict(t, store, second, SettlementOutcomeZeroSettled)
			requestID := input.RequestID
			if lookup == "external" {
				requestID = externalID
			}
			finality, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, requestID, now+2, now)
			if err != nil || !found {
				t.Fatalf("mixed scope lookup found=%v err=%v", found, err)
			}
			if finality.ModeScopeComplete || finality.Closed || finality.Outcome != SettlementOutcomePending || finality.Reason != "mixed_settlement_policy_snapshot" {
				t.Fatalf("mixed modes retained complete authority: %+v", finality)
			}
			assertFinalityModeScopeJSON(t, finality, false)
		})
	}
}

func TestRequestSettlementFinalitySnapshotWithoutVerdictIsIncomplete(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	for _, outcome := range []string{SettlementOutcomeVerified, SettlementOutcomeQuarantined, SettlementOutcomeZeroSettled, SettlementOutcomePending} {
		for _, scope := range []string{"same_scope", "mixed_mode", "mixed_policy"} {
			t.Run(outcome+"/"+scope, func(t *testing.T) {
				input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
				accountID := "acct_snapshot_finality_scope"
				input.AccountScope = AccountScopeForSettlement(accountID)
				input.RouteSnapshot.AccountScope = input.AccountScope
				input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeObserve
				_, store := newRequestAndBillingStores(t)
				seedFinalitySecurityVerdict(t, store, input, outcome)
				later := input
				later.AttemptN++
				later.RouteSnapshot.AttemptN = later.AttemptN
				wantReason := "missing_current_settlement_finality"
				if scope == "mixed_mode" {
					later.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeEnforce
					wantReason = "mixed_settlement_policy_snapshot"
				} else if scope == "mixed_policy" {
					later.RouteSnapshot.RouteSnapshotPolicyVersion = "spec022-prereq-v0"
					wantReason = "mixed_settlement_policy_snapshot"
				}
				if _, err := store.InsertRouteSnapshot(context.Background(), later.RouteSnapshot); err != nil {
					t.Fatal(err)
				}
				now := input.TerminalStateTSUnixMS + 1
				finality, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, input.RequestID, now)
				if err != nil || !found {
					t.Fatalf("snapshot gap found=%v err=%v", found, err)
				}
				if finality.ModeScopeComplete || finality.Closed || finality.Outcome != SettlementOutcomePending ||
					finality.ReceiptResult != SettlementReceiptResultInconclusive || finality.Reason != wantReason ||
					finality.PromptTokens != 0 || finality.CompletionTokens != 0 || finality.TotalTokens != 0 || finality.TokenSource != "" {
					t.Fatalf("snapshot without verdict retained finality authority: %+v", finality)
				}
				assertFinalityModeScopeJSON(t, finality, false)
				if scope == "same_scope" {
					insertFinalitySecurityVerdict(t, store, later, SettlementOutcomeZeroSettled)
					complete, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, input.RequestID, now)
					if err != nil || !found || !complete.ModeScopeComplete {
						t.Fatalf("all snapshot verdicts did not restore known scope: finality=%+v found=%v err=%v", complete, found, err)
					}
				}
			})
		}
	}
}

func TestAggregateExternalRequestFinalityScopeRequiresEveryChild(t *testing.T) {
	first := RequestSettlementFinality{
		PolicyVersion: RouteSnapshotPolicyVersion, Mode: RouteSnapshotModeObserve,
		ModeScopeComplete: true, Outcome: SettlementOutcomePending, PendingAttempts: 1,
	}
	for _, change := range []string{"incomplete_child", "different_policy"} {
		t.Run(change, func(t *testing.T) {
			second := first
			if change == "incomplete_child" {
				second.ModeScopeComplete = false
			} else {
				second.PolicyVersion = "spec022-prereq-v0"
			}
			finality := aggregateExternalRequestFinality("external", []RequestSettlementFinality{first, second})
			if finality.ModeScopeComplete || finality.Closed || finality.Outcome != SettlementOutcomePending {
				t.Fatalf("incomplete child scope retained authority: %+v", finality)
			}
		})
	}
}

func TestRequestSettlementFinalityBoundRequiresCurrentLoggedRequest(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	for _, mode := range []string{RouteSnapshotModeObserve, RouteSnapshotModeEnforce} {
		t.Run(mode, func(t *testing.T) {
			input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
			accountID, externalID := "acct_bound_finality", "external-bound-finality"
			input.AccountScope = AccountScopeForSettlement(accountID)
			input.RouteSnapshot.AccountScope = input.AccountScope
			input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeObserve
			reqStore, store := newRequestAndBillingStores(t)
			seedFinalitySecurityVerdict(t, store, input, SettlementOutcomeQuarantined)
			now := input.TerminalStateTSUnixMS + 1
			insertExternalFinalityRequestLog(t, reqStore, input, accountID, externalID, input.RequestID, now)
			current := input
			current.RequestID += "-current"
			current.RouteSnapshot.RequestID = current.RequestID
			current.RouteSnapshot.RouteSnapshotMode = mode
			if _, err := store.InsertRouteSnapshot(context.Background(), current.RouteSnapshot); err != nil {
				t.Fatal(err)
			}
			// Streaming writes this mapping after the terminal body. An earlier
			// retry alone cannot prove the policy of the in-flight current request.
			unbound, found, err := store.RequestSettlementFinalityForAccount(context.Background(), accountID, externalID, now, now)
			if err != nil || !found || !unbound.ModeScopeComplete {
				t.Fatalf("prior-only scope setup: finality=%+v found=%v err=%v", unbound, found, err)
			}
			bound, found, err := store.RequestSettlementFinalityForAccountBound(context.Background(), accountID, externalID, current.RequestID, now, now)
			if err != nil || found || bound.ModeScopeComplete || bound.RequiredInternalRequestID != "" {
				t.Fatalf("unlogged current request authorized prior scope: finality=%+v found=%v err=%v", bound, found, err)
			}
			insertExternalFinalityRequestLog(t, reqStore, current, accountID, externalID, current.RequestID, now+1)
			bound, found, err = store.RequestSettlementFinalityForAccountBound(context.Background(), accountID, externalID, current.RequestID, now+2, now)
			if err != nil || !found || bound.ModeScopeComplete || bound.RequiredInternalRequestID != current.RequestID || bound.Outcome != SettlementOutcomePending {
				t.Fatalf("mapped current request without verdict authorized prior scope: finality=%+v found=%v err=%v", bound, found, err)
			}
			insertFinalitySecurityVerdict(t, store, current, SettlementOutcomeZeroSettled)
			bound, found, err = store.RequestSettlementFinalityForAccountBound(context.Background(), accountID, externalID, current.RequestID, now+2, now)
			if err != nil || !found || bound.RequiredInternalRequestID != current.RequestID || bound.RequestID != externalID {
				t.Fatalf("bound lookup lost identity: finality=%+v found=%v err=%v", bound, found, err)
			}
			if bound.ModeScopeComplete != (mode == RouteSnapshotModeObserve) {
				t.Fatalf("bound lookup failed to aggregate prior and current mode: %+v", bound)
			}
			if mode == RouteSnapshotModeEnforce && bound.Reason != "mixed_settlement_policy_snapshot" {
				t.Fatalf("mixed retry policies were not preserved: %+v", bound)
			}
		})
	}
}

func TestRequestSettlementFinalityBoundDoesNotBypassExternalIdentityFence(t *testing.T) {
	fixtures := loadSettlementVerifierFixtures(t)
	pubkey := decodeSettlementVerifierPubkey(t, fixtures.ProviderReceiptPubkeyB64)
	tuple := firstSettlementTupleWithTerminal(t, fixtures, "normal_done")
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pubkey)
	accountID, externalID := "acct_identity_finality", "external-identity-finality"
	input.AccountScope = AccountScopeForSettlement(accountID)
	input.RouteSnapshot.AccountScope = input.AccountScope
	input.RouteSnapshot.RouteSnapshotMode = RouteSnapshotModeObserve
	reqStore, store := newRequestAndBillingStores(t)
	seedFinalitySecurityVerdict(t, store, input, SettlementOutcomePending)
	now := input.TerminalStateTSUnixMS + 1
	insertExternalFinalityRequestLog(t, reqStore, input, accountID, externalID, input.RequestID, now)
	for _, tc := range []struct {
		name, accountID, externalID, requiredID string
		start                                   int64
	}{
		{"other_account", "acct_other", externalID, input.RequestID, now},
		{"other_external", accountID, "external-other", input.RequestID, now},
		{"direct_id_collision", accountID, input.RequestID, input.RequestID, now},
		{"other_internal", accountID, externalID, input.RequestID + "-other", now},
		{"old_generation", accountID, externalID, input.RequestID, now + int64((6*time.Minute)/time.Millisecond)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			finality, found, err := store.RequestSettlementFinalityForAccountBound(context.Background(), tc.accountID, tc.externalID, tc.requiredID, now, tc.start)
			if err != nil || found || finality.ModeScopeComplete || finality.RequiredInternalRequestID != "" {
				t.Fatalf("identity fence bypassed: finality=%+v found=%v err=%v", finality, found, err)
			}
		})
	}
	finality, found, err := store.RequestSettlementFinalityForAccountBound(context.Background(), accountID, externalID, input.RequestID, now, now)
	if err != nil || !found || !finality.ModeScopeComplete || finality.RequiredInternalRequestID != input.RequestID || finality.Outcome != SettlementOutcomePending {
		t.Fatalf("complete observe pending scope should bind without receipt verification: finality=%+v found=%v err=%v", finality, found, err)
	}
	for _, tc := range []struct {
		requiredID string
		start      int64
	}{{"", now}, {input.RequestID, 0}} {
		if _, found, err := store.RequestSettlementFinalityForAccountBound(context.Background(), accountID, externalID, tc.requiredID, now, tc.start); err == nil || found {
			t.Fatalf("missing binding input accepted: found=%v err=%v", found, err)
		}
	}
}

func seedFinalitySecurityVerdict(t *testing.T, store *Store, input SettlementVerifyInput, outcome string) {
	t.Helper()
	seedSettlementReceiptEvidence(t, store, input)
	insertFinalitySecurityVerdict(t, store, input, outcome)
}

func insertFinalitySecurityVerdict(t *testing.T, store *Store, input SettlementVerifyInput, outcome string) {
	t.Helper()
	markSPEC022ReceiptVerified(t, store.db, input)
	if outcome == SettlementOutcomeVerified {
		insertSPEC022LedgerCreditWithMode(t, store.db, input, 700, input.RouteSnapshot.RouteSnapshotMode, "")
		return
	}
	result, closed := SettlementReceiptResultValid, 1
	if outcome == SettlementOutcomeQuarantined {
		result = SettlementReceiptResultInvalid
	} else if outcome == SettlementOutcomePending {
		result, closed = SettlementReceiptResultInconclusive, 0
	}
	if _, err := store.db.Exec(`UPDATE settlement_receipt_verdicts
SET settlement_outcome = ?, receipt_result = ?, closed = ?, reason = 'scope_fixture'
WHERE account_scope_hash = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		outcome, result, closed, SettlementAccountScopeHash(input.AccountScope), input.RequestID, input.AttemptN, input.ProviderID); err != nil {
		t.Fatal(err)
	}
}

func insertExternalFinalityRequestLog(t *testing.T, store *requestlog.Store, input SettlementVerifyInput, accountID, externalID, internalID string, ts int64) {
	t.Helper()
	if err := store.Insert(context.Background(), requestlog.Row{
		TSUtc: time.UnixMilli(ts).UTC(), RequestID: internalID, ExternalRequestID: externalID,
		AccountID: accountID, Model: input.RouteSnapshot.ModelID,
		ProviderAssignedID: "assigned", Status: 200, Stream: true, BuyerIP: "127.0.0.1",
	}); err != nil {
		t.Fatal(err)
	}
}

func assertFinalityModeScopeJSON(t *testing.T, finality RequestSettlementFinality, want bool) {
	t.Helper()
	body, err := json.Marshal(finality)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		t.Fatal(err)
	}
	expected := "false"
	if want {
		expected = "true"
	}
	if string(fields["mode_scope_complete"]) != expected {
		t.Fatalf("mode_scope_complete must be explicitly %s: %s", expected, body)
	}
}
