CRITICAL (0):
  None.

HIGH (0):
  None.

MEDIUM (1):
  C1. rebuildLegacyConfigSnapshots cap=1 regression test does not exercise the legacy nested-cursor path
      Evidence: phase4-coordinator/internal/billing/nested_query_regression_test.go:59
      Fix:     In the test, create a legacy unique index on ledger_config_snapshots(config_hash) before calling rebuildLegacyConfigSnapshots, so the loop must run PRAGMA index_info after the outer PRAGMA index_list cursor is closed.

LOW (2):
  L1. buyerEquivalentCredits deadlock regression uses only one request_log outer row
      Evidence: phase4-coordinator/internal/billing/nested_query_regression_test.go:115
      Fix:     Insert at least two request_log rows in the cap=1 reconcile test, preferably including the non-byte-estimated snapshotAt path and a 503 row with malformed tsText to lock the r2 timestamp-filter behavior.

  L2. buyerEquivalentCredits test comment describes parsed time even though the fix intentionally carries raw tsText
      Evidence: phase4-coordinator/internal/billing/nested_query_regression_test.go:113
      Fix:     Update the comment to say the scratch slice carries request_log scalars plus raw ts text, then parses only after the 503 filter.

QUESTIONS (1):
  Q1. requestlog.OpenStore comment names "admission" as sharing the DB, but this worktree has no phase4-coordinator/internal/admission package
      Evidence: phase4-coordinator/internal/requestlog/store.go:69
      Fix:     Confirm with the architect lane whether "admission" is stale terminology or an external component name; if stale, remove it from the comment.
