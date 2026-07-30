package explorer

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestStoreRecentSessionsCursorRejectsMalformedValue(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	_, err := Store{}.RecentSessions(context.Background(), db, fixedExplorerTime().Add(-time.Hour), fixedExplorerTime().Add(time.Hour), "not-a-cursor", 10)
	if err != ErrBadCursor {
		t.Fatalf("err=%v want %v", err, ErrBadCursor)
	}
}

func TestStoreSessionDetailReturnsLedgerJoin(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	detail, err := Store{}.SessionDetail(context.Background(), db, "req_seed")
	if err != nil {
		t.Fatalf("SessionDetail: %v", err)
	}
	if detail["request_id"] != "req_seed" {
		t.Fatalf("request_id=%v", detail["request_id"])
	}
	if got := detail["attempts"].([]map[string]any); len(got) != 1 {
		t.Fatalf("attempts=%d", len(got))
	}
	if got := detail["ledger_rows"].([]map[string]any); len(got) != 1 || got[0]["gross_credits"] != int64(15) {
		t.Fatalf("ledger_rows=%v", got)
	}
}

// SPEC-005 v0.5 §11.6.5 explorer reads must surface latest/current
// resolution aliases without duplicating ledger rows, while preserving
// ordered resolution history for detail views.
func TestStoreSessionDetail_SurfacesQuarantineResolutionAliases(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	now := fixedExplorerTime()
	if _, err := db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason='test_quarantine' WHERE request_id='req_seed'`); err != nil {
		t.Fatalf("mark seed quarantined: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO ledger_quarantine_resolutions
    (request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc)
SELECT id, 'force_credit', 'alice', 'credit-first', ?, ?, ?
  FROM ledger_request_credits WHERE request_id='req_seed'`,
		now.Format(time.RFC3339Nano),
		now.Add(24*time.Hour).Format(time.RFC3339Nano),
		now.Add(24*time.Hour).Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("insert force-credit resolution: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO ledger_quarantine_resolutions
    (request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc, correction_deadline_at_utc)
SELECT id, 'force_void', 'bob', 'void-correction', ?, ?
  FROM ledger_request_credits WHERE request_id='req_seed'`,
		now.Add(time.Minute).Format(time.RFC3339Nano),
		now.Add(24*time.Hour).Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("insert force-void resolution: %v", err)
	}
	detail, err := Store{}.SessionDetail(context.Background(), db, "req_seed")
	if err != nil {
		t.Fatalf("SessionDetail: %v", err)
	}
	rows := detail["ledger_rows"].([]map[string]any)
	if len(rows) != 1 {
		t.Fatalf("ledger_rows=%d want 1", len(rows))
	}
	row := rows[0]
	if got, _ := row["resolution_kind"].(string); got != "force_void" {
		t.Fatalf("resolution_kind=%v want force_void", row["resolution_kind"])
	}
	if got, _ := row["resolution_operator_id"].(string); got != "bob" {
		t.Fatalf("resolution_operator_id=%v want bob", row["resolution_operator_id"])
	}
	if got, _ := row["resolution_reason"].(string); got != "void-correction" {
		t.Fatalf("resolution_reason=%v want void-correction", row["resolution_reason"])
	}
	if got, _ := row["resolution_at_utc"].(string); got == "" {
		t.Fatalf("resolution_at_utc is empty")
	}
	history := detail["quarantine_resolution_history"].([]map[string]any)
	if len(history) != 2 {
		t.Fatalf("history len=%d want 2: %+v", len(history), history)
	}
	if got, _ := history[0]["resolution_kind"].(string); got != "force_credit" {
		t.Fatalf("history[0] kind=%v want force_credit", history[0]["resolution_kind"])
	}
	if got, _ := history[1]["resolution_kind"].(string); got != "force_void" {
		t.Fatalf("history[1] kind=%v want force_void", history[1]["resolution_kind"])
	}
	// Also verify the Ledger() list view surfaces the same aliases.
	ledger, err := Store{}.Ledger(context.Background(), db, now.Add(-time.Hour), now.Add(time.Hour), 10)
	if err != nil {
		t.Fatalf("Ledger: %v", err)
	}
	if len(ledger) == 0 {
		t.Fatalf("ledger list empty")
	}
	var found bool
	for _, lr := range ledger {
		if id, _ := lr["request_id"].(string); id == "req_seed" {
			found = true
			if got, _ := lr["resolution_kind"].(string); got != "force_void" {
				t.Fatalf("Ledger list resolution_kind=%v want force_void", lr["resolution_kind"])
			}
			break
		}
	}
	if !found {
		t.Fatalf("req_seed missing from ledger list")
	}
}

func TestStoreOverviewIncludesMaturedForceCreditPayableRows(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	now := fixedExplorerTime()
	if _, err := db.Exec(`
INSERT INTO ledger_request_credits (
	request_id, attempt_n, provider_id, provider_assigned_id, ts_utc, model, status, stream,
	prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
	prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm,
	gross_credits, provider_share_bps, provider_credits, quarantined, quarantine_reason, created_at_utc
) VALUES ('req_force_credit_payable', 0, 'provider_seed', 'assigned_seed', ?, 'llama', 200, 0, 10, 5, NULL, 'provider_reported', 1, 1, 1000000, 20, 9000, 18, 1, 'test_quarantine', ?)`,
		now.Format(time.RFC3339Nano), now.Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("insert force-credit ledger row: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO ledger_quarantine_resolutions
    (request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc, force_credit_matures_at_utc, correction_deadline_at_utc)
SELECT id, 'force_credit', 'alice', 'matured credit', ?, '2000-01-01T00:00:00.000000000Z', ?
  FROM ledger_request_credits WHERE request_id='req_force_credit_payable'`,
		now.Format(time.RFC3339Nano), now.Add(24*time.Hour).Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("insert force-credit resolution: %v", err)
	}
	overview, err := Store{}.Overview(context.Background(), db, now.Add(-time.Hour), now.Add(time.Hour))
	if err != nil {
		t.Fatalf("Overview: %v", err)
	}
	ledger := overview["ledger"].(map[string]any)
	if got := ledger["total_gross_credits"]; got != int64(35) {
		t.Fatalf("total_gross_credits=%v want 35", got)
	}
	if got := ledger["total_provider_credits"]; got != int64(31) {
		t.Fatalf("total_provider_credits=%v want 31", got)
	}
	if got := ledger["total_operator_credits"]; got != int64(4) {
		t.Fatalf("total_operator_credits=%v want 4", got)
	}
	if got := ledger["current_window_provider_credits"]; got != int64(31) {
		t.Fatalf("current_window_provider_credits=%v want 31", got)
	}
}

func TestStoreActivitySinceCursorOnlyReturnsNewerRows(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	result, err := Store{}.Activity(context.Background(), db, fixedExplorerTime().Add(-time.Hour), fixedExplorerTime().Add(time.Hour), "", "", "", 10)
	if err != nil {
		t.Fatalf("Activity initial: %v", err)
	}
	if result.LatestCursor == nil {
		t.Fatalf("missing latest cursor")
	}
	seedRequestLog(t, db, fixedExplorerTime().Add(time.Minute), "req_store_newer")
	next, err := Store{}.Activity(context.Background(), db, fixedExplorerTime().Add(-time.Hour), fixedExplorerTime().Add(time.Hour), "", *result.LatestCursor, "", 10)
	if err != nil {
		t.Fatalf("Activity since: %v", err)
	}
	if len(next.Items) != 1 || next.Items[0]["request_id"] != "req_store_newer" || next.Items[0]["status"] != int64(http.StatusOK) {
		t.Fatalf("since items=%v", next.Items)
	}
}
