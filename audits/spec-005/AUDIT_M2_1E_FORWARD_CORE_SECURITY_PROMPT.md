# M2-1e forwardWithFailover core — SECURITY-lane audit

You are the **security** lane of a three-lane audit (code / security /
architect) of the M2-1e forwardWithFailover core extraction for
issue #94. Stay narrowly in your lane.

## Branch / commit
- Branch: `fix/m2-1e-forward-with-failover-core`
- Worktree: `../macprovider-m2-1e-forward-core` (origin/main base: 4f73f5d)
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/internal/buyer/forward_with_failover.go` (new)
  - `phase4-coordinator/internal/buyer/server.go` (three sequence helpers refactored)
  - `audits/2026-06-10/REMAINING_WORK.md` (ledger update)

## Why security cares about this diff

This is buyer-facing money-path code:
- The three sequence helpers are the chat-completions request hot path.
- The failover state machine determines which provider gets attributed
  for a buyer's request — i.e. which provider gets billed credit, which
  the SPEC-005 ledger keys off `request_log.provider_assigned_id`.
- attempt_n numbering + logAttempt row sequence MUST be byte-identical
  to PR #91 baseline (the issue's load-bearing acceptance criterion).
- The receipt-bearing null-usage early-return path is a money-path
  primitive (preserves the provider's receipt header when the buyer's
  retry budget is exhausted).

## Security-lane scope (apply each; stay in lane)

### SEC-1. Money-path semantics preservation under the refactor
- The 12 row-sequence forward_loop_test scenarios cover the happy-
  paths + 4 failover-from-HTTP-streaming + 1 WS-NS-queue-full +
  WS-NS-failover. Are there OTHER money-path invariants the test
  suite doesn't pin that this refactor could have broken?
  Specifically:
  - WS-non-streaming failoverEligible HIT → no logAttempt at the
    failed provider for the failover row? Pre-refactor at
    server.go:1458 emitted `logAttempt(state.provider, 502, ...)`
    INSIDE the failover-hit branch (BEFORE state.provider = next).
    Confirm the new onFailoverHit callback also emits that row at
    state.provider (the OLD provider) before the core mutates
    state.provider = next.
  - HTTP receipt-bearing null-usage early-return: the receipt header
    + status code propagate to the buyer verbatim. Confirm the new
    callback (inside HTTP dispatch) preserves the header-copy +
    status-code-write order.
  - Cancelled (buyer disconnected mid-stream after first chunk):
    streaming renderCommitted gates the logAttempt on shouldLog-
    Attempt(tr.attempt). Confirm the new callback honors that
    gating (mis-gating would either over-bill or under-bill the
    cancelled-but-committed attempt).

### SEC-2. cancelAttempt lifecycle (HTTP-only)
- HTTP's dispatch callback owns a `cancelAttempt` closure tied to
  the per-attempt context.WithTimeout. Pre-refactor, cancelAttempt
  fired on EVERY exit path (success, terminal, retry-advance,
  read-error, etc.). After refactor, cancelAttempt is local to the
  dispatch closure. Trace all exit paths inside HTTP dispatch and
  confirm cancelAttempt fires on each. Specifically:
  - 200 success with body read error → cancelAttempt fires?
  - 200 success with logProviderRow error → cancelAttempt fires?
  - 200 success normal path → cancelAttempt fires?
  - Receipt-bearing early-return with logProviderRow error → cancel?
  - Receipt-bearing early-return normal → cancelAttempt fires before
    return?
  - Non-200 fall-through path → cancelAttempt fires before classify?
- A missed cancelAttempt is a goroutine + context leak (the timer
  fires harmlessly but the context isn't released). Low-blast but
  diagnose pattern.

### SEC-3. provider_id attribution + billing correctness
- The failover branch in the core: `tx.onFailoverHit(...) →
  failoverAttempted = true → state.provider = next →
  tx.afterFailoverHit(state)`. Confirm `state.provider` at the time
  of `onFailoverHit` is still the FAILED provider (so the WS dead-
  mid-request log + logAttempt-at-502 row carry the failed provider,
  NOT the new one). Pre-refactor at server.go:1457: `next, ok :=
  s.failoverCandidate(...)` → `s.logWSDeadMidRequest(... state.
  provider, "failover", next.ProviderID)` → `logAttempt(state.
  provider, 502, ...)` — both calls use state.provider BEFORE the
  `state.provider = next` mutation at server.go:1460. The new core
  preserves this order? Trace the core's failover branch.
- Could a concurrent call to forwardWithFailover (different buyer
  request, different goroutine) observe an inconsistent state?
  Each call gets its own *forwardState; the core doesn't share
  mutable state with itself across goroutines. Confirm no callback
  closes over a shared mutable variable that two goroutines could
  race on (the closures capture `s *Server`, `r *http.Request`,
  `excluded`, `rec` — all per-request).

### SEC-4. shouldRetry double-call surface in HTTP receipt-bearing path
- HTTP dispatch's receipt-bearing null-usage branch calls
  `s.shouldRetry(r, startedAt, state.explicitRetries, state.
  faultedProviders, status, nil)` to decide whether to early-return.
  If the early-return DOESN'T fire (budget is fresh), dispatch falls
  through; the core's retry-budget gate then calls shouldRetry
  AGAIN with the same arguments. Two consecutive calls with no
  state mutation between them should return the same value. Confirm
  shouldRetry is idempotent (no rate-limit-like side effects that
  count consecutive calls as separate retries).
- The classifier's `tr.err` for HTTP non-200 is `doErr` (the Go
  network error). The core's shouldRetry call uses `tr.err`. In the
  receipt-bearing case, doErr is nil (resp arrived with status code).
  So the core passes nil err; the receipt-bearing inline call passed
  nil err. Both match.

### SEC-5. Logged attribution-row taint
- Each logAttempt / logProviderRow call writes a request_log row.
  After the refactor, the call sites moved from inline branches into
  callbacks (closures). Confirm none of the callbacks accidentally
  log against the WRONG provider (e.g. using state.provider AFTER
  the core mutated it for failover, or using a captured `next`
  variable from an outer scope).
- The new file's onFailoverHit signature passes `next pool.Provider`
  but the WS-NS callback still uses `state.provider` (the OLD
  provider) for logWSDeadMidRequest and logAttempt — confirming the
  core didn't yet mutate state.provider when calling onFailoverHit.

### SEC-6. New surface area in forward_with_failover.go
- The new file adds ~250 lines of Go in a money-path package. Lint
  the file for:
  - any new unchecked error path
  - any new place that could log via fmt.Fprintf to ResponseWriter
    (none expected — writes go through writeError / writeStream-
    ForwardError / explicit w.Write)
  - any panic-on-nil callback (the core has nil-guards before each
    optional callback invocation; verify each guard)
- The `dispatchedAttempt.extra any` field is type-asserted via
  `dispatched.extra.(httpDispatchExtra)` in the HTTP callbacks.
  If a future contributor wires the wrong callback for HTTP (or
  another transport reuses the HTTP callbacks accidentally), this
  type assertion would panic. Is the cost of `any` worth the
  flexibility, or should it be a typed interface? Architect-overlap;
  flag as QUESTION.

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
`specs/M2_1E_FORWARD_CORE_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`
