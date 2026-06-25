# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 2**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 4
IMPL — round 2.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md`. HEAD: `dd72e0e`.

The r1 audit returned 0 CRITICAL / 2 MAJOR / 3 MEDIUM / 1 LOW. The
r1 findings file is at
`specs/SPEC-016-IMPL-STEP_4-code-r1-audit.md`. Two fix-pass commits
landed (`b7ff8b1` + `dd72e0e`). Verify each r1 finding is genuinely
closed AND look for new defects introduced by the fix-pass.

## Files in scope (Step 4 delta + r1 fix-pass delta)

Step 4 originals (re-audit at r2):
- `phase4-coordinator/internal/payout/config_tuning.go`
- `phase4-coordinator/internal/payout/config_tuning_test.go`
- `phase4-coordinator/internal/payout/reconcile.sql`
- `phase4-coordinator/internal/payout/reconcile.go`
- `phase4-coordinator/internal/payout/payouts.go`
- `phase4-coordinator/internal/payout/runner.go`
- `phase4-coordinator/internal/payout/rpc.go`
- `phase4-coordinator/internal/payout/mux.go`
- `phase4-coordinator/internal/payout/step4_test.go`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/dist/coordinator.yaml.example`
- `phase4-coordinator/dist/check-deploy-config.sh`
- `phase4-coordinator/dist/payout-runbook.md`

Files changed by r1 fix-pass (priority focus):
- `phase4-coordinator/internal/payout/runner.go` — halt primitive + Tuning + activeSnap + snap() + ErrRunnerHalted
- `phase4-coordinator/internal/payout/lease.go` — ErrRunnerHalted sentinel added
- `phase4-coordinator/internal/payout/addresses.go` — Tuning + currentCoolingOff
- `phase4-coordinator/internal/payout/reorg.go` — Tuning + currentPollWindow
- `phase4-coordinator/internal/payout/reaper.go` — tuning + currentStaleAge
- `phase4-coordinator/internal/payout/mux.go` — run-now-halted 409
- `phase4-coordinator/internal/payout/reconcile.go` — extractLabel leading-only
- `phase4-coordinator/internal/payout/step4_test.go` — 7 new tests
- `phase4-coordinator/internal/payout/config_tuning_test.go` — AST walk
- `phase4-coordinator/internal/config/config.go` — LoadPayoutTuningOnly + resolveEnv payout coverage
- `phase4-coordinator/cmd/coordinator/main.go` — full re-wiring
- `phase4-coordinator/dist/check-deploy-config.sh` — low_balance + low_native keys

## Code-review checklist (r2)

### A. r1 finding closure verification

For each of the eight r1 findings (2 MAJOR + 3 MEDIUM + 1 LOW from
code lane + the convergent HIGH from security + CRITICAL from arch),
verify:

1. The fix matches the recommended remediation AND closes the
   underlying defect (not just a surface fix).
2. No regression — existing Step 1/2/3 tests still pass.
3. The fix doesn't introduce a NEW defect class.

### B. New halt primitive

1. `RequestHalt` is idempotent: CompareAndSwap on `halted`. First
   reason wins; subsequent calls don't overwrite (or do they? verify).
2. The PAGE event is emitted EXACTLY ONCE on the first RequestHalt.
3. `RunOnce` halt-check happens BEFORE the `inFlight` mu acquire (or
   after?) — verify the right ordering. A race where halt is set
   mid-cycle should NOT corrupt state.
4. `ErrRunnerHalted` is `errors.Is`-checkable. The runner's main
   `loop()` correctly handles the error.
5. Run-now admin endpoints (Step2/3/4 mux) check IsHalted + return
   409 with body `{"error":"runner_halted","reason":"..."}`.

### C. TuningProvider consumer plumbing

1. Runner's `snap()` returns the `activeSnap` field DURING a cycle,
   falls back to `currentTuning()` outside. The `ConfirmationBlocks
   == 0` test is the sentinel for "no cycle active" — confirm this
   is robust (zero is genuinely impossible during a cycle given the
   bounds matrix).
2. `processRow` and all helper methods (pollCancelOnce, pollAndConfirm,
   etc.) read `r.snap().ConfirmationBlocks` not
   `r.opts.ConfirmationBlocks`. Same for MaxRowsPerRun reads.
3. `emitBalanceAlerts` takes `snap` as a parameter, not from r.opts.
4. `AddressesService.pendingUntil` uses `s.currentCoolingOff()`.
5. `ReorgPoller.Run` reads `p.currentPollWindow()`.
6. `Reaper.reapStaleOutbox` reads `r.currentStaleAge()`.

### D. config.LoadPayoutTuningOnly

1. Parses YAML into a struct that has ONLY payout.tuning.* keys.
2. Runs the SAME bound matrix as the full Config validation (no
   drift between paths).
3. Does NOT touch payout.security.* — no env resolution, no
   security validation invoked on this path.
4. The SIGHUP handler in main.go uses this function in place of
   `config.Load`.

### E. AST static check

1. `TestTuningStaticCheck_NoSecurityNamespaceReference` walks the
   parsed `*ast.File` via `ast.Inspect` (not string scan).
2. The forbidden identifier set is centralized at top of test
   (single source of truth).
3. The test fails LOUD with node identity + position when a forbidden
   identifier appears.
4. `*ast.BasicLit` (string literal) with `"payout.security."`
   substring is caught.

### F. Deploy gate keys

1. `low_balance_threshold` and `low_native_threshold` in the
   required-keys loop.
2. They're required when `payout.enabled: true`.
3. Value `0` is acceptable (probe-disabled), but key MUST be present.

### G. resolveEnv payout coverage

1. `payout.security.rpc_url_primary` resolves env: indirection.
2. Same for `rpc_url_secondary`, `hot_wallet_address`, and
   `encrypted_wallet_path`.
3. Resolution uses the SAME helper as auth/OAuth, no special-case
   logic.
4. The test `TestLoadResolvesPayoutSecurityEnvFields` actually
   asserts the resolution.

### H. extractLabel

1. `leadingBlock` sentinel toggles to false on the first non-comment,
   non-blank line.
2. Once `leadingBlock=false`, no more directive stripping occurs.
3. Body comments containing `-- @label: X` are preserved verbatim.

### I. Test coverage

1. `TestPayoutsHandler_MissingBearer_401` + `_EmptyBearer_401` cover
   the 401 paths.
2. `TestPayoutsHandler_RateLimit_429` exercises the per-provider
   sliding window past 60.
3. `TestParseLabeledQueries_ExactlyThreeUnlabeled` asserts strict
   count.
4. `TestExtractLabel_PreservesBodyComment` covers (H).
5. `TestEmitBalanceAlerts_NonZeroThresholdInvokesProbes` covers the
   probe-invocation path with a counting mock.
6. `TestRunnerHalted_Skips_Cycle` covers the halt-skip semantics.

### J. Race detector

- `go test -race -count=1 ./internal/payout/...` — verify clean.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-code-r2-audit.md`. Standard structure
(Code Review Summary, By Severity, Findings, Recommendation).

## Discipline

- Don't re-flag closed r1 findings; verify closure + look for new
  defects introduced by the fix-pass.
- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
