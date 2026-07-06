# SECURITY AUDIT - Load/fairness harness kickstart PR 1, Round 2

Branch/worktree: `feat/load-harness-pr1-baseline` at `/Users/augstar/macprovider-load-pr1`

Scope note: the Round 2 request targeted the r1 HIGH finding in
`test/network-harness/internal/scenario/schema.go` plus the regression tests in
`test/network-harness/internal/scenario/rig_target_test.go`. I also rechecked
the security-prompt areas from the r1 lane against the current working-tree
implementation.

## Findings

No findings.

## Round 2 Fix Verification

- `test/network-harness/internal/scenario/schema.go:680` now normalizes the
  parsed gateway hostname with
  `strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")` before checking the
  production suffix. This closes the r1 bypass where
  `https://api.streamvc.live.` skipped the `*.streamvc.live` DoS guard.
- `test/network-harness/internal/scenario/schema.go:698` covers both subdomains
  ending in `.streamvc.live` and the apex `streamvc.live` host.
- `test/network-harness/internal/scenario/schema.go:701` still accepts only the
  literal `ALLOW_PROD_LOAD=1` override.
- `test/network-harness/internal/scenario/rig_target_test.go:194` covers the
  trailing-dot host case.
- `test/network-harness/internal/scenario/rig_target_test.go:207` covers
  uppercase host normalization.
- `test/network-harness/internal/scenario/rig_target_test.go:218` covers the
  apex `streamvc.live` host.
- `test/network-harness/internal/scenario/rig_target_test.go:231` covers that
  truthy values other than literal `1` do not bypass the guard.

## Non-Findings Rechecked

- Uppercase hosts, non-standard ports, and userinfo do not bypass the prod load
  guard because the check uses `url.Hostname()` and lowercases the host before
  suffix comparison.
- The guard is scoped to buyer-fleet validation; sku-econ continues to use its
  own coordinator host pinning.
- Local rig listeners and generated coordinator/gateway configs bind to
  `127.0.0.1`; greps found no `0.0.0.0` or bare-port listener forms under
  `internal/localrig`.
- Coordinator and gateway YAML files are written with `0o600`. The default rig
  tempdir is created by `os.MkdirTemp` and is removed by `Rig.Shutdown()`.
- The minted buyer API key is patched only into the in-memory scenario before
  `buyer.Run`; artifact writing copies the original scenario YAML and writes
  request/meta/load summaries that do not include `BuyerToken`.
- Gateway seeding discards subprocess stdout/stderr. Provider-token issuance
  parses successful `token=` output without logging the raw token; the
  coordinator CLI prints `token=` only after `store.IssueToken` returns nil, so
  localrig's failure-output wrapper does not expose a newly minted token from a
  failed command.
- Scenario 17 contains no `${VAR}` placeholders.
- Rig binary builds set `CGO_ENABLED=0`.

## Validation

- `go test ./internal/loadmetrics/... ./internal/scenario/... ./internal/localrig/... ./cmd/harness`
- `go test ./internal/scenario -run 'TestProdLoadGuard|TestValidateRig' -count=1`
- Greps run for prod guard coverage, listener bind forms, token/logging call
  sites, artifact `BuyerToken` usage, temp/config file writes, subprocess env
  inheritance, `CGO_ENABLED`, and `${VAR}` placeholders in scenario 17.

STATUS: SECURITY lane — CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0 INFO=0
