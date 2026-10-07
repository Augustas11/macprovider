package buyer

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sourceevidence"
	"github.com/rs/zerolog"
)

func TestBoundedTokenPointerClampsUntrustedRelayBlindUsage(t *testing.T) {
	for _, test := range []struct {
		name  string
		value int64
		limit int64
		want  int64
	}{
		{name: "negative", value: -1, limit: 32, want: 0},
		{name: "within", value: 17, limit: 32, want: 17},
		{name: "malicious_overreport", value: 1<<62 - 1, limit: 32, want: 32},
	} {
		t.Run(test.name, func(t *testing.T) {
			got := boundedTokenPointer(&test.value, test.limit)
			if got == nil || *got != test.want {
				t.Fatalf("bounded value=%v want=%d", got, test.want)
			}
		})
	}
}

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

// SPEC-015 §N.6 / SPEC-047-R003(iv) v0.1.10 (#1694): usage relayed from a
// loopback runtime is provider-only, so the attempt is recorded
// byte_estimated with zero billable usage whatever counts the provider
// reported. Native sessions (mlx_cache, or a legacy hello with no source)
// keep coordinator_observed with billable == observed.
func TestRecordSettlementAttemptOutputLoopbackUsageIsNeverCoordinatorObserved(t *testing.T) {
	for _, tc := range []struct {
		source       string
		wantSource   string
		wantBillable bool
	}{
		{"", billing.UsageSourceCoordinatorObserved, true},
		{"mlx_cache", billing.UsageSourceCoordinatorObserved, true},
		{"ollama_loopback", billing.UsageSourceByteEstimated, false},
		{"llamacpp_loopback", billing.UsageSourceByteEstimated, false},
		{"lmstudio_loopback", billing.UsageSourceByteEstimated, false},
		{"openai_compatible_loopback", billing.UsageSourceByteEstimated, false},
	} {
		t.Run("source="+tc.source, func(t *testing.T) {
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
			prompt := int64(900)
			completion := int64(5000)
			rec := &billingRecorder{accountID: "acct-loopback", requestID: "req-loopback"}
			output := &billing.SettlementOutput{
				Content:             "ok",
				OutputPrefixEndByte: 2,
				TerminalState:       billing.TerminalStateNormalDone,
			}
			if err := rec.recordSettlementAttemptOutput(context.Background(), store, billing.HotPathInput{
				RequestID:             "req-loopback",
				ProviderID:            "provider-a",
				ProviderRuntimeSource: tc.source,
				PromptTokens:          &prompt,
				CompletionTokens:      &completion,
			}, output); err != nil {
				t.Fatalf("recordSettlementAttemptOutput: %v", err)
			}
			db, err := sql.Open("sqlite", dbPath)
			if err != nil {
				t.Fatalf("open db: %v", err)
			}
			defer db.Close()
			var source, raw string
			if err := db.QueryRow(`SELECT usage_source, usage_canonical_json FROM settlement_attempt_outputs WHERE request_id = ?`, "req-loopback").Scan(&source, &raw); err != nil {
				t.Fatalf("query attempt: %v", err)
			}
			var usage struct {
				BillableInputTokens  int64 `json:"billable_input_tokens"`
				BillableOutputTokens int64 `json:"billable_output_tokens"`
				ObservedInputTokens  int64 `json:"observed_input_tokens"`
			}
			if err := json.Unmarshal([]byte(raw), &usage); err != nil {
				t.Fatalf("decode usage: %v", err)
			}
			if source != tc.wantSource {
				t.Fatalf("usage_source=%q want %q", source, tc.wantSource)
			}
			if tc.wantBillable {
				if usage.BillableInputTokens != prompt || usage.BillableOutputTokens != completion {
					t.Fatalf("native usage must stay billable==observed: %+v", usage)
				}
				return
			}
			if usage.BillableInputTokens != 0 || usage.BillableOutputTokens != 0 || usage.ObservedInputTokens == prompt {
				t.Fatalf("loopback usage must not carry the provider-reported counts: %+v", usage)
			}
		})
	}
}

