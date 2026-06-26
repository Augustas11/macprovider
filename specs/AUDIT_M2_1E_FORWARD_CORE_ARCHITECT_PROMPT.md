# M2-1e forwardWithFailover core — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit (code / security /
architect) of the M2-1e forwardWithFailover core extraction for
issue #94. Stay narrowly in your lane.

**This lane has authority to approve / withhold the ARCH-1 / CODE-1
RESOLVED gate** named in the issue's acceptance criteria:

> Architect post-merge verification approves promotion of ARCH-1 /
> CODE-1 to RESOLVED.

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core` (origin/main base: 4f73f5d)
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/internal/buyer/forward_with_failover.go` (new — shared core + transportCallbacks struct + dispatchedAttempt)
  - `phase4-coordinator/internal/buyer/server.go` (three sequence helpers refactored)
  - `audits/2026-06-10/REMAINING_WORK.md` (ARCH-1 / CODE-1 entries removed, M2-1 row → RESOLVED)

## Architect history: what ARCH-1 / CODE-1 named

Original audit (2026-06-10 REPO_AUDIT.md §3.1 item 3):
> handleChatCompletions god-function with three diverging copies of
> failover state machine.

PR #91 (M2-1c) landed three transport-typed sequence helpers but
the failover state machine was still split across helper-local
decision trees. PR #93 (M2-1d) closed the Q3 BLOCKING shared-state-
bypass at WS queue-full but left Q1 open.

Architect verdict on PR #93 named the M2-1e shape:
> Scope M2-1e as extraction of a shared `forwardWithFailover` core,
> or equivalent shared transition core, with transport callbacks for
> dispatch, success/error rendering, committed handling, and WS-to-
> HTTP fallthrough.

## What this branch ships

- `forward_with_failover.go` — new file containing
  `s.forwardWithFailover(...)` (the shared decision-tree core) +
  `transportCallbacks` struct (12 callback fields) +
  `dispatchedAttempt` carrier struct (`tr` + `nativeResult` +
  `success` + `extra any`).
- The three sequence helpers in `server.go` are now thin wrappers
  (~80-120 lines each) that build per-transport callback bundles
  and delegate to the core.
- The audit-flagged INTENTIONAL per-transport differences remain
  flagged in callbacks, not flattened:
  1. HTTP per-attempt `context.WithTimeout` — inside HTTP dispatch
     callback.
  2. WS-non-streaming `failoverEligible+retryable=false` fast-fail —
     `onFailoverMiss` returns handled=true; streaming returns
     handled=false (falls through to shouldRetry).
  3. Streaming committed early-exit — `renderCommitted` callback;
     other transports leave it nil.
  Plus the 4th divergence the test sweep caught (WS-non-streaming
  queue-full skips shouldRetry) is now expressed via
  `skipRetryBudgetCheck` callback.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Does this satisfy the architect's named close-out shape?
- The verdict named "one failover state machine" with "transport
  callbacks for dispatch, success/error rendering, committed
  handling, and WS-to-HTTP fallthrough". Map the named callbacks to
  what shipped:
  - dispatch → `tx.dispatch` ✅
  - success rendering → `tx.renderSuccess` ✅
  - error rendering → `tx.renderRetryExhausted` ✅
  - committed handling → `tx.renderCommitted` ✅
  - WS-to-HTTP fallthrough → `tx.afterAdvance` + `tx.afterFailoverHit`
    (both return `fallThrough bool`) ✅
- The 4 named callbacks plus the 8 additional ones (`handleNon-
  RetryableTerminal`, `onFailoverHit`, `onFailoverMiss`, `skipRetry-
  BudgetCheck`, `logRetryAttempt`, `afterAdvance` overlap). Are any
  of the additional callbacks evidence of leftover decision-tree
  code that should have moved INTO the core?
- Is `skipRetryBudgetCheck` a clean abstraction or a code smell?
  WS-non-streaming queue-full intentionally bypasses shouldRetry per
  the M2-1d-baseline byte-identical contract. The cleanest move
  would be to surface this as a 4th INTENTIONAL per-transport
  difference, properly named, OR to refactor shouldRetry itself so
  the bypass isn't needed. Recommend the right resolution.

### ARCH-2. Is "one failover state machine" actually met?
- Search the new server.go for any remaining `failoverCandidate`
  call. The pre-refactor had 2 such calls (one each in stream +
  WS-NS). Post-refactor, the core has exactly 1; the helpers have 0.
  Confirm.
