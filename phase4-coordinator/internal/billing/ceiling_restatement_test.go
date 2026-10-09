package billing

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type restatableRow struct {
	store    *Store
	input    SettlementVerifyInput
	id       int64
	receipt  int64
	estimate int64
	ts       time.Time
}

// seedRestatableRow is an enforce-mode non-streaming attempt whose verified
// receipt the sync clamped to a superseded /16 estimate: one credit per
// completion token, none for the prompt.
func seedRestatableRow(t *testing.T) restatableRow {
	t.Helper()
	input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
	receipt := input.ExpectedUsage.BillableOutputTokens
	// The smallest superseded estimate whose restated ceiling covers the
	// receipt, which must still be below it to have clamped.
	estimate := 1 + (receipt-1+supersededNonStreamBytesPerToken-1)/supersededNonStreamBytesPerToken
	if estimate >= receipt {
		t.Fatalf("fixture completion %d too small to show a /16 clamp", receipt)
	}
	_, store := newRequestAndBillingStores(t)
	store.SetOutputBytesPerTokenCeiling(16)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCredit(t, store.db, input, 700)
	if _, err := store.db.Exec(`UPDATE ledger_request_credits
   SET prompt_rate_per_mtok = 0, completion_rate_per_mtok = 1000000, estimated_completion_tokens = ?
 WHERE request_id = ?`, estimate, input.RequestID); err != nil {
		t.Fatal(err)
	}
	state, err := store.IngestSettlementReceipt(context.Background(), SettlementReceiptIngestionInput{
		SettlementReceiptIdentity: settlementIdentityFromInput(input),
		Header:                    input.Header,
		ProviderReceiptPubkey:     input.ProviderReceiptPubkey,
		receiptReceivedUnixMS:     input.ReceiptReceivedUnixMS,
	})
	if err != nil {
		t.Fatal(err)
	}
	if state.SettlementOutcome != SettlementOutcomeVerified {
		t.Fatalf("outcome=%s reason=%s, want verified", state.SettlementOutcome, state.Reason)
	}
	row := restatableRow{store: store, input: input, receipt: receipt, estimate: estimate, ts: time.UnixMilli(input.TerminalStateTSUnixMS).UTC()}
	row.id = scalar(t, store.db, `SELECT id FROM ledger_request_credits WHERE request_id = ?`, input.RequestID)
	if gross := row.gross(t); gross != estimate {
		t.Fatalf("seeded clamp gross=%d want %d", gross, estimate)
	}
	return row
}

func (r restatableRow) gross(t *testing.T) int64 {
	t.Helper()
	return scalar(t, r.store.db, `SELECT gross_credits FROM ledger_request_credits WHERE id = ?`, r.id)
}

