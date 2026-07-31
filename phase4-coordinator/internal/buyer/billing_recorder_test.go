package buyer

import (
	"context"
	"database/sql"
	"encoding/json"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// TestRecordSettlementAttemptOutputNormalDoneBillableEqualsObserved locks in the
// SPEC-015 receipts invariant: for a normal_done attempt the settlement evidence
// tuple MUST carry billable_input_tokens == observed_input_tokens, even when the
// provider-reported prompt tokens exceed the len(body)/4 prompt-token upper bound.
// Capping billable below observed here produces a tuple the settlement verifier
// rejects (usage_observed_mismatch) and that no honest provider receipt can match,
// which quarantined 100% of settlements for models whose chat-template tokenization
// exceeds len(body)/4 (Llama-3.2/3.1, gpt-oss). Regression guard for that bug.
func TestRecordSettlementAttemptOutputNormalDoneBillableEqualsObserved(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqLog, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}

	// bound (len(body)/4) is deliberately far below the provider-reported prompt
	// tokens, as happens for short prompts under a token-dense chat template.
	bound := int64(10)
	reportedPrompt := int64(100)
	completion := int64(4)
	rec := &billingRecorder{accountID: "acct-normaldone", requestID: "req-normaldone"}
	rec.setPromptTokenUpperBound(bound)
	output := &billing.SettlementOutput{
		Content:             "ok",
		OutputPrefixEndByte: 2,
		TerminalState:       billing.TerminalStateNormalDone,
	}
	err = rec.recordSettlementAttemptOutput(context.Background(), store, billing.HotPathInput{
		RequestID:             "req-normaldone",
		ProviderID:            "provider-a",
		PromptTokens:          &reportedPrompt,
		PromptTokenUpperBound: &bound,
		CompletionTokens:      &completion,
	}, output)
	if err != nil {
		t.Fatalf("recordSettlementAttemptOutput: %v", err)
	}

	var raw string
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	if err := db.QueryRow(`SELECT usage_canonical_json FROM settlement_attempt_outputs WHERE request_id = ?`, "req-normaldone").Scan(&raw); err != nil {
		t.Fatalf("query usage: %v", err)
	}
	var usage struct {
		BillableInputTokens  int64 `json:"billable_input_tokens"`
		ObservedInputTokens  int64 `json:"observed_input_tokens"`
		BillableOutputTokens int64 `json:"billable_output_tokens"`
		ObservedOutputTokens int64 `json:"observed_output_tokens"`
	}
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		t.Fatalf("decode usage: %v", err)
	}
	// SPEC-015 normal_done: billable == observed on both axes; NOT capped to bound.
	if usage.BillableInputTokens != reportedPrompt || usage.ObservedInputTokens != reportedPrompt {
		t.Fatalf("normal_done prompt evidence = billable %d observed %d, want both %d (SPEC-015 billable==observed, uncapped)", usage.BillableInputTokens, usage.ObservedInputTokens, reportedPrompt)
	}
	if usage.BillableOutputTokens != completion || usage.ObservedOutputTokens != completion {
		t.Fatalf("normal_done completion evidence = billable %d observed %d, want both %d", usage.BillableOutputTokens, usage.ObservedOutputTokens, completion)
	}
}