- Search for any remaining inline `state.provider = next` assignment
  outside the core's failover branch. Pre-refactor had 2 (one each
  in stream + WS-NS failover blocks). Post-refactor: the core has
  exactly 1; the helpers have 0. Confirm.
- The architect's intent: "every retry-semantics edit touches
  exactly one place per transport, not three near-duplicate inline
  loop bodies". Post-1e, where does a retry-semantics edit live?
  - "Change shouldRetry's budget semantics" → buyer/retry.go (out
    of scope, single file already).
  - "Change failover candidate selection" → failoverCandidate
    helper (single function, all callers go through it).
  - "Change advance-to-next-provider mutation order" →
    advanceToNextProvider (single function).
  - "Add a new transport result branch" → classifier + core
    branch + callback addition.
  - "Tighten the HTTP per-attempt context handling" → HTTP
    dispatch callback only.
  - "Change committed-stream semantics" → streaming's
    renderCommitted callback only.
  Does this map satisfy ARCH-1 / CODE-1? IS this RESOLVED, or
  RESOLVED_DIFFERENTLY again?

### ARCH-3. New surface area: cost / benefit
- The new file is ~260 lines (core + types). Each helper shed
  ~80-150 lines of inline decision tree but gained ~80-120 lines
  of callback construction. Net code volume is roughly similar.
  Is the abstraction worth the visual cost?
- The `transportCallbacks` struct has 12 fields. Several are
  optional (nil for some transports). Is the struct shape right
  (large flat callback bag) or should it be split into mandatory
  + optional groups?
- `dispatchedAttempt.extra any` — type-asserted in HTTP callbacks.
  Is this the right escape hatch, or should it be a typed
  interface? Cost: type assertion runtime cost (negligible) +
  miswiring risk (a future contributor wiring HTTP callbacks
  for WS would panic on the type assertion). Recommend a fix
  if the risk is real.

### ARCH-4. Cross-cutting refactors enabled by this shape
- With the core in place, what NEW work is now easier?
  - Adding a new transport (e.g. gRPC streaming): build a new
    callback bundle, no inline-loop duplication.
  - Adding cross-transport instrumentation (e.g. per-attempt
    timing histogram): single place to add.
  - Adding a new failover-eligibility criterion (e.g. "skip failover
    when buyer set X-No-Failover header"): single place to add.
- What's still hard / unchanged?
  - The classifier per-transport (classifyStreamResult,
    classifyWSResult, classifyHTTPResult) remains separate; their
    transportResult flag matrix is the actual decision encoding.
  - The handler-level wiring (handleChatCompletions dispatches to
    one of three sequence helpers based on stream + WS-tunneled)
    remains. Should that dispatch ALSO move into the core?

### ARCH-5. Doc trail
- `audits/2026-06-10/REMAINING_WORK.md` strip-out of ARCH-1 / CODE-1
  per the doc contract — correct per the issue's acceptance criteria
  ("RESOLVED items do not appear")?
- The 2026-06-26 sweep update note at line 5 added by this branch
  documents the M2-1e flip. Is the wording precise enough that a
  future reader unfamiliar with the M2-1 arc understands what
  shipped and what it closed?
- M2-1 task table row updated to `RESOLVED`. Correct?
- Is there ANYTHING in the M2-1e shape that should be tracked as
  follow-up (i.e. a NEW finding to add to REMAINING_WORK.md)? E.g.
  the architect's question on handleChatCompletions dispatch moving
  INTO the core (ARCH-4 above) — should that become an M2-1f issue?

### ARCH-6. Architect verdict
- Based on ARCH-1 through ARCH-5, does this branch warrant
  promotion of ARCH-1 / CODE-1 from `RESOLVED_DIFFERENTLY` to
  `RESOLVED`?
- If yes, state so in the verdict line.
- If no, name the specific gap and the smallest delta needed to
  close it.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/M2_1E_FORWARD_CORE_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM AND ARCH-1/CODE-1 can promote to RESOLVED,
end with:
`VERDICT: architect lane READY TO MERGE — ARCH-1 / CODE-1 → RESOLVED`

If 0 C/H/M but RESOLVED gate withheld for a substantive architect
reason, end with:
`VERDICT: architect lane READY TO MERGE — ARCH-1 / CODE-1 stay
RESOLVED_DIFFERENTLY pending <one-line gap>`
