# SPEC-016 Step 4 — architecture-review lane, r1 audit

Codex run: `codex-impl-audit-prompt-spec-016-step-4-architecture-review-lane-r-2026-06-25T18-53-16-781Z.md`
HEAD: `dbf7e78`
Branch: `impl/spec-016`

## Verdict

**BLOCK** — 1 CRITICAL / 2 MAJOR / 1 MEDIUM / 2 LOW.

The chain-balance worker detects negative drift but `main.go` wires
the halt callback to logging only, so the runner is not actually
halted on the fake-funding signature. The §6.5 tuning reload path
also accepts new values without wiring them into most long-lived
consumers, and §6.2 balance alerts are disabled at startup because
thresholds are never passed to the runner.

`go test ./... -count=1` in `phase4-coordinator` passed across all
packages.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 1 |
| MAJOR    | 2 |
| MEDIUM   | 1 |
| LOW      | 2 |

## Findings

### [arch:4.1] CRITICAL — negative chain-balance drift does not actually halt the runner

- `phase4-coordinator/cmd/coordinator/main.go:868`
- `phase4-coordinator/internal/payout/reconcile.go:416`
- SPEC §7.4 (`specs/SPEC-016-payout-pipeline.md:3913`): drift beyond
  tolerance emits a signed drift event and halts the runner.

`ChainBalanceWorker.runOnce` correctly emits
`payout_chain_balance_drift_negative` and invokes
`w.haltRunner(...)` on negative drift. But `setupPayout` wires the
callback only to emit `payout_runner_halt_requested`; it explicitly
says programmatic auto-halt is not done.

**Fix:** add a real runner halt primitive (or persistent halt flag in
`runtime_flags`), wire `ChainBalanceWorker` negative drift to it, and
make admin run-now refuse while halted.

Converges with [sec:r1-1] HIGH and [code:r1-1]/[code:r1-2] MAJORs.

### [arch:4.2] MAJOR — accepted SIGHUP tuning reloads do not reach the components that must consume them

- `phase4-coordinator/cmd/coordinator/main.go:1290` — SIGHUP listener
  loads YAML and swaps only `TuningProvider`.
- `phase4-coordinator/cmd/coordinator/main.go:733` — AddressesService
  constructed with fixed `cfg.Payout.Tuning.AddressCoolingOffPeriod`.
- `phase4-coordinator/internal/payout/addresses.go:420` —
  `pending_until_utc` computed from the static field.
- Same construction-time capture applies to runner cadence and payout
  selection (`runner.go:162`, `:262`), reorg polling (`reorg.go:295`),
  and reaper cadence/stale age (`reaper.go:111`).

New registrations do not cool off against the new value after
reload, and the runner/reorg/reaper continue at the original cadence
+ caps despite `payout_config_reloaded` audit trail.

**Fix:** inject `TuningProvider` (or a `Snapshot() TuningSnapshot`
function) into each consumer and read at the right boundary; OR
stop-and-rebuild affected components on accepted SIGHUP. Tickers
that read cadence at construction need explicit ticker reset.

Converges with [code:r1-1] MAJOR and [sec:r1-2] MEDIUM.

### [arch:4.3] MAJOR — §6.2 balance monitoring is disabled even at startup

- `phase4-coordinator/internal/payout/runner.go:67` — `RunnerOptions`
  has `LowBalanceThreshold` and `LowNativeThreshold`.
- `phase4-coordinator/internal/payout/runner.go:1217` —
  `emitBalanceAlerts` returns immediately when both are zero.
- `phase4-coordinator/cmd/coordinator/main.go:745` — `setupPayout`
  builds `NewRunner` without assigning either configured threshold.

Configured nonzero thresholds never activate the probes.

**Fix:** pass both fields into `RunnerOptions` (or via the
`TuningProvider` plumbing from [arch:4.2]). Add a test that
configured non-zero thresholds invoke the probes.

Converges with [code:r1-2] MAJOR and [sec:r1-3] MEDIUM.

### [arch:4.4] MEDIUM — the security/tuning static check is not a true AST guarantee

- `phase4-coordinator/internal/payout/config_tuning_test.go:185`
- `phase4-coordinator/internal/payout/config_tuning_test.go:214`
- `phase4-coordinator/internal/payout/config_tuning_test.go:221`

`TestTuningStaticCheck_NoSecurityNamespaceReference` mostly uses
`strings.Contains` over file bytes. It parses the file only to prove
valid Go, then keeps `go/ast` alive with `_ = ast.NewPackage`. The
current code appears clean, but the test is not the
compile-time/static-AST guard the prompt claims.

**Fix:** replace the test with a real AST walk
(`ast.Inspect(file, fn)`) that fails on any `*ast.Ident`,
selector-expression, or string-literal referencing the forbidden
security-namespace identifier set.

Converges with [code:r1-4] MEDIUM.

### [arch:4.5] LOW — Step 3 advisories are still open and should be tracked explicitly

- `phase4-coordinator/internal/payout/orphans.go:397` —
  `ProduceStaleOutboxRows` still selects all stale candidates
  without `LIMIT`.
- Chronic single-RPC outage still has only per-cycle RPC error
  events, not a distinct "primary down >1h" operator signal.
- `specs/SPEC-016-IMPL-STEP_3-r4-convergence.md:163` — Step 3
  convergence file carried both as Step 4 advisories.

**Fix:** file ONE tracking issue per
[[tracking-issue-scope-control]] covering both. Don't bundle into
Step 4.

### [arch:4.6] LOW — deploy gate does not require all Step 4 tuning keys

- `phase4-coordinator/dist/coordinator.yaml.example:210` — example
  includes `low_balance_threshold` and `low_native_threshold`.
- `phase4-coordinator/dist/check-deploy-config.sh:373` — required
  tuning-key loop omits both.

**Fix:** add both keys to the loop. Converges with [sec:r1-3] MEDIUM.

## PR-readiness matrix

| Row | Verdict |
|-----|---------|
| §6.5 dual-namespace loader split | **PARTIAL** — split exists at the type level but reload does not propagate to consumers |
| §7.4 reconciliation queries verbatim | OK |
| §7.4 chain-balance worker drift detection | **PARTIAL** — detection works; halt does not |
| §6.2 balance monitoring emits | **NO** — thresholds never wired into RunnerOptions |
| §7.3 provider-scoped read endpoint | OK |
| Ops bundle (yaml.example + deploy gate + runbook) | **PARTIAL** — gate missing 2 keys |
| 4-background shutdown composition | OK |
| Step 3 advisories addressed or deferred | **DEFERRED** — must be tracking-issue'd |

## Root cause

Step 4 introduced `TuningProvider` as a passive atomic holder, but
did not complete the architectural handoff into lifecycle-owned
services. Likewise, the chain-balance worker has the right local
callback shape, but the production callback in `main.go` was
downgraded from "halt" to "log a request." This is the same pattern
as PR #69 fix-pass-4 (cf [[audit-cycles-are-design-discovery]]): the
abstraction is right; enforcement isn't centralized across the
system.

## Recommendation

BLOCK. Three convergent fixes required before r2 audit. The Step 3
advisories should be filed as a single tracking issue, not bundled
into Step 4.
