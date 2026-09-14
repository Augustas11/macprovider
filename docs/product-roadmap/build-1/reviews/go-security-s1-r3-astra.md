# Build 1 Go security review — complete S1 billing correction, R3

- Reviewer: independent native Astra high security lane.
- Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
- Branch/worktree: `codex/product-build-1`, `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
- Scope: all six changed/untracked billing files below against the base, including the complete artifact evidence, immutable snapshot, receipt credit synchronization, recovery changes and regression tests. Relevant unchanged settlement schema/payable view were checked. S2 and all Swift/app code are outside this follow-up.
- Method: static source/diff and supplied log inspection. No runtime, test execution or source changes by this reviewer; only this report was written.

**Disposition: S1 retained-extension loss and the subsequently reproduced missing-whole-route recovery case are corrected in the reviewed source. There are 0 unresolved CRITICAL, HIGH or MEDIUM findings in this bounded S1 review.** The current full billing race run was still pending at capture; the previous S1 full billing race passed. S2 remains open under its separate plan gate. This report does not replace the final complete combined code/security/architecture audits.

## S1 — corrected, with the established threat scope preserved

The prior MEDIUM finding concerns failed validation of inconsistent retained settlement evidence. Normal SQL UPDATE of route snapshots is prevented by the existing `trg_srs_immutable` trigger (`internal/billing/store.go:260`). The original red test encountered that guard. Extension-loss fixtures deliberately drop it in disposable databases to simulate corruption or an incomplete restore; production trigger code remains unchanged. No provider endpoint or normal service path that can strip the record was demonstrated. Whole-row absence is also injected in the fixture, not caused through provider traffic. These tests establish a recovery integrity boundary, not a remote exploit.

The R2 missing-whole-route hypothesis is now supported by a targeted reproduction: `/tmp/build1-billing-missing-route-red.log` shows uncached recovery returning success after an enforce verdict was retained and the route removed, with a runtime-model/default-rate lookup. The red test stopped at the unexpected successful return; this log alone does not measure resulting payable credits, payout or buyer debit. The broader monetary consequence remains supported by the previously traced legacy-policy/payable-view control flow, not an independently observed payout transaction.

## Correction assessment

`loadArtifactAdmissionForAttempt` now implements three distinct outcomes (`artifact_admission.go:92`):

1. An existing route must pass full immutable digest validation before an absent extension can select legacy pricing. Intact artifact routes additionally validate captured configuration and ledger rate agreement through `loadSettlementRouteSnapshotConn`.
2. When the whole route is missing, the helper queries the exact account-scope hash, request, attempt and provider identity in `settlement_receipt_verdicts`. Any retained verdict causes an error instead of treating known settlement history as legacy. Query errors also fail closed. It deliberately does not limit refusal to already verified/enforce verdicts, since any retained verdict establishes that the route evidence is expected.
3. No route and no retained verdict preserve the genuine historical no-route helper behavior. Intact old routes retain their original digest/extension interpretation.

`RecoverLedger` calls this helper before choosing rates, inserting credit or reconciling existing credit. Although `recoveredSettlementPolicyTx` still initially returns a legacy value on a missing route, the added retained-verdict refusal prevents that provisional value from reaching ledger mutation in the reproduced case. The helper runs on the same recovery transaction, so the missing-route/verdict decision and subsequent work share its database view. No today's feed, keyring or default rate is used to reconstruct missing artifact authority.

`syncVerifiedReceiptLedgerCreditForAttemptTx` validates retained route evidence before decoding usage and before any credit modification, regardless of cache use. The correction retains exact captured prompt/cache/completion rates, multiplier/share and config ID checks. The optional extension remains covered by the route digest and its legacy omission behavior is unchanged. The separate frozen-clock admin limiter test change alters no production limiter behavior.

## Validation evidence and limits

- The current recovery table has four cases: cached tokens 0/4 crossed with entire-extension loss/whole-route absence. Each retains fixture settlement history, then requires recovery failure and **zero new ledger rows**. The absence case retains the enforce verdict while deleting the route. These are seeded verdict fixtures, not new real-service cryptographic journeys.
- The signed-receipt regression continues to produce and verify an actual fixture signature, then injects extension loss and requires both direct loading and cached/uncached synchronization to reject the corrupted retained record without changing provider credit. Its cached and uncached fault checks share a database; they do not constitute two independent end-to-end receipt journeys.
- Valid artifact recovery still checks exact candidate rates after a later config appears and repeats recovery for idempotence. The explicit old-record test accepts an intact old snapshot and a no-route/no-verdict case, and rejects corrupted old JSON. This positively distinguishes legitimate legacy behavior from known missing settlement history.
- `/tmp/build1-billing-missing-route-green.log`: targeted artifact suite reports `ok`, **0.828s**. Source inspection confirms that the four-case negative table is included. The log is terse and does not independently enumerate subtests or the exact invocation.
- `/tmp/build1-billing-stripped-full-race.log`: previous S1 full billing race reports `ok`, **134.156s**. It predates the additional retained-verdict lookup, so it is not evidence of a completed full race run for the current bytes.
- The root reports billing vet passed for the current change. No separate vet log was supplied to this reviewer.
- `/tmp/build1-billing-missing-route-full-race.log` was empty at capture; its current run is **pending**, not passed. No tests were rerun by this reviewer.

No further supported S1 correction is requested. Complete the current full billing race run and include these hashes in the final combined review. This approval does not cover arbitrary simultaneous loss of all historical evidence or a privileged actor able to rewrite all database authority, and makes no physical MLX or production conformance claim.

## Complete current billing source SHA-256 manifest

Captured UTC: 2026-09-10T08:58:15.737767+00:00

```text
10825911f104422c290eb248022d77ecde936fe2f342a4fe5d22a3da5d7c5896  phase4-coordinator/internal/billing/artifact_admission.go
db468bd2a062b54f1205f0fe2c5d77455fefe86ad116abd640a86c59dfb5244a  phase4-coordinator/internal/billing/artifact_admission_test.go
2c6228c2e97b15e6a1c3ee7b4db6c14270787a65a089df52f9092a4018b7b05b  phase4-coordinator/internal/billing/quarantine_test.go
95c68af6ea5bbf11df33e57e8ff6060d7bbc118ea6b277c3dd5a2d1dda59e3ae  phase4-coordinator/internal/billing/recovery.go
2cc705c4a1f4137cc25b22aa317ddf30f303a7c27bae8bb221a8d8fef53d2597  phase4-coordinator/internal/billing/route_snapshot.go
3045601f3ecb054788a84e0e724c64d5e9da082236d6cead1288fece13effb78  phase4-coordinator/internal/billing/settlement_receipts.go
```

## Inspected log snapshot manifest

```text
c883f0e03e94295c260f7ae1918037ab24c8e150da01e6f2e217ecb592f84deb  /tmp/build1-billing-missing-route-red.log (478 bytes)
783b9ed16199df5d8642842b653d25738d752290e4f823fba46828224c49bf8d  /tmp/build1-billing-missing-route-green.log (72 bytes)
8ec1c1d49980dda47efc1aaa3d816891035281309632c8f9511f2a6fba55ee71  /tmp/build1-billing-stripped-full-race.log (74 bytes)
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  /tmp/build1-billing-missing-route-full-race.log (0 bytes)
```
