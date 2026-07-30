# IMPL audit prompt — SPEC-016 FULL implementation, **CODE REVIEW lane, r2**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r2.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any implementation file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing the FULL SPEC-016
implementation — round 2.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r2.md`. HEAD: `3b41c0d`.
The r1 round found 2 HIGH + 3 MEDIUM + 1 LOW in this lane; r1
fix-pass landed all closures. r2 must verify each is closed AND
catch what r1 closures introduced.

## r1 closure verification

### [full-code:r1-1] both-RPC confirmation depth

Walk `pollCancelOnce` (runner.go:813 area) and `pollAndConfirm`
(runner.go:1146 area). Verify:
- Both call `Primary.BlockNumber(ctx)` AND `Secondary.BlockNumber(ctx)`.
- BOTH per-RPC depths satisfy `>= snap().ConfirmationBlocks` before
  marking confirmed / breaking the poll loop.
- A test exercises primary-deep + secondary-shallow → NO confirmation.
  (If no such regression exists, flag as MEDIUM coverage gap.)
- The fix didn't introduce a transient-error gap (both-RPC head
  read can race; verify the loop continues on either error rather
  than returning rowOutcomeFailed and abandoning the row).

### [full-code:r1-2] halt mid-cycle

Walk:
- runner.go rowLoop top: `r.halted.Load()` break + observability emit.
- allocateBuildSignBroadcast: gate AFTER SelfFence, BEFORE BroadcastBoth.
- rebroadcastAndPoll: gate AFTER SelfFence, BEFORE BroadcastBoth.
- claimAndLog: gate BEFORE ClaimPayoutReady.

Verify:
- All four gates use `r.halted.Load()` (not just `IsHalted()` — they're
  equivalent but the audit needs to confirm the same atomic Bool is
  read).
- The row-loop break leaves the deferred run_finished emit firing with
  correct counts (paid/capped/failed/skipped).
- No double halt event — only the row-loop top emits
  `payout_runner_halted_skipping_rows`; the inner gates return
  rowOutcomeSkipped silently.
- The gate in allocateBuildSignBroadcast lands AFTER COMMIT — verify
  the BEGIN IMMEDIATE txn was committed (cursor bumped + persisted
  bytes durable) so the next non-halted cycle's rebroadcastAndPoll
  picks up the row. Is the row left in a state the next cycle can
  recover from? The persisted bytes are in payout_attempts with
  raw_signed_tx set + broadcast_at_utc NULL — confirm this is
  recoverable by walking the §4.3 step 5 path.

### [full-code:r1-3] admin halt-bypass policy

Walk `withHaltObservability` in mux.go. Verify:
- All 5 admin endpoints OTHER than run-now are wrapped in Step2/Step3/
  Step4 muxes (abandon, pause, resume, record-funding, record-orphan).
- run-now is NOT wrapped (its halt gate is in RunNowController +
  remains 409-rejecting).
- The wrapper handles `runner == nil` (Step1 posture) without
  panicking.
- The emit goes through Runner.EmitAdminInvokedWhileHalted which
  reads `r.opts.Logger` + `r.opts.NowFn()` — verify both are non-nil
  by the time admin requests can arrive.

### [full-code:r1-4] ALTER TABLE pre-check

Walk `stripExistingColumnAlters` + `columnExists` in migrations.go.
Verify:
- The regex `addColumnStmt` correctly matches the 0010 + 0012
  migration body (single-line ALTER + multi-statement files OK).
- `columnExists` handles missing tables — what happens if migration
  0010 runs before payout_attempts exists? Walk migration ordering:
  0001 creates payout_attempts FIRST, so by the time 0010 runs the
  table exists.
- The rewrite preserves byte layout outside the matched statement —
  no off-by-one truncation in the trailing `;` walk.
- The comment used to replace the ALTER is valid SQL (a SQL line
  comment `--` works in SQLite).
- The function name reads naturally for future readers.

### [full-code:r1-5] e2e test

Walk `TestE2E_RegisterThroughClaim` in runner_e2e_test.go. Verify:
- The test actually exercises ServePayoutAddress (HTTP path), not
  a direct svc method call.
- The provider key differs from the hot wallet key (signerForTest
  and providerKeyForE2E use different rawHex constants).
- The backdated pending_until_utc is the ONLY scaffolding — no
  other invariant is bypassed.
- The assertion that ClaimPayoutReady was called with USDC-BASE +
  tx_hash holds.
- The test doesn't depend on order or shared state from another
  test in the package.

### [full-code:r1-6] gofmt

`gofmt -l phase4-coordinator/internal/config/config.go` clean.

## New cross-step probes

### A. Halt-state recovery

After RequestHalt + cycle break at allocateBuildSignBroadcast, the
attempt row exists with raw_signed_tx + broadcast_at_utc NULL. A
process restart clears the halt flag (in-memory atomic.Bool). The
next RunOnce will see the persisted-bytes row and call
rebroadcastAndPoll. Is this trace correct end-to-end? Is the
chain-balance worker's drift check what the operator runbook tells
them to verify before restarting?

### B. RunNowController halt semantics composition

The run-now controller gates on IsHalted and returns 409. After
the r1 changes, RunOnce itself also gates on IsHalted at the row-
loop top. Verify:
- The race-body fix (Step 4 r2 [code:r2-3]) for halt-after-admission-
  before-RunOnce still works correctly with the r1 row-loop gate.
  Specifically: if IsHalted=false at admission, RunOnce starts, then
  RequestHalt fires concurrently before row-loop top — does
  RunOnce return ErrRunnerHalted with a properly emitted
  run_finished (zero counts)?

### C. r1 byte-layout regressions

Walk every file touched by the r1 fix-pass (commit `3b41c0d`) and
look for:
- Unintended cosmetic changes that drift the §7.1 event field set.
- Off-by-one in any new loop or slice operation.
- New error paths that don't propagate correctly.

### D. govulncheck + race

- `govulncheck ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./internal/payout/...`
- `gofmt -l phase4-coordinator/` (allow pre-existing drift outside SPEC-016 surface)

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-code-r2-audit.md`.
Standard structure (Code Review Summary, By Severity, Findings,
Recommendation). If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Verify r1 closures hold. Look for what only emerges after the
  r1 changes.
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```