func TestPersistSettlementAttemptOutputRouteMirrorPressureKeepsOutputBudget(t *testing.T) {
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

	settlementRouteSnapshotMirrorErrForTest = billing.ErrRouteSnapshotStorePressure
	settlementRouteSnapshotMirrorContextForTest = func(ctx context.Context) context.Context {
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Fatal("route-snapshot mirror context must have a deadline")
		}
		if remaining := time.Until(deadline); remaining > 50*time.Millisecond {
			t.Fatalf("route-snapshot mirror budget=%s, want bounded near 25ms", remaining)
		}
		canceled, cancel := context.WithCancel(ctx)
		cancel()
		return canceled
	}
	outputWriteCalled := false
	settlementOutputWriteContextForTest = func(attempt int, ctx context.Context) context.Context {
		outputWriteCalled = true
		if attempt != 1 {
			t.Fatalf("settlement output attempt=%d want 1", attempt)
		}
		if err := ctx.Err(); err != nil {
			t.Fatalf("settlement output context inherited mirror cancellation: %v", err)
		}
		deadline, ok := ctx.Deadline()
		if !ok {
			t.Fatal("settlement output context must have a deadline")
		}
		if remaining := time.Until(deadline); remaining < requestLogWriteTimeout-time.Second {
			t.Fatalf("settlement output budget=%s, want fresh requestLogWriteTimeout budget", remaining)
		}
		return ctx
	}
	t.Cleanup(func() {
		settlementRouteSnapshotMirrorErrForTest = nil
		settlementRouteSnapshotMirrorContextForTest = nil
		settlementOutputWriteContextForTest = nil
	})

	prompt := int64(10)
	completion := int64(1)
	rec := &billingRecorder{accountID: "acct-pressure", requestID: "req-pressure"}
	err = rec.persistSettlementAttemptOutput(store, billing.HotPathInput{
		RequestID:        "req-pressure",
		AttemptN:         7,
		ProviderID:       "provider-a",
		Status:           200,
		PromptTokens:     &prompt,
		CompletionTokens: &completion,
	}, settlementOutputForContent("ok", nil, nil, billing.TerminalStateNormalDone))
	if err != nil {
		t.Fatalf("persistSettlementAttemptOutput: %v", err)
	}
	if !outputWriteCalled {
		t.Fatal("settlement output write was not attempted")
	}
	if got := settlementAttemptOutputCount(t, dbPath, "req-pressure"); got != 1 {
		t.Fatalf("settlement attempt outputs=%d want 1", got)
	}
}

func TestPersistSettlementAttemptOutputRouteMirrorIntegrityFailsClosed(t *testing.T) {
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

	mirrorErr := errors.New("route snapshot mirror digest mismatch")
	settlementRouteSnapshotMirrorErrForTest = mirrorErr
	outputWriteCalled := false
	settlementOutputWriteContextForTest = func(attempt int, ctx context.Context) context.Context {
		outputWriteCalled = true
		return ctx
	}
	t.Cleanup(func() {
		settlementRouteSnapshotMirrorErrForTest = nil
		settlementOutputWriteContextForTest = nil
	})

	prompt := int64(10)
	completion := int64(1)
	rec := &billingRecorder{accountID: "acct-integrity", requestID: "req-integrity"}
	err = rec.persistSettlementAttemptOutput(store, billing.HotPathInput{
		RequestID:        "req-integrity",
		AttemptN:         3,
		ProviderID:       "provider-a",
		Status:           200,
		PromptTokens:     &prompt,
		CompletionTokens: &completion,
	}, settlementOutputForContent("ok", nil, nil, billing.TerminalStateNormalDone))
	if !errors.Is(err, mirrorErr) {
		t.Fatalf("persistSettlementAttemptOutput err=%v want mirror integrity error", err)
	}
	if outputWriteCalled {
		t.Fatal("settlement output write must not run after route-snapshot integrity failure")
	}
	if got := settlementAttemptOutputCount(t, dbPath, "req-integrity"); got != 0 {
		t.Fatalf("settlement attempt outputs=%d want 0", got)
	}
}

