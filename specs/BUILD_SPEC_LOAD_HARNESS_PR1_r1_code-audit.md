# Code Audit: Load/fairness harness PR 1

Scope note: `git diff origin/main...HEAD --stat` is empty in this worktree; the implementation is present as dirty tracked files plus untracked new files. I audited the current worktree contents for the files named by `specs/AUDIT_BUILD_SPEC_LOAD_HARNESS_PR1_IMPL_CODE_PROMPT.md`.

## Findings

1. HIGH - `test/network-harness/cmd/harness/main.go:205`: the rig shutdown is deferred, but `cmdRun` later calls `os.Exit(10)` directly on invariant failure at `test/network-harness/cmd/harness/main.go:359`. In Go, `os.Exit` bypasses defers, so any rig-backed scenario that completes and then fails I1-I4 leaves the coordinator, gateway, fake providers, and rig tempdir running on disk instead of executing `Rig.Shutdown()`. Load scenarios are specifically meant to surface hard-invariant failures, so this is a normal failure path, not an edge case. Return a sentinel exit-code error from `cmdRun` and let `main` exit after defers run.

## Verification

- `git diff origin/main...HEAD --stat` returned no files.
- `git diff --stat` / `git ls-files --others --exclude-standard` showed the pending tracked and untracked harness implementation files; those were audited as the effective pending-change scope.
- Anti-scope grep/diff checks found no pending edits under `phase4-coordinator/**`, `phase5-gateway/**`, `phase3-binary/**`, `test/network-harness/internal/metrics/collector.go`, `test/network-harness/internal/invariants/**`, scenario files other than 17, SPEC-004 files, or CI workflows.
- Token/bind grep found loopback binds only in the rig code and no rig logger callsite that prints bearer or buyer tokens.
- `go test ./internal/loadmetrics/... ./internal/scenario/...` passed.
- `go test ./internal/localrig -run TestRigLifecycle -count=1` passed.
- `go run ./cmd/harness run scenarios/17_sustained_load_baseline.yaml --out /tmp/macprovider-harness-audit-dry --dry-run` passed.

STATUS: CODE lane — CRITICAL=0 HIGH=1 MEDIUM=0 LOW=0 INFO=0
