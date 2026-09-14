# Immutable retirement binding r3 — independent architecture plan gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.** R3 closes BIND2-ARCH-M1 and BIND2-ARCH-M2 without weakening the earlier terminal-replay, origin-discrimination, legacy-capacity or lock-budget requirements. No additional blocking architecture defect was identified in this exact proposal. This approves the specified design for implementation; it does not certify unimplemented behavior or the concurrent Swift test run.

Proposal SHA-256: `ab9179ecc17c31c733ad21705b7ad0a8db2b99d8739eb7ec8d892a06bb7318f8` (verified).
Base and worktree HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Snapshot time: 2026-09-10T08:37:43.646368+00:00. Only this report was written. No source changes, subagents or runtime tests. The inspected two implementation files have the same hashes as the r2 review; binding/origin/certificate behavior remains proposed.

## BIND2-ARCH-M1 — closed

**Prior severity:** Medium. **Evidence:** Proposal lines 26–45 and acceptance test 6.

The source control now retains the actual complete ordered UUID/phase set, its old-index SHA/generation or initial-inventory identity, and migration identity. The progress control separately retains an authoritative next position, acknowledged prefix and one pending decision. Crucially, the exact canonical origin bytes, provenance and supporting source evidence are fsynced in pending progress before origin publication. After origin/file-directory fsync, the acknowledgment pins its digest and advances progress. An absent pending origin can only receive those stored bytes after source revalidation; an absent acknowledged origin cannot be reconstructed. Changed source cannot establish a new legacy classification. This distinguishes the missing-file states that r2 conflated.

Progress resumes from the durable next position rather than rereading completed primary bodies. The 1,024-entry, 16-entry-yield, eight-second work constraints are compatible with resumable publication: each successfully acknowledged UUID advances future invocations. A busy owner or changed pending source deliberately prevents progress at that position; it is an honest protected migration outcome, not permission to omit/reclassify the UUID. Only one current UUID owner and its bounded evidence need be retained.

Finalizing progress pins the exact intended initial new-index bytes by SHA plus generation/source linkage. Construction and validation require equality of full frozen membership, phases and acknowledged origin references. Crash after index publication therefore has an exact completion proof, not a schema-only guess. Missing/corrupt progress cannot reset baselining; complete plus old-format index rejects downgrade. Later legitimate index generations preserve lineage without requiring perpetual equality to the initial index. Finalization may retain an acknowledged-but-now-missing origin as an unavailable counted entry; it cannot drop the entry or repair its evidence.

**Consequence after correction:** A crash at decision/origin/acknowledgment or final-index publication no longer permits fresh classification from changed primary bytes or loses the authoritative completion position. Initial inventory can be reconstructed from the frozen list without rescanning altered root contents.

**Required correction:** None remaining at plan level. Implementation must realize the explicit CAS/fsync states and reject incompatible progress combinations. Existing `initializeRetention` at `ModelCatalogTransactionRetention.swift:87` is not a substitute for this new state machine. The specified actual restart matrix, multi-budget progress proof, no-completed-body-reread instrumentation and independent final-index mutations are mandatory implementation evidence.

## BIND2-ARCH-M2 — closed

**Prior severity:** Medium. **Evidence:** Proposal lines 82–100 and acceptance test 9; current `ModelTransactionSuccessCommitment` and `successDigest` remain evaluation-only.

R3 defines five exhaustive certificate variants. Successful generated evaluation retains the approved r4 commitment, binding/context/result links and resolved current-cleanup evidence. Prepare success and prepare/evaluation non-success use an exact retirement-time primary snapshot with explicitly absent/present result/seal evidence. Legacy uses its exact immutable migration baseline and existing supported legacy validators, without fabricated generation or a new generated preparation-seal requirement. Failed/intent-only preparation cannot enter successful publication certification; retained results on failed evaluations do not become recommendations.

The snapshot freezes every primary field/event and current cleanup stream only after terminal truth, cleanupRequired false and staging absence. Publication of the certificate fences all later original/current-cleanup writers even before index removal. Certificate-before-removal crash recovery can only finish exact validated removal. Thus whole-primary snapshots do not conflict with legitimate earlier cleanup, and a post-certificate writer cannot invalidate the evidence while leaving retirement half committed. Every present sidecar requires exact digest agreement plus its existing pure validator; missing, orphan or incompatible evidence is protected. Prior cleanup-generation history remains direct-read evidence and is not enumerated.

**Consequence after correction:** Healthy supported prepare, non-success evaluation and generation-less legacy histories have executable retirement proofs and archived direct validation; they do not depend on an undefined generic commitment or the evaluation-success helper. The exact mixed-outcome capacity requirement now tests this distinction.

