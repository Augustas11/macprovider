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
