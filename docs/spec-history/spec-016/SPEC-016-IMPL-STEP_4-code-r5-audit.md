# SPEC-016 Step 4 IMPL Code Audit - Round 5

## Verdict

REQUEST CHANGES.

The r4 fix-pass closes several targeted findings: the production SIGHUP
YAML-load failure path now emits structured `payout_config_reload_rejected`
fields with sanitized `attempted_value=config_load_failed`; chain-balance RPC
disagreement now includes `hot_wallet`; stale-cancel production has a
runner-level `snap.RunInterval` regression test; and the runbook now documents
64-hex SPKI pins plus `CloseIdleConnections` in-flight semantics.

However, the final Section 7.1 sweep found missing SPEC-mandated production
events/fields, including two behavior-level gaps around insufficient funds and
daily cap handling. This lane is not convergent.

## Counts

- CRITICAL: 0
- HIGH: 2
- MEDIUM: 3
- LOW: 3

## Findings

### [code:r5-1] HIGH - No `payout_insufficient_funds` path exists

Confidence: HIGH

Evidence:
- `specs/SPEC-016-payout-pipeline.md:3244` to
  `specs/SPEC-016-payout-pipeline.md:3247` requires the runner to emit
  `payout_insufficient_funds` when hot-wallet USDC is insufficient for the next
  selected row and halt until the next cadence cycle.
- `specs/SPEC-016-payout-pipeline.md:3722` requires the event fields
  `run_id, payout_id, provider_id, required_usdc_base_units,
  available_usdc_base_units, ts_utc`.
- Repository search found no `payout_insufficient_funds` emit site in
  `phase4-coordinator/internal/payout` or `phase4-coordinator/cmd/coordinator`.
- `phase4-coordinator/internal/payout/runner.go:383` always reports
  `skipped_funds=0` in `payout_run_finished`.

Issue:
The implementation has low-balance probes, but it does not implement the
required per-selected-row insufficient-funds branch. A production runner can
attempt to build/broadcast a transfer without first producing the required
operator audit event and cycle halt semantics.

Fix:
Before signing/broadcasting the selected payout row, read the current hot-wallet
USDC balance, compare it with the row amount, emit
`payout_insufficient_funds` with the Section 7.1 fields, increment
`skipped_funds`, and stop the current cycle when funds are insufficient.

### [code:r5-2] HIGH - Daily-cap trip emits the wrong event and continues later rows

Confidence: HIGH

Evidence:
- `specs/SPEC-016-payout-pipeline.md:3173` to
  `specs/SPEC-016-payout-pipeline.md:3177` says when the next row would push
  the 24h window past the cap, the runner skips that row and subsequent rows and
  emits `payout_daily_cap_tripped`.
- `specs/SPEC-016-payout-pipeline.md:3723` requires
  `payout_daily_cap_tripped` fields `run_id, window_paid_usdc_base_units,
  cap_usdc_base_units, ts_utc`.
- `phase4-coordinator/internal/payout/runner.go:778` to
  `phase4-coordinator/internal/payout/runner.go:789` instead emits
  `payout_capped` with `reason=per_day_cap` and returns `rowOutcomeCapped`.
- `phase4-coordinator/internal/payout/runner.go:449` to
  `phase4-coordinator/internal/payout/runner.go:458` counts that one row as
  capped and continues iterating subsequent rows.
- Repository search found no `payout_daily_cap_tripped` emit site.

Issue:
This violates both the audit event contract and the control-flow contract. After
a daily cap trip, later smaller rows can still be processed in the same cycle,
even though the SPEC requires the runner to skip subsequent rows until a later
cadence cycle.

Fix:
Add a daily-cap-specific outcome that emits `payout_daily_cap_tripped` with the
required window/cap fields, then stops the current row loop. Keep
`payout_capped` for per-payout caps.

### [code:r5-3] MEDIUM - `payout_nonce_cold_start_within_tolerance` omits `ts_utc`

Confidence: HIGH

Evidence:
- `specs/SPEC-016-payout-pipeline.md:3729` requires
  `from_address, rpc_a_nonce, rpc_b_nonce, chosen_nonce, ts_utc`.
- `phase4-coordinator/cmd/coordinator/main.go:747` to
  `phase4-coordinator/cmd/coordinator/main.go:754` emits
  `payout_nonce_cold_start_within_tolerance` with the nonce fields but no
  `ts_utc`.

