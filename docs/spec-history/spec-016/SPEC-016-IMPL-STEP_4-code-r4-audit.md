# SPEC-016 Step 4 IMPL Code Audit - Round 4

## Verdict

NOT CONVERGENT.

The r3 production fixes mostly close the prior code-lane defects:
`RunOnce` now returns the cycle `run_id`, the cadence loop compiles with the
new signature, stale production reads `snap.RunInterval`, reload success
returns actually changed keys, SPKI reloads close both idle HTTP transports,
and the post-RunOnce halt race is now reachable through `runnerExecutor`.

However, the r4 code lane still has event-schema gaps and required regression
test gaps.

## Counts

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 4
- LOW: 1

## Findings

### [code:r4-1] MEDIUM - YAML parse reload rejection still emits the old sparse event shape

Confidence: HIGH

Evidence:
- `phase4-coordinator/cmd/coordinator/main.go:1353` calls
  `config.LoadPayoutTuningOnly(configPath)`.
- `phase4-coordinator/cmd/coordinator/main.go:1355` to `phase4-coordinator/cmd/coordinator/main.go:1358`
  logs `payout_config_reload_rejected` with only `event`, `severity`, and the
  zerolog error field.
- `specs/SPEC-016-payout-pipeline.md:3731` requires
  `key, attempted_value, bound, actor, ts_utc` for
  `payout_config_reload_rejected`.
- `phase4-coordinator/internal/payout/config_tuning.go:370` to
  `phase4-coordinator/internal/payout/config_tuning.go:378` has a structured
  fallback for non-bound errors, but the SIGHUP YAML-load failure returns
  before that helper is reached.

Issue:
The r3 fix closed bound-violation reload events, but parse/load failures still
violate the same Section 7.1 event contract. The shared r4 context explicitly
expected YAML-load failure to emit `key=yaml_parse` plus the structured
rejection fields; the active SIGHUP branch does not.

Fix:
Route loader errors through a shared structured rejection emitter, or log this
branch with `key="yaml_parse"`, `attempted_value=err.Error()`,
`bound="valid_yaml"`, `actor="operator_key:coordinator"`, `ts_utc`, and
`severity="PAGE"`.

### [code:r4-2] MEDIUM - `payout_chain_balance_rpc_disagreement` omits `hot_wallet`

Confidence: HIGH

