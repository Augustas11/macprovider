# Security High Findings: Implementation Verification

Initial base: `b63ccb465fa9ae6fab2084e45e703103efe40a9e` (fetched `origin/main`).
Final landing base: `00984a3105dc09d899ae6dd5d14d39f197124215`
(fetched `origin/main` after the adversarial correction round).
Branch: `codex/security-high-fixes-2026-09-08`.
Scope: F01-F04 from the 2026-09-07 security boundary audit. This record captures
implementation verification before PR publication. No deployment, production
credentials, or signed journey operation was performed.

## Changes

- F01: reject duplicate and case-colliding schema-owned JSON fields before
  translation, reservation, or dispatch; preserve extension and user schemas.
- F02: retain coordinator receipt authority despite missing trailers or facade
  validation errors. Persist generation-bound local usage for observe recovery;
  require complete request-scoped mode authority, including current-attempt
  membership and snapshot/verdict coverage. Persist fair retry order across
  gateway restarts. An initial coordinator attempt ID, persisted with the
  candidate, fences the lookup and must be echoed after membership validation;
  an earlier logged retry cannot substitute for a current unlogged attempt.
  Every production path that leaves a reconcileable hold now persists this
  binding first. Legacy rows and persistence failures without a candidate stay
  held without contacting the coordinator. Verified demo recovery also writes
  the paired `demo_usage_events` audit row.
- F03: exchange a hashed, single-use issuance intent for an in-memory API key;
  transactionally store only the key hash and consume the intent. Schema 12
  invalidates legacy plaintext handoffs and stores settlement recovery state.
- F04: production fix already merged as
  `fc32dad7bfe80320e2203e3090fa2a71e620d579`. Added streaming/nonstreaming
  pre-dispatch release regressions. No production Swift change was needed.

## Verification

Commands run from the named package in this worktree unless otherwise stated.

| Package | Command | Result |
| --- | --- | --- |
| Gateway | `go test -race -count=1 -timeout 5m ./...` | Exit 0; router 122.092s, SQLite 18.903s; all packages passed before final headerless-hold compatibility tightening |
| Gateway | `go test -count=1 -timeout 5m ./...` | Final source: exit 0; router 29.894s, SQLite 3.378s; all packages passed |
| Gateway | `go vet ./...` | Exit 0 |
| Coordinator | `go test -count=1 -timeout 3m ./internal/billing ./internal/buyer` | Exit 0; billing 12.548s, buyer 9.144s |
| Coordinator | `go vet ./internal/billing ./internal/buyer` | Exit 0 |
| Swift | `swift test --scratch-path /tmp/macprovider-security-high-fixes-20260908-cli-swift-build --disable-automatic-resolution --filter ConsumeCommandTests` | 127 tests passed, zero failures |
| Worktree | `git diff --check` | Exit 0 |

After the final adversarial correction and clean rebase onto `00984a31`:

| Package | Command | Result |
| --- | --- | --- |
| Gateway | `go test -count=1 -timeout 8m ./... && go vet ./...` | Exit 0; router 33.260s, SQLite 4.199s; all packages and vet passed |
| Gateway | `go test -race -count=1 -timeout 5m ./internal/router -run '^(TestSettlementReconcileWithoutCurrentAttemptBindingRejectsPriorFinality\|TestSettlementReconcileVerifiedDemoWritesDemoAuditRow)$'` | Exit 0; 1.940s |
| Coordinator | `go test -count=1 -timeout 8m ./... && go vet ./...` | Exit 0; all packages and vet passed |
| Integration | `go test -race -count=1 -timeout 5m -run '^TestSpec022V04StreamingSettlementReconcilerE2E$' .` | Isolated rerun exit 0; 5.204s |
| Swift | `swift test --scratch-path /tmp/macprovider-pr1431-final-swift-20260908 --disable-automatic-resolution --filter ConsumeCommandTests` | 130 tests passed, zero failures |
| Worktree | `git diff --check origin/main...HEAD` | Exit 0 |

The first post-rebase integration invocation ran concurrently with three heavy
build/test commands and failed before the reconciler assertion because its seed
gateway did not create the accounts schema. The exact isolated rerun above
passed; the failed invocation is not represented as a pass.

Final recovery/scheduling additions also passed:
`go test ./internal/storage/sqlite ./internal/router -run 'TestSettlementFallback|TestObserveFallback|TestSPEC022GatewaySettlementReconcile|TestWalletSessionSettlementReconcile|TestSecurity' -race -count=1`
(SQLite 2.215s, router 14.199s). This includes 101 unavailable candidates with a
batch limit of 100, later observe/enforce holds, a fixed clock and two database
reopens, plus monotonic/generation-bound retry markers and wallet local usage.
Current-attempt identity survives restart and wallet recovery; absent or wrong
echoes cannot authorize observe/enforce debit or refund.
Headerless candidates retain an immutable empty binding across restart and do
not enter an unbound lookup or debit path, even if a prior enforce result exists.

