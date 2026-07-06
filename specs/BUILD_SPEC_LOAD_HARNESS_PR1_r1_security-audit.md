# SECURITY AUDIT — Load/fairness harness kickstart PR 1

Branch/worktree: `feat/load-harness-pr1-baseline` at `/Users/augstar/macprovider-load-pr1`

Scope note: `git diff origin/main...HEAD -- test/network-harness/` returned no files because the PR1 harness changes are currently unstaged/untracked in this worktree while `HEAD` is behind `origin/main`. I audited the pending working-tree changes reported by `git status --short` plus the in-scope files named by `specs/AUDIT_BUILD_SPEC_LOAD_HARNESS_PR1_IMPL_CODE_PROMPT.md`.

## Findings

### HIGH

1. `test/network-harness/internal/scenario/schema.go:690`

   Issue: `validateProdLoadGuard` does not normalize a trailing DNS root dot before checking the production suffix. It lowercases `u.Hostname()` and then requires `strings.HasSuffix(host, ".streamvc.live")`; for `gateway_url: https://api.streamvc.live.`, `url.Hostname()` returns `api.streamvc.live.`, which does not end with `.streamvc.live`. DNS treats the trailing-dot form as equivalent to `api.streamvc.live`, so a buyer-fleet scenario with `buyers.count: 20` and no `ALLOW_PROD_LOAD=1` bypasses the DoS guard and can still hit Pearl production.

   Attack scenario: a committed or operator-supplied scenario sets `mode: buyer-fleet`, `gateway_url: https://api.streamvc.live.`, a valid buyer token, and `buyers.count` above `10`. Validation reaches `validateProdLoadGuard`, skips the guard at `schema.go:694`, and the run can send load-lane traffic to the production gateway even though the same host without the trailing dot is rejected by `TestProdLoadGuard_HighConcurrencyRejected`.

   Fix: normalize the hostname before the suffix check, for example `host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")`, then check `host == "streamvc.live" || strings.HasSuffix(host, ".streamvc.live")` as appropriate for the intended production host set. Add a regression test for `https://api.streamvc.live.` and keep the existing `ALLOW_PROD_LOAD == "1"` literal-only override behavior.

## Non-Findings Checked

- Uppercase production host and non-standard port are covered by `url.Hostname()` plus lowercasing; the port is not part of `Hostname()`.
- Userinfo does not affect the guard because `url.Hostname()` excludes it.
- The guard is scoped to buyer-fleet validation; `sku-econ` uses its own host pinning.
- Only literal `ALLOW_PROD_LOAD=1` bypasses the guard.
- Local rig listeners and generated coordinator/gateway configs bind to `127.0.0.1`; no `0.0.0.0` or bare `":port"` listener was found under `internal/localrig`.
- Coordinator and gateway YAML files are written with `0o600`; default rig tempdirs are owned tempdirs and are removed by `Rig.Shutdown()`.
- The minted gateway buyer key is patched into the in-memory scenario for `buyer.Run`; `run_meta.json`, `per_request.jsonl`, and `load_summary.json` do not serialize `BuyerToken`.
- Gateway seeding discards subprocess stdout/stderr, and provider-token issuance output is parsed without logging the raw token on the successful path.
- Scenario 17 contains no `${VAR}` placeholders.
- `go build` for rig binaries sets `CGO_ENABLED=0`.

## Validation

- `go test ./internal/loadmetrics/... ./internal/scenario/...`
- `go test ./internal/localrig/...`
- `go test ./cmd/harness`
- `go test ./internal/scenario -run 'TestProdLoadGuard|TestValidateRig' -count=1`
- Greps run for logging/token call sites, bearer usage, file writes, listener binds, `0.0.0.0`, bare TCP listener forms, and `${VAR}` placeholders in scenario 17.

STATUS: SECURITY lane — CRITICAL=0 HIGH=1 MEDIUM=0 LOW=0 INFO=0
