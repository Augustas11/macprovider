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

func TestRecordSettlementAttemptOutputBoundsBillablePromptEvidence(t *testing.T) {
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
	rec := &billingRecorder{accountID: "acct-bounded", requestID: "req-bounded"}
	rec.setPromptTokenUpperBound(bound)
	output := &billing.SettlementOutput{
		Content:             "ok",
		OutputPrefixEndByte: 2,
		TerminalState:       billing.TerminalStateNormalDone,
	}
	err = rec.recordSettlementAttemptOutput(context.Background(), store, billing.HotPathInput{
		RequestID:             "req-bounded",
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
	if err := db.QueryRow(`SELECT usage_canonical_json FROM settlement_attempt_outputs WHERE request_id = ?`, "req-bounded").Scan(&raw); err != nil {
		t.Fatalf("query usage: %v", err)
	}
	var usage struct {
		BillableInputTokens int64 `json:"billable_input_tokens"`
		ObservedInputTokens int64 `json:"observed_input_tokens"`
	}
	if err := json.Unmarshal([]byte(raw), &usage); err != nil {
		t.Fatalf("decode usage: %v", err)
	}
	if usage.BillableInputTokens != bound || usage.ObservedInputTokens != reportedPrompt {
		t.Fatalf("usage prompt evidence = billable %d observed %d, want billable %d observed %d", usage.BillableInputTokens, usage.ObservedInputTokens, bound, reportedPrompt)
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
