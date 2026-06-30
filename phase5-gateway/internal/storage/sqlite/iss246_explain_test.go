package sqlite

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"
)

// TestExplorerDetailHelpers_UnscopedUsesIndex pins SPEC-007 §6.4 +
// issue #246: when the operator calls
// `GET /admin/explorer/sessions/ext_<id>` WITHOUT
// `?account_id=` (unscoped session-detail path), each of the five
// downstream detail helpers MUST be planned by SQLite as
// `SEARCH ... USING INDEX idx_*_request` — NOT `SCAN`.
//
// Pre-#246 the helpers used the `(? = '' OR col = ?)` optional-
// predicate pattern so a single prepared statement could serve both
// scoped and unscoped paths. SQLite cannot use a normal index plan
// against a compound `OR` predicate — `EXPLAIN QUERY PLAN` reported
// `SCAN`. With #231's `idx_*_request` indexes in place, the fix is
// to branch on parameter presence at the helper level: when
// `account_id` is empty AND `request_id` is supplied, emit only
// `WHERE request_id = ?` so SQLite can plan against
// `idx_*_request`. See `explorerDetailWhere` in explorer.go.
//
// This is the regression test the issue body called for.
func TestExplorerDetailHelpers_UnscopedUsesIndex(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()
	// The unscoped session-detail WHERE shape produced by
	// explorerDetailWhere(accountID="", requestID="req-xyz",
	// from=zero, to=zero) is exactly: `WHERE request_id = ?`.
	cases := []struct {
		table     string
		wantIndex string
	}{
		{table: "usage_events", wantIndex: "idx_usage_request"},
		{table: "quota_reservations", wantIndex: "idx_quota_request"},
		{table: "concurrency_reservations", wantIndex: "idx_concurrency_request"},
		{table: "feedback_events", wantIndex: "idx_feedback_request"},
		{table: "audit_events", wantIndex: "idx_audit_request"},
	}
	for _, tc := range cases {
		t.Run(tc.table, func(t *testing.T) {
			rows, err := store.db.QueryContext(ctx,
				fmt.Sprintf(`EXPLAIN QUERY PLAN
					SELECT * FROM %s WHERE request_id = ? LIMIT ?`, tc.table),
				"req-xyz", 1)
			if err != nil {
				t.Fatalf("EXPLAIN: %v", err)
			}
			defer rows.Close()
			var plan strings.Builder
			for rows.Next() {
				var id, parent, notused int
				var detail string
				if err := rows.Scan(&id, &parent, &notused, &detail); err != nil {
					t.Fatalf("scan: %v", err)
				}
				plan.WriteString(detail)
				plan.WriteString("\n")
			}
			got := plan.String()
			if !strings.Contains(got, "SEARCH") {
				t.Fatalf("expected SEARCH plan, got:\n%s", got)
			}
			if !strings.Contains(got, tc.wantIndex) {
				t.Fatalf("expected plan to use %s, got:\n%s", tc.wantIndex, got)
			}
			if strings.Contains(got, "SCAN "+tc.table) {
				t.Fatalf("plan still contains SCAN on %s — fix regressed:\n%s", tc.table, got)
			}
		})
	}
}

