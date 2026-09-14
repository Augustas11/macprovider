# Build 1 acceptance status — in progress

This is a live evidence map, not build acceptance or PR approval. Preliminary implementation audits have unresolved Medium findings. No implementation commit, Build1 PR, hardware qualification, or production activation has been completed.

| Requirement | Fresh evidence | Outstanding |
|---|---|---|
| B1-T01 feed conformance | Python artifact/legacy145 passed; relevant Swift artifact28 passed in shared runs; Go signed authority tests passed | Final composite Swift/run snapshot and full audit |
| B1-T02 preparation | Actual owner prepare fixture + fresh durable discovery, CLI grammar and app confirmation tests | Full final source test matrix and audit |
| B1-T03 cancellation/crash/concurrency | Owner metadata/transfer/hash/copy/prepublication cancellation; postpublication cancellation truth; actual candidate parent-death test; Swift9 owner16/16 included real subprocess deaths at reserved/started/publication-intent/published/preterminal boundaries | Selector races, result-commit process recovery, full composition |
| B1-T04 failures/recovery | Corrupt/stale transfer, disk-space/timeout/cleanup-failure owner tests, ancestor no-follow tests | Cleanup projection/control and retention gated changes; final failure matrix |
| B1-T05 app | Post-security/resource-change app Xcode641 passed, including all16 resource tests and actual GPU arithmetic through production resource-copy path; implementation-app.md | Final combined audits and real production-signed snapshot positive remain separate |
| B1-T06 adoption | Existing adoption regression surface; root preserves original recommendation bytes | New actual measured-result command composition and final rollback suite |
| B1-T07 authority | Go exact signed feed/Tier2/rate/session tests, live restriction mutation and status-only expiry/disconnect regressions | Final independent reviews and exact final source evidence |
| B1-T08 concurrency | Go CAS withdrawal/reoffer and signed retry/replay tests; actual closing-session request before status rejects even when revocation persistence fails; new pool/Tier2 guards race149top-level+54subtests passed | Full S2 authority/transport race matrix, final full audit and large legacy migration correction |
| B1-T09 settlement | Real coordinator/gateway SQLite fixture with authenticated encrypted WS, signed receipt, exact20-token/16gross/14provider accounting, restart/replay; race3 passed; dedicated signed cache/recovery tests; full billing race passed | Full cross-service regression run after final Swift fixture build; fixture does not establish MLX or cross-service cache-hit discount |
| B1-T10 physical | Read-only public feed preflight: artifact body/signature404, candidate body/signature200; M5/32GiB inventory | BLOCKED/UNPROVEN: live signed artifact feed and justified real-model authority chain; no physical preparation-to-settlement run |
| B1-T11 bootstrap | Swift25 parsed bootstrap4/0 in14.977s: one complete parsed preparation/restart/discovery/measured recommendation/original adoption/signed offer/status/retry/settlement/restart journey, one identity negative and two helper methods | Final source regression after binding/S2; helper entry noops do not prove separate journeys; fixture runtime is not real MLX |
| B1-T12 durable bridge | Nine bridge tests plus owner preparation->fresh discovery stable ready identity | Separate process/restart command composition and final regression |
| B1-T13 isolation | Configurable receipt/token custody parity test; default-preserving internal testability design; no operator changes | Final command fixture proves all roots/ports; no shipping/default trust chain claim |
| B1-T14 measured producer | Prepared map fail-closed tests; Swift10 owner17/17 includes actual Stage1Prober/CandidateProviderRunner against compiled fixture, success/cancel/timeout/pressure/missing/corrupt/postcommit cancellation and child/port cleanup | Strong measured numeric assertions, full original result/adoption command journey, committed result process recovery; no real MLX qualification |

Broader fresh evidence is recorded in validation-lead.md and per-lane implementation reports: full coordinator and gateway normal suites; full app initial suite; ws/buyer race; full billing race after deterministic test-only clock correction; coordinator isolated-cache lint; Go vet and governance; Python artifact/legacy tests. The full Swift suite and final three independent implementation gates remain pending. Failed, skipped, interrupted and fixture-only runs retain their labels.

Qualification remains distinct: local Go/Xcode/Swift fixtures are not actual MLX; Xcode26.6 is not the absent release-required16.4; no release signing, updater, deployment, reward/payout activation, or production qualification is claimed.

Actual pinned MLX GPU arithmetic is now separately evidenced in validation-lead.md: resource-present helper succeeds, identical binary-only helper fails library loading. This is neither model inference nor signed app snapshot or settlement acceptance. Immutable-retirement-binding r3 independently approved0C/H/M; initial implementation awaits fresh full acceptance matrix. S1 billing corruption recovery independently accepted0C/H/M with full billing race104.945s. S2 promotion plan r3 is approved at zero Critical/High/Medium; its implementation and complete race matrix are in progress. The original r1/r2 findings and resolutions remain in the review records.

