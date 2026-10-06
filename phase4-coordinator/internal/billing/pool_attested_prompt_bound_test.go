package billing

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/json"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// #1690 BUG-1 / SPEC-022-R012.4, R-3.4.2: the len(body)/4 prompt bound caps
// the ledger amount only. A loopback pool_operator_attested attempt's
// settlement evidence carries the runtime's own prompt count, which is what
// the provider signs, so an honest receipt verifies and the credit stays at
// the bounded ledger prompt.

const (
	boundedPoolReportedPrompt = int64(69)
	boundedPoolPromptBound    = int64(47)
)

func journaledSettlementUsage(t *testing.T, store *Store, requestID string) (string, SettlementUsage) {
	t.Helper()
	var source, canonical string
	if err := store.db.QueryRow(`SELECT usage_source, usage_canonical_json FROM settlement_attempt_output_journal WHERE request_id = ?`, requestID).
		Scan(&source, &canonical); err != nil {
		t.Fatal(err)
	}
	var usage settlementUsageV04
	if err := json.Unmarshal([]byte(canonical), &usage); err != nil {
		t.Fatal(err)
	}
	return source, SettlementUsage{
		BillableInputTokens: usage.BillableInputTokens, BillableOutputTokens: usage.BillableOutputTokens,
		DeliveredOutputBytes: usage.DeliveredOutputBytes,
		ObservedInputTokens:  usage.ObservedInputTokens, ObservedOutputTokens: usage.ObservedOutputTokens,
	}
}

func TestWriteHotPath_PoolAttestedEvidenceKeepsProviderReportedPrompt(t *testing.T) {
	for name, tc := range map[string]struct {
		runtime    string
		attested   bool
		usageSrc   string
		wantSource string
	}{
		"loopback pool_operator_attested": {"llamacpp_loopback", true, UsageSourcePoolOperatorAttested, UsageSourcePoolOperatorAttested},
		"ollama loopback attested":        {"ollama_loopback", true, UsageSourcePoolOperatorAttested, UsageSourcePoolOperatorAttested},
		// Native evidence is the recorder's coordinator_observed tuple,
		// passed through unchanged.
		"native coordinator_observed": {"", false, UsageSourceCoordinatorObserved, UsageSourceCoordinatorObserved},
	} {
		t.Run(name, func(t *testing.T) {
			reqStore, store := newRequestAndBillingStores(t)
			store.SetPoolOperatorAttestationAuthority(stableFencedAuthority())
			store.SetSettlementPoolLabelSource(matchingPoolLabels)
			input, row := testHotPathInput(t, store)
			reported, completion, bound := boundedPoolReportedPrompt, int64(4), boundedPoolPromptBound
			row.PromptTokens, row.CompletionTokens = &reported, &completion
			input.PromptTokens, input.CompletionTokens = &reported, &completion
			input.PromptTokenUpperBound = &bound
			input.ProviderRuntimeSource = tc.runtime
			if tc.attested {
				fence := testPoolFence()
				fence.Claim.RuntimeSource = tc.runtime
				input.PoolOperatorAttested, input.PoolAttestationFence = true, fence
			}
			now := time.Now().UTC().UnixMilli()
			input.SettlementAttemptOutput = &SettlementAttemptOutput{
				AccountScope: AccountScopeForSettlement(""), RequestID: row.RequestID, ProviderID: input.ProviderID,
				Output:          SettlementOutput{Content: "ok", Available: true, OutputPrefixEndByte: 2, TerminalState: TerminalStateNormalDone, TerminalStateTSUnixMS: now},
				OutputAvailable: true, UsageSource: tc.usageSrc, TerminalStateTSUnixMS: now,
				Usage: SettlementUsage{BillableInputTokens: reported, BillableOutputTokens: completion, DeliveredOutputBytes: 2, ObservedInputTokens: reported, ObservedOutputTokens: completion},
			}
			if err := store.WriteHotPath(context.Background(), reqStore, row, input); err != nil {
				t.Fatal(err)
			}
			var charged, reportedLedger, quarantined int64
			if err := store.db.QueryRow(`SELECT charged_prompt_tokens, provider_reported_prompt_tokens, quarantined FROM ledger_request_credits WHERE request_id = ?`, row.RequestID).
				Scan(&charged, &reportedLedger, &quarantined); err != nil {
				t.Fatal(err)
			}
			if charged != bound || reportedLedger != reported || quarantined != 0 {
				t.Fatalf("ledger charged/reported/quarantined=%d/%d/%d want %d/%d/0", charged, reportedLedger, quarantined, bound, reported)
			}
			source, usage := journaledSettlementUsage(t, store, row.RequestID)
			want := SettlementUsage{BillableInputTokens: reported, BillableOutputTokens: completion, DeliveredOutputBytes: 2, ObservedInputTokens: reported, ObservedOutputTokens: completion}
			if source != tc.wantSource || usage != want {
				t.Fatalf("evidence source=%s usage=%+v, want %s %+v (the provider-reported prompt, not the bound)", source, usage, tc.wantSource, want)
			}
		})
	}
}

