# Architect Audit - Load/fairness Harness PR 1 - Round 2

Scope note: `git diff origin/main...HEAD` is empty because this PR 1
implementation is currently in the working tree as unstaged/untracked files.
This audit reviewed the working-tree content under the architect prompt's
scope. The referenced source build spec
`specs/BUILD_SPEC_LOAD_FAIRNESS_HARNESS_KICKSTART_PROMPT.md` is absent from
this checkout, so traceability is against the audit prompt and in-scope files.

## Findings

1. LOW - The config-writing fork from `test/integration` is still documented
   only as coexistence, not as an intentional deferred share-refactor with a
   coupling test. The README says `test/integration` continues to own
   real-binary functional regression tests and future PRs may add a smoke
   target (`test/network-harness/README.md:333`), while localrig says the
   process boundary has the same shape as integration
   (`test/network-harness/internal/localrig/rig.go:14`). There is still no
   `TODO(shared-rig-refactor)` marker in localrig and no test tying the
   generated coordinator/gateway YAML shape to
   `test/integration/harness_test.go`, so config-shape drift remains a
   low-severity longevity risk.

2. LOW - PR-body coverage still cannot be verified because no GitHub PR is
   discoverable for the current branch (`gh pr view` returned "no pull
   requests found for branch \"feat/load-harness-pr1-baseline\""). The scenario
   and code comments cover the operational rationale, but the architect prompt
   specifically asks whether the PR description explains the empirical scale
   ceiling, follow-up scenarios 18-22, and fairness metric choice.

3. INFO - The audit prompt references
   `specs/BUILD_SPEC_LOAD_FAIRNESS_HARNESS_KICKSTART_PROMPT.md`, but that file
   is absent from this worktree and from the visible `specs/` listing. I
   audited against the architect prompt's embedded contract plus the full
   in-scope working-tree files.

## R1 Medium Recheck

- Resolved: cold binary builds are now cancellation-aware. `buildBinaries`
  accepts `context.Context` and passes it into all three `buildOne` calls
  (`test/network-harness/internal/localrig/build.go:45`,
  `test/network-harness/internal/localrig/build.go:52`), and `buildOne` uses
  `exec.CommandContext` plus returns the context error on cancellation
  (`test/network-harness/internal/localrig/build.go:64`). `Start` now passes
  the rig context into the build step
  (`test/network-harness/internal/localrig/rig.go:237`), so SIGINT/SIGTERM
  during a cold `go build` cancels the child process instead of blocking until
  the compiler exits naturally.

- Resolved: coordinator/gateway death is now surfaced to the runner.
  `Rig.Done()` exposes the crash channel and `Rig.Err()` exposes the first
  supervised-process error (`test/network-harness/internal/localrig/rig.go:156`,
  `test/network-harness/internal/localrig/rig.go:165`). `registerProc`
  observes `cmd.Wait()` and records non-shutdown exits
  (`test/network-harness/internal/localrig/rig.go:443`,
  `test/network-harness/internal/localrig/rig.go:453`), while `recordCrash`
  suppresses exits after `Shutdown` has started via `shuttingDown`
  (`test/network-harness/internal/localrig/rig.go:473`). The runner derives
  `buyerCtx`, races `rig.Done()` against `buyer.Run`, cancels the buyers on
  rig crash, and converts the completed race into a localrig error
  (`test/network-harness/cmd/harness/main.go:240`,
  `test/network-harness/cmd/harness/main.go:259`,
  `test/network-harness/cmd/harness/main.go:263`).