Coordinator focused race command (exit 0, 5.490s):

```sh
go test -race -count=1 -timeout 3m ./internal/billing -run '^(TestRequestSettlementFinality|TestAggregateExternalRequestFinality|TestSPEC022NonStreamingVerifiedReceiptCreatesBuyerFinalityAndProviderPayout|TestSPEC022StreamingVerifiedReceiptCreatesBuyerFinalityAndProviderPayout)'
```

Final coordinator current-attempt binding race command (exit 0; billing 2.097s,
buyer 1.873s):

```sh
go test -race -count=1 -timeout 2m ./internal/billing ./internal/buyer -run '^(TestRequestSettlementFinalityBound|TestSettlementInternalRequestHeaderIsCoordinatorOwnedBeforeStreamEOF|TestSettlementFinalityRequiredInternalRequestQueryFailsClosed)'
```

The buyer test checks the coordinator-owned header before HTTP EOF/request-log
creation, rejects substitution by buyer/provider headers, and covers fresh and
idempotency-key requests. Bound lookup tests cover the unlogged current attempt,
later mapping, missing verdicts, mixed mode and account/external/generation fences.

Selected integration command (exit 0, 27.051s):

```sh
go test -race -count=1 -timeout 5m -run '^(TestSpec022V04StreamingSettlementReconcilerE2E|TestInternalBearerWrongTokenRejected|TestInternalBearerNoAuthRejected|TestInternalBearerServiceTokenAccepted|TestInternalBearerOperatorKeyRejectedPostCutover|TestStickyHeaderForwardedToCoordinator|TestGatewayGitHubOAuthDisabledRoutesReturn404)$' .
```

The full coordinator billing race run was **not green**:
`go test -race -count=1 -timeout 3m ./internal/billing` failed after 77.443s at
`TestAdminRateLimitBucketConsumesFailures`. An isolated race rerun with
`-timeout 90s -run '^TestAdminRateLimitBucketConsumesFailures$'` also failed
(41.657s). Its 600 calls took 41.32s (about 14.5 requests/second), below the
configured 60-token/second refill rate, and produced no rate-limit responses.
This unchanged admin-limiter test does not execute the modified finality path.
No unrelated test was edited.

One later gateway full race run failed the unchanged
`TestPoolRejectionTimingFloor_EnforcedAndUniform` (router 156.149s): p95 difference
15.735042ms exceeded its 15ms bound. The isolated command
`go test -race -count=1 -timeout 1m ./internal/router -run '^TestPoolRejectionTimingFloor_EnforcedAndUniform$'`
passed in 4.244s. Its timing assertion was not relaxed.

## Review Gate

Independent code, security and architecture lanes reviewed the complete combined
fix. The final adversarial cross-check found one Medium current-attempt gap: a
candidate-less hold still performed an unbound coordinator lookup. The correction
requires a persisted candidate before any remote lookup and adds verified/refund
prior-finality substitution regressions. A subsequent security lane found one Low
demo audit-integrity gap; enforce reconciliation now uses atomic demo settlement
and has a paired-row regression. The complete rebased landing diff was then
re-reviewed. All three final lanes reported zero Critical, High or Medium findings.
The inherited/operational limitations below remain.

## PR Publication Follow-Up

PR #1431 was initially rebased onto
`58fcd226078438d4c10fa5204496812f9f0f53a7`, then rebased cleanly after the
adversarial correction onto `00984a3105dc09d899ae6dd5d14d39f197124215`.
CI correctly rejected stale historical selector
evidence for SPEC-006-R003, SPEC-022-R005 and SPEC-022-R008. These mappings are
demoted to pending, retaining historical evidence; issue #1433 tracks a separately
authorized evidence refresh before re-promotion. No signed journey was created.

## Rollout and Residual Risks

- Deploy the coordinator completeness signal first; older coordinator responses
  intentionally leave missing-trailer recovery held. See gateway README.
- Stop old gateway binaries before schema 12 migration. Legacy OAuth handoffs
  must restart. Historical database pages/WAL/backups are not erased, and existing
  API keys are not automatically revoked.
- Pre-candidate historical holds cannot be reconstructed automatically.
- Separate follow-up: omitted/null generation caps are not materialized into the
  forwarded body. This change addresses collisions, not that adjacent contract.
- Separate inherited follow-up: the structured-admission timeout branch can
  ignore finality on a retained coordinator response. No blanket claim that all
  settlement paths are repaired is made.
- No real-wire Swift partial-write/deadline race, separate-process consumer
  restart, full Swift app suite, ML inference, or production rollout was tested.
  Wallet candidate storage/generation and local-usage recovery are covered, but
  a wallet-specific outage/restart/reconcile end-to-end scenario remains untested.
- These fixes do not establish full conformance or production readiness.
- The trailer-tail drain is line-granular (potentially nearly 2 MiB, not an exact
  1 MiB budget); it remains time- and per-line-bounded.