func (r restatableRow) restate(t *testing.T, dryRun bool) CeilingRestatementResult {
	t.Helper()
	res, err := r.store.RestateNonStreamCeilings(context.Background(), CeilingRestatementInput{
		OperatorID: "ops-a", Reason: "restate superseded non-streaming ceiling",
		From: r.ts.Add(-time.Hour), To: r.ts.Add(time.Hour), DryRun: dryRun,
	})
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func (r restatableRow) auditRows(t *testing.T) int64 {
	t.Helper()
	return scalar(t, r.store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = ?`, eventCeilingRestatement)
}

func TestCeilingRestatementDryRunReportsDeltasWithoutWriting(t *testing.T) {
	r := seedRestatableRow(t)
	res := r.restate(t, true)
	delta := r.receipt - r.estimate
	if !res.DryRun || res.Candidates != 1 || res.Restated != 1 || res.GrossDelta != delta || res.ProviderDelta != delta || res.OperatorDelta != 0 || len(res.Rows) != 1 {
		t.Fatalf("dry run=%+v, want one row with gross/provider delta %d", res, delta)
	}
	if row := res.Rows[0]; row.NewUsageSource != UsageProviderReported || row.NewEstimate != nil || row.NewGross != r.receipt {
		t.Fatalf("dry-run row=%+v, want provider_reported, NULL estimate, gross %d", row, r.receipt)
	}
	if got := r.gross(t); got != r.estimate {
		t.Fatalf("dry run wrote gross=%d, want unchanged %d", got, r.estimate)
	}
	if n := r.auditRows(t); n != 0 {
		t.Fatalf("dry run wrote %d audit rows", n)
	}
}

func TestCeilingRestatementRestatesOnceWithAudit(t *testing.T) {
	r := seedRestatableRow(t)
	res := r.restate(t, false)
	if res.Restated != 1 || res.GrossDelta != r.receipt-r.estimate {
		t.Fatalf("restatement=%+v, want one row restated by %d", res, r.receipt-r.estimate)
	}
	var gross, provider, completion int64
	var usage string
	var estimate sql.NullInt64
	if err := r.store.db.QueryRow(`SELECT gross_credits, provider_credits, completion_tokens, usage_source, estimated_completion_tokens FROM ledger_request_credits WHERE id = ?`, r.id).
		Scan(&gross, &provider, &completion, &usage, &estimate); err != nil {
		t.Fatal(err)
	}
	if gross != r.receipt || provider != r.receipt || completion != r.receipt || usage != UsageProviderReported || estimate.Valid {
		t.Fatalf("restated row gross=%d provider=%d completion=%d usage=%s estimate=%v, want receipt %d provider_reported NULL", gross, provider, completion, usage, estimate, r.receipt)
	}
	if opGross := scalar(t, r.store.db, `SELECT gross_credits FROM ledger_operator_credits WHERE request_credit_id = ?`, r.id); opGross != r.receipt {
		t.Fatalf("operator credit gross=%d want %d", opGross, r.receipt)
	}
	var payloadJSON string
	if err := r.store.db.QueryRow(`SELECT payload_json FROM audit_log WHERE event_type = ?`, eventCeilingRestatement).Scan(&payloadJSON); err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(payloadJSON), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["operator_id"] != "ops-a" || payload["request_credit_id"] != float64(r.id) ||
		payload["old_gross_credits"] != float64(r.estimate) || payload["new_gross_credits"] != float64(r.receipt) ||
		payload["old_usage_source"] != UsageByteEstimated || payload["new_usage_source"] != UsageProviderReported ||
		payload["old_estimated_completion_tokens"] != float64(r.estimate) || payload["new_estimated_completion_tokens"] != nil {
		t.Fatalf("audit payload=%s", payloadJSON)
	}

	if n := scalar(t, r.store.db, `SELECT COUNT(*) FROM ledger_ceiling_restatements WHERE request_credit_id = ? AND old_gross_credits = ? AND new_gross_credits = ? AND operator_id = 'ops-a'`, r.id, r.estimate, r.receipt); n != 1 {
		t.Fatalf("restatement records=%d want 1", n)
	}
	// Pruning audit_log does not reopen the row: the restatement ledger
	// is the dedupe.
	if _, err := r.store.db.Exec(`DELETE FROM audit_log WHERE event_type = ?`, eventCeilingRestatement); err != nil {
		t.Fatal(err)
	}
	again := r.restate(t, false)
	if again.Candidates != 0 || again.Restated != 0 {
		t.Fatalf("second run=%+v, want nothing left to restate", again)
	}
	if n := r.auditRows(t); n != 0 {
		t.Fatalf("audit rows=%d after a repeat run over a pruned log, want 0", n)
	}
}

func TestCeilingRestatementLeavesOutOfScopeRowsUntouched(t *testing.T) {
	for name, mutate := range map[string]string{
		"settled":              `UPDATE ledger_request_credits SET settled = 1 WHERE id = ?`,
		"settlement assigned":  `UPDATE ledger_request_credits SET settlement_id = 42 WHERE id = ?`,
		"quarantined":          `UPDATE ledger_request_credits SET quarantined = 1, quarantine_reason = 'held' WHERE id = ?`,
		"streaming":            `UPDATE ledger_request_credits SET stream = 1 WHERE id = ?`,
		"legacy unclamped row": `UPDATE ledger_request_credits SET usage_source = 'provider_reported', estimated_completion_tokens = NULL WHERE id = ?`,
		"outside the window":   `UPDATE ledger_request_credits SET ts_utc = '2020-01-01T00:00:00.000000000Z' WHERE id = ?`,
	} {
		t.Run(name, func(t *testing.T) {
			r := seedRestatableRow(t)
			before := r.gross(t)
			if _, err := r.store.db.Exec(mutate, r.id); err != nil {
				t.Fatal(err)
			}
			res := r.restate(t, false)
			if res.Restated != 0 {
				t.Fatalf("restated %d out-of-scope rows: %+v", res.Restated, res)
			}
			if got := r.gross(t); got != before {
				t.Fatalf("gross changed %d -> %d", before, got)
			}
			if n := r.auditRows(t); n != 0 {
				t.Fatalf("audit rows=%d want 0", n)
			}
		})
	}
}

// An observe-mode row shaped like a clamped non-streaming row is outside the
// restatement even with a receipt on file.
func TestCeilingRestatementSkipsObserveModeRows(t *testing.T) {
	input := r012SettlementInput(t, "receipt_tuple_v4_normal_done", false)
	_, store := newRequestAndBillingStores(t)
	store.SetOutputBytesPerTokenCeiling(16)
	createSettlementReceiptAuditLog(t, store.db)
	seedSettlementReceiptEvidence(t, store, input)
	insertSPEC022LedgerCreditWithMode(t, store.db, input, 1, RouteSnapshotModeObserve, "")
	if _, err := store.db.Exec(`UPDATE ledger_request_credits
   SET usage_source = 'byte_estimated', estimated_completion_tokens = 1, gross_credits = 1, provider_credits = 1
 WHERE request_id = ?`, input.RequestID); err != nil {
		t.Fatal(err)
	}
	ts := time.UnixMilli(input.TerminalStateTSUnixMS).UTC()
	res, err := store.RestateNonStreamCeilings(context.Background(), CeilingRestatementInput{
		OperatorID: "ops-a", Reason: "restate", From: ts.Add(-time.Hour), To: ts.Add(time.Hour),
	})
	if err != nil {
		t.Fatal(err)
	}
	if res.Candidates != 0 || res.Restated != 0 {
		t.Fatalf("observe-mode restatement=%+v, want no candidates", res)
	}
	if gross := scalar(t, store.db, `SELECT gross_credits FROM ledger_request_credits WHERE request_id = ?`, input.RequestID); gross != 1 {
		t.Fatalf("observe-mode gross=%d want 1", gross)
	}
}

func TestCeilingRestatementWithoutVerifiedReceiptIsSkipped(t *testing.T) {
	r := seedRestatableRow(t)
	if _, err := r.store.db.Exec(`UPDATE settlement_attempt_outputs SET overlapping_or_duplicate = 1 WHERE request_id = ?`, r.input.RequestID); err != nil {
		t.Fatal(err)
	}
	res := r.restate(t, false)
	if res.Restated != 0 || res.Skipped["not_verified_payable"] != 1 {
		t.Fatalf("restatement=%+v, want the overlapping attempt skipped", res)
	}
	if got := r.gross(t); got != r.estimate {
		t.Fatalf("gross changed to %d", got)
	}
}

// The nightly reconcile re-prices a verified row against its stored
// ceiling, so neither a sync-clamped nor a restated row is flagged.
func TestReconcileAcceptsClampedAndRestatedVerifiedRows(t *testing.T) {
	r := seedRestatableRow(t)
	reconcile := func(stage string) {
		t.Helper()
		prompt := r.input.ExpectedUsage.BillableInputTokens
		completion := r.receipt
		tx, err := r.store.db.BeginTx(context.Background(), nil)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback()
		_, _, found, mismatch, err := reconcileExistingCreditTx(context.Background(), tx, HotPathInput{
			RequestID: r.input.RequestID, AttemptN: int(r.input.AttemptN), ProviderID: r.input.ProviderID,
			PromptTokens: &prompt, CompletionTokens: &completion,
			RateEntry:     RateCardEntry{PromptCreditsPerMtok: 0, CompletionCreditsPerMtok: 1000000},
			MultiplierPPM: 1000000, ProviderShareBps: 10000,
		}, BilledRow{}, time.Now().UTC().Format(time.RFC3339Nano))
		if err != nil {
			t.Fatal(err)
		}
		if !found || mismatch {
			t.Fatalf("%s: reconcile found=%v mismatch=%v, want a matching row", stage, found, mismatch)
		}
	}
	reconcile("sync-clamped")
	r.restate(t, false)
	reconcile("restated")
}

func TestCeilingRestatementRouteIsGated(t *testing.T) {
	r := seedRestatableRow(t)
	h := r.store.Handlers("operator-key", nil, false, 0)
	body, err := json.Marshal(map[string]any{
		"operator_id": "ops-a", "reason": "restate superseded ceiling",
		"from_utc": r.ts.Add(-time.Hour).Format(time.RFC3339Nano), "to_utc": r.ts.Add(time.Hour).Format(time.RFC3339Nano),
		"dry_run": true,
	})
	if err != nil {
		t.Fatal(err)
	}
	post := func(bearer string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, ceilingRestatementPath, bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		rr := httptest.NewRecorder()
		h.ServeHTTP(rr, req)
		return rr
	}
	if rr := post("operator-key"); rr.Code != http.StatusNotFound {
		t.Fatalf("flag off status=%d want 404", rr.Code)
	}
	if err := r.store.SetCeilingRestatementEnabled(context.Background(), true, "sighup"); err != nil {
		t.Fatal(err)
	}
	if n := scalar(t, r.store.db, `SELECT COUNT(*) FROM audit_log WHERE event_type = 'billing_config_flag_changed' AND json_extract(payload_json, '$.flag') = 'ceiling_restatement_enabled'`); n != 1 {
		t.Fatalf("flag-change audit rows=%d want 1", n)
	}
	if rr := post(""); rr.Code != http.StatusForbidden {
		t.Fatalf("no bearer status=%d want 403", rr.Code)
	}
	r.store.SetOutputBytesPerTokenCeiling(4)
	if rr := post("operator-key"); rr.Code != http.StatusConflict || !strings.Contains(rr.Body.String(), "restatement_refused") {
		t.Fatalf("refused status=%d body=%s, want 409 restatement_refused", rr.Code, rr.Body.String())
	}
	r.store.SetOutputBytesPerTokenCeiling(16)
	badLimit, _ := json.Marshal(map[string]any{"operator_id": "ops-a", "reason": "r", "from_utc": r.ts.Format(time.RFC3339Nano), "to_utc": r.ts.Add(time.Hour).Format(time.RFC3339Nano), "dry_run": true, "limit": 0})
	req := httptest.NewRequest(http.MethodPost, ceilingRestatementPath, bytes.NewReader(badLimit))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer operator-key")
	limitRR := httptest.NewRecorder()
	h.ServeHTTP(limitRR, req)
	if limitRR.Code != http.StatusUnprocessableEntity || !strings.Contains(limitRR.Body.String(), "bad_limit") {
		t.Fatalf("limit 0 status=%d body=%s, want 422 bad_limit", limitRR.Code, limitRR.Body.String())
	}
	if rr := post(""); rr.Code != http.StatusForbidden {
		t.Fatalf("no bearer status=%d want 403", rr.Code)
	}
	rr := post("operator-key")
	if rr.Code != http.StatusOK {
		t.Fatalf("dry run status=%d body=%s", rr.Code, rr.Body.String())
	}
	var res CeilingRestatementResult
	if err := json.Unmarshal(rr.Body.Bytes(), &res); err != nil {
		t.Fatal(err)
	}
	if !res.DryRun || res.Restated != 1 || res.GrossDelta != r.receipt-r.estimate {
		t.Fatalf("dry-run response=%+v", res)
	}
	if got := r.gross(t); got != r.estimate {
		t.Fatalf("dry run over HTTP wrote gross=%d", got)
	}
}

func TestCeilingRestatementRefusesWithoutItsPreconditions(t *testing.T) {
	for name, tc := range map[string]struct {
		setup func(r restatableRow)
		to    func(r restatableRow) time.Time
	}{
		"activation marker missing": {setup: func(r restatableRow) {
			if _, err := r.store.db.Exec(`DELETE FROM ledger_markers WHERE name = ?`, nonStreamBodyCeilingActiveMarker); err != nil {
				t.Fatal(err)
			}
		}},
		"window ends after activation": {to: func(r restatableRow) time.Time {
			var at string
			if err := r.store.db.QueryRow(`SELECT ts_utc FROM ledger_markers WHERE name = ?`, nonStreamBodyCeilingActiveMarker).Scan(&at); err != nil {
				t.Fatal(err)
			}
			ts, err := time.Parse(time.RFC3339Nano, at)
			if err != nil {
				t.Fatal(err)
			}
			return ts.Add(time.Second)
		}},
		"output ceiling is not 16": {setup: func(r restatableRow) { r.store.SetOutputBytesPerTokenCeiling(4) }},
		"output ceiling never set": {setup: func(r restatableRow) { r.store.SetOutputBytesPerTokenCeiling(0) }},
	} {
		t.Run(name, func(t *testing.T) {
			r := seedRestatableRow(t)
			if tc.setup != nil {
				tc.setup(r)
			}
			to := r.ts.Add(time.Hour)
			if tc.to != nil {
				to = tc.to(r)
			}
			_, err := r.store.RestateNonStreamCeilings(context.Background(), CeilingRestatementInput{
				OperatorID: "ops-a", Reason: "restate", From: r.ts.Add(-time.Hour), To: to, DryRun: true,
			})
			if !errors.Is(err, ErrCeilingRestatementRefused) {
				t.Fatalf("err=%v want ErrCeilingRestatementRefused", err)
			}
			if got := r.gross(t); got != r.estimate {
				t.Fatalf("refused restatement changed gross to %d", got)
			}
		})
	}
}

func TestCeilingRestatementActivationMarkerIsWrittenOnce(t *testing.T) {
	r := seedRestatableRow(t)
	var first string
	if err := r.store.db.QueryRow(`SELECT ts_utc FROM ledger_markers WHERE name = ?`, nonStreamBodyCeilingActiveMarker).Scan(&first); err != nil {
		t.Fatal(err)
	}
	reopened, err := NewStore(r.store.db)
	if err != nil {
		t.Fatal(err)
	}
	var again string
	if err := reopened.db.QueryRow(`SELECT ts_utc FROM ledger_markers WHERE name = ?`, nonStreamBodyCeilingActiveMarker).Scan(&again); err != nil {
		t.Fatal(err)
	}
	if again != first {
		t.Fatalf("activation marker moved %s -> %s on restart", first, again)
	}
}

func TestCeilingRestatementDuplicateRecordAbortsTheBatch(t *testing.T) {
	r := seedRestatableRow(t)
	// A record for the row with no matching dedupe would be a second
	// restatement; the primary key aborts the whole batch.
	conn, err := r.store.db.Conn(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	row := CeilingRestatementRow{RequestCreditID: r.id, RequestID: r.input.RequestID, ProviderID: r.input.ProviderID, OldUsageSource: UsageByteEstimated, NewUsageSource: UsageProviderReported}
	in := CeilingRestatementInput{OperatorID: "ops-a", Reason: "restate"}
	if err := insertCeilingRestatementRecordTx(context.Background(), conn, in, "2026-01-01T00:00:00.000000000Z", row); err != nil {
		t.Fatal(err)
	}
	if err := insertCeilingRestatementRecordTx(context.Background(), conn, in, "2026-01-01T00:00:00.000000000Z", row); err == nil {
		t.Fatal("second restatement record for the same row was accepted")
	}
}
