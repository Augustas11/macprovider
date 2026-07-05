# Session direct-push audit R3 — ARCHITECT lane

You are the **architect** lane. R2 ARCH returned FAIL with one MEDIUM
(ARCH-R2-M-1: cascade re-signals itself). R3 fires against the R2 fix.

R2 SECURITY lane passed and is not re-fired.

Convergence bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** in CODE + ARCH.

## Scope — what changed since R2

Worktree: `/Users/augstar/macprovider-poc-r1fix/` on branch
`fix/session-r1-orphan-and-ws-url` (base = `origin/main` at `2b7021b`).

Single new commit above R2:

**`983ddb3` — fix(autotune): make signal cascade one-shot (R2 CODE-R2-M-1 / ARCH-R2-M-1)**

- New `AutotuneCascadeGate` class in `AutotuneRuntimeSupport.swift`:
  `NSLock`-guarded Bool latch, `trip()` returns `true` on first call
  then `false` on every subsequent call.
- `AutotuneSignalSources` now holds one gate per instance; both
  SIGINT and SIGTERM handlers check `gate.trip()` before cascading.
- Unit tests pin the one-shot + thread-safe contracts.

## Architect-lane R3 scope (apply each; stay in lane)

### ARCH-R3.1 — Does the R3 fix close Case A?

R2 ARCH-R2.1 Case A verdict was **OPEN** because the cascade wasn't
idempotent. The R3 fix adds the CascadeGate. Verify:

- App fires `kill(cliPid, SIGTERM)` → CLI SIGTERM handler → cascade
  once via `killpg(0, SIGTERM)` → children die AND CLI self-signals
  → CLI SIGTERM handler fires again → `gate.trip()` returns false →
  no-op → CLI benchmarker exits (interrupt flag) → CLI process exits.
  Trace the full sequence and confirm no runaway signal loop, no
  wasted syscalls beyond a single cascade, no missed grandchild
  teardown.
- Re-state ARCH-R2.1 with fresh verdicts for Case A / B / C after R3.

### ARCH-R3.2 — Design coherence of CascadeGate

- Is a single-purpose `AutotuneCascadeGate` the right abstraction, or
  should it be a general-purpose `OneShotLatch` shared across the
  codebase? Judge on YAGNI vs consistency.
- `cascadeGate` is `let` (package-visible) on `AutotuneSignalSources`.
  Tests read via `hasTripped()`. Is this the right visibility, or
  should it be private-per-source with a wrapping `hasCascaded()`
  method on `AutotuneSignalSources` for tests?
- Any risk that a future refactor to a shared-static gate would break
  multiple recommend-path lifetimes in one CLI process (currently
  impossible because CLI exits after --recommend, but pin the
  contract)?

### ARCH-R3.3 — Signal cascade vs alternative designs

The R3 fix is the minimum surgical patch. Are there alternative
designs that would be structurally cleaner (evaluate briefly, don't
demand a rewrite):

- (a) Cancel the SIGTERM dispatch source before calling `killpg` so
  the self-signal is dropped. Trade-off: subsequent SIGINT events
  still fire, but there's no separate SIGINT cascade path if SIGTERM
  disarmed itself. Probably worse than the gate.
- (b) Send `killpg` to a NEGATIVE pgid excluding self — POSIX doesn't
  offer this. Would need to iterate children via `procfs`
  (unavailable on macOS) or maintain a child PID list. More invasive.
- (c) Change the signal handler to `pthread_sigmask(SIG_BLOCK)` for
  SIGTERM before `killpg` and unblock after. Complexity increase
  without a clear win over the gate.

Given (a)-(c), is the gate the right choice? Judge.

### ARCH-R3.4 — Remaining LOW / INFO items from R2

R2 ARCH-R2-L-1 (App-side subtree tests don't prove grandchild
teardown) — status? Still LOW. Not blocking. Cite as follow-up.

R2 ARCH-R2-L-2 (Process-group leadership contract not pinned by
tests) — status? Still LOW. Not blocking. Cite as follow-up.

R2 ARCH-R2-I-1 (Optional interrupt flag OK for current shape) —
still INFO. No change needed.

R2 ARCH-R2-I-2 (Register validator design OK) — still INFO.

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r3-architect-findings.md`:

```
# Session direct-push R3 — ARCHITECT lane findings

## Verdict
PASS / FAIL

## ARCH-R3.1 verification (orphan scenario closure after cascade gate)
- Case A (normal App quit): CLOSED / OPEN — reason
- Case B (CLI hang): CLOSED / OPEN — reason
- Case C (App SIGKILL): CLOSED_DEFERRED / OPEN — reason

## Findings
### ARCH-R3-C-1 (CRITICAL) <title>
### ARCH-R3-H-1 (HIGH) <...>
### ARCH-R3-M-1 (MEDIUM) <...>
### ARCH-R3-L-1 (LOW) <...>
### ARCH-R3-I-1 (INFO) <...>
```

If verdict is PASS, write a narrative + ARCH-R3.1 verification block.
