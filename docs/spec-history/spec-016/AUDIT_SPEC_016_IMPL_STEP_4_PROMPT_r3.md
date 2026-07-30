# IMPL audit prompt — SPEC-016 Step 4, **r3 shared context**

Master shared-context block for the round-3 fan-out:
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r3.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_SECURITY_PROMPT_r3.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_ARCH_PROMPT_r3.md`

All three lanes are **read-only**. Codex MUST NOT modify any file.

## Round history

| Round | Code | Security | Arch | Verdict |
|-------|------|----------|------|---------|
| r1 | 0/2/3/1 | 0/1/3/0 | 1/2/1/2 | BLOCK (3 convergent) |
| r2 | 0/1/3/0 | 0/1/1/0 | 0/2/0/0 | BLOCK (1 convergent + 1 arch + 3 MEDIUM) |

## What changed between r2 and r3 (fix-pass commit `fe6a699`)

### Closed BLOCKers

1. **[code:r2-1]/[sec:r2-1]/[arch:r2-4.1] CONVERGENT MAJOR — run-now contract.**
   New `phase4-coordinator/internal/payout/runnow.go` with
   `RunNowController` centralising the §4.2 admin run-now contract:
   - Per-request live read of `RunNowMinInterval` from
     `TuningProvider.Snapshot()`
   - Per-request `payout_run_now_invoked` emit (every outcome:
     accepted / rate_limited / runner_halted / cycle_in_flight_or_failed)
   - 429 inside the window, 409 with halt reason when halted, 200
     with run_id on success
   - Post-RunOnce `errors.Is(err, ErrRunnerHalted)` check returns
     `runner_halted` body, closing the [code:r2-3] race
   - `mux.go` Step2/Step3/Step4 handlers all delegate to the same
     controller — single authority for run-now
   - New tests in `runnow_test.go` (8 cases incl. clock-inject,
     halt-race, tuning live-read)

2. **[arch:r2-4.2] MAJOR — SPKI pin live read.** `NewHTTPRPCClient`
   third parameter changed from `string` to `func() string`. The
   `makeSPKIPinVerifier` callback invokes the func per TLS handshake
   so SIGHUP changes to `rpc_url_*_pin_spki` land without process
   restart. `main.go` passes `func() string {
   return tuningProvider.Snapshot().RPCURLPrimaryPinSPKI }` (and
   secondary equivalent). TuningProvider construction moved BEFORE
   RPC client construction. New `TestMakeSPKIPinVerifier_LiveRead`
   covers wrong-pin reject + correct-pin accept + empty-pin
   bypass.

### Closed MEDIUMs

3. **[code:r2-2]/[sec:r2-2] MEDIUM — AST forbidden set.** The
   `TestTuningStaticCheck_NoSecurityNamespaceReference` forbidden
   identifier set now lists EXACT exported names from
   `PayoutSecurityConfig` — `PerDayCapUSDCBaseUnits`,
   `PerPayoutCapUSDCBaseUnits`, `PayoutSecurityConfig`,
   `RPCURLPrimary`, `RPCURLSecondary`, etc. Non-exact substrings
   removed.

4. **[code:r2-3] MEDIUM — halt-race body.** Closed by the
   `RunNowController` post-RunOnce check (above).

5. **[code:r2-4] MEDIUM — §7.1 alert field names.**
   `payout_low_balance` now emits `from_address, usdc_base_units,
   threshold_usdc_base_units, ts_utc` per SPEC §7.1 line 3720.
   `payout_low_native_balance` uses `from_address, native_wei,
   threshold_wei, ts_utc` per line 3721. Both chain-balance drift
   events use `from_address, in_db_expected_usdc_base_units,
   on_chain_usdc_base_units, drift_usdc_base_units, ts_utc` per
   lines 3727-3728. Old non-spec field names dropped entirely.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `fe6a699 impl(016): Step 4 r2 fix-pass — close all BLOCK findings`
- Step 4 is the LAST step before the single PR opens. PR opens after
  the audit loop converges to 0/0/0 across all three lanes.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r3 lane MUST check

1. **r2 finding closure verification.** For each of the 5 r2 findings,
   verify the fix matches the SPEC requirement and doesn't introduce
   a new defect class.
2. **`RunNowController` correctness.** Atomic time-and-decision-update
   inside the mutex? Event emission is exactly-once per request? The
   `outcome=accepted` event still emits if `RunOnce` returns success?
   The halt-race path emits the right outcome label?
3. **SPKI live-read correctness.** `func() string` is called per
   handshake (not per request — the TLS verifier runs at handshake,
   then reuses the connection). Verify the keep-alive interaction
   isn't a footgun: a long-lived TLS session WILL retain the old
   pin until reconnection.
4. **AST forbidden set completeness.** Use the actual struct fields
   in `phase4-coordinator/internal/config/config.go` PayoutSecurityConfig
   definition as ground truth. Any field not in the forbidden set?
5. **§7.1 field name sweep.** Are there OTHER Step 4 events with
   non-spec field names? `payout_run_now_invoked` (the new event)
   itself — does it match the §7.1 contract or is it adding fields
   the spec doesn't name?
6. **`payout_run_now_invoked` SPEC compliance.** SPEC §7.1
   line 3716 names fields: `run_id, actor=operator_key, ts_utc`. The
   implementation adds `outcome` (defensive). Is this a SPEC drift
   the lane should flag, or an acceptable extension?

## Severity guidance + BLOCK rule (unchanged from r1/r2)

- CRITICAL — money-path defect or data-loss class.
- MAJOR — confirmed bug observable in production.
- MEDIUM — confirmed bug not directly observable but breaks an
  audit invariant.
- LOW — cosmetic / docs / minor consistency.

BLOCK only on: new CRITICAL, regression of an r1/r2 finding, or a SPEC
normative violation a future step cannot unwind. Everything else is
fix-then-proceed.

## Output format

Each lane writes findings to its own file:
- `specs/SPEC-016-IMPL-STEP_4-code-r3-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-security-r3-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-arch-r3-audit.md`

Standard structure: Verdict, counts, one section per finding with
[code:r3-X.Y] / [sec:r3-X.Y] / [arch:r3-X.Y] label + severity +
evidence (file:line) + recommended fix.