Issue:
The cold-start nonce tolerance event is missing a required timestamp, weakening
the operator audit trail for a startup safety decision.

Fix:
Add `Str("ts_utc", time.Now().UTC().Format(time.RFC3339Nano))` or reuse the
startup timestamp used for the nonce cursor write.

### [code:r5-4] MEDIUM - Cancel-side `payout_reorg_revert` omits required fields

Confidence: HIGH

Evidence:
- `specs/SPEC-016-payout-pipeline.md:3724` requires
  `payout_id, attempt_seq, tx_hash, last_seen_block, rpc_source,
  is_cancel_self_transfer, observed_via, ts_utc`.
- Provider-payout reorgs include `last_seen_block` and `rpc_source` at
  `phase4-coordinator/internal/payout/reorg.go:198` to
  `phase4-coordinator/internal/payout/reorg.go:209`.
- Cancel-self-transfer reorgs at
  `phase4-coordinator/internal/payout/reorg.go:264` to
  `phase4-coordinator/internal/payout/reorg.go:273` emit
  `payout_id, attempt_seq, tx_hash, is_cancel_self_transfer, observed_via,
  ts_utc`, but omit `last_seen_block` and `rpc_source`.

Issue:
Consumers of `payout_reorg_revert` cannot rely on the Section 7.1 field set for
cancel-side reorgs. This is a schema drift on the same event name.

Fix:
Include `last_seen_block` and `rpc_source` in the cancel-side event. If the
cancel path does not preserve a meaningful last block, emit a documented
sentinel such as `0`; use `rpc_source="both"` for the two-RPC not-found path.

### [code:r5-5] MEDIUM - `TestHTTPRPCClient_CloseIdleConnections` does not prove the pool is drained

Confidence: HIGH

Evidence:
- The r5 checklist requires `TestHTTPRPCClient_CloseIdleConnections` to cover a
  real transport where, after a request lands an idle connection in the pool,
  `CloseIdleConnections` empties the pool.
- `phase4-coordinator/internal/payout/rpc_test.go:397` to
  `phase4-coordinator/internal/payout/rpc_test.go:407` performs one request and
  calls `client.CloseIdleConnections()`, but has no assertion that a subsequent
  request uses a new connection or that the original idle connection was closed.

Issue:
The test proves the method is callable and nil-safe, but it does not prove the
r4 regression condition. A future change could stop draining the actual
transport pool while this test still passes.

Fix:
Instrument an `httptest.Server` with `ConnState` or connection IDs, perform a
request, call `CloseIdleConnections`, then perform a second request and assert
the first idle connection was closed / a new connection was established.

### [code:r5-6] LOW - `Reload` drops `BoundViolationError` from the returned error chain

Confidence: HIGH

Evidence:
- `phase4-coordinator/internal/payout/config_tuning.go:272` says `Reload`
  returns `ErrTuningBoundViolation` wrapped with the violated field.
- `phase4-coordinator/internal/payout/config_tuning.go:284` to
  `phase4-coordinator/internal/payout/config_tuning.go:286` returns
  `fmt.Errorf("%w: %v", ErrTuningBoundViolation, bve)`, which wraps only
  `ErrTuningBoundViolation`; the `*BoundViolationError` is formatted with
  `%v`, not wrapped.
- `phase4-coordinator/internal/payout/config_tuning_test.go:357` to
  `phase4-coordinator/internal/payout/config_tuning_test.go:360` calls
  `errors.As(reloadErr, &bve)` but does not assert either success or failure.

Issue:
The emitted log is correct because `emitRejected` receives `bve` before the
return. But callers and tests cannot extract the renamed structured error from
the returned `Reload` error, contrary to the r5 checklist and the function
comment.

Fix:
Return an error that wraps both values, for example
`fmt.Errorf("%w: %w", ErrTuningBoundViolation, bve)` on supported Go versions,
or define a small wrapper type with `Unwrap() []error`. Update the test to
assert `errors.As(reloadErr, &bve)` and verify `Field` / `Attempted`.

### [code:r5-7] LOW - YAML-load rejection test does not assert the sanitized attempted value

Confidence: HIGH

Evidence:
- The r5 checklist requires YAML-load failure to use literal
  `attempted_value="config_load_failed"` and not leak raw YAML contents.
