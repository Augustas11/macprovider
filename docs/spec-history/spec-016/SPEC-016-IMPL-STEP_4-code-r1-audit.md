# SPEC-016 Step 4 — code-review lane, r1 audit

Codex run: `codex-impl-audit-prompt-spec-016-step-4-code-review-lane-round-1-m-2026-06-25T18-52-00-491Z.md`
HEAD: `dbf7e78`
Branch: `impl/spec-016`

## Verdict

**REQUEST CHANGES** — 0 CRITICAL / 2 MAJOR / 3 MEDIUM / 1 LOW.

`go test ./internal/payout` + `go test ./cmd/coordinator` both pass.
The implementation compiles and tests pass, but the §6.5 reload path
and §6.2 low-balance monitoring are not functionally wired into
production behavior.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| MAJOR    | 2 |
| MEDIUM   | 3 |
| LOW      | 1 |

## Findings

### [code:r1-1] MAJOR — SIGHUP tuning reload not connected to live payout behavior

- File: `phase4-coordinator/cmd/coordinator/main.go:733`
- Confidence: HIGH

`setupPayout` constructs address service, runner, reorg poller, and
reaper from static `cfg.Payout.Tuning` values, then constructs
`TuningProvider` later. `startPayoutSIGHUPListener` reloads only the
provider, but no production consumer reads
`TuningProvider.Snapshot()`. An accepted SIGHUP reload emits
`payout_config_reloaded` while the live runner cadence,
max-rows, confirmation blocks, reorg window, cooling-off period, and
thresholds remain unchanged.

**Fix:** plumb `TuningProvider` into every reloadable consumer and
snapshot at the relevant cycle/write boundary, or rebuild affected
components on accepted reload. Add a test proving a SIGHUP changes
live behavior.

### [code:r1-2] MAJOR — Low-balance alerts are disabled by production wiring

- File: `phase4-coordinator/cmd/coordinator/main.go:745`
- Confidence: HIGH

`RunnerOptions` has `LowBalanceThreshold` and `LowNativeThreshold`,
and `emitBalanceAlerts` only probes when those values are `> 0`, but
`setupPayout` never passes `cfg.Payout.Tuning.LowBalanceThreshold` or
`LowNativeThreshold` into `NewRunner`. In production, both default to
zero and §6.2 probes never run.

**Fix:** pass both fields into `RunnerOptions`, preferably through
the same live `TuningProvider` fix above. Add a test that
configured non-zero thresholds invoke primary `CallContract` /
`NativeBalance`.

### [code:r1-3] MEDIUM — SIGHUP tuning reload validates immutable security config

- File: `phase4-coordinator/cmd/coordinator/main.go:1290`
- Confidence: HIGH

The SIGHUP handler calls `config.Load`, which resolves env vars and
validates the full config, including `payout.security.*`. That
couples tuning reload success to immutable security fields, contrary
to the "security namespace not touched" rule.

**Fix:** add a tuning-only load path that parses `payout.tuning.*`
and validates it against the startup `per_day_cap`, without
resolving or validating security keys.

### [code:r1-4] MEDIUM — AST static-check test does not walk identifiers

- File: `phase4-coordinator/internal/payout/config_tuning_test.go:214`
- Confidence: HIGH

`TestTuningStaticCheck_NoSecurityNamespaceReference` parses
`config_tuning.go` but discards the parsed file and only references
`ast.NewPackage` to keep the import alive. The checklist requires
the test to walk identifiers.

**Fix:** store the `*ast.File` returned by `parser.ParseFile` and use
`ast.Inspect` to check `*ast.Ident`, selector expressions, and
relevant string literals against the forbidden security-namespace
identifier set.

### [code:r1-5] MEDIUM — Step 4 tests miss required checklist cases

- File: `phase4-coordinator/internal/payout/step4_test.go:21`
- Confidence: HIGH

Tests cover several happy/security paths, but not all required audit
cases: missing/empty bearer 401, rate-limit 429, exact-3 unlabeled
reconcile queries assertion, semicolons inside comments,
`extractLabel` preserving body content, low-balance probe behavior,
production wiring of thresholds.

**Fix:** add focused unit tests per missing checklist item — the
production-wiring test for `RunnerOptions` is the highest-value of
the set.

### [code:r1-6] LOW — `extractLabel` removes any label directive line, not just the leading directive

- File: `phase4-coordinator/internal/payout/reconcile.go:144`
- Confidence: MEDIUM

`extractLabel` scans all lines and strips every `-- @label:` line it
sees. Current SQL is unaffected because no body line carries the
directive, but the function contract says the directive is at the
top of a statement and should strip only that directive line, not
later body comments.

**Fix:** restrict label extraction to the leading comment/blank
prefix and stop scanning once SQL body begins.

## Positive observations

- Provider mismatch correctly returns 403, not 401.
- Query (D), Query (F), provider payouts, and chain-balance
  expected-balance logic all exclude cancel self-transfers
  appropriately.
- Chain-balance negative drift emits PAGE and calls the halt
  callback at the worker layer.
- Step 4 path table correctly registers
  `/providers/{provider_id}/payouts` under provider-token auth.

## Recommendation

REQUEST CHANGES. The implementation compiles and tests pass, but the
§6.5 reload path and §6.2 low-balance monitoring are not functionally
wired into production behavior.
