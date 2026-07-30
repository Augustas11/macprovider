package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
)

func TestSettlementOutputStrictKeysAndDigestSensitivity(t *testing.T) {
	output := testSettlementOutput()
	digest, canonical, err := output.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if len(digest) != 64 || !json.Valid(canonical) {
		t.Fatalf("digest/canonical invalid: digest=%q canonical=%s", digest, canonical)
	}
	value := output.Value()
	wantKeys := []string{
		"content",
		"finish_reason",
		"output_prefix_end_byte",
		"output_prefix_start_byte",
		"terminal_state",
		"tool_calls",
	}
	if len(value) != len(wantKeys) {
		t.Fatalf("key count=%d want %d: %#v", len(value), len(wantKeys), value)
	}
	for _, key := range wantKeys {
		if _, ok := value[key]; !ok {
			t.Fatalf("missing key %q", key)
		}
		mutated := cloneMap(value)
		mutated[key] = mutatedRouteSnapshotValue(mutated[key])
		mutatedDigest, _, err := CanonicalSHA256Hex(mutated)
		if err != nil {
			t.Fatalf("digest mutated %s: %v", key, err)
		}
		if mutatedDigest == digest {
			t.Fatalf("mutating %s did not change digest", key)
		}
	}
}

func TestSettlementUsageStrictKeysAndDeliveredBytes(t *testing.T) {
	usage := testSettlementUsage()
	digest, canonical, err := usage.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if len(digest) != 64 || !json.Valid(canonical) {
		t.Fatalf("digest/canonical invalid: digest=%q canonical=%s", digest, canonical)
	}
	value := usage.Value()
	wantKeys := []string{
		"billable_input_tokens",
		"billable_output_tokens",
		"delivered_output_bytes",
		"observed_input_tokens",
		"observed_output_tokens",
	}
	if len(value) != len(wantKeys) {
		t.Fatalf("key count=%d want %d: %#v", len(value), len(wantKeys), value)
	}
	for _, key := range wantKeys {
		if _, ok := value[key]; !ok {
			t.Fatalf("missing key %q", key)
		}
	}
}

func TestSettlementOutputToolCallsBindHashWithoutChangingContentRange(t *testing.T) {
	calls := []SettlementToolCall{{
		ID:        "call-a",
		Type:      "function",
		Name:      "lookup",
		Arguments: `{"query":"Vilnius"}`,
	}}
	output := SettlementOutput{
		Content:               "",
		Available:             true,
		OutputPrefixStartByte: 0,
		OutputPrefixEndByte:   0,
		TerminalState:         TerminalStateNormalDone,
		ToolCalls:             calls,
	}
	if err := output.Validate(); err != nil {
		t.Fatalf("tool-call-only output should allow empty content range: %v", err)
	}
	digest, _, err := output.Digest()
	if err != nil {
		t.Fatal(err)
	}
	output.ToolCalls[0].Arguments = `{"query":"Kaunas"}`
	mutated, _, err := output.Digest()
	if err != nil {
		t.Fatal(err)
	}
	if digest == mutated {
		t.Fatal("tool call mutation did not change output hash")
	}
}

func TestInsertSettlementAttemptOutputPersistsAndRejectsRewrite(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	attempt := SettlementAttemptOutput{
		AccountScope:          "acct-a",
		RequestID:             "req-output",
		AttemptN:              0,
		ProviderID:            "provider-a",
		Output:                testSettlementOutput(),
		OutputAvailable:       true,
		Usage:                 testSettlementUsage(),
		UsageSource:           UsageSourceByteEstimated,
		TerminalStateTSUnixMS: 1716768000000,
	}
	outputHash, err := store.InsertSettlementAttemptOutput(context.Background(), attempt)
	if err != nil {
		t.Fatal(err)
	}
	var storedHash string
	var canonical sql.NullString
	if err := store.db.QueryRow(`
SELECT output_hash, settlement_output_canonical_json
FROM settlement_attempt_outputs
WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`,
		attempt.RequestID, attempt.AttemptN, attempt.ProviderID,
	).Scan(&storedHash, &canonical); err != nil {
		t.Fatal(err)
	}
	if storedHash != outputHash {
		t.Fatalf("stored hash=%s want %s", storedHash, outputHash)
	}
	if canonical.Valid {
		t.Fatalf("raw settlement output persisted unexpectedly: %s", canonical.String)
	}
	attempt.Output.Content = "changed"
	delivered := SettlementDeliveredOutputBytes(attempt.Output.Content)
	attempt.Output.OutputPrefixEndByte = delivered
	attempt.Usage.DeliveredOutputBytes = delivered
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), attempt); err == nil {
		t.Fatal("second insert rewrote immutable settlement attempt output")
	}
}