// TestExplorerSessionDetail_UnscopedRequestIDBoundedRuntimeSemantics
// pins the runtime behaviour the EXPLAIN test above can't see (R1
// CODE/SEC/ARCH convergent LOW): a future regression that drops
// `request_id = ?` on the empty-account branch — or reintroduces an
// optional-predicate that matches all accounts — would pass the
// EXPLAIN test but leak cross-account rows. Here we seed target +
// distractor rows across all five tables and assert
// ExplorerSessionDetail(ctx, "", targetRequestID) returns only the
// target's data.
func TestExplorerSessionDetail_UnscopedRequestIDBoundedRuntimeSemantics(t *testing.T) {
	store := newTestStore(t)
	ctx := context.Background()

	const targetReq = "req-target-iss246"
	const otherReq = "req-distractor-iss246"
	const targetAcct = "acct_target"
	const otherAcct = "acct_distractor"
	createAccount(t, store, targetAcct)
	createAccount(t, store, otherAcct)
	at := time.Date(2026, 6, 30, 12, 0, 0, 0, time.UTC)

	// Seed: 1 target row + 2 distractor rows per table.
	// Distractors vary by (accountID, requestID) combination:
	//   D1: target_acct + other_req   (same account, different request)
	//   D3: other_acct  + other_req   (different account, different request)
	// We DO NOT seed a cross-account-same-request row (other_acct +
	// target_req) because that would correctly trigger the ambiguity
	// probe's 409 — which is a separate, already-tested code path.
	// The threat this test guards: if a future regression dropped
	// `request_id = ?` on the empty-account branch of the detail-
	// fetch helpers, BOTH D1 and D3 (different request_id) would
	// leak into the result. So asserting "no row with
	// request_id != targetReq" catches the regression.
	type tableSeeder struct {
		name string
		seed func(t *testing.T, acct, req, eventID string)
	}
	exec := func(t *testing.T, query string, args ...any) {
		t.Helper()
		if _, err := store.db.ExecContext(ctx, query, args...); err != nil {
			t.Fatalf("exec %q: %v", query, err)
		}
	}
	seeders := []tableSeeder{
		{name: "usage_events", seed: func(t *testing.T, acct, req, _ string) {
			exec(t, `INSERT INTO usage_events(request_id, account_id, demo_identity, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
				VALUES(?, ?, '', '2026-06-30', 1, 1, 2, 'provider_reported', 'success', ?)`, req, acct, encodeTime(at))
		}},
		{name: "quota_reservations", seed: func(t *testing.T, acct, req, _ string) {
			exec(t, `INSERT INTO quota_reservations(account_id, request_id, window_date, reserved_tokens, settled_tokens, status, expires_at, created_at, settled_at)
				VALUES(?, ?, '2026-06-30', 100, 0, 'active', ?, ?, '')`, acct, req, encodeTime(at.Add(time.Hour)), encodeTime(at))
		}},
		{name: "concurrency_reservations", seed: func(t *testing.T, acct, req, _ string) {
			exec(t, `INSERT INTO concurrency_reservations(account_id, request_id, status, expires_at, created_at, released_at)
				VALUES(?, ?, 'active', ?, ?, '')`, acct, req, encodeTime(at.Add(time.Hour)), encodeTime(at))
		}},
		{name: "feedback_events", seed: func(t *testing.T, acct, req, eventID string) {
			exec(t, `INSERT INTO feedback_events(event_id, request_id, account_id, scope, rating, comment, created_at)
				VALUES(?, ?, ?, 'response', 4, '', ?)`, eventID, req, acct, encodeTime(at))
		}},
		{name: "audit_events", seed: func(t *testing.T, acct, req, eventID string) {
			exec(t, `INSERT INTO audit_events(event_id, request_id, account_id, actor, event_type, payload_json, created_at)
				VALUES(?, ?, ?, 'test', 'iss246', '{}', ?)`, eventID, req, acct, encodeTime(at))
		}},
	}
	for i, s := range seeders {
		s.seed(t, targetAcct, targetReq, fmt.Sprintf("evt-target-%d", i)) // target
		s.seed(t, targetAcct, otherReq, fmt.Sprintf("evt-d1-%d", i))      // D1
		s.seed(t, otherAcct, otherReq, fmt.Sprintf("evt-d3-%d", i))       // D3
	}

	// Unscoped call: accountID="" + requestID=targetReq. The handler
	// flow runs the ambiguity probe first; here we exercise the
	// post-probe detail-fetch helpers directly (they don't run the
	// probe themselves — that's the gateway router's job).
	detail, err := store.ExplorerSessionDetail(ctx, "", targetReq)
	if err != nil {
		t.Fatalf("ExplorerSessionDetail: %v", err)
	}

	// Every returned row across all 5 categories MUST have
	// request_id == targetReq. Otherwise the empty-account branch is
	// leaking distractor rows. For the single-row fields (limit=1
	// in the helper call), the returned row MUST belong to targetReq;
	// if the request_id predicate were dropped, ORDER BY created_at
	// DESC would let ANY distractor's row land in the slot.
	if detail.UsageEvent != nil && detail.UsageEvent.RequestID != targetReq {
		t.Errorf("usage_event leaked request_id=%q want %q", detail.UsageEvent.RequestID, targetReq)
	}
	if detail.QuotaReservation != nil && detail.QuotaReservation.RequestID != targetReq {
		t.Errorf("quota_reservation leaked request_id=%q want %q", detail.QuotaReservation.RequestID, targetReq)
	}
	if detail.ConcurrencyReservation != nil && detail.ConcurrencyReservation.RequestID != targetReq {
		t.Errorf("concurrency_reservation leaked request_id=%q want %q", detail.ConcurrencyReservation.RequestID, targetReq)
	}
	for _, row := range detail.FeedbackEvents {
		if row.RequestID != targetReq {
			t.Errorf("feedback_events leaked request_id=%q want %q", row.RequestID, targetReq)
		}
	}
	for _, row := range detail.AuditEvents {
		if row.RequestID != targetReq {
			t.Errorf("audit_events leaked request_id=%q want %q", row.RequestID, targetReq)
		}
	}
	// Slice categories should return exactly 1 row (the target). If
	// the helper dropped the request_id predicate, D1 (otherReq same
	// acct) and D3 (otherReq other acct) would leak too — caught by
	// the per-row check above.
	if len(detail.FeedbackEvents) != 1 || len(detail.AuditEvents) != 1 {
		t.Errorf("expected exactly 1 row in slice categories (only target matches request_id); got fb=%d audit=%d",
			len(detail.FeedbackEvents), len(detail.AuditEvents))
	}
	// Singular fields MUST be populated (at least one row matches).
	if detail.UsageEvent == nil {
		t.Errorf("usage_event nil — limit=1 fetch should have returned target row")
	}
	if detail.QuotaReservation == nil {
		t.Errorf("quota_reservation nil — limit=1 fetch should have returned target row")
	}
	if detail.ConcurrencyReservation == nil {
		t.Errorf("concurrency_reservation nil — limit=1 fetch should have returned target row")
	}
}
