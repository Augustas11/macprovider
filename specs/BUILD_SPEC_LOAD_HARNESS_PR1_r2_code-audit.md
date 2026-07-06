# Code Audit Round 2: Load/fairness harness PR 1

Scope note: the PR implementation is still present as dirty tracked files plus untracked new files in `/Users/augstar/macprovider-load-pr1`. `git diff origin/main...HEAD --stat` is empty because the branch itself has no committed PR diff; I used the current worktree diff plus untracked files as the effective r1-to-r2 audit surface, with special focus on the Round 1 HIGH finding in `test/network-harness/cmd/harness/main.go`.

## Findings

No findings.

## Round 1 HIGH verification

- Fixed: `test/network-harness/cmd/harness/main.go:35` defines `errHardInvariantFail`.
- Fixed: `test/network-harness/cmd/harness/main.go:49` maps `errors.Is(err, errHardInvariantFail)` to `os.Exit(10)` in `main()`, after `cmdRun` has returned.
- Fixed: `test/network-harness/cmd/harness/main.go:187` and `test/network-harness/cmd/harness/main.go:395` now return the sentinel instead of calling `os.Exit(10)` from inside `cmdRun`.
- Teardown path preserved: `test/network-harness/cmd/harness/main.go:216` defers `rig.Shutdown()` immediately after successful `localrig.Start`, so hard-invariant failures now unwind `cmdRun` defers before the process exits with code 10.
- No remaining direct `os.Exit` calls are reachable after rig startup inside `cmdRun`; remaining `os.Exit` calls are in `main()`/usage handling before `cmdRun` returns or for other subcommands.

## Verification

- `git diff -- test/network-harness/cmd/harness/main.go` shows the Round 2 change from direct `os.Exit(10)` inside `cmdRun` to `return errHardInvariantFail`.
- `git diff --check` passed.
- `go test ./internal/loadmetrics/... ./internal/scenario/...` passed.
- `go test ./cmd/harness` passed.
- `go test ./internal/localrig -run TestRigLifecycle -count=1` passed.
- `go run ./cmd/harness run scenarios/17_sustained_load_baseline.yaml --out /tmp/macprovider-harness-r2-dry --dry-run` passed.
- Grep review found rig binds/config URLs on `127.0.0.1` and no rig logger callsite that prints buyer/provider bearer token values.
- Anti-scope check found no tracked pending edits under `phase4-coordinator/**`, `phase5-gateway/**`, `phase3-binary/**`, `test/network-harness/internal/metrics/collector.go`, `test/network-harness/internal/invariants/**`, SPEC-004 files, CI workflows, or scenario files other than scenario 17.

STATUS: CODE lane — CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0 INFO=0
