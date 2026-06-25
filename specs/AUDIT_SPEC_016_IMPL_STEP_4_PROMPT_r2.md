# IMPL audit prompt — SPEC-016 Step 4, **r2 shared context**

This file is the master shared-context block for the round-2 fan-out:

- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r2.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_SECURITY_PROMPT_r2.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_ARCH_PROMPT_r2.md`

All three lanes are **read-only**. Codex MUST NOT modify any file.

## Round-1 verdict recap

- **Code r1:** 0 CRITICAL / 2 MAJOR / 3 MEDIUM / 1 LOW — REQUEST CHANGES
- **Security r1:** 0 CRITICAL / 1 HIGH / 3 MEDIUM / 0 LOW — BLOCK MERGE
- **Arch r1:** 1 CRITICAL / 2 MAJOR / 1 MEDIUM / 2 LOW — BLOCK

## What changed between r1 and r2

Two fix-pass commits landed on `impl/spec-016`:

### `b7ff8b1` — wire TuningProvider into consumers + runner halt primitive

Closes the three convergent CRITICAL/HIGH/MAJOR architectural defects.

1. **[arch:4.1]/[sec:r1-1] CRITICAL/HIGH — runner halt is real.** Runner
   gained an `atomic.Bool halted` + `RequestHalt(reason)` + `IsHalted()`
   + `HaltReason()` + `ErrRunnerHalted` sentinel. `RunOnce` checks at
   the TOP and aborts with `payout_runner_halted_skipping_cycle` PAGE
   when halted. `setupPayout` in `main.go` now wires the
   `ChainBalanceWorker` halt callback to `runner.RequestHalt(reason)`
   instead of just emitting `payout_runner_halt_requested`.
2. **[code:r1-1]/[sec:r1-2]/[arch:4.2] MAJOR — TuningProvider is the
   live source of truth.** All four reloadable consumers now read from
   the SIGHUP-reloadable atomic snapshot at the right boundary:
   - `Runner` — `opts.Tuning *TuningProvider` + `activeSnap` field set
     at top of `RunOnce` under mu+inFlight; `snap()` helper used for
     `MaxRowsPerRun`, `ConfirmationBlocks`, `LowBalanceThreshold`,
     `LowNativeThreshold` reads.
   - `AddressesService` — `Tuning *TuningProvider` field +
     `currentCoolingOff()` reads at write-time (per SPEC §6.5
     normative: new registrations cool off against NEW value;
     in-flight `pending_until_utc` rows are NOT recomputed).
   - `ReorgPoller` — `Tuning *TuningProvider` field +
     `currentPollWindow()` reads at top of each `Run`.
   - `Reaper` — `tuning *TuningProvider` field +
     `currentStaleAge()` reads `3 × Tuning.Snapshot().RunInterval` at
     top of `ReapOnce`.
   - **Documented limitation:** ticker cadences (RunInterval-driven
     ticker) are captured at Start; SIGHUP changes to `run_interval`
     require process restart to take effect on the ticker. The
     per-cycle behaviours (max_rows, confirmation_blocks, stale-age
     CHECK, cooling-off, balance probes) DO land without restart.
3. **[code:r1-2]/[arch:4.3] MAJOR — low-balance thresholds wired.**
   `setupPayout` passes
   `cfg.Payout.Tuning.LowBalanceThreshold` and `LowNativeThreshold`
   into `RunnerOptions`. `emitBalanceAlerts` now reads from the snap
   parameter, not static fields.

### `dd72e0e` — close 6 MEDIUMs + 2 LOWs

Closes the remaining MEDIUM/LOW findings:

1. **[code:r1-3] MEDIUM** — `config.LoadPayoutTuningOnly` added.
   `startPayoutSIGHUPListener` now calls this in place of `config.Load`,
   so the SIGHUP path NEVER parses, env-resolves, or validates
   `payout.security.*`. Tuning-only YAML parser + same bound matrix
   re-applied.
2. **[code:r1-4]/[arch:4.4] MEDIUM** —
   `TestTuningStaticCheck_NoSecurityNamespaceReference` now uses a real
   `ast.Inspect` walk against `*ast.Ident` and `*ast.BasicLit` over a
   forbidden security-namespace identifier set. String-scan removed.
3. **[code:r1-5] MEDIUM** — 7 new httptest tests in `step4_test.go`
   covering missing-bearer 401, empty-bearer 401, per-provider 429
   rate-limit, exact-3-unlabeled-count assertion,
   `TestExtractLabel_PreservesBodyComment`,
   `TestEmitBalanceAlerts_NonZeroThresholdInvokesProbes`,
   `TestRunnerHalted_Skips_Cycle`.
4. **[code:r1-6] LOW** — `extractLabel` introduces a `leadingBlock`
   sentinel; only directive lines BEFORE the first non-comment SQL
   token are stripped. Body comments containing `-- @label:` are
   preserved.
5. **[sec:r1-3] MEDIUM** — `dist/check-deploy-config.sh` now requires
   `low_balance_threshold` and `low_native_threshold` in the
   payout-tuning required-keys loop.
6. **[sec:r1-4] MEDIUM** — `Config.resolveEnv` now walks
   `payout.security.{rpc_url_primary, rpc_url_secondary,
   hot_wallet_address, encrypted_wallet_path}` for `env:NAME`
   indirection. New unit test
   `TestLoadResolvesPayoutSecurityEnvFields`.
7. **NEW (not r1-flagged but follow-on to halt primitive):** the
   `run-now` admin endpoints in Step2/Step3/Step4 mux levels return
   `409 runner_halted` with reason body when `runner.IsHalted()` is
   true.

**Deferred to PR-open phase:**
- **[arch:4.5] LOW** Step 3 advisories tracking issue (file at PR open
  per `[[tracking-issue-scope-control]]`).

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `dd72e0e impl(016): Step 4 r1 fix-pass — close 6 MEDIUMs + 2 LOWs`
- Step 4 is the LAST step before the single PR opens. PR opens after
  the audit loop converges to 0/0/0 across all three lanes. Do NOT
  push, do NOT open PR until convergence.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r2 audit lane MUST verify

Each lane has its own prompt with checklists; the cross-lane
invariants to verify at r2:

1. **Halt primitive correctness.** `RequestHalt` is idempotent.
   `RunOnce` skip is observable (event emitted, ErrRunnerHalted
   returned). `chainWorker → runner.RequestHalt` wiring composes
   correctly with the existing shutdown ordering. Admin run-now 409
   does NOT short-circuit other side effects (e.g. ProduceStaleOutbox
   should still run if it's a real cycle; or it should be skipped —
   verify what the implementation does and that it matches SPEC §7.4).
2. **TuningProvider consumer plumbing.** Each consumer's
   `current*()` method is actually called at the cycle boundary.
   No site has been left reading the static field when Tuning is
   wired. Test path (Tuning nil) still works.
3. **SIGHUP tuning-only path.** Confirm `config.LoadPayoutTuningOnly`
   does NOT touch `payout.security.*`. Confirm bound matrix
   re-applied. Confirm the SIGHUP listener never path-references
   security fields after the change.
4. **Run-now-halted 409.** Returns 409 status, with a reason body that
   names the halt reason. Doesn't break the existing tests.
5. **SIGHUP between cycles, not mid-cycle.** Verify the snapshot is
   read ONCE at `RunOnce` top via `activeSnap`. A SIGHUP arriving
   mid-cycle does NOT cause a torn read.
6. **resolveEnv coverage.** Verify the env: resolution rule applies
   to all 4 payout.security string fields the same way it applies to
   auth/OAuth (no special-case logic, no skipped checks).
7. **Static-check AST walk.** Confirm `TestTuningStaticCheck` would
   fail if `config_tuning.go` referenced `SecurityConfig` (try the
   test in dry-run if helpful — but read-only, do NOT edit).

## Severity guidance

Same as r1:

- CRITICAL — money-path defect or data-loss class.
- MAJOR — confirmed bug observable in production.
- MEDIUM — confirmed bug not directly observable in production but
  breaks an audit invariant.
- LOW — cosmetic / docs / minor consistency.

## What to BLOCK on

BLOCK only on:

- A new CRITICAL.
- A regression of an r1 finding.
- A SPEC normative rule that a future step cannot unwind.

Everything else is FIX-THEN-PROCEED.

## Output format

Each lane writes findings to its own file:

- `specs/SPEC-016-IMPL-STEP_4-code-r2-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-security-r2-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-arch-r2-audit.md`

Structure: Verdict, counts table, one section per finding with
[code:rN-X.Y] / [sec:rN-X.Y] / [arch:rN-X.Y] label + severity +
evidence (file:line) + recommended fix.
