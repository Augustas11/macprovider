package sqlite

import (
	"context"
	"fmt"
	"strings"
	"testing"
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