Evidence:
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r4.md:110` requires the new
  chain-balance-only event fields:
  `primary_balance, secondary_balance, tolerance, hot_wallet, ts_utc`.
- `phase4-coordinator/internal/payout/reconcile.go:404` to
  `phase4-coordinator/internal/payout/reconcile.go:410` emits
  `event`, `severity`, `primary_balance`, `secondary_balance`, `tolerance`,
  and `ts_utc`, but not `hot_wallet`.

Issue:
The r3 rename avoids the collision with the Section 7.1
`payout_rpc_disagreement` schema, but the new chain-balance event still lacks
the wallet identity required by the r4 event sweep. That makes multi-wallet or
future rotated-wallet logs harder to attribute.

Fix:
Add `Str("hot_wallet", w.cfg.HotWalletAddr)` to the disagreement event and
extend the chain-balance disagreement test to assert the field.

### [code:r4-3] MEDIUM - No regression test covers the SPKI close-idle path

Confidence: HIGH

Evidence:
- `phase4-coordinator/internal/payout/rpc.go:175` to
  `phase4-coordinator/internal/payout/rpc.go:178` implements
  `HTTPRPCClient.CloseIdleConnections`.
- `phase4-coordinator/cmd/coordinator/main.go:1394` to
  `phase4-coordinator/cmd/coordinator/main.go:1405` calls it on both primary
  and secondary clients when either SPKI key appears in `changedKeys`.
- The r3 diff for `phase4-coordinator/internal/payout/rpc_test.go` only
  removes the final blank line; no close-idle test was added.
- Repository search found SPKI live-read tests at
  `phase4-coordinator/internal/payout/rpc_test.go:324`, but no test that
  exercises `CloseIdleConnections` or the SIGHUP changed-key composition.

Issue:
The production code appears correct, but the r4 checklist requires a new test
for the SPKI close-idle path. The high-severity r3 closure can regress if a
future change removes the transport field, changes the concrete-client type, or
stops closing one side.

Fix:
Add a focused unit test for `HTTPRPCClient.CloseIdleConnections` and, ideally,
a coordinator-level test with fake primary/secondary clients proving that SPKI
changed keys close both clients while non-SPKI changes close neither. If the
current concrete type assertion makes fakes awkward, introduce a narrow
`interface{ CloseIdleConnections() }` path for testability.

### [code:r4-4] MEDIUM - No runner-level regression test proves stale production uses the live snapshot interval

Confidence: HIGH

Evidence:
- `phase4-coordinator/internal/payout/runner.go:401` to
  `phase4-coordinator/internal/payout/runner.go:402` now passes
  `snap.RunInterval` into `ProduceStaleOutboxRows`.
- Existing stale producer tests call `ProduceStaleOutboxRows` directly, for
  example `phase4-coordinator/internal/payout/step3_r2_test.go:39` to
  `phase4-coordinator/internal/payout/step3_r2_test.go:55`; they do not prove
  `Runner.RunOnce` uses a `TuningProvider` snapshot rather than
  `r.opts.RunInterval`.
- Repository search found no runner test combining `TuningProvider`,
  `RunOnce`, and stale-cancel production.

Issue:
The code change closes the stale-producer authority gap, but the r4 checklist
requires a new test for `snap.RunInterval`. Without a runner-level regression
test, a future edit can silently revert to the startup interval while direct
producer tests keep passing.

Fix:
Add a `Runner.RunOnce` test that seeds a stale cancel row at an age between
`3 * liveRunInterval` and `3 * startupRunInterval`, wires a `TuningProvider`
with the shorter live interval, and asserts an outbox row is produced. That
test fails if `RunOnce` uses `r.opts.RunInterval`.

### [code:r4-5] LOW - `BoundViolationError` shape does not match the r4 review contract

Confidence: MEDIUM

Evidence:
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r4.md:90` to
  `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r4.md:94` asks for
  public `Field`, `Attempted`, `Bound`, and `Actor` fields and
  `errors.As` extraction from the SIGHUP handler.
- `phase4-coordinator/internal/payout/config_tuning.go:245` to
  `phase4-coordinator/internal/payout/config_tuning.go:249` exposes
  `Key`, `AttemptedValue`, and `Bound`; `Actor` is hardcoded later in
  `emitRejected`.

Issue:
The runtime bound-violation log includes the required Section 7.1 fields, so
this is not a behavioral blocker. It is still a review-contract mismatch and
makes the structured error less directly reusable by callers.

Fix:
Either update the r4 contract/documentation to the implemented `Key` /
`AttemptedValue` shape, or expose aliases/fields matching the requested
`Field`, `Attempted`, `Bound`, `Actor` names and let the SIGHUP layer extract
them with `errors.As`.

## Positive Observations

- `TuningProvider.Reload` now returns `nil` changed keys on validation failure
  and computes changed keys from field-by-field old/new comparisons.
- `RunNowController` uses the `RunOnce` return value for the accepted response
  and `payout_run_now_invoked`, closing the r3 run-ID correlation defect.
- `CloseIdleConnections` uses `http.Transport.CloseIdleConnections`, which only
  drains idle pooled connections; active in-flight requests are not cancelled by
  this call.
- SPKI changes to empty strings are included in the changed-key comparison, so
  accepted pin-disable reloads still close idle connections and force the next
  handshake to observe pinning disabled.
- `TestRunNowController_PostRunOnceHaltRaceReturnsHaltedBody` covers the
  intended 409 halt-race branch.

## Validation

- `go test -race -count=1 ./internal/payout/...` passed from
  `phase4-coordinator`.
- `go test -count=1 ./cmd/coordinator` passed from `phase4-coordinator`.
- `go vet ./internal/payout/... ./cmd/coordinator` passed from
  `phase4-coordinator`.
- Pattern sweep for hardcoded secret-style assignments and empty catches in the
  reviewed Go scope found no matches.
- `lsp_diagnostics` and `ast_grep_search` were requested by the reviewer
  contract, but no such tools/binaries were available in this environment
  (`gopls`, `ast-grep`, and `sg` were not installed).

## Recommendation

COMMENT.

No CRITICAL or HIGH code-lane defects were found at high confidence, but the
lane is not convergent until the remaining event-schema gaps and required
regression tests are fixed.
