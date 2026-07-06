# CODE AUDIT PROMPT — Load/fairness harness kickstart PR 1

You are the CODE audit lane for `feat/load-harness-pr1-baseline`.
Work read-only. Do not edit files.

Audit the implementation of PR 1 from `specs/BUILD_SPEC_LOAD_FAIRNESS_HARNESS_KICKSTART_PROMPT.md`.

## Scope (in-scope directories/files only)

- `test/network-harness/internal/scenario/schema.go` — new `Rig` / `Providers` fields on `Target`, `RigProvider` type, `validateRigTarget`, `validateProdLoadGuard`, `ProdLoadGuardEnv`/`ProdLoadGuardBuyerLimit` constants
- `test/network-harness/internal/scenario/rig_target_test.go` — validator tests
- `test/network-harness/internal/localrig/**` — new package: embedded coord+gateway+fake-providers rig
- `test/network-harness/internal/loadmetrics/**` — new package: `Compute`, `Summary`, fairness math
- `test/network-harness/cmd/harness/main.go` — wiring the rig start/stop + `load_summary.json` emit
- `test/network-harness/internal/artifact/bundle.go` — optional `load_summary.json` write hook
- `test/network-harness/scenarios/17_sustained_load_baseline.yaml`
- `test/network-harness/README.md` — rig section + scenario 17 table row
- `test/network-harness/go.mod` / `go.sum` — `github.com/gobwas/ws` add

## Anti-scope (must NOT appear in diff)

- `phase4-coordinator/**`, `phase5-gateway/**`, `phase3-binary/**`
- `test/network-harness/internal/metrics/collector.go` — additive `loadmetrics` package must not mutate the shared aggregator
- `test/network-harness/internal/invariants/**` — I1-I4 unchanged
- Any scenario file other than 17
- SPEC-004 sticky contract edits
- CI workflow changes

## Expected contract

- **Fairness math correctness**: `gini`, `stddev`, `maxMinRatio` handle empty input, all-zero counts, and single-provider fleets without div-by-zero or negative outputs. `pct` percentile matches nearest-rank convention already used in `metrics/collector.go:133-145`.
- **Route distribution attribution**: only `Outcome == "ok"` results count toward per-provider shares; providers with zero successes appear in the emitted `route_distribution` list ONLY when they are in the rig-supplied Ready set (or, on non-rig fallback, when they appear at least once in the results).
- **Starvation floor**: `min_requests_per_ready_provider` and `providers_with_zero_success` derive from the same Ready set used for fairness. Documented TODO for mid-run disconnect handling is acceptable in PR 1.
- **Prompt-class bucketing**: `LatencyByPromptClass` re-derives max_tokens via `sc.PromptFor(BuyerIndex, RequestIndex)` — no new field on `buyer.Result`. Empty buckets emit with `count=0` (stable schema for run-to-run diffs).
- **Scenario schema validators**:
  - `Rig=="local"` forbids `GatewayURL`, `CoordinatorURL`, `BuyerToken`, `DemoIdentity`, both DB path fields, both DB SSH fields, and requires `Providers` non-empty with unique IDs, non-empty Model, `TTFTMs>=0`, `TokensPerSec>=0`, `CapacitySlots>=1`.
  - Every `Prompt.Model` must be advertised by at least one `RigProvider.Model` when rig is on.
  - `Rig==""` with any `Providers` set is rejected.
  - `Buyers.Count > 10` against `*.streamvc.live` requires `ALLOW_PROD_LOAD=1`; local/other hosts are unaffected.
- **Rig lifecycle**:
  - `localrig.Start(ctx, cfg)` returns an error and leaves nothing running on partial failure.
  - `Rig.Shutdown()` is idempotent and cancels all child processes + fake providers.
  - Ports are bound to `127.0.0.1` only (grep for any `0.0.0.0` / `""` bind in configs).
  - Buyer token / provider tokens must not appear in log lines (grep the rig's Logger callsites).
- **Runner wiring**: on `sc.Target.Rig == "local"` the harness spawns the rig BEFORE `buyer.Run`, patches `sc.Target.GatewayURL` / `CoordinatorURL` / `BuyerToken` / `CoordinatorDBPath` / `GatewayDBPath`, and ensures `Rig.Shutdown()` runs on both the happy path and SIGINT/SIGTERM.
- **Three-dot diff** `git diff origin/main...HEAD` matches the scope above; no drive-by edits in coord/gateway/binary directories.

## Method

1. Read the PR: `git diff origin/main...HEAD --stat`, then walk each in-scope file.
2. Run `go test ./internal/loadmetrics/... ./internal/scenario/...` and confirm both pass.
3. Grep for `0.0.0.0`, `MAC`, `"Bearer"`, token substrings in rig code — token echo in logs is a defect.
4. Skim `test/integration/harness_test.go` (already merged, out-of-scope) to compare rig config shapes — deviations must be justified.
5. For each finding, cite `file:line`, severity (CRITICAL / HIGH / MEDIUM / LOW / INFO), and the specific failure mode.

Return findings ordered by severity with file:line references.
If no issues remain, say `No findings.`

End with:
`STATUS: CODE lane — CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n> INFO=<n>`
