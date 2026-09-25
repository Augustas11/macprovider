package billing

import (
	"context"
	"strings"
	"testing"
	"time"
)

// E2E-F5: a verified receipt on an attempt whose only credit the hot path
// quarantined (here invalid_cached_prompt_tokens) closes zero_settled with a
// valid receipt result, so the gateway refunds. Before the fix the lookup
// returned "verified charged ledger usage missing" and the buyer's
// reservation was held forever.
func TestVerifiedReceiptOnQuarantinedCreditClosesZeroSettled(t *testing.T) {
	store, route := enforceCreditFixture(t, "verified-quarantined-credit", true, true, RouteSnapshotModeEnforce)
	ctx := context.Background()
	if _, err := store.db.ExecContext(ctx, `
INSERT INTO settlement_attempt_outputs (account_scope, request_id, attempt_n, provider_id, terminal_state, terminal_state_ts_unix_ms,
    output_prefix_start_byte, output_prefix_end_byte, usage_hash, usage_canonical_json, usage_source, created_at_utc)
VALUES (?, ?, 0, ?, 'normal_done', ?, 0, 83, ?, ?, 'coordinator_observed', ?)`,
		route.AccountScope, route.RequestID, route.ProviderID, enforceCreditFixtureTS.UnixMilli(), strings.Repeat("a", 64),
		`{"billable_input_tokens":175,"billable_output_tokens":21,"delivered_output_bytes":83,"observed_input_tokens":175,"observed_output_tokens":21}`,
		enforceCreditFixtureTS.Format(time.RFC3339Nano)); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.ExecContext(ctx, `UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'invalid_cached_prompt_tokens', gross_credits = 0, provider_credits = 0 WHERE request_id = ?`, route.RequestID); err != nil {
		t.Fatal(err)
	}
	finality, found, err := store.RequestSettlementFinality(ctx, route.AccountScope, route.RequestID, enforceCreditFixtureTS.Add(time.Hour).UnixMilli())
	if err != nil || !found {
		t.Fatalf("finality found=%v err=%v, want a terminal answer", found, err)
	}
	if finality.Outcome != SettlementOutcomeZeroSettled || finality.ReceiptResult != SettlementReceiptResultValid || !finality.Closed ||
		finality.Reason != VerifiedCreditQuarantinedReason || finality.ZeroSettledAttempts != 1 || finality.VerifiedAttempts != 0 ||
		finality.PromptTokens != 0 || finality.CompletionTokens != 0 || !finality.ModeScopeComplete {
		t.Fatalf("finality=%+v, want closed zero_settled/valid %s with no tokens", finality, VerifiedCreditQuarantinedReason)
	}
	// The same through the account-scoped lookup the gateway reconciler uses.
	again, found, err := store.RequestSettlementFinality(ctx, route.AccountScope, route.RequestID, enforceCreditFixtureTS.Add(2*time.Hour).UnixMilli())
	if err != nil || !found || again.Outcome != SettlementOutcomeZeroSettled {
		t.Fatalf("second read finality=%+v found=%v err=%v, want the same terminal answer", again, found, err)
	}
	// A verified verdict with no credit at all is still an error: nothing
	// shows the provider side is settled.
	if _, err := store.db.ExecContext(ctx, `DELETE FROM ledger_request_credits WHERE request_id = ?`, route.RequestID); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.RequestSettlementFinality(ctx, route.AccountScope, route.RequestID, enforceCreditFixtureTS.Add(time.Hour).UnixMilli()); err == nil {
		t.Fatal("a verified verdict without any ledger credit returned finality, want the missing-usage error")
	}
}