**Required correction:** None remaining at plan level. Implement the closed variants and all their writer guards together. Tests must use supported lifecycle outcomes, including cancellation, timeout, expiry without startedAt, committed non-success evidence and actual cleanup resolution; manufacturing only evaluation-success fixtures would not satisfy the stated greater-than-2,052 mixed-history acceptance requirement.

## Remaining contract challenge

The earlier three r1 corrections remain intact. The pending success binding freezes cleanupRequired plus the exact successful event and canonical prospective full primary SHA. Current `ModelCatalogTransactions.swift:108` stores state through events, and r3 explicitly prohibits inventing separate state/updatedAt fields. Both false-to-true and true-to-false cleanup transitions therefore have an exact normal/recovery representation. Later authorized pre-retirement cleanup uses the unchanged r4 commitment, not the temporary pending-transition full-primary digest.

Allocation precommits the prospective origin digest before primary/origin publication. Its recovery variants retain required absence checks and cannot create an owner inode to prove absence. Active missing-origin evidence cannot enter allocation recovery. Binding publication precedes expected index reference, which precedes successful primary; an index-reference gap may only be closed using the exact still-nonterminal preterminal/result/origin proof. Missing required binding is never regenerated. Writer checks must precede heartbeat, cancellation, failure, restart and cleanup mutation, not only pointer creation.

Origin/binding/certificate dispatch precedes mutable kind/state/generation classification and context-path derivation. This closes signer/feed relocation and success-to-failure/generated-to-legacy bypasses. Retired generated eligibility retains direct origin/certificate/binding expectations after active membership disappears. Missing proofs produce unavailable eligibility; the deliberately weaker generic historical diagnostic path grants no action, adoption, certification, owner or reconstructed membership. Pre-binding generated journals are explicitly protected development evidence, while supported generation-less resolved legacy and healthy new mixed outcomes retain the inherited capacity guarantees.

Current/previous pointer evidence is validated outside the global lock, with no previous-owner acquisition and no release of the current owner. New origin/binding/certificate and migration evidence joins descriptor-relative safety checks and final exact metadata/index-generation CAS. The proposed 256-KiB source, 1-MiB progress/index and 16-KiB per-UUID bounds are compatible with 1,024 compact entries; no all-history descriptor set or body scan is required. Repeated bounded progress-file replacement may be costly, so actual multi-invocation completion and independent heartbeat/command deadline tests remain necessary. A count bound is not a timing proof. No new bulk parse/hash/encode loop is allowed under the journal lock, and the independent fence remains necessary for stalled kernel calls.

All ten r3 test groups and inherited retention-r4, lock-budget-r2, long-hash-r3, plan-r4 and test-spec-r4 outcomes remain required. Full combined code/security/architecture audits must review the implementation as it will land. No current artifact readiness, fresh feed/economic authority, signed execution, physical MLX qualification or settlement acceptance follows from historical retirement certification.

## Verification snapshot

Read the exact r3 proposal, prior r2 findings, approved retention/lock contracts and current allocation, retirement, preparation commitment, terminal record and pointer-validation seams. No tests were run for unimplemented schemas. Snapshot manifest SHA-256: `f0af7088894b7d9c7460c4dbebbad9e19a6ae8c669e5cdfa3208e1abd004666f`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/immutable-retirement-binding-r3.md` | `ab9179ecc17c31c733ad21705b7ad0a8db2b99d8739eb7ec8d892a06bb7318f8` |
| `docs/product-roadmap/build-1/immutable-retirement-binding-r2.md` | `8ba51963aa0af266ef74030fa43fdeadd2d6ab09a64f7ce76362372ea078d0dc` |
| `docs/product-roadmap/build-1/reviews/immutable-retirement-binding-r2-astra.md` | `4449ac96ac516f1a635f6cc8af11dff1f5f70d1c9c78d49f948ccf12b19d04ac` |
| `docs/product-roadmap/build-1/transaction-retention-addendum-r4.md` | `caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc` |
| `docs/product-roadmap/build-1/retention-lock-budget-r2.md` | `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21` |
| `docs/product-roadmap/build-1/long-hash-control-addendum-r3.md` | `19286de938b886e788792ec0d2f3d8e9ec019f8ba26501e400c78d953659db4e` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `9fbfb11f271f120b32e1034bbbdee81a0e2cac55b3d6702d9f284c8c6b3e1caf` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `2ead8096b77014d60d63b24b25b73b88ef600787c65546d5eba4c094e320e031` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `8e48fd37f63e7634bc3138edf7f1438e4c3c9fa72ec1389da7e45ff824e3bbdc` |
