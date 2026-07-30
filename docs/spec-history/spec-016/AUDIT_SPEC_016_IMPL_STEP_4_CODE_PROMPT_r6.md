# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 6 (code-only)**

Architecture lane CONVERGED at r4. Security lane CONVERGED at r5.
Only code lane re-audits at r6.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane auditing SPEC-016 Step 4 IMPL —
round 6, code-only since security + arch already CONVERGED.

## Round history

| Round | Code | Security | Arch | Verdict |
|-------|------|----------|------|---------|
| r1 | 0/2/3/1 | 0/1/3/0 | 1/2/1/2 | BLOCK |
| r2 | 0/1/3/0 | 0/1/1/0 | 0/2/0/0 | BLOCK |
| r3 | 0/1/3/1 | 0/1/1/0 | 0/1/1/0 | BLOCK |
| r4 | 0/0/4/1 | 0/0/1/1 | **0/0/0/0** | arch CONVERGENT; code COMMENT; security BLOCK MERGE |
| r5 | 0/2/3/3 | **0/0/0/0** | — | security CONVERGENT; code REQUEST CHANGES |

## What changed between r5 and r6 (fix-pass commit `e0f7da1`)

The r5 code lane found 2 HIGH money-path defects + 3 MEDIUMs + 3 LOWs.
The r5 fix-pass closes all 8:

### Closed HIGH

1. **[code:r5-1] `payout_insufficient_funds` path.** New
   `currentHotWalletUSDCBalance(ctx)` reads the hot-wallet USDC balance
   via primary RPC `usdcBalanceCalldata` + `CallContract` +
   `parseBalanceResult`. `Runner.RunOnce` reads ONCE at top of cycle,
   then deducts each successful payout amount from a running tally.
   Per-row check before processRow: if running balance < required,
   emit `payout_insufficient_funds` with `run_id, payout_id,
   provider_id, required_usdc_base_units, available_usdc_base_units,
   ts_utc` AND break out of the row loop (labeled `rowLoop`). The
   running counter `skippedFunds` is reported in
   `payout_run_finished`. New test
   `TestRunner_RunOnce_InsufficientFundsHaltsAndEmits`.

2. **[code:r5-2] daily-cap event + halt.** New `rowOutcomeDailyCapTripped`
   distinct from `rowOutcomeCapped`. Daily-cap-trip site in
   `runner.go:778` now emits `payout_daily_cap_tripped`
   (`run_id, window_paid_usdc_base_units, cap_usdc_base_units, ts_utc`)
   per SPEC §7.1 line 3723. Row loop in `RunOnce` breaks on the new
   outcome. Per-payout cap keeps `payout_capped` + continues. New test
   `TestRunner_RunOnce_DailyCapTrippedHaltsLoop`.

### Closed MEDIUM

3. **[code:r5-3] nonce-cold-start `ts_utc`.** `main.go:747` event emit
   includes `Str("ts_utc", coldStartTS)` (shared with
   UpsertNonceCursor for consistency).

4. **[code:r5-4] cancel-side reorg `last_seen_block + rpc_source`.**
   `reorg.go:264` cancel-self-transfer reorg emit now includes
   `last_seen_block=0` (documented sentinel — cancel rows don't
   preserve block_number when reorged) and `rpc_source="both"` (both
   RPCs agreed not-found).

5. **[code:r5-5] CloseIdleConnections pool-drain proof.**
   `TestHTTPRPCClient_CloseIdleConnections` rewritten with
   `httptest.NewUnstartedServer` + `ConnState` callback proving the
   connection pool drains and request 2 opens a new connection.

### Closed LOW

6. **[code:r5-6] BoundViolationError wrapping.** `Reload` uses
   `%w:%w` double-wrap so `errors.As(*BoundViolationError)` works
   from the caller. Test asserts it.

7. **[code:r5-7] sanitized attempted_value assertion.** YAML-rejection
   test asserts `attempted_value == "config_load_failed"` exactly.