func TestSettlementAttemptOutputDBRejectsNonHexDigestMaterial(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	hex64 := strings.Repeat("a", 64)
	nonHex64 := strings.Repeat("g", 64)
	if _, err := store.db.Exec(`
INSERT INTO settlement_attempt_outputs (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_available, output_prefix_start_byte, output_prefix_end_byte,
    output_hash, usage_hash, usage_canonical_json, usage_source,
    overlapping_or_duplicate, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		"acct-a", "req-output-nonhex", 0, "provider-a", TerminalStateNormalDone, int64(1716768000000),
		1, int64(0), int64(5),
		nonHex64, hex64, `{}`, UsageSourceCoordinatorObserved,
		0, "2026-01-01T00:00:00Z",
	); err == nil {
		t.Fatal("non-hex output_hash inserted despite DB CHECK")
	}
	if _, err := store.db.Exec(`
INSERT INTO settlement_attempt_outputs (
    account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_available, output_prefix_start_byte, output_prefix_end_byte,
    output_hash, usage_hash, usage_canonical_json, usage_source,
    overlapping_or_duplicate, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		"acct-a", "req-usage-nonhex", 0, "provider-a", TerminalStateNormalDone, int64(1716768000000),
		1, int64(0), int64(5),
		hex64, nonHex64, `{}`, UsageSourceCoordinatorObserved,
		0, "2026-01-01T00:00:00Z",
	); err == nil {
		t.Fatal("non-hex usage_hash inserted despite DB CHECK")
	}
}

func TestInsertSettlementAttemptOutputMarksOverlap(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	first := SettlementAttemptOutput{
		AccountScope:          "acct-a",
		RequestID:             "req-overlap",
		AttemptN:              0,
		ProviderID:            "provider-a",
		Output:                testSettlementOutput(),
		OutputAvailable:       true,
		Usage:                 testSettlementUsage(),
		UsageSource:           UsageSourceByteEstimated,
		TerminalStateTSUnixMS: 1716768000000,
	}
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	second := first
	second.AttemptN = 1
	second.ProviderID = "provider-b"
	second.Output.Content = "lo"
	second.Output.ToolCalls = nil
	second.Output.OutputPrefixStartByte = 3
	second.Output.OutputPrefixEndByte = 5
	second.Usage.DeliveredOutputBytes = 2
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	var firstOverlap, secondOverlap int
	if err := store.db.QueryRow(`
SELECT overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`,
		first.RequestID, first.AttemptN, first.ProviderID,
	).Scan(&firstOverlap); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`
SELECT overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE request_id = ? AND attempt_n = ? AND provider_id = ?`,
		second.RequestID, second.AttemptN, second.ProviderID,
	).Scan(&secondOverlap); err != nil {
		t.Fatal(err)
	}
	if firstOverlap != 1 || secondOverlap != 1 {
		t.Fatalf("overlaps=(%d,%d), want both marked", firstOverlap, secondOverlap)
	}
}

