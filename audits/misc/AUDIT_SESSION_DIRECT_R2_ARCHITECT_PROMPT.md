# Session direct-push audit R2 — ARCHITECT lane

You are the **architect** lane verifying the R1 → R2 fixes for
SEC-M-1 (coordinator_ws_url validator) and ARCH-M-1 (autotune
orphan-child SIGTERM cascade). R1 ARCH lane returned FAIL with one
MEDIUM (ARCH-M-1). R2 must verify the fix closes the design concern
without introducing new coupling issues.

Convergence bar: **0 CRITICAL, 0 HIGH, 0 MEDIUM findings** across all
three lanes.

## Scope — what changed since R1

Worktree: `/Users/augstar/macprovider-poc-r1fix/` on branch
`fix/session-r1-orphan-and-ws-url` (base = `origin/main` at `2b7021b`).

Two new commits:

1. **`f7d44f9` SEC-M-1** — `RegisterClient.validateCoordinatorWSURL`
   after decode, `RegisterClientError.invalidCoordinatorWSURL(reason:)`.
2. **`cfc0efe` ARCH-M-1** — CLI `--recommend` becomes pgid leader
   with cascading SIGTERM handler; App uses new
   `AutotuneRecommendationRunner.terminateAutotuneSubtree(process:graceSeconds:)`
   (SIGTERM → grace → killpg SIGKILL fallback) both on timeout and
   error paths; benchmarker respects an optional `AutotuneInterruptFlag`.

## Architect-lane scope (apply each; stay in lane)

### ARCH-R2.1 — Does ARCH-M-1 fix actually close the orphan scenario?

The R1 architect finding traced one concrete orphan chain:

```
App → AutotuneRecommendationRunner (Foundation.Process)
    → macprovider-cli autotune --recommend --json (CLI)
        → CandidateProviderRunner (Foundation.Process)
            → macprovider-cli serve --no-join (grandchild model runtime)
```

Case A — **normal App quit / runner timeout**: App calls
`process.terminate()` → SIGTERM to CLI → CLI cascade handler →
`killpg(0, SIGTERM)` → children die → CLI unwinds → App observes
exit. **Verify this closes case A end-to-end**, tracing the exact
signal delivery order.

Case B — **CLI hangs on SIGTERM**: App's grace expires, App fires
`killpg(cliPid, SIGKILL)` + `kill(cliPid, SIGKILL)`. **Verify this
closes case B**, especially the `killpg(cliPid, ...)` semantics: only
works if `setpgid(0, 0)` has run in the CLI. The App-side fallback
`kill(cliPid, SIGKILL)` handles the race window before `setpgid`
executes but leaves grandchildren orphaned in that specific window.
Judge whether the race is realistic (the App enforces a 5 s grace
before escalating; `setpgid` runs BEFORE any child is spawned so the
race is only if the CLI hangs BEFORE its first pgid-affecting syscall,
which is essentially a corrupted binary case). Rate residual risk.

Case C — **App itself SIGKILLed**: neither the App nor the CLI sees
any signal. CLI's parent-death is not detected. Grandchildren survive
until manual `pkill`. The commit body explicitly defers this as
ARCH-M-1-followup. Is that acceptable for this convergence, or should
this stay open as a MEDIUM until closed?

### ARCH-R2.2 — Does the fix introduce new coupling debt?

- The App and CLI now share an implicit contract: the CLI MUST
  become pgid leader before any subprocess spawn, and MUST install
  the cascade handler. If someone edits `runAutotuneRecommend()` in
  the future and drops the `setpgid` call, the App's SIGKILL
  fallback still works but graceful teardown regresses. Is that
  contract discoverable? Is there a comment / test / assertion
  that pins it?
- The interrupt flag is threaded through the benchmarker as an
  optional parameter. Any future caller of
  `AutotuneRecommendationBenchmarker.benchmarks(...)` who omits it
  gets no interrupt semantics. Should the flag be required (positive
  contract) or optional (permissive, easy to forget)?
- The App's `terminateAutotuneSubtree` uses raw `Darwin.killpg` /
  `Darwin.kill`. Foundation.Process is not aware of this out-of-band
  signaling. Any risk that Foundation's state (e.g. its wait4
  bookkeeping) gets confused? Trace whether `process.waitUntilExit()`
  still cleanly reaps.

### ARCH-R2.3 — SEC-M-1 fix as an architecture question

- The validator lives in `RegisterClient` — an HTTP client
  responsibility. That's the right place. But note the register base
  URL is set by the caller (LaunchProviderController), NOT constant-
  pinned to `coordinator.malibu.tech`. The validator only enforces
  "same origin as registrar base URL", not "= production coordinator".
  Is that the right contract? Pros: dev/test flexibility. Cons: if
  someone accidentally instantiates `RegisterClient(coordinatorBaseURL:
  attacker-controlled-URL)`, the validator does nothing. Judge whether
  this is a real risk or overreach for a defensive layer.
- The prod pinned URL still lives in OnboardingWindow.swift:33 as a
  bare `URL(string:)!` — no code path uses env override or config for
  dev. Confirm that on-disk-config-based URL overrides can't easily
  slip in via future refactors.

### ARCH-R2.4 — SPEC-026 alignment

The R1 architect lane raised ARCH-L-3 asking for a SPEC-026 follow-up
codifying the identity-signature bridge contract. The R2 fixes don't
touch that bridge, so no new SPEC-026 divergence to flag there — but
does the new coordinator-WS-URL validator warrant a SPEC-026 note
(e.g. "register response coordinator_ws_url MUST be same-origin with
the registrar base URL")? Recommend an update or judge it not
worth churn.

### ARCH-R2.5 — Test infrastructure coherence

The new tests spawn real subprocesses via `/bin/sh`. They're
integration-flavored but live in the unit-test bundle. That's a
pragmatic choice given the scope, but flakiness risk:
- Timing assertions in
  `testTerminateAutotuneSubtreeSIGKILLEscalatesWhenChildIgnoresSIGTERM`
  (elapsed ≥ 0.4 s and < 5 s) — are those bounds robust on a loaded
  CI runner?
- No sanitizer / instrumentation confirms grandchild teardown; only
  the immediate child is asserted dead. That's OK for the immediate
  regression, but the design is that grandchildren die too. A future
  regression that removes the cascade handler without removing
  setpgid would pass these tests but leave grandchildren orphaned.
  Should the test set spawn a `sh -c 'sleep 60 & echo $! > /tmp/pid'`
  then check the `sleep` is gone?

## Response format

Write findings to
`audits/2026-07-05/session-direct-r1/session-direct-r2-architect-findings.md`
using this template:

```
# Session direct-push R2 — ARCHITECT lane findings

## Verdict
PASS / FAIL

## ARCH-R2.1 verification (orphan scenario closure)
- Case A (normal App quit): CLOSED / OPEN — reason
- Case B (CLI hang): CLOSED / OPEN — reason
- Case C (App SIGKILL): CLOSED_DEFERRED / OPEN — reason and follow-up recommendation

## Findings
### ARCH-R2-C-1 (CRITICAL) <title>
- File: <path:line>
- Design concern: ...
- Recommendation: ...
### ARCH-R2-H-1 (HIGH) <...>
### ARCH-R2-M-1 (MEDIUM) <...>
### ARCH-R2-L-1 (LOW) <...>
### ARCH-R2-I-1 (INFO) <...>
```

If verdict is PASS, write a one-paragraph narrative + the ARCH-R2.1
verification block.
