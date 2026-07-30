# Session direct-push audit R3 — CODE lane

You are the **code** lane. R2 CODE returned FAIL with one MEDIUM
(CODE-R2-M-1: cascade re-signals itself). R3 fires against the R2 fix.

R2 SECURITY lane passed and is not re-fired per the skip-accepted-audit-lanes
rule (SECURITY scope was not touched by the R2→R3 fix).

Convergence bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** in CODE + ARCH.

## Scope — what changed since R2

Worktree: `/Users/augstar/macprovider-poc-r1fix/` on branch
`fix/session-r1-orphan-and-ws-url` (base = `origin/main` at `2b7021b`).

Single new commit above R2:

**`983ddb3` — fix(autotune): make signal cascade one-shot (R2 CODE-R2-M-1 / ARCH-R2-M-1)**

- `phase3-binary/Sources/macprovider-cli/AutotuneRuntimeSupport.swift`
  - New `AutotuneCascadeGate` — `NSLock`-guarded `Bool` latch with
    `trip() -> Bool` returning `true` exactly on the first call and
    `false` on every subsequent call, plus `hasTripped() -> Bool` for
    tests.
  - `AutotuneSignalSources` now owns a `cascadeGate: AutotuneCascadeGate`.
    Both SIGINT and SIGTERM handlers check `gate.trip()` BEFORE calling
    `Darwin.killpg(0, SIGTERM)`, so only the first signal cascades.
- `phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift`
  - `testAutotuneCascadeGateTripsExactlyOnce` — sequential contract.
  - `testAutotuneCascadeGateIsThreadSafeUnderContention` — 64
    concurrent `trip()` calls; asserts exactly one true.

Everything from R1 (`f7d44f9`, `cfc0efe`) and the audit artifact commits
is untouched.

## Code-lane R3 scope (apply each; stay in lane)

### CODE-R3.1 — CascadeGate correctness

- Verify `trip()` semantics: locked check-then-set is race-free.
- Verify `hasTripped()` returns the current state without altering it
  (not a Compare-And-Swap side effect).
- Confirm the gate is created per-instance (each `AutotuneSignalSources`
  gets its own gate). If someone later refactors to a shared static
  gate, that would be wrong for multiple recommend-path lifetimes in
  a single CLI process (currently N/A because the CLI exits after
  --recommend, but pin the contract).

### CODE-R3.2 — Signal handler idempotency

- Trace: App fires `kill(cliPid, SIGTERM)`. CLI's SIGTERM dispatch
  source runs its handler. Handler flags interrupt, checks
  `gate.trip()` — returns true. Handler calls `killpg(0, SIGTERM)`.
  Every process in the group (including CLI) receives SIGTERM.
- CLI's SIGTERM handler fires AGAIN due to the self-signal (`SIG_IGN`
  does not mask DispatchSourceSignal). Handler flags interrupt (no-op),
  checks `gate.trip()` — returns false. Handler no-ops. Cascade
  contained.
- What if SIGINT arrives first, then SIGTERM (e.g. user Ctrl-C then
  App terminate)? SIGINT handler trips gate, cascades via SIGTERM.
  SIGTERM handler fires; gate returns false; no re-cascade. Verify
  this is the intended behavior — is losing the SIGTERM cascade a
  problem? (No, because SIGINT already cascaded SIGTERM to the group,
  which is what SIGTERM would have done anyway.)
- What if both handlers fire ALMOST SIMULTANEOUSLY? Signal queue is
  a serial dispatch queue (`"autotune.signal"`) so handlers run
  serialized. The lock inside `trip()` is redundant against the queue
  but not incorrect — belt-and-suspenders for future queue changes.

### CODE-R3.3 — CascadeGate visibility / API surface

- `cascadeGate: AutotuneCascadeGate` — declared `let` (not `private`).
  Was this intentional (so tests can inspect via a public reference)?
  Currently only tests use `AutotuneCascadeGate.hasTripped()`.
  Restrict to `private(set)` or private if not needed publicly.
- `AutotuneCascadeGate` class itself is package-private (no `public`
  modifier). Correct for the test-target `@testable import` pattern.

### CODE-R3.4 — Test adequacy

- `testAutotuneCascadeGateTripsExactlyOnce` covers the sequential
  contract fully.
- `testAutotuneCascadeGateIsThreadSafeUnderContention` — 64 dispatches
  to global queue. Are 64 concurrent tasks realistic contention? At
  minimum enough to blow up on unlocked check-then-set. Good.
- Missing coverage:
  - No test asserts that `AutotuneSignalSources.init(cascadeToProcessGroup:
    false)` NEVER trips the gate (cheap invariant to pin).
  - No test asserts that after `trip()` returns true, the actual
    `killpg` call happens (would require dependency injection for
    `killpg`; deferred to end-to-end integration test per commit body).

### CODE-R3.5 — No regressions in existing paths

Grep the R2→R3 diff for anywhere that could affect callsites outside
`AutotuneSignalSources`:

- `AutotuneCommand.runAutotuneRecommend()` — still constructs sources
  with `cascadeToProcessGroup: true`. Unchanged.
- Any other caller of `AutotuneSignalSources` — grep. The non-recommend
  autotune path uses `AutotuneSignalSources(flag:)` with default
  `cascadeToProcessGroup: false`. Verify that path still gets zero
  cascade behavior.

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r3-code-findings.md`:

```
# Session direct-push R3 — CODE lane findings

## Verdict
PASS / FAIL

## Findings
### CODE-R3-C-1 (CRITICAL) <title>
### CODE-R3-H-1 (HIGH) <...>
### CODE-R3-M-1 (MEDIUM) <...>
### CODE-R3-L-1 (LOW) <...>
### CODE-R3-I-1 (INFO) <...>
```

If verdict is PASS, write a one-paragraph "what I looked at" narrative
and an empty findings list.
