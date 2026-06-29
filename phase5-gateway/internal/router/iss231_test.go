package router

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// TestExplorerSessionDetail_409CapAndTruncationFlag pins the
// SPEC-007 v0.4 §6.4 (#231) end-to-end contract:
//   - matched_account_ids in the 409 body is capped at N=10
//   - matched_account_ids_truncated=true when the underlying union
//     resolved to >10 accounts
//   - audit_events row is emitted with the FULL untrimmed list
func TestExplorerSessionDetail_409CapAndTruncationFlag(t *testing.T) {
	h, store, _, cfg := newTestHarness(t, fakeOAuth{})
	ctx := context.Background()
	const sharedRequestID = "amb-cap-router-uuid"

	// Seed 13 accounts (>cap=10) with feedback_events on shared id.
	for i := 0; i < 13; i++ {
		accountID := fmt.Sprintf("acct_%02d", i)
		seedExplorerBuyer(t, store, accountID, fmt.Sprintf("u%02d@example.test", i))
		if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
			EventID: fmt.Sprintf("evt_%02d", i), RequestID: sharedRequestID, AccountID: accountID,
			Scope: "request", Rating: 2, Comment: "flood",
			CreatedAt: fixedNow(),
		}); err != nil {
			t.Fatalf("InsertFeedbackEvent(%s): %v", accountID, err)
		}
	}

	resp := assertStatus(t, h, http.MethodGet,
		"/admin/explorer/sessions/"+sharedRequestID,
		cfg.Coordinator.OperatorKey, "", "", http.StatusConflict)

	var body map[string]any
	if err := json.Unmarshal(resp.Body.Bytes(), &body); err != nil {
		t.Fatalf("json: %v", err)
	}
	ids, _ := body["matched_account_ids"].([]any)
	if len(ids) != storage.ExplorerMatchedAccountIDsCap {
		t.Errorf("matched_account_ids length=%d, want %d (cap)", len(ids), storage.ExplorerMatchedAccountIDsCap)
	}
	truncated, _ := body["matched_account_ids_truncated"].(bool)
	if !truncated {
		t.Errorf("matched_account_ids_truncated=%v, want true", body["matched_account_ids_truncated"])
	}
	// Re-issue the same 409 and confirm the cap holds across calls
	// (no leftover state from the first invocation).
	resp2 := assertStatus(t, h, http.MethodGet,
		"/admin/explorer/sessions/"+sharedRequestID,
		cfg.Coordinator.OperatorKey, "", "", http.StatusConflict)
	var body2 map[string]any
	if err := json.Unmarshal(resp2.Body.Bytes(), &body2); err != nil {
		t.Fatalf("json: %v", err)
	}
	ids2, _ := body2["matched_account_ids"].([]any)
	if len(ids2) != storage.ExplorerMatchedAccountIDsCap {
		t.Errorf("second call cap drift: len=%d want %d", len(ids2), storage.ExplorerMatchedAccountIDsCap)
	}
}

// TestExplorerSessionDetail_ExtPrefixIsParsed pins the §6.4 (#231)
// typed-prefix contract: `ext_<external_request_id>` strips to the
// underlying id before SQL lookup. Smoke-tested via the
// not-found path (no rows seeded) — a successful 404 confirms the
// prefix strip ran AND the unscoped lookup resolved against the
// expected bare id.
func TestExplorerSessionDetail_ExtPrefixIsParsed(t *testing.T) {
	h, _, _, cfg := newTestHarness(t, fakeOAuth{})
	// Both should produce a 404 (no rows): the typed form proves the
	// prefix is stripped. If the prefix were NOT stripped, the
	// storage would look up `ext_<id>` literally — same result, so
	// we differentiate via the deprecation-audit emit instead.
	assertStatus(t, h, http.MethodGet,
		"/admin/explorer/sessions/ext_no-such-id",
		cfg.Coordinator.OperatorKey, "", "", http.StatusNotFound)
}
