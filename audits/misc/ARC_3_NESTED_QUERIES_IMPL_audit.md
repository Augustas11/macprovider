CRITICAL (0):
  (none)

HIGH (0):
  (none)

MEDIUM (1):
  M1. `buyerEquivalentCredits` no longer preserves the 503 skip-before-parse behavior.
      Evidence: phase4-coordinator/internal/billing/endpoints.go:319
      Fix:     Move the `status == http.StatusServiceUnavailable` filter ahead of `time.Parse`, or defer timestamp parsing until the second pass after the 503 filter, so malformed 503 rows remain ignored as on origin/main.

LOW (0):
  (none)

QUESTIONS (0):
  (none)
