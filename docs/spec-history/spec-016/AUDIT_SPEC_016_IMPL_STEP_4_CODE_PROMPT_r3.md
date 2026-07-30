# IMPL audit prompt — SPEC-016 Step 4, **CODE REVIEW lane, round 3**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r3.md`.

Fire via:

```
omc ask codex --agent-prompt code-reviewer --prompt "<this file's body>"
```

Read-only. Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are the code-reviewer lane (1 of 3) auditing SPEC-016 Step 4
IMPL — round 3.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r3.md`. HEAD: `fe6a699`.

The r2 audit returned 0 CRITICAL / 1 MAJOR / 3 MEDIUM / 0 LOW.
Findings file: `specs/SPEC-016-IMPL-STEP_4-code-r2-audit.md`. The
r2 fix-pass landed at `fe6a699`. Verify closure + look for new
defects.

## Files priority focus

New + modified in r2 fix-pass:
- `phase4-coordinator/internal/payout/runnow.go` (NEW)
- `phase4-coordinator/internal/payout/runnow_test.go` (NEW)
- `phase4-coordinator/internal/payout/mux.go` (handlers delegate to controller)
- `phase4-coordinator/internal/payout/rpc.go` (NewHTTPRPCClient signature change)
- `phase4-coordinator/internal/payout/rpc_test.go` (new TLS live-read test)
- `phase4-coordinator/internal/payout/runner.go` (alert event field rename)
- `phase4-coordinator/internal/payout/reconcile.go` (drift event field rename)
- `phase4-coordinator/internal/payout/config_tuning_test.go` (AST set exact names)
- `phase4-coordinator/cmd/coordinator/main.go` (live SPKI closure + RunNowController wiring + construction reorder)
- `phase4-coordinator/internal/payout/step3_test.go` (Step2MuxOptions RunNow wired)
- `phase4-coordinator/internal/payout/step4_test.go` (Step2MuxOptions RunNow wired)

## Code-review checklist (r3)

### A. r2 closure verification

For each r2 finding, verify the fix:
- [code:r2-1]/[sec:r2-1]/[arch:r2-4.1] convergent MAJOR — run-now controller
- [arch:r2-4.2] MAJOR — SPKI live read
- [code:r2-2]/[sec:r2-2] MEDIUM — AST forbidden set
- [code:r2-3] MEDIUM — halt-race body fix
- [code:r2-4] MEDIUM — §7.1 alert field names

### B. RunNowController

1. `ServeRunNow`: holds the mutex across the time-check + lastAccepted
   update? A concurrent request that lands MID-`Allow` must see the
   timestamp as committed.
2. `payout_run_now_invoked` emission: emitted EXACTLY ONCE per
   request via defer. No double-emit on the halt-race path.
3. Field shape matches SPEC §7.1 line 3716: `run_id, actor, ts_utc`.
   Extra `outcome` field — note whether this is a defensive extension
   or a SPEC drift the implementer should flag.
4. The 429 body should not leak internal state (timestamps, queue
   depth). Verify.
5. `errors.Is(err, ErrRunnerHalted)` post-RunOnce — handles the race.
6. Nil-runner / nil-controller defenses correctly (mux nil-checks).
7. Run ID generation: uuid.NewString — confirm it's deterministic
   enough for the SPEC contract (correlation across PAGE events).

### C. SPKI live read

1. `func() string` is invoked INSIDE the verifier closure on every
   handshake (not memoized).
2. Empty-pin behavior: when `pinFn() == ""`, verifier skips pin
   check. Verify this still works for the no-pin operator path.
3. Test coverage: `TestMakeSPKIPinVerifier_LiveRead` actually
   exercises the live update by mutating the pin source between
   handshakes. Read the test to confirm.
4. Keep-alive concern: HTTP/2 multiplexing + connection pooling
   means the verifier runs once at connection establishment. A
   SIGHUP after connection establishment will NOT affect that
   live connection. Is this a defect or acceptable? Flag if not
   documented.

### D. AST forbidden set

1. Cross-reference against `phase4-coordinator/internal/config/config.go`
   `PayoutSecurityConfig` struct — every exported field must be in
   the forbidden set.
2. Type name `PayoutSecurityConfig` and any aliases (e.g.
   `SecurityConfig` in the payout package) are listed.
3. The test still fails LOUD when a forbidden identifier appears.

### E. §7.1 field names sweep

1. `payout_low_balance`: `from_address, usdc_base_units,
   threshold_usdc_base_units, ts_utc` — verify.
2. `payout_low_native_balance`: `from_address, native_wei,
   threshold_wei, ts_utc` — verify.
3. `payout_chain_balance_drift_positive` /
   `payout_chain_balance_drift_negative`: `from_address,
   in_db_expected_usdc_base_units, on_chain_usdc_base_units,
   drift_usdc_base_units, ts_utc` — verify.
4. Sweep ALL Step 4 events for any other field-name drift —
   `payout_balance_probe_rpc_error`, `payout_run_now_invoked`,
   `payout_chain_balance_rpc_error`, `payout_rpc_disagreement`,
   `payout_runner_halted`, `payout_runner_halted_skipping_cycle`,
   `payout_config_reloaded`, `payout_config_reload_rejected`.

### F. Construction ordering correctness

1. `main.go::setupPayout` constructs TuningProvider BEFORE the RPC
   clients (since RPCs now need a func() string closure over the
   provider's Snapshot).
2. The lease still acquires AFTER TuningProvider construction? Or
   has the reordering shifted other dependencies? Verify the
   shutdown closure still releases the lease only when runnerClean
   && pollerClean.

### G. Tests

1. Existing Step 1/2/3 tests still pass (the reorder of construction
   in main.go could break ordering assumptions).
2. New runnow tests cover all 4 outcomes.
3. New rpc live-read test exercises both error paths.

### H. Race detector

- `go test -race -count=1 ./internal/payout/...` — clean.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-code-r3-audit.md`. Standard structure
(Code Review Summary, By Severity, Findings, Recommendation).

## Discipline

- Don't re-flag closed r1/r2 findings; verify closure + look for new
  defects introduced by the fix-pass.
- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
