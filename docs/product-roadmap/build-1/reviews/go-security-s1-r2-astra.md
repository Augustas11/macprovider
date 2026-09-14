# Build 1 Go security review — S1 correction, R2

- Reviewer: independent native Astra high security lane.
- Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
- Worktree/branch: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, `codex/product-build-1`.
- Scope: S1 correction reviewed within the complete current billing diff and new artifact-admission tests. S2 promotion races and the Swift/app changes are outside this follow-up.
- Method: read-only source, schema and test/log review. No tests run or source changes by this reviewer; only this report was written.
- **Disposition: S1's retained-snapshot validation defect is corrected in the reviewed source. No new supported CRITICAL/HIGH/MEDIUM finding in this correction.** Full billing race validation was still pending at evidence capture. This is not final combined audit approval; R1 S2 remains open and a separate missing-whole-route hypothesis needs targeted validation.

## S1 disposition and qualified threat scope

**Original severity:** MEDIUM integrity/recovery-contract finding. This rating applies to handling inconsistent retained evidence, not demonstrated remote exploitability.

The production schema's `trg_srs_immutable` is a `BEFORE UPDATE` trigger that aborts route-snapshot updates (`internal/billing/store.go:260`). The initial red log confirms the normal SQL update attempt was blocked with `settlement route snapshot is immutable`. Therefore the initial review must not be read as demonstrating that a provider or ordinary runtime SQL UPDATE can strip artifact evidence. No such endpoint or bypass was found. The successful fault injection deliberately drops that trigger in disposable test databases to simulate corrupt/restored retained state; production trigger code is unchanged. An attacker with arbitrary schema/database control already exceeds the provider wire trust boundary.

The defense remains warranted under SPEC-047 R003 and its v0.1.4 immutable-evidence clarification: the reader must reject a retained artifact record whose JSON no longer matches its original digest instead of silently selecting legacy/fallback pricing. Red2 demonstrates the original reader accepted that inconsistent state in both recovery and receipt-credit synchronization after controlled corruption. This is narrower than a claim of remotely reachable credit creation.

**Correction evidence.** `artifact_admission.go:92–108` checks whether the exact route identity exists, then calls `loadSettlementRouteSnapshotConn` unconditionally for existing routes. Extension absence is interpreted only after full route validation/digest recomputation succeeds. That loader retains artifact/config/ledger rate matching. An intact old snapshot still returns nil evidence, preserving its original interpretation, and a genuinely absent route retains the helper's previous nil behavior.

`settlement_receipts.go:376–381` now invokes the same validation before decoding usage or mutating credit, independently of the positive-cached-token condition. The prior verified-verdict join no longer bypasses validation of retained JSON on the uncached synchronization path. Cache-specific reconstruction then uses the validated artifact rate or the legitimate old rate source. No current feed is consulted and immutable route bytes are not rewritten.

**Regression evidence inspected.**

- `TestArtifactAdmissionRecoveryRejectsWholeExtensionLoss`, cached 0 and 4: persist a route/request log/identity and a fixture verified verdict, remove the whole extension with the original digest unchanged, recover a missing ledger row, require an error and zero new ledger rows. The verdict in this recovery test is seeded by a test helper, not produced by fresh cryptographic verification.
- `TestArtifactAdmissionSignedReceiptKeepsCapturedCacheRate`: actually signs/verifies a receipt bound to the artifact route, proves the captured cache rate, then injects whole-extension loss and requires direct loading and receipt synchronization to error without changing provider credits for cached and uncached values. The two corruption checks share a test database; they are not separate clean end-to-end uncached receipt journeys. The source places validation before both branches, so that distinction does not leave the corrected bypass open.
- `TestArtifactAdmissionAbsentExtensionRequiresIntactLegacySnapshot`: truly absent route and intact old route return nil; corrupt old route JSON is rejected. Existing pre-change route-snapshot tests continue to supply legacy digest coverage; this new test itself does not pin a historical digest constant.
- Red1: expected failures occurred at the production immutability trigger. Red2: after test-only trigger removal, original code accepted stripped extensions, allowed recovery and synchronization, and accepted corrupt old JSON. Green: package success, `1.192s`, for the parent's targeted artifact tests. The parent reports `go vet` passed; no separate vet log was supplied. The full billing race log was empty at this report's capture and is not claimed passed.

