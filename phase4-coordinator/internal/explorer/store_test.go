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

// R4 fix (CODE-M4): SPEC-005 v0.4 §11.6.5 explorer LEFT JOIN must
// surface the resolution_* alias columns. Earlier AC-Q050 (in
// billing package) ran the expected SQL directly against store.db,
// which could mask an explorer-layer regression. This test exercises
// the REAL explorer API — Store{}.SessionDetail and Store{}.Ledger —
// against a fixture that has a force-void resolution row.
func TestStoreSessionDetail_SurfacesQuarantineResolutionAliases(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	now := fixedExplorerTime()
	// Mark the seed ledger row as quarantined + force-voided.
	if _, err := db.Exec(`UPDATE ledger_request_credits SET quarantined=1, quarantine_reason='test_quarantine' WHERE request_id='req_seed'`); err != nil {
		t.Fatalf("mark seed quarantined: %v", err)
	}
	if _, err := db.Exec(`
INSERT INTO ledger_quarantine_resolutions
    (request_credit_id, resolution_kind, operator_id, resolution_reason, created_at_utc)
SELECT id, 'force_void', 'alice', 'real-explorer-test', ?
  FROM ledger_request_credits WHERE request_id='req_seed'`,
		now.Format(time.RFC3339Nano)); err != nil {
		t.Fatalf("insert quarantine resolution: %v", err)
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
	if got, _ := row["resolution_operator_id"].(string); got != "alice" {
		t.Fatalf("resolution_operator_id=%v want alice", row["resolution_operator_id"])
	}
	if got, _ := row["resolution_reason"].(string); got != "real-explorer-test" {
		t.Fatalf("resolution_reason=%v want real-explorer-test", row["resolution_reason"])
	}
	if got, _ := row["resolution_at_utc"].(string); got == "" {
		t.Fatalf("resolution_at_utc is empty")
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
