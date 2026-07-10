CRITICAL (0):
  (none)

HIGH (0):
  (none)

MEDIUM (0):
  (none)

LOW (3):
  L1. Name the retry-budget bypass as the fourth intentional transport divergence
      Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:155
      Fix:     Keep the behavior non-blocking, but prefer a classifier-owned flag such as `advanceWithoutRetryBudget` or a prominently named "INTENTIONAL difference #4" note so queue-full bypass semantics are data, not callback policy.

  L2. Split the callback bag if this core grows another transport or result branch
      Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:204
      Fix:     Leave the current flat `transportCallbacks` struct for M2-1e, but split mandatory callbacks from optional divergence hooks before adding a fourth transport or more terminal branches.

  L3. Replace `extra any` before HTTP callback reuse becomes likely
      Evidence: phase4-coordinator/internal/buyer/forward_with_failover.go:348
      Fix:     Keep the current escape hatch for this branch, but replace it with a typed per-attempt payload interface or transport-specific wrapper before contributors start composing HTTP and WS callback pieces.

QUESTIONS (0):
  (none)

ARCHITECT GATE:
  The branch satisfies the named M2-1e close-out shape. The shared core owns the loop and transition order: dispatch, committed early-exit, terminal short-circuit, success, fault marking, failoverCandidate, retry-budget check, advanceToNextProvider, and WS-to-HTTP fallthrough all flow through `forwardWithFailover`.

  Callback mapping is complete:
  - dispatch: `tx.dispatch` at phase4-coordinator/internal/buyer/forward_with_failover.go:68
  - success rendering: `tx.renderSuccess` at phase4-coordinator/internal/buyer/forward_with_failover.go:107
  - error rendering: `tx.renderRetryExhausted` at phase4-coordinator/internal/buyer/forward_with_failover.go:165
  - committed handling: `tx.renderCommitted` at phase4-coordinator/internal/buyer/forward_with_failover.go:82
  - WS-to-HTTP fallthrough: `tx.afterFailoverHit` and `tx.afterAdvance` at phase4-coordinator/internal/buyer/forward_with_failover.go:137 and phase4-coordinator/internal/buyer/forward_with_failover.go:190

  The additional callbacks are not evidence of three leftover inline state machines. They carry transport-specific rendering, logging, terminal envelopes, and fallthrough behavior while the core owns shared mutation order. The only design smell is `skipRetryBudgetCheck`: it is a real preserved transport divergence, not a blocker, but it should be documented as the fourth intentional difference or moved into a classifier-owned flag.

ONE STATE MACHINE CHECK:
  Confirmed by search: the only executable `failoverCandidate` call is in the shared core at phase4-coordinator/internal/buyer/forward_with_failover.go:132. The helper mentions are comments around callback construction, not calls.

  Confirmed by search: the failover same-attempt provider mutation is centralized at phase4-coordinator/internal/buyer/forward_with_failover.go:136. The other executable provider assignments are initial route selection at phase4-coordinator/internal/buyer/server.go:1220 and normal retry advance at phase4-coordinator/internal/buyer/server.go:1767.

  Retry-semantics edits now have a single owner by category: budget semantics in `shouldRetry` at phase4-coordinator/internal/buyer/server.go:3323, candidate selection in `failoverCandidate` at phase4-coordinator/internal/buyer/server.go:2886, advance mutation in `advanceToNextProvider` at phase4-coordinator/internal/buyer/server.go:1748, and cross-transport loop order in `forwardWithFailover` at phase4-coordinator/internal/buyer/forward_with_failover.go:51.

COST / BENEFIT:
  The abstraction is worth the visual cost. Net code volume is similar, but the previous drift risk was not line count; it was three places owning retry/failover transition order. This branch moves that order into one function while preserving the audit-flagged transport differences in explicit callback bundles.

  The `transportCallbacks` shape is acceptable for this close-out because all optional hooks map to known divergences. It should not be treated as an open-ended extension point: adding a new transport should trigger a small interface cleanup first.

  The `dispatchedAttempt.extra any` risk is real but low. The current type assertions are limited to HTTP callbacks at phase4-coordinator/internal/buyer/server.go:1698 and phase4-coordinator/internal/buyer/server.go:1712, so miswiring would be caught quickly in tests or panic visibly. This does not block the gate.

CROSS-CUTTING FOLLOW-UP:
  New work made easier: adding another transport can be done by adding a classifier/callback bundle instead of cloning the loop; cross-transport per-attempt instrumentation can be inserted in the core; failover eligibility policy changes have one core branch plus classifier inputs to update.

  Still hard/unchanged: classifier semantics remain the true transport decision matrix at phase4-coordinator/internal/buyer/transport_result.go:85, phase4-coordinator/internal/buyer/transport_result.go:125, and phase4-coordinator/internal/buyer/transport_result.go:184. Handler-level stream / WS / HTTP dispatch remains in `handleChatCompletions` at phase4-coordinator/internal/buyer/server.go:1231. That dispatch should not move into the core now; it chooses transport family before the failover loop starts and does not duplicate retry/failover state transitions.

DOC TRAIL:
  The `REMAINING_WORK.md` strip-out is correct under the stated doc contract: RESOLVED and RESOLVED_DIFFERENTLY items do not appear in the severity punch list. The 2026-06-26 sweep note is precise enough for a future reader: it names M2-1e, the shared core, the three thin wrappers, the transition chain, and the preserved intentional differences at audits/2026-06-10/REMAINING_WORK.md:7. The M2-1 task row is correctly marked `RESOLVED` at audits/2026-06-10/REMAINING_WORK.md:89.

VALIDATION:
  Ran `go test ./internal/buyer -run 'TestM2_1C|TestM92|TestM2_1D' -count=1` from `phase4-coordinator`; result: pass.

VERDICT: architect lane READY TO MERGE — ARCH-1 / CODE-1 → RESOLVED
