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

func TestStoreActivitySinceCursorOnlyReturnsNewerRows(t *testing.T) {
	_, db := newTestExplorer(t, nil)
	result, err := Store{}.Activity(context.Background(), db, fixedExplorerTime().Add(-time.Hour), fixedExplorerTime().Add(time.Hour), "", "", 10)
	if err != nil {
		t.Fatalf("Activity initial: %v", err)
	}
	if result.LatestCursor == nil {
		t.Fatalf("missing latest cursor")
	}
	seedRequestLog(t, db, fixedExplorerTime().Add(time.Minute), "req_store_newer")
	next, err := Store{}.Activity(context.Background(), db, fixedExplorerTime().Add(-time.Hour), fixedExplorerTime().Add(time.Hour), "", *result.LatestCursor, 10)
	if err != nil {
		t.Fatalf("Activity since: %v", err)
	}
	if len(next.Items) != 1 || next.Items[0]["request_id"] != "req_store_newer" || next.Items[0]["status"] != int64(http.StatusOK) {
		t.Fatalf("since items=%v", next.Items)
	}
}
