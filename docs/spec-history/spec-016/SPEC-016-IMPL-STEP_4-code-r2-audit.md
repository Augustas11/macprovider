# SPEC-016 Step 4 — code-review lane, r2 audit

Codex run: `codex-impl-audit-prompt-spec-016-step-4-code-review-lane-round-2-m-2026-06-25T19-28-55-724Z.md`
HEAD: `dd72e0e`
Branch: `impl/spec-016`

## Verdict

**REQUEST CHANGES** — 0 CRITICAL / 1 MAJOR / 3 MEDIUM / 0 LOW.

Full coordinator test suite passes. The r1 functional closures are mostly
in place, but run-now still misses a normative rate-limit/event contract,
and the AST closure is incomplete.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| MAJOR    | 1 |
| MEDIUM   | 3 |
| LOW      | 0 |

## R1 Finding Closure

| R1 finding | r2 status |
|------------|-----------|
| [code:r1-1] SIGHUP reload not connected to live behavior | CLOSED — TuningProvider plumbed into runner/addresses/reorg/reaper |
| [code:r1-2] LowBalance/LowNative not in RunnerOptions | CLOSED — setupPayout passes both + snap reads in emitBalanceAlerts |
| [code:r1-3] SIGHUP validates security namespace | CLOSED — LoadPayoutTuningOnly |
| [code:r1-4] AST static check doesn't walk identifiers | PARTIAL — see [code:r2-2] |
| [code:r1-5] Missing test coverage | CLOSED — 7 new tests in step4_test.go |
| [code:r1-6] extractLabel strips any directive line | CLOSED — leadingBlock sentinel |

## Findings

### [code:r2-1] MAJOR — `run_now_min_interval` is not enforced and `payout_run_now_invoked` is never emitted

- File: `phase4-coordinator/internal/payout/mux.go:160`
- Confidence: HIGH

The Step2/3/4 run-now handlers authenticate and halt-check, then call
`Runner.RunOnce` directly. There is no consumer of
`payout.tuning.run_now_min_interval`, no 429 path, and no
`payout_run_now_invoked` event. The locked spec requires rate limiting
at `specs/SPEC-016-payout-pipeline.md:861` and the invocation event in
the §7.1 field-set table at `:3716`.

**Fix:** introduce a shared run-now controller/handler used by
Step2/3/4 that tracks last accepted invocation under a mutex, reads
`RunNowMinInterval` from the live `TuningProvider`, returns 429
inside the window, and emits `payout_run_now_invoked` with `run_id +
actor + ts_utc + outcome`. The runner likely needs a way to accept
or return the run_id so the event can carry the spec-required
`run_id`.

Converges with [sec:r2-1] HIGH and [arch:r2-4.1] MAJOR.

### [code:r2-2] MEDIUM — AST static check does not cover all `payout.security.*` identifiers

- File: `phase4-coordinator/internal/payout/config_tuning_test.go:180`
- Confidence: HIGH

The test now uses `ast.Inspect`, but its forbidden set omits security
fields such as `RPCURLPrimary`, `RPCURLSecondary`,
`PerPayoutCapUSDCBaseUnits`, and `PerDayCapUSDCBaseUnits` from
`PayoutSecurityConfig` at `phase4-coordinator/internal/config/config.go:62`.
A future reference to those identifiers in `config_tuning.go` would
pass the static guard. Also uses non-exact substrings (e.g. `PerDayCap`)
when the AST sees only exact identifier names.

This means r1 finding `[code:r1-4]` is only PARTIAL_RESOLVED_DIFFERENTLY.

**Fix:** derive the forbidden identifier set from the
`PayoutSecurityConfig` AST, or explicitly list every exact exported
field name and type name that belongs to the security namespace.

Converges with [sec:r2-2] MEDIUM.

### [code:r2-3] MEDIUM — Concurrent halt can return the wrong run-now error body

- File: `phase4-coordinator/internal/payout/mux.go:172`
- Confidence: MEDIUM

The handlers pre-check `Runner.IsHalted()`, but if `RequestHalt` lands
after that check and before `RunOnce`'s own halt check, `RunOnce`
returns `ErrRunnerHalted` and the handler responds with
`{"error":"cycle_in_flight_or_failed"}` instead of the required
`{"error":"runner_halted","reason":"..."}`.

**Fix:** after `RunOnce`, handle `errors.Is(err, ErrRunnerHalted)`
and return the same `runner_halted` body. Centralize this in the
shared run-now handler to avoid Step2/3/4 drift.

### [code:r2-4] MEDIUM — Step 4 alert events use non-spec field names

- File: `phase4-coordinator/internal/payout/runner.go:1379`
- Confidence: HIGH

`payout_low_balance` emits `hot_wallet`, `balance_usdc_base_units`,
and `threshold`, while the spec requires `from_address`,
`usdc_base_units`, and `threshold_usdc_base_units` at
`specs/SPEC-016-payout-pipeline.md:3720`. The native alert and
chain-balance drift events similarly use non-spec names at
`runner.go:1399` and `phase4-coordinator/internal/payout/reconcile.go:427`.

This can break log consumers and audit checks expecting the §7.1 schema.

**Fix:** emit the spec field names. The full sweep covers
`payout_low_balance`, `payout_low_native_balance`,
`payout_chain_balance_drift_positive`, and
`payout_chain_balance_drift_negative`.

## Positive observations

- Halt primitive is idempotent: `CompareAndSwap(false, true)`
  preserves the first reason and emits the halt PAGE once.
- Runner, address service, reorg poller, and reaper are wired to
  `TuningProvider`; cycle snapshots avoid mid-cycle torn tuning reads.
- `LoadPayoutTuningOnly` avoids the security namespace and the SIGHUP
  handler uses it instead of full `config.Load`.
- Deploy gate now requires `low_balance_threshold` and
  `low_native_threshold` when `payout.enabled=true`, while allowing 0.
- `resolveEnv` now covers the four payout security string fields
  through the shared helper.
- `extractLabel` preserves body `-- @label:` comments.

## Validation

- `go test ./internal/payout/...` passed.
- `go test ./internal/config ./cmd/coordinator` passed.
- `go test -race -count=1 ./internal/payout/...` passed.
- `go test ./...` passed in `phase4-coordinator`.

## Recommendation

REQUEST CHANGES.