func TestPersistSettlementAttemptOutputFailsWhenJournalAndProjectionAreMissing(t *testing.T) {
	prev := settlementOutputWriteContextForTest
	settlementOutputWriteContextForTest = func(int, context.Context) context.Context {
		ctx, cancel := context.WithCancel(context.Background())
		cancel()
		return ctx
	}
	t.Cleanup(func() { settlementOutputWriteContextForTest = prev })

	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	reqLog, err := requestlog.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = reqLog.Close() })
	store, err := billing.NewStore(reqLog.DB())
	if err != nil {
		t.Fatal(err)
	}
	prompt, completion := int64(10), int64(1)
	in := billing.HotPathInput{
		RequestID:        "req-missing-durable-evidence",
		AttemptN:         0,
		ProviderID:       "provider-a",
		Status:           200,
		PromptTokens:     &prompt,
		CompletionTokens: &completion,
	}
	rec := &billingRecorder{accountID: "acct-missing", requestID: in.RequestID}
	attempt, _ := rec.buildSettlementAttemptOutput(in, settlementOutputForContent("ok", nil, nil, billing.TerminalStateNormalDone), false)
	in.SettlementAttemptOutput = &attempt
	if err := rec.persistSettlementAttemptOutput(store, in, nil); err == nil {
		t.Fatal("missing journal and projection were accepted as successful persistence")
	}
}

func settlementAttemptOutputCount(t *testing.T, dbPath, requestID string) int {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open db: %v", err)
	}
	defer db.Close()
	var count int
	if err := db.QueryRow(`SELECT COUNT(*) FROM settlement_attempt_outputs WHERE request_id = ?`, requestID).Scan(&count); err != nil {
		t.Fatalf("count settlement attempt outputs: %v", err)
	}
	return count
}

func TestLogNoDispatchClosureFallbacksRedactRefusalModel(t *testing.T) {
	tests := []struct {
		name         string
		withEvidence bool
		terminalKind string
		status       int
		message      string
	}{
		{name: "default_disabled_model_not_found", terminalKind: sourceevidence.TerminalModelNotFound, status: http.StatusNotFound, message: "No provider has advertised the requested model"},
		{name: "default_disabled_pool_unavailable", terminalKind: sourceevidence.TerminalPoolUnavailable, status: http.StatusServiceUnavailable, message: "Pool unavailable"},
		{name: "enabled_closure_failure_model_not_found", withEvidence: true, terminalKind: sourceevidence.TerminalModelNotFound, status: http.StatusNotFound, message: "No provider has advertised the requested model"},
		{name: "enabled_closure_failure_pool_unavailable", withEvidence: true, terminalKind: sourceevidence.TerminalPoolUnavailable, status: http.StatusServiceUnavailable, message: "Pool unavailable"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
			reqLog, err := requestlog.OpenStore(dbPath)
			if err != nil {
				t.Fatalf("requestlog.OpenStore: %v", err)
			}
			t.Cleanup(func() { _ = reqLog.Close() })
			opts := []Option{WithRequestLog(reqLog)}
			if test.withEvidence {
				evidenceStore, err := sourceevidence.NewStore(reqLog.DB(), []byte("01234567890123456789012345678901"), func() time.Time { return time.Unix(1716768000, 0).UTC() })
				if err != nil {
					t.Fatalf("sourceevidence.NewStore: %v", err)
				}
				opts = append(opts, WithSourceEvidence(evidenceStore))
			}
			server := NewServer(nil, zerolog.Nop(), time.Unix(1716768000, 0), opts...)
			startedAt := time.Unix(1716768000, 0).UTC()
			state := newForwardState(startedAt)
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil)
			requestID := "77777777-7777-4777-8777-777777777777"
			rec := server.newBillingRecorder(req, state, startedAt, requestID, "external-default", "acct-default", requestlog.AuthenticatedAccount{}, false)
			rec.setModel("private-unserved-model")
			rec.logNoDispatchClosure(test.terminalKind, test.status, test.message)
			var model, msg string
			if err := reqLog.DB().QueryRow(`SELECT model, error FROM request_log WHERE request_id = ?`, requestID).Scan(&model, &msg); err != nil {
				t.Fatalf("query request_log: %v", err)
			}
			if model != "" {
				t.Fatalf("fallback request_log.model = %q, want blank", model)
			}
			if msg != test.message {
				t.Fatalf("fallback request_log.error = %q, want %q", msg, test.message)
			}
		})
	}
}