func TestInsertSettlementAttemptOutputMarksDuplicateZeroByteToolCallHash(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	first := SettlementAttemptOutput{
		AccountScope:          "acct-a",
		RequestID:             "req-tool-dup",
		AttemptN:              0,
		ProviderID:            "provider-a",
		Output:                testToolCallOnlySettlementOutput(`{"query":"Vilnius"}`),
		OutputAvailable:       true,
		Usage:                 SettlementUsage{},
		UsageSource:           UsageSourceCoordinatorObserved,
		TerminalStateTSUnixMS: 1716768000000,
	}
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	second := first
	second.AttemptN = 1
	second.ProviderID = "provider-b"
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	var firstOverlap, secondOverlap int
	if err := store.db.QueryRow(`
SELECT overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		first.AccountScope, first.RequestID, first.AttemptN, first.ProviderID,
	).Scan(&firstOverlap); err != nil {
		t.Fatal(err)
	}
	if err := store.db.QueryRow(`
SELECT overlapping_or_duplicate
FROM settlement_attempt_outputs
WHERE account_scope = ? AND request_id = ? AND attempt_n = ? AND provider_id = ?`,
		second.AccountScope, second.RequestID, second.AttemptN, second.ProviderID,
	).Scan(&secondOverlap); err != nil {
		t.Fatal(err)
	}
	if firstOverlap != 1 || secondOverlap != 1 {
		t.Fatalf("duplicate zero-byte tool-call overlaps=(%d,%d), want both marked", firstOverlap, secondOverlap)
	}
}

func TestInsertSettlementAttemptOutputOverlapIsAccountScoped(t *testing.T) {
	_, store := newRequestAndBillingStores(t)
	first := SettlementAttemptOutput{
		AccountScope:          "acct-a",
		RequestID:             "req-account-scoped-overlap",
		AttemptN:              0,
		ProviderID:            "provider-a",
		Output:                testSettlementOutput(),
		OutputAvailable:       true,
		Usage:                 testSettlementUsage(),
		UsageSource:           UsageSourceByteEstimated,
		TerminalStateTSUnixMS: 1716768000000,
	}
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), first); err != nil {
		t.Fatal(err)
	}
	second := first
	second.AccountScope = "acct-b"
	second.ProviderID = "provider-b"
	if _, err := store.InsertSettlementAttemptOutput(context.Background(), second); err != nil {
		t.Fatal(err)
	}
	if got := scalar(t, store.db, `SELECT COUNT(*) FROM settlement_attempt_outputs WHERE overlapping_or_duplicate = 1`); got != 0 {
		t.Fatalf("cross-account overlap count=%d want 0", got)
	}
}

func testSettlementOutput() SettlementOutput {
	finish := "stop"
	toolCalls := []SettlementToolCall{{
		ID:        "call-a",
		Type:      "function",
		Name:      "lookup",
		Arguments: `{"query":"Café"}`,
	}}
	delivered := SettlementDeliveredOutputBytes("hello")
	return SettlementOutput{
		Content:               "hello",
		FinishReason:          &finish,
		Available:             true,
		OutputPrefixStartByte: 0,
		OutputPrefixEndByte:   delivered,
		TerminalState:         TerminalStateNormalDone,
		ToolCalls:             toolCalls,
	}
}

func testToolCallOnlySettlementOutput(arguments string) SettlementOutput {
	finish := "tool_calls"
	return SettlementOutput{
		FinishReason:          &finish,
		Available:             true,
		OutputPrefixStartByte: 0,
		OutputPrefixEndByte:   0,
		TerminalState:         TerminalStateNormalDone,
		ToolCalls: []SettlementToolCall{{
			ID:        "call-a",
			Type:      "function",
			Name:      "lookup",
			Arguments: arguments,
		}},
	}
}

func testSettlementUsage() SettlementUsage {
	delivered := SettlementDeliveredOutputBytes("hello")
	return SettlementUsage{
		BillableInputTokens:  3,
		BillableOutputTokens: 2,
		DeliveredOutputBytes: delivered,
		ObservedInputTokens:  3,
		ObservedOutputTokens: 2,
	}
}