**Required remaining action for S1 closure:** retain the production immutable trigger, complete and inspect the already-running billing race gate, and include these final bytes in the full combined audit. No further correction to the retained-snapshot S1 path is requested by this follow-up.

## Separate hypothesis: a missing whole route must not be confused with known covered history

This is **not a reproduced additional finding or a demonstrated S1 regression**. The new helper preserves an existing no-route compatibility behavior. However, a truly absent historical legacy route differs from a lost route for an attempt with a retained enforce verdict. Static inspection shows:

1. `recoveredSettlementPolicyTx` (`recovery.go:432–449`) returns `legacy` whenever the route query finds no row; it does not inspect a retained enforce verdict.
2. `loadArtifactAdmissionForAttempt` also returns nil on no row, and recovery selects the legacy model/default rate.
3. Receipt-credit synchronization cannot find its route join and returns without validation; the payable view explicitly accepts `legacy`/`observe` rows independently of the enforce-route branch (`store.go:1150`).

The immutable trigger guards UPDATE, not whole-row DELETE, but no normal production route-deletion path was found in the inspected billing/coordinator source. Foreign-key restrictions can also affect a deletion depending on associated compute-integrity records. Consequently, this is a corrupt/incomplete-history scenario to test, not evidence that normal service traffic can cause route disappearance.

**Recommended bounded check:** retain an enforce verdict/output and request-log/identity records for a formerly artifact-bound attempt, remove only its complete route in a disposable test store, leave the ledger missing, then call recovery. Assert it does not create a payable legacy row. Preserve genuine old no-route recovery as a separate positive case. If reproduced, report and correct the pre-existing missing-history classification separately, rather than asserting the existing S1 retained-JSON fix already covers it. The root was notified before this report.

## Current complete billing source manifest

Captured UTC: 2026-09-10T08:55:23.288558+00:00

```text
c650cffd92f1f60d3a3b61efacdad3c98c61af82ade7cbbae5fbc798591ef22e  phase4-coordinator/internal/billing/artifact_admission.go
f8890d98d105c5d8eb6cf51cf327f1a5e8706b79e3fedd26857a62c6440e5548  phase4-coordinator/internal/billing/artifact_admission_test.go
2c6228c2e97b15e6a1c3ee7b4db6c14270787a65a089df52f9092a4018b7b05b  phase4-coordinator/internal/billing/quarantine_test.go
95c68af6ea5bbf11df33e57e8ff6060d7bbc118ea6b277c3dd5a2d1dda59e3ae  phase4-coordinator/internal/billing/recovery.go
2cc705c4a1f4137cc25b22aa317ddf30f303a7c27bae8bb221a8d8fef53d2597  phase4-coordinator/internal/billing/route_snapshot.go
3045601f3ecb054788a84e0e724c64d5e9da082236d6cead1288fece13effb78  phase4-coordinator/internal/billing/settlement_receipts.go
```

## Inspected log snapshot manifest

```text
1b37774d4e69d2021a6aeb8e7da3c090ddc394c804ed6325f71e7a4d553239da  /tmp/build1-billing-stripped-red.log (897 bytes)
940f56fbf5dd663eec51a29be3a3e6cb3e6d4f986900dad1bf183394f58bed3a  /tmp/build1-billing-stripped-red2.log (1614 bytes)
d68512b084ed3b06677aee1b680a124c4f407a3e1454dbc92a1479dd27203897  /tmp/build1-billing-stripped-green.log (72 bytes)
8ec1c1d49980dda47efc1aaa3d816891035281309632c8f9511f2a6fba55ee71  /tmp/build1-billing-stripped-full-race.log (74 bytes)
```
