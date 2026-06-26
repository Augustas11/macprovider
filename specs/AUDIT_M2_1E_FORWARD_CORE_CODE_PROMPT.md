# M2-1e forwardWithFailover core — CODE-lane audit

You are the **code** lane of a three-lane audit (code / security /
architect) of the M2-1e forwardWithFailover core extraction for
issue #94. Stay narrowly in your lane.

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core` (origin/main base: 4f73f5d)
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/internal/buyer/forward_with_failover.go` (new — shared core + transportCallbacks)
  - `phase4-coordinator/internal/buyer/server.go` (three sequence helpers now thin wrappers)
  - `audits/2026-06-10/REMAINING_WORK.md` (ARCH-1 / CODE-1 entries removed; M2-1 row → RESOLVED)

## What the change does (operator summary — NOT the audit answer)

Issue #94 (M2-1e) is the architect's named close-out for ARCH-1 /
CODE-1 on top of M2-1c (PR #91, three-sequence-helper landing) + M2-1d
(PR #93, Q3 shared-state-bypass close-out). The architect verdict on
PR #93 named the shape:

> Scope M2-1e as extraction of a shared `forwardWithFailover` core, or
> equivalent shared transition core, with transport callbacks for
> dispatch, success/error rendering, committed handling, and WS-to-HTTP
> fallthrough.

This branch ships:
- `forward_with_failover.go` — new file containing `forwardWithFailover`
  (the shared decision-tree core) + `transportCallbacks` struct + the
  `dispatchedAttempt` carrier type.
- `forwardStreamSequence`, `forwardWSNonStreamSequence`,
  `forwardHTTPSequence` — now thin wrappers that build per-transport
  callbacks and delegate to the core.

Acceptance criteria (from the issue):
- `forward_loop_test.go` 12 row-sequence scenarios byte-identical to
  PR #91 baseline ✅
- `go test ./internal/buyer -race -count=5` green ✅ (10.5s)
- Three audit-flagged INTENTIONAL per-transport differences remain
  flagged in callbacks, not flattened.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Decision-tree semantics preservation
For each of the three migrated sequences, trace one execution path
end-to-end against the pre-refactor inline behavior.
- WS-non-streaming queue-full path: pre-refactor at server.go:1466-
  1493 (before this branch). After refactor: classifier sets markBusy
  + retryable=true; core marks fault state + MarkState; the new
  `skipRetryBudgetCheck` callback returns true for wsForwardQueueFull
  so shouldRetry is bypassed; logRetryAttempt logs at 502; advance
  fires; afterAdvance returns true if next provider is non-WS. Confirm
  this path matches forward_loop_test scenario
  TestM2_1D_RowSequence_WSNonStreamingQueueFullThroughAdvance
  byte-for-byte (logAttempt row sequence, retried bumps, status codes).
- WS-non-streaming failoverEligible miss: pre-refactor at server.go:
  1444-1455 (fast-fail with 502, NO shouldRetry consultation). After
  refactor: core fires failover branch; on miss, onFailoverMiss
  returns handled=true after rendering 502 + logging fast_fail. Trace
  through the core's failover branch — `tx.onFailoverMiss(...) → if
  handled return false` correctly bypasses shouldRetry?
- Streaming HTTP (non-WS) pre-chunk disconnect: pre-refactor at
  server.go:1337 was `if tr.failoverEligible && wsTunneled` —
  HTTP-streaming SKIPS the failover branch and falls through to
  shouldRetry+advance. After refactor: the streaming dispatch
  callback explicitly clears `tr.failoverEligible` when
  `!wsTunneled`. Confirm this preserves the byte-identical row
  sequence in TestM92_RowSequence_HTTPStreaming* (4 scenarios: zero-
  body, one-byte-partial, comment-only, [DONE]-only). The test
  expectation is "row 0 status=502 retried=0 for bad provider, row 1
  status=200 retried=1 for ok provider" — driven by advance, NOT
  failover.
- HTTP success path: lives ENTIRELY inside the HTTP dispatch
  callback (writes body + headers + logs row + returns ok=false).
  The core's success branch is unused for HTTP. Confirm there's no
  path that could double-render or skip the cancelAttempt cleanup.
- HTTP receipt-bearing null-usage early-return: lives inside the
  HTTP dispatch callback, before the fall-through path. Confirm
  shouldRetry is called only once (not duplicated between dispatch
  and the core's shouldRetry gate) for this path. If the early-return
  fires, dispatch returns ok=false → core returns immediately. If it
  doesn't fire, dispatch falls through to classify+return ok=true
  with extra populated; the core then calls shouldRetry again with
  the classified status — that's a second call but with the same
  buyer-budget state.

### CODE-2. Core function correctness
- `forwardWithFailover` (forward_with_failover.go) — branch order:
  dispatch → committed (streaming-only) → non-retryable terminal
  short-circuit (WS-NS-only) → success → fault state mutations →
  failover branch (failoverEligible) → retry budget gate (with
  skipRetryBudgetCheck opt-out) → logRetryAttempt → advance →
  afterAdvance. Is this the correct decision-tree order? Is there
  any path where two callbacks fire when one should?
- `state.provider = next` mutation in the failover branch lives in
  the CORE (line ~115 of forward_with_failover.go), not in
  onFailoverHit callback. Confirm callbacks don't ALSO mutate
  state.provider (would be a double-mutation bug).
- `failoverAttempted` flag in the core — never set to false again;
  scoped to a single forwardWithFailover invocation. Correct?
- The shared `excluded[routeKey(state.provider)] = struct{}{}` after
  the success branch — happens BEFORE the failover/retry branches.
  Pre-refactor inlined this in each helper. Confirm no ordering
  changes (e.g. the excluded-add must precede failoverCandidate so
  the candidate isn't the failed provider).

### CODE-3. Callback bundle completeness
- Each migrated helper provides a transportCallbacks struct. Are
  there any fields the helper FORGOT to set that the core might
  invoke? E.g.:
  - HTTP doesn't set onFailoverHit / onFailoverMiss / afterFailover-
    Hit — because HTTP's classifyHTTPResult never sets
    failoverEligible. Confirm the classifier truly never sets it,
    so the core's `if tr.failoverEligible && tx.onFailoverHit !=
    nil && tx.onFailoverMiss != nil` guard correctly short-circuits.
  - Streaming doesn't set handleNonRetryableTerminal — because
    classifyStreamResult covers Cancelled via committed=true (not
    via the WS-NS-style short-circuit). Confirm.
  - WS-NS doesn't set renderCommitted — because classifyWSResult
    never sets committed=true for non-streaming. Confirm.
- The streaming dispatch's `if !wsTunneled { tr.failoverEligible =
  false }` line: is this the cleanest place for that gate, or should
  it live in the classifier? Architect-overlap — flag as QUESTION,
  not MEDIUM.

### CODE-4. Byte-identical contract
- The 12 forward_loop_test scenarios pass post-refactor. List the
  scenarios and the path each exercises:
  1. HTTP success first-attempt (forwardHTTPSequence success branch)
  2. HTTP retry-to-success (HTTP shouldRetry + advance)
  3. Streaming committed single-row (streaming renderCommitted)
  4. WS-non-streaming failover doesn't bump retried (WS-NS failover-
     Hit + afterFailoverHit fallthrough)
  5-9. HTTP streaming failover scenarios (5 sub-cases: zero-body,
     one-byte-partial, slow-first-event-commits, comment-only,
     [DONE]-only, usage-only-first-chunk-commits)
  10. WS-non-streaming queue-full through advance (M2-1d skip-
      RetryBudgetCheck path)
  Are there OTHER row-sequence-sensitive paths not covered by these
  12 scenarios that the refactor could have broken? Specifically:
  - HTTP receipt-bearing null-usage early-return (no test).
  - HTTP non-200 + retry-budget-exhausted (no specific test? exists
    in TestForwardLoop_HTTP_RetryExhausted?).
  - WS-non-streaming cancelled + shouldLogAttempt true vs false.

### CODE-5. Comment quality + maintainability
- Each callback closure carries a 3-5 line comment justifying its
  per-transport divergence. Comments justifying NON-OBVIOUS code
  (the retryable/failoverEligible matrix, the cancelAttempt lifetime,
  the skipRetryBudgetCheck rationale) are good; comments restating
  what the code does are noise.
- The new file forward_with_failover.go opens with a doc block
  enumerating the three INTENTIONAL divergences. Is the wording
  precise enough that an editor unfamiliar with the audit history
  would understand WHY each callback exists?

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
`specs/M2_1E_FORWARD_CORE_CODE_audit.md` (round suffix on follow-ups).

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