- `phase4-coordinator/cmd/coordinator/main.go:1361` to
  `phase4-coordinator/cmd/coordinator/main.go:1368` uses the sanitized literal
  in production.
- `phase4-coordinator/internal/payout/config_tuning_test.go:285` to
  `phase4-coordinator/internal/payout/config_tuning_test.go:289` has an empty
  conditional branch, so any unexpected `attempted_value` that is neither
  `config_load_failed` nor the raw parse error still passes.
- Repository search found no separate test for the production SIGHUP
  `config_load_failed` literal.

Issue:
The production fix appears correct, but the regression test does not lock the
secret-safe literal behavior it claims is tested separately.

Fix:
Assert `attempted_value == "config_load_failed"` in a test that exercises the
actual SIGHUP YAML-load failure branch, or at minimum make the current helper
test fail on unexpected values.

### [code:r5-8] LOW - Modified Go files are not gofmt-formatted

Confidence: HIGH

Evidence:
- `gofmt -l` reported:
  - `phase4-coordinator/cmd/coordinator/main.go`
  - `phase4-coordinator/internal/payout/config_tuning.go`
  - `phase4-coordinator/internal/payout/config_tuning_test.go`
  - `phase4-coordinator/internal/payout/reconcile.go`
  - `phase4-coordinator/internal/payout/rpc_test.go`
  - `phase4-coordinator/internal/payout/step4_test.go`
- Example: `phase4-coordinator/internal/payout/config_tuning.go:103` to
  `phase4-coordinator/internal/payout/config_tuning.go:105` has compact struct
  literal fields that `gofmt` would realign.

Issue:
This is not a runtime bug, but Go source should remain gofmt-clean before PR
open. It also makes review diffs noisier.

Fix:
Run `gofmt -w` on the listed Go files after the behavior fixes.

## r4 Closure Verification

- [code:r4-1]/[sec:r4-1] YAML-load structured emit: CODE CLOSED. Production
  `main.go` emits `key`, `attempted_value=config_load_failed`, `bound`,
  `actor`, `ts_utc`, and `severity=PAGE`. Test coverage is incomplete; see
  [code:r5-7].
- [code:r4-2] chain-balance disagreement `hot_wallet`: CLOSED.
  `reconcile.go` emits `hot_wallet`; `TestChainBalanceWorker_RPCDisagreementEmitsHotWallet`
  asserts it.
- [code:r4-3] close-idle regression test: PARTIAL. Nil-safe and composition
  cases exist, but real pool draining is not asserted; see [code:r5-5].
- [code:r4-4] stale-producer live `snap.RunInterval`: CLOSED. The new runner
  test uses startup 60m, live 10m, and a 31m-old stale row.
- [code:r4-5] `BoundViolationError` field rename: PARTIAL. Public fields are
  renamed and emit mapping works, but returned-error `errors.As` extraction is
  not preserved; see [code:r5-6].

## Positive Observations

- The production SIGHUP YAML-load path uses a sanitized literal instead of raw
  loader error text in `attempted_value`, which is the right security posture.
- `payout_chain_balance_rpc_disagreement` is no longer schema-colliding with
  payout-row `payout_rpc_disagreement` and now includes wallet attribution.
- `TestRunner_RunOnce_StaleProducerUsesLiveSnapRunInterval` is a strong,
  deterministic boundary test for the live snapshot interval.
- SPKI runbook corrections now match the implementation's 64-hex validation and
  accurately describe `CloseIdleConnections` as idle-pool-only.

## Validation

- `go test -count=1 ./...` from `phase4-coordinator/`: PASSED.
- `go test -race -count=1 ./internal/payout/...` from
  `phase4-coordinator/`: PASSED.
- `go vet ./...` from `phase4-coordinator/`: PASSED.
- `git diff --check bc1409f^..bc1409f`: PASSED.
- Pattern sweep for hardcoded secret-style assignments, empty JS catch blocks,
  and `console.log` in reviewed Go scope: no matches.
- `lsp_diagnostics` and `ast_grep_search` were requested by the reviewer
  contract but are not available as callable tools in this Codex environment;
  Go test/vet plus targeted `rg` sweeps were used as the fallback.

## Recommendation

REQUEST CHANGES.

Do not declare CONVERGENT. Fix [code:r5-1] and [code:r5-2] before PR open; they
are confirmed SPEC behavior/event violations. Fix the MEDIUM field/test gaps in
the same pass because Step 4 is the final audit gate.