// TestRecordSettlementAttemptOutputPartialPrefixBillableEqualsObserved proves that
// a positive-money non-normal_done terminal state WITH a delivered prefix
// (provider_error/buyer_cancel/gateway_timeout/upstream_transport_disconnect) also
// carries billable_input == observed_input in the settlement evidence, uncapped by
// the len(body)/4 prompt-token bound. tupleUsageMatchesLedger requires exact
// equality with the provider receipt for EVERY terminal state, and the provider
// cannot reproduce the coordinator's byte-heuristic cap; capping here would
// quarantine token-dense-prompt partial settlements the same way it did normal_done.
func TestRecordSettlementAttemptOutputPartialPrefixBillableEqualsObserved(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqLog, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}

	bound := int64(10)
	reportedPrompt := int64(100)
	completion := int64(4)
	rec := &billingRecorder{accountID: "acct-partial", requestID: "req-partial", server: &Server{}}
	rec.setPromptTokenUpperBound(bound)
	// Non-normal_done terminal state with a delivered prefix (delivered > 0 so the
	// delivered==0 zeroing branch does not fire).
	output := &billing.SettlementOutput{
		Content:             "partial-prefix",
		Available:           true,
		OutputPrefixEndByte: int64(len("partial-prefix")),
		TerminalState:       billing.TerminalStateProviderError,
	}
	err = rec.recordSettlementAttemptOutput(context.Background(), store, billing.HotPathInput{
		RequestID:             "req-partial",
		ProviderID:            "provider-a",
		PromptTokens:          &reportedPrompt,
		PromptTokenUpperBound: &bound,
		CompletionTokens:      &completion,
	}, output)
	if err != nil {
		t.Fatalf("recordSettlementAttemptOutput: %v", err)
	}

	var raw string
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	if err := db.QueryRow(`SELECT usage_canonical_json FROM settlement_attempt_outputs WHERE request_id = ?`, "req-partial").Scan(&raw); err != nil {
		t.Fatalf("query usage: %v", err)
	}
	var usage struct {
		BillableInputTokens int64 `json:"billable_input_tokens"`
		ObservedInputTokens int64 `json:"observed_input_tokens"`
	}
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		t.Fatalf("decode usage: %v", err)
	}
	if usage.BillableInputTokens != reportedPrompt || usage.ObservedInputTokens != reportedPrompt {
		t.Fatalf("partial-prefix prompt evidence = billable %d observed %d, want both %d (billable==observed, uncapped)", usage.BillableInputTokens, usage.ObservedInputTokens, reportedPrompt)
	}
}

func TestRecordSettlementAttemptOutputByteEstimatedBuyerCancelIsNotBillable(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqLog, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open request log: %v", err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatalf("billing.NewStore: %v", err)
	}

	output := &billing.SettlementOutput{
		Content:             "forwarded-prefix",
		Available:           true,
		OutputPrefixEndByte: int64(len("forwarded-prefix")),
		TerminalState:       billing.TerminalStateBuyerCancel,
	}
	rec := &billingRecorder{
		accountID: "acct-cancel",
		requestID: "req-cancel",
		server:    &Server{},
	}
	err = rec.recordSettlementAttemptOutput(context.Background(), store, billing.HotPathInput{
		RequestID:  "req-cancel",
		ProviderID: "provider-a",
	}, output)
	if err != nil {
		t.Fatalf("recordSettlementAttemptOutput: %v", err)
	}

	var usageRaw string
	var usageSource string
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	if err := db.QueryRow(`SELECT usage_source, usage_canonical_json FROM settlement_attempt_outputs WHERE request_id = ?`, "req-cancel").Scan(&usageSource, &usageRaw); err != nil {
		t.Fatalf("query settlement attempt output: %v", err)
	}
	var usage struct {
		BillableInputTokens  int64 `json:"billable_input_tokens"`
		BillableOutputTokens int64 `json:"billable_output_tokens"`
		DeliveredOutputBytes int64 `json:"delivered_output_bytes"`
		ObservedOutputTokens int64 `json:"observed_output_tokens"`
	}
	if err := json.Unmarshal([]byte(usageRaw), &usage); err != nil {
		t.Fatalf("decode usage: %v", err)
	}
	if usageSource != billing.UsageSourceByteEstimated {
		t.Fatalf("usage_source=%s want %s", usageSource, billing.UsageSourceByteEstimated)
	}
	if usage.DeliveredOutputBytes <= 0 || usage.ObservedOutputTokens <= 0 {
		t.Fatalf("usage evidence = delivered %d observed %d, want positive byte-estimated evidence", usage.DeliveredOutputBytes, usage.ObservedOutputTokens)
	}
	if usage.BillableInputTokens != 0 || usage.BillableOutputTokens != 0 {
		t.Fatalf("usage billable tokens = input %d output %d, want 0/0 for byte-estimated buyer cancel", usage.BillableInputTokens, usage.BillableOutputTokens)
	}
}
