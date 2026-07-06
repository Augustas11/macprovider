# Architect Audit - Load/fairness Harness PR 1

Scope note: `git diff origin/main...HEAD` is empty because the PR 1
implementation is currently uncommitted in this worktree. Per the task's
"pending changes" wording, this audit reviewed the working tree changes
reported by `git status` and `git diff` against the branch checkout.

## Findings

1. MEDIUM - Cold rig builds ignore cancellation, so SIGINT during the
   first-run build can leave the harness blocked until `go build` returns.
   `cmdRun` creates a signal-cancelled context before rig startup
   (`test/network-harness/cmd/harness/main.go:156`), and `Start` receives
   that context (`test/network-harness/cmd/harness/main.go:198`), but
   `Start` calls `buildBinaries(repoRoot, binDir)` with no context
   (`test/network-harness/internal/localrig/rig.go:150`). The actual
   build uses `exec.Command("go", "build", ...)`, not
   `exec.CommandContext` (`test/network-harness/internal/localrig/build.go:58`).
   That violates the lifecycle requirement in the architect prompt:
   a SIGINT during the ~15s cold build does not cancel the child build
   promptly, and tempdir cleanup is delayed until the build completes.

2. MEDIUM - Coordinator/gateway process death is not surfaced to the
   runner during buyer execution. The harness starts the rig and then calls
   `buyer.Run(ctx, sc)` with only the signal context
   (`test/network-harness/cmd/harness/main.go:229`). The rig's
   `registerProc` goroutine discards the child exit status and only marks
   the WaitGroup done (`test/network-harness/internal/localrig/rig.go:331`).
   There is no exposed `Done`/`Err` channel or context cancellation path
   from a crashed coordinator or gateway back into `cmdRun`. If either
   process dies after startup health checks, buyers continue firing until
   request timeouts and the scenario duration govern exit
   (`test/network-harness/internal/buyer/loadgen.go:26`). This makes a
   rig infrastructure failure look like load-lane traffic data instead of
   a fast harness failure.

3. MEDIUM - The local rig is fake-provider only at its public boundary,
   which makes the planned "sometimes-fails" provider and real
   `macprovider-cli` substitution require localrig internals to change.
   `Config.Providers` is a slice of the concrete data struct
   (`test/network-harness/internal/localrig/rig.go:40`), `Provider` only
   carries ID/model/latency/capacity fields
   (`test/network-harness/internal/localrig/rig.go:52`), and `Start`
   unconditionally turns every provider into `newFakeProvider(...)`
   (`test/network-harness/internal/localrig/rig.go:272`). The fake owns
   both the HTTP responder and WS lifecycle in one concrete type
   (`test/network-harness/internal/localrig/providers.go:18`). Adding
   more providers by count is fine, but adding failure-mode providers or
   mixing in a real `macprovider-cli serve` process is not additive at the
   current package boundary.

4. LOW - The config-writing fork from `test/integration` is documented
   only as coexistence, not as an intentional deferred share-refactor with
   coupling tests. The README says `test/integration` continues to own
   real-binary functional tests and future PRs may add a smoke target
   (`test/network-harness/README.md:333`), but there is no
   `TODO(shared-rig-refactor)` marker in the new rig and no test tying
   the rig's coordinator/gateway YAML shape back to
   `test/integration/harness_test.go`. This is a drift risk when prod
   config shape changes.

5. LOW - PR-body requirements could not be verified because this branch
   has no discoverable PR metadata (`gh pr view` returned no PR for the
   current branch). The scenario file itself covers the empirical scale
   ceiling, Pearl DoS rationale, fairness metric choice, and follow-up
   scenarios 18-22 (`test/network-harness/scenarios/17_sustained_load_baseline.yaml:3`,
   `test/network-harness/scenarios/17_sustained_load_baseline.yaml:26`,
   `test/network-harness/scenarios/17_sustained_load_baseline.yaml:46`),
   but the architect prompt requires those points in the PR description.

6. INFO - The audit prompt references
   `specs/BUILD_SPEC_LOAD_FAIRNESS_HARNESS_KICKSTART_PROMPT.md`
   (`specs/AUDIT_BUILD_SPEC_LOAD_HARNESS_PR1_IMPL_ARCHITECT_PROMPT.md:6`),
   but that build-spec file is absent from this checkout and from
   `origin/main`. I audited against the architect prompt's embedded
   contract and the full changed files, but this weakens traceability for
   future audit rounds.

## Design Notes

- `load_summary.json` schema is mostly stable. The top-level summary
  fields are shallow and generic (`test/network-harness/internal/loadmetrics/summary.go:22`),
  route/fairness/starvation fields avoid non-streaming-only names
  (`test/network-harness/internal/loadmetrics/summary.go:52`,
  `test/network-harness/internal/loadmetrics/summary.go:62`,
  `test/network-harness/internal/loadmetrics/summary.go:108`), and empty
  class buckets are emitted for stable keys
  (`test/network-harness/internal/loadmetrics/summary.go:277`). Window
  seconds is computed from StartUTC/EndUTC extremes over partial results,
  so mid-run cancellation truthfully reports the observed window
  (`test/network-harness/internal/loadmetrics/summary.go:158`).
- Fairness metric tradeoffs are documented well enough for PR 1:
  Gini, stddev, max/min, and provider count ship together
  (`test/network-harness/internal/loadmetrics/summary.go:62`), and the
  max/min floor is explicitly documented with a pointer to raw starvation
  fields (`test/network-harness/internal/loadmetrics/summary.go:77`).
- The DoS guard runs during scenario validation before requests fire and
  covers any buyer-fleet scenario with `buyers.count > 10` against
  `*.streamvc.live`, including chaos scenarios if they are scaled that
  high (`test/network-harness/internal/scenario/schema.go:671`). Tests use
  `t.Setenv` for both reject and override paths
  (`test/network-harness/internal/scenario/rig_target_test.go:162`,
  `test/network-harness/internal/scenario/rig_target_test.go:175`).
- `Shutdown` is idempotent via `sync.Once` and removes only the rig-owned
  workdir (`test/network-harness/internal/localrig/rig.go:295`). The
  127.0.0.1 bind invariant is explicit in generated configs and fake
  listeners (`test/network-harness/internal/localrig/coord.go:46`,
  `test/network-harness/internal/localrig/gateway.go:37`,
  `test/network-harness/internal/localrig/providers.go:85`).

## Verification

- Read the architect prompt, code prompt, full changed files, and
  relevant integration harness sections.
- `go test ./internal/loadmetrics/... ./internal/scenario/...` passed from
  `test/network-harness`.
- Grep for `0.0.0.0`, `Bearer`, token strings, and rig logger callsites
  found no bearer/token values emitted through the rig logger.

STATUS: ARCHITECT lane — CRITICAL=0 HIGH=0 MEDIUM=3 LOW=2 INFO=1