Latest transaction run Swift30 failed:44 selected methods,5 failures(1unexpected),490.899s. Retention33 methods had3 failures (one fixture expectation and two bounded-progress failures); controllease6 had2 failures in one helper-boundary case; cleanupowner1 and ownerguard4 passed. These failures block final local verification. A structural progress correction requires another approved plan addendum before implementation. Swift29 owner30/0 passed191.493s but does not override Swift30 failures or prove the final combined snapshot.

## Current superseding evidence

The earlier app and transport rows above are superseded in part by later fresh
runs. The corrected signed CLI export passed 1/1, the actual app capture passed
1/1, the full Malibu suite passed 652/652, and unchanged app arguments replayed
through the real CLI parser passed 1/1; all had zero failures and zero skips.
The consolidated Go transport/readback selection passed 705 logical cases under
the race detector in 212.263 seconds. These close the local executable app/CLI
bridge and frozen transport-matrix runs, subject to subsequent source changes.

Build 1 is still not accepted. The first independent GPT-5.6 Sol review reported
three Medium admission test-mapping gaps in T06/T10/T11; bounded corrections
are implemented and their fresh GPT-5.6 Sol rereview approved the mapping at
zero Critical, High, Medium, and Low findings. The revised
catalog-read completeness plan and revised reservation measurement plan are
approved at zero Critical, High, and Medium findings. Catalog implementation is
in progress. Swift36's superseded maximum-shape setup reached only 512/1,024
records before its 600-second setup ceiling and executed zero reservation
measurement calls, so it supplies no capacity conclusion. The corrected r3
measurement supersedes it and completed as recorded below. Physical
preparation through real MLX inference and correctly settled service remains
blocked by signed feed/release/hardware prerequisites named above.

As of 2026-09-10, the bounded T06/T10/T11 admission corrections are implemented
and locally green: the WS selection passed 11 top-level scenarios / 28 terminal
leaves under `-race` in 7.661 seconds, `go vet ./internal/ws` passed, and the
buyer selection passed 6 top-level scenarios / 33 leaves under `-race` in
13.471 seconds with its full package test and vet checks passing. The fresh
GPT-5.6 Sol independent mapping review also reran the focused buyer, WS, and
closing-route integration selections and approved the mapping at zero Critical,
High, Medium, and Low findings.

The catalog-read completeness r2 plan is approved by an independent GPT-5.6
Sol review at zero Critical, High, Medium, and Low findings. Its implementation
is source-frozen and the corrected focused Swift selections passed 10/10 and
7/7 with zero failures and skips; the full Swift suite remains pending. The bounded
maximum-shape reservation measurement correction is implemented test-only and
approved. The corrected long-running measurement then passed one selected test
with zero failures and skips in 1,223.543 seconds: all 1,024 records / 4 GiB
were built and all six unchanged-budget calls returned typed `busy` after the
same 585-record prefix with no scan completion or publication. This supports
the exact maximum-shape repeated-prefix starvation conclusion. Independent
GPT-5.6 Sol result review approved that evidence at zero Critical, High, Medium,
and Low findings. Current-source structural-plan compatibility was then
approved at zero Critical, High, Medium, and Low; the R4 runtime implementation
is in progress and remains unverified.

`origin/main` advanced after this worktree was created: merged PR #1469 is now
commit `c9445561e4fe00a073926ff2ab0fdb0536d00e37`, one commit above the worktree
base. The Build 1 diff therefore requires explicit reconciliation against the
landed GGUF settlement-identity implementation before final regression, audit,
commit, or PR preparation. SPEC governance still passes against the new
`origin/main`; this is governance evidence only, not reconciliation or runtime
acceptance.

A separate active worktree, `feat/byom-v02-slice4-decision-path` at
`d1ce1a64`, contains additional proposed
SPEC-047 decision-path contracts and has no PR as of this checkpoint. It is
unlanded external work and is not part of Build 1 evidence. The refreshed
read-only GPT-5.6 Sol assessment finds no current overlap requiring a gate
reopen, but records the exact coordinator admission checks that must be rerun if
that branch lands first. Build 1 must neither assume it lands nor silently
duplicate it.

The complete c944 reconciliation plan r1-r6 and test bundle r5-r10 passed
independent GPT-5.6 Sol review at zero Critical, High, Medium and Low findings.
Earlier revisions were rejected until they closed WS catalog/index publication,
SQLite-first ordering, the canonical-v2 envelope, SPEC-047 ownership, strict
numeric tokens, the direct authority-setter bypass and RFC-8785-safe numeric
bounds. Runtime reconciliation has not started: the approved procedure first
requires the in-progress Swift R4 writer to finish, a frozen recovery checkpoint,
and replay into a fresh c944 worktree.