8. **[code:r5-8] gofmt drift.** `gofmt -w` applied; no formatting
   diff remains.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `e0f7da1 impl(016): Step 4 r5 fix-pass — close 2 HIGH money-path
  defects + 3 MEDIUMs + 3 LOWs`
- Step 4 is the LAST step. After r6 CONVERGENCE, the single PR opens.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r6 lane MUST check

### A. r5 closure verification

For each r5 finding, verify CLOSED with no regression:

1. **[code:r5-1] payout_insufficient_funds.**
   - Field set matches SPEC §7.1 line 3722: `run_id, payout_id,
     provider_id, required_usdc_base_units,
     available_usdc_base_units, ts_utc`.
   - Per-row check happens BEFORE sign/broadcast.
   - Running balance updates after each successful payout
     (in-memory deduct).
   - Cycle halts (breaks rowLoop) on insufficient funds; subsequent
     rows NOT processed.
   - `payout_run_finished.skipped_funds` reports the counter (not 0).
   - Test exercises the boundary: 2 ready rows with provider_credits
     such that row 1 fits the initial balance, row 2 does not.

2. **[code:r5-2] payout_daily_cap_tripped + halt.**
   - Field set matches SPEC §7.1 line 3723: `run_id,
     window_paid_usdc_base_units, cap_usdc_base_units, ts_utc`.
   - Row loop breaks on `rowOutcomeDailyCapTripped`.
   - `payout_capped` is RESERVED for per-payout cap (still emitted
     when amount > PerPayoutCapBaseUnits).
   - Test asserts 3 rows: row 1 processes, row 2 trips daily cap,
     row 3 NOT processed.

3. **[code:r5-3] nonce-cold-start ts_utc** — verify the emit shape.

4. **[code:r5-4] cancel reorg fields** — verify both fields present
   and have non-zero documented values.

5. **[code:r5-5] CloseIdleConnections pool drain** — verify the
   test asserts NEW connection on request 2 via ConnState.

6. **[code:r5-6] Reload wrapping** — verify `errors.As` works.

7. **[code:r5-7] test assertion** — verify exact match.

8. **[code:r5-8] gofmt** — `gofmt -l` produces no output.

### B. No regressions of r1-r4 closures

Spot-check that the r5 fix-pass did NOT regress:
- r1: TuningProvider plumbing; runner halt primitive
- r2: RunNowController; SPKI live-read; AST forbidden set; §7.1
  alert field names
- r3: CloseIdleConnections + SIGHUP wiring; runner stale-producer
  snap.RunInterval; RunOnce run_id correlation; payout_config_*
  field names; chain-balance event rename; halt-race interface
- r4: YAML-load structured emit; hot_wallet on chain-balance
  disagreement; CloseIdleConnections regression test;
  Runner.RunOnce stale-producer test; BoundViolationError rename

### C. New defects introduced by the r5 fix-pass

The HIGH fixes involve substantial new control flow:
- Labeled `rowLoop` break — verify both new outcomes (insufficient
  funds, daily cap trip) reach the break correctly.
- Running balance counter — verify it deducts the EXACT amount
  paid (not the row's provider_credits if the actual amount
  differed; not the pre-claim amount if claim could fail).
- `currentHotWalletUSDCBalance` — verify error handling: on RPC
  failure, what happens? Probably the cycle should continue without
  the check (observability-only), not halt. Verify.

### D. §7.1 sweep — final pass

Re-verify EVERY Step 4 event in SPEC §7.1 lines 3712-3732. This is
the final §7.1 sweep before PR-open.

### E. Tests + race + gofmt

- `go test -count=1 ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./internal/payout/...`
- `gofmt -l phase4-coordinator/`
- `git diff --check e0f7da1^..e0f7da1`

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_4-code-r6-audit.md`.

**If 0/0/0/0 — declare CONVERGENT.** This is the FINAL audit round
before PR-open.

## Discipline

- Don't re-flag closed findings; verify closure.
- The HIGH closures are money-path — pay particular attention to
  edge cases (RPC failure during balance read, race conditions,
  etc.).
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```
