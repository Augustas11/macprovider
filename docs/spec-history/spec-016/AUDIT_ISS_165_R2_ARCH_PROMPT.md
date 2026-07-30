# Audit: ISS-165 R2 architect lens — fix pass on R1 findings

R1 returned 3 HIGH + 1 MEDIUM + 1 LOW (arch). R2 verifies on
commit `a5e9e34`. Tree: `spec/iss-165-spec-016-followups`.

## R1 ARCH findings to verify

- **HIGH-1**: A2 Evaluate cadence vs window. Fix: independent
  `(*ChronicOutageTracker).Run(ctx)` goroutine ticking at
  `min(window/2, 1min)`.
- **HIGH-2 (convergent with code)**: SPKI wrapper type assertion.
  Fix: idleCloser interface + `(*trackingRPC).CloseIdleConnections()`.
- **HIGH-3**: §9 BetterStack runbook missing event names. Fix:
  both new events added to alert-filter list.
- **MEDIUM**: `max_rows_per_run` shared budget overload. Fix:
  normative paragraph in v0.1.22 change-log documenting the shared
  cap; bound `[1, 500]` unchanged.
- **LOW**: backlog WARN repeats every cycle. Documented in the
  change-log as intentional per-cycle gauge (operator-actionable).

## What I want (R2 arch lens)

Verify each closure stuck. Look for:

- Does `Run()` interact correctly with `payoutS2.stop()` shutdown
  flow? (It hooks off shutdownCtx, no explicit stop.)
- Does the SPEC v0.1.22 normative paragraph contradict any existing
  §payout.tuning prose elsewhere in the body?
- Is the §9 runbook entry sufficient (just the event names + a
  one-line description) or should there be a runbook page anchor?
- Does the wrapper's `CloseIdleConnections()` cover BOTH primary
  AND secondary, and is the interface assertion at the SIGHUP
  handler exhaustive across future RPCClient implementations
  (e.g. a mock that doesn't implement the method)?
- The R1 SEC fix changed `total_candidates` from "pre-cycle count"
  to "remaining un-paged" without restating that change at the
  §4.7 step-5 prose level. Audit-trail risk: future readers of
  this PR diff vs the v0.1.22 SPEC paragraph could be confused.
  Verify the SPEC paragraph names the post-production semantics
  clearly.

Find new ARCH defects. Same severity + output format. End with
`## Convergence X/X/X/X → DECISION`.