- Resolved: provider implementation selection is now additive at the localrig
  boundary. `Provider.Kind` and `ProviderKindFake` document the dispatch
  point for future fail-inject and real-binary providers
  (`test/network-harness/internal/localrig/rig.go:68`,
  `test/network-harness/internal/localrig/rig.go:79`). `providerProcess`
  abstracts provider lifecycle start/stop
  (`test/network-harness/internal/localrig/rig.go:90`), `Start` constructs
  providers through `newProviderProcess`
  (`test/network-harness/internal/localrig/rig.go:359`), and the factory
  currently supports fake providers while rejecting unknown kinds explicitly
  (`test/network-harness/internal/localrig/rig.go:414`). Future
  `ProviderKindFailInject` / `ProviderKindRealBinary` additions can plug into
  that factory without rewriting the main rig start loop.

## Design Notes

- `load_summary.json` field names remain generic enough for later streaming
  scenarios: route distribution, fairness, latency buckets, and starvation
  floor are named without scenario-17-only terminology
  (`test/network-harness/internal/loadmetrics/summary.go:22`,
  `test/network-harness/internal/loadmetrics/summary.go:52`,
  `test/network-harness/internal/loadmetrics/summary.go:62`,
  `test/network-harness/internal/loadmetrics/summary.go:108`).
- Empty-run schema is stable at the top level because `Compute` always returns
  a `Summary` with all struct fields and initializes the latency-class map
  (`test/network-harness/internal/loadmetrics/summary.go:147`,
  `test/network-harness/internal/loadmetrics/summary.go:154`). Empty latency
  buckets are emitted for every configured class
  (`test/network-harness/internal/loadmetrics/summary.go:277`).
- `WindowSeconds` is computed from the earliest result start and latest result
  end across the observed results, so a mid-run cancellation truthfully reports
  the shorter observed window
  (`test/network-harness/internal/loadmetrics/summary.go:158`).
- Fairness metric tradeoffs are documented in code: Gini, stddev, max/min, and
  provider count ship together (`test/network-harness/internal/loadmetrics/summary.go:62`),
  and the max/min denominator floor points readers to the raw starvation fields
  (`test/network-harness/internal/loadmetrics/summary.go:77`,
  `test/network-harness/internal/loadmetrics/summary.go:367`).
- Localrig has no provider-count cap beyond slice length and OS/socket limits:
  provider ports are allocated per configured provider
  (`test/network-harness/internal/localrig/rig.go:255`), and each fake binds
  to `127.0.0.1` (`test/network-harness/internal/localrig/providers.go:85`).
- Metric primitives remain reusable. `Class` accepts arbitrary labels and
  token ranges (`test/network-harness/internal/loadmetrics/summary.go:125`);
  `DefaultClasses` are scenario-17 defaults only, and callers can pass a custom
  class list (`test/network-harness/internal/loadmetrics/summary.go:135`,
  `test/network-harness/internal/loadmetrics/summary.go:149`).
- The production load guard still runs during scenario validation before any
  request fires and covers high buyer counts against the StreamVC apex or
  subdomains (`test/network-harness/internal/scenario/schema.go:671`,
  `test/network-harness/internal/scenario/schema.go:698`). Tests use
  `t.Setenv` for reject and override paths
  (`test/network-harness/internal/scenario/rig_target_test.go:162`,
  `test/network-harness/internal/scenario/rig_target_test.go:175`).

## Verification

- Read the architect prompt, code prompt, R1 architect audit, and the in-scope
  working-tree files under `test/network-harness/internal/localrig/`,
  `test/network-harness/internal/loadmetrics/`,
  `test/network-harness/internal/scenario/`, `cmd/harness/main.go`,
  `internal/artifact/bundle.go`, `README.md`, and scenario 17.
- Ran from `test/network-harness`:
  `go test ./internal/localrig/... ./internal/scenario/... ./internal/loadmetrics/... ./cmd/harness`
  and it passed.
- Checked PR metadata with `gh pr view --json number,title,body,headRefName,baseRefName`;
  no PR exists for the current branch, so PR-body-only requirements remain
  unverifiable in this worktree.

STATUS: ARCHITECT lane - CRITICAL=0 HIGH=0 MEDIUM=0 LOW=2 INFO=1