// boundedPoolReceiptRun writes a loopback pool attempt through the real hot
// path with a prompt above the len(body)/4 bound, then ingests a v0.4 receipt
// signing signedPrompt as the input tokens.
func boundedPoolReceiptRun(t *testing.T, signedPrompt int64) (SettlementReceiptState, *Store, SettlementVerifyInput, int64) {
	t.Helper()
	fixtures := loadSettlementVerifierFixtures(t)
	tuple := settlementReceiptTuplesByID(fixtures)["receipt_tuple_v4_normal_done"]
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	input := settlementVerifierInputFromFixture(t, fixtures, tuple, pub)
	keyID, err := ReceiptKeyID(pub)
	if err != nil {
		t.Fatal(err)
	}
	input.ProviderReceiptKeyID = keyID
	input.RouteSnapshot.ProviderReceiptKeyID = keyID
	input.RouteSnapshot.ProviderReceiptKeySource = "auth_session"
	input.RouteSnapshot = *attestedPoolSnapshot(input.RouteSnapshot)
	input.ExpectedUsage.ObservedInputTokens = signedPrompt
	input.ExpectedUsage.BillableInputTokens = signedPrompt
	input.Header = signedSettlementReceiptForInputWithKey(t, input, priv)

	reqStore, store := newRequestAndBillingStores(t)
	createSettlementReceiptAuditLog(t, store.db)
	setHoldingPoolRoute(store, &fakePoolAttestationAuthority{})
	if _, err := store.InsertRouteSnapshot(context.Background(), input.RouteSnapshot); err != nil {
		t.Fatal(err)
	}
	fence, ok := store.PoolAttestationFenceFor(context.Background(), input.RouteSnapshot)
	if !ok {
		t.Fatal("no pool fence")
	}
	cfg := testRewards()
	snapshotID, err := store.InsertConfigSnapshot(context.Background(), cfg, time.UnixMilli(input.TerminalStateTSUnixMS).Add(-time.Hour).UTC())
	if err != nil {
		t.Fatal(err)
	}
	reported, completion, bound := boundedPoolReportedPrompt, input.ExpectedUsage.ObservedOutputTokens, boundedPoolPromptBound
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	row := requestlog.Row{TSUtc: ts, RequestID: input.RequestID, Model: input.RouteSnapshot.ModelID, ProviderAssignedID: "assigned-a",
		PromptTokens: &reported, CompletionTokens: &completion, Status: 200, BuyerIP: "127.0.0.1"}
	finish := "stop"
	// The recorder's evidence: the runtime's reported usage, unbounded.
	attempt := &SettlementAttemptOutput{
		AccountScope: input.AccountScope, RequestID: input.RequestID, AttemptN: input.AttemptN, ProviderID: input.ProviderID,
		Output: SettlementOutput{Content: "Final answer.", FinishReason: &finish, Available: true,
			OutputPrefixStartByte: input.OutputPrefixStartByte, OutputPrefixEndByte: input.OutputPrefixEndByte,
			TerminalState: input.TerminalState, TerminalStateTSUnixMS: input.TerminalStateTSUnixMS},
		OutputAvailable: true, UsageSource: UsageSourcePoolOperatorAttested, TerminalStateTSUnixMS: input.TerminalStateTSUnixMS,
		Usage: SettlementUsage{BillableInputTokens: reported, BillableOutputTokens: completion, DeliveredOutputBytes: input.ExpectedUsage.DeliveredOutputBytes,
			ObservedInputTokens: reported, ObservedOutputTokens: completion},
	}
	if err := store.WriteHotPath(context.Background(), reqStore, row, HotPathInput{
		RequestID: row.RequestID, AttemptN: int(input.AttemptN), ProviderAssignedID: row.ProviderAssignedID, ProviderID: input.ProviderID,
		Model: row.Model, Status: 200, TSUtc: ts, PromptTokens: &reported, PromptTokenUpperBound: &bound, CompletionTokens: &completion,
		ConfigSnapshotID: snapshotID, RateEntry: RateFor(cfg.RateCard, row.Model), MultiplierPPM: ParseMultiplierPPM(cfg.GlobalMultiplier),
		ProviderShareBps: ParseShareBps(cfg.ProviderShare), ProviderRuntimeSource: "llamacpp_loopback",
		PoolOperatorAttested: true, PoolAttestationFence: fence,
		SettlementAccountScopeHash: SettlementAccountScopeHash(input.AccountScope), SettlementPolicyMode: RouteSnapshotModeEnforce,
		SettlementPolicyVersion: input.RouteSnapshot.RouteSnapshotPolicyVersion, SettlementAttemptOutput: attempt,
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := store.MaterializeSettlementAttemptOutputFor(context.Background(), settlementIdentityFromInput(input)); err != nil {
		t.Fatal(err)
	}
	grossBefore := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID)
	if grossBefore == 0 {
		t.Fatal("bounded loopback pool attempt was not credited on the hot path")
	}
	routeHash, _, err := input.RouteSnapshot.Digest()
	if err != nil {
		t.Fatal(err)
	}
	state, err := store.IngestPoolSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		PoolLabels:                matchingR012Labels(routeHash),
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	return state, store, input, grossBefore
}

func TestIngestPoolSettlementReceipt_BoundedPromptVerifiesProviderReportedUsage(t *testing.T) {
	state, store, input, grossBefore := boundedPoolReceiptRun(t, boundedPoolReportedPrompt)
	if state.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("receipt signing the runtime prompt %d outcome=%s reason=%s, want verified", boundedPoolReportedPrompt, state.SettlementOutcome, state.Reason)
	}
	var prompt, charged, reported, gross, quarantined int64
	if err := store.db.QueryRow(`SELECT prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens, gross_credits, quarantined FROM ledger_request_credits WHERE request_id = ?`, input.RequestID).
		Scan(&prompt, &charged, &reported, &gross, &quarantined); err != nil {
		t.Fatal(err)
	}
	if prompt != boundedPoolPromptBound || charged != boundedPoolPromptBound || reported != boundedPoolReportedPrompt {
		t.Fatalf("ledger prompt/charged/reported=%d/%d/%d want %d/%d/%d", prompt, charged, reported, boundedPoolPromptBound, boundedPoolPromptBound, boundedPoolReportedPrompt)
	}
	if gross != grossBefore || quarantined != 0 {
		t.Fatalf("verified receipt moved gross %d -> %d (quarantined=%d); the bounded prompt must still be what is charged", grossBefore, gross, quarantined)
	}
	finality, _, err := store.RequestSettlementFinality(context.Background(), input.AccountScope, input.RequestID, input.ReceiptReceivedUnixMS)
	if err != nil {
		t.Fatal(err)
	}
	if finality.Outcome != SettlementOutcomeVerified || finality.PromptTokens != boundedPoolPromptBound {
		t.Fatalf("buyer finality outcome=%s prompt=%d, want verified at the charged prompt %d", finality.Outcome, finality.PromptTokens, boundedPoolPromptBound)
	}
}

func TestIngestPoolSettlementReceipt_BoundedPromptRejectsReceiptSigningTheBound(t *testing.T) {
	state, _, _, _ := boundedPoolReceiptRun(t, boundedPoolPromptBound)
	if state.SettlementOutcome == SettlementOutcomeVerified || state.Reason != "usage_mismatch" {
		t.Fatalf("receipt signing the coordinator bound %d outcome=%s reason=%s, want usage_mismatch", boundedPoolPromptBound, state.SettlementOutcome, state.Reason)
	}
}
