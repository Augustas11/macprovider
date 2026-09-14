# Migration receipt and budget R1 — independent architecture plan gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.** The proposed placement and operation-local reuse are feasible without weakening the approved durable classification, metadata custody or deadline contract. No blocking architecture defect was identified in this exact proposal. This is not approval of the current implementation or proof that the finite performance tests pass.

Exact proposal SHA-256: `a8d22c7680f7eaa026966615eda86c51a53350154b0fe910ac859eda918bb49b` (verified).
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.
Snapshot UTC: 2026-09-10T09:29:18.270317+00:00. Static source/plan review only. No runtime tests, builds, service calls, source edits or subagents; only this artifact was written. Swift29 timing/failure numbers are supplied evidence recorded by the author/lead, not independently rerun results. Source hashes below identify the inspected binding-r3 implementation.

## Evidence and design assessment

**Repeated work and placement — addressed.** Current `ModelCatalogTransactionMigration.swift:248–257` captures, hashes, closed-decodes and validates source/progress/index on every loop, both before a decision and before its acknowledgment. The bootstrap lock already spans that loop (`:178–179`). `requireBindingMigrationCompleteLocked` at `:155–164` reads/decodes the migration ledger and walks its prefix while the global journal scope is active; `snapshotIndex` calls it at `ModelCatalogTransactionRetention.swift:203–205`. Maintenance repeatedly snapshots at `:352`, `:378`, `:383` and `:413`, multiplying this cost. The proposal removes repeated prefix decoding/validation and moves completion body work outside the global lock. It does not misattribute the subsequent direct history reads in the failing legacy fixture to migration-origin revalidation.

**Consequence:** A completed 1,024-entry migration no longer adds a complete source/progress parse to every locked index observation. Within an unfinished migration call, the fully validated state can advance through its own exact durable transitions without revalidating all acknowledged primary bodies. WAL encoding/writing/hashing remains; this is a reduction of redundant work, not a claim of constant total migration cost.

**Required correction:** None beyond the proposal. Verification 2 must instrument the actual source/progress read, hash, closed decode and full-prefix functions, including already-complete initialization and resumed completion, rather than merely asserting the outer call is unlocked. Existing bounded active-index/format decoding remains explicitly allowed under the global lock.

**Completion receipt authority — sound at plan level.** The receipt owns source/progress descriptors, exact validated bytes/lineage and root placement; it is local to one bounded operation. The current `ModelTransactionFileEvidence` captures an open no-follow descriptor, exact digest and device/inode/owner/mode/link/size/mtime/ctime observations (`ModelCatalogTransactionEvidence.swift:21–75`). Its final validation compares both the open inode and current placement, so byte-identical replacement invalidates an existing receipt, as do in-place changes and removal. Directory validation anchors the same scoped journal rather than a newly trusted path. Source/progress body validity cannot be inferred from index generation alone.

The receipt proves migration completion only. It does not replace current active-index parsing, exact per-UUID origin/provenance/binding/certificate expectations, sidecar absence checks, owner custody or ordinary membership CAS. In particular, same-generation index-reference tampering must still be rejected by the inherited per-UUID checks; a matching generation or migration UUID is not equivalent authority. New snapshots may observe later valid active-index generations while retaining the same immutable completed migration lineage.

**Required correction:** None at plan level. Implement verification 3 literally: the completion receipt must reach final index/primary/certificate/pointer mutation validation. Validating it only in an earlier snapshot, then calling a later mutation path that checks only membership/generation, would not satisfy the approved test. Current ActiveReceipt and retirement mutation seams need this propagation as part of the correction; a process/global cache or silent authority recapture during mutation is not authorized. Reuse also must retain the original operation budget rather than restart an eight-second deadline per nested snapshot.

**Migration custody and restart — sound at plan level.** The nonblocking bootstrap lock owns each bounded invocation; source, initial progress and active-index evidence are fully captured and validated after acquiring it. The one current UUID owner remains held across pending decision, origin and acknowledgment. Subsequent steps compare the pinned source/index/progress and affected UUID evidence before publishing the already-preencoded transition. This detects substitution even when an attacker preserves a generation or supplies byte-identical replacement before that validation.

After a successful progress write, outside-lock recapture must equal the exact preencoded bytes before its already-generated decoded value replaces the old receipt. There is no inference of durable success from the in-memory value alone. Publication/capture failure, changed evidence or budget expiry ends the invocation; it cannot authorize the next transition. A new call starts from complete durable validation. Therefore crashes before/after pending, origin or acknowledgment retain the previous approved meaning: pending replay uses frozen bytes, acknowledged origins are not reconstructed, and primary changes do not reclassify provenance.

Finalization retains its fsynced intended-index byte digest and accepts only old index or exact intended new index during recovery. Publishing the final index then complete progress returns; the old index receipt cannot be reused for later operations. The correction changes neither the disk schemas nor the durable transition order. Deletion, unsafe evidence, missing progress and ambiguous classification stay fail-closed; no historical pointer seeds a new binding and no archive scan repairs missing authority.

**Required correction:** None at plan level. Run verification 4 at actual decision/acknowledgment publication and recapture seams, including thrown interruptions and child death. Tests must distinguish a stale receipt invalidated by replacement from a fresh fully validated receipt to unchanged authority. Preserve all existing initial preparation and finalizing/index/complete crash hooks.

## Finite progress and acceptance

The finite tests remain appropriately strict. The legacy fixture must first demonstrate three actual eight-second expirations with a strictly advancing acknowledged prefix, then reach zero active legacy entries in at most sixteen more bounded calls while preserving original/result bytes and absent generations. Moving repeated ledger work is a plausible way to meet that bound, but this review does not claim it will; remaining WAL/fsync and index costs require measurement. If it still fails, further diagnosis is required without increasing the budget or retry count.

Replacing the unrelated one-call full-capacity assertion with at most eight reservation attempts and a 64-second outer deadline matches the already-approved resumable maintenance/cursor behavior. It is not permission to accept permanent busy: the resolved UUID must retire, fresh allocation must succeed and the other 1,023 unresolved primaries must remain identical. The current reuse scan precedes maintenance (`ModelCatalogTransactionRetention.swift:272–298`), so verification 6 must specifically detect repeated reuse scanning starving maintenance rather than treating any busy/capacity sequence as progress.

The greater-than-2,052 mixed-outcome history, missing/corrupt sidecars, same-generation provenance-reference CAS, queued-successor adoption, full migration/death matrix and large-evidence heartbeat/control interference remain required. The completion receipt has constant descriptor ownership; it must not retain all 1,024 per-UUID evidence sets. Global-lock body loops are forbidden, but fsync/metadata system calls can still stall; existing independent owner fences/watchdogs retain their role. No cooperative budget is claimed to preempt arbitrary kernel latency.

The proposal's seven verification groups and inherited binding-r3/retention-budget outcomes are sufficient plan-level acceptance criteria. Runtime implementation remains subject to fresh root-coordinated tests and complete combined code/security/architecture review. No syntax-only or interrupted run can close the performance/correctness failures. New persistence, cross-operation cache, relaxed validators, changed legacy eligibility or increased deadlines require a new gate.

## Snapshot manifest

Manifest SHA-256: `b814ad7df1159c51f6fd1e51b7b34c7fe7b2da9f7fbfaa70da78cc6a8c6f0b29`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/migration-receipt-budget-r1.md` | `a8d22c7680f7eaa026966615eda86c51a53350154b0fe910ac859eda918bb49b` |
| `docs/product-roadmap/build-1/immutable-retirement-binding-r3.md` | `ab9179ecc17c31c733ad21705b7ad0a8db2b99d8739eb7ec8d892a06bb7318f8` |
| `docs/product-roadmap/build-1/retention-lock-budget-r2.md` | `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21` |
| `docs/product-roadmap/build-1/long-hash-control-addendum-r3.md` | `19286de938b886e788792ec0d2f3d8e9ec019f8ba26501e400c78d953659db4e` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `232fca8ca522bd132068f57c8b6669a906d3fc7833d68e6b94c5b6880b249c5c` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `f61a371f14bed85204ee49a809a3f3fbd79f83c5d561d0a70cf19be149da415c` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `7d440bf661729bff721d2269887472c2212a31df2d95b074981dcb6467496b50` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `3fdf995460882e8752016aa0679fcdb7668e484d5433b14ec6e74dcbe53d52bc` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift` | `c406c0bf9c71a80977414800b76f3e471fc9a078ae179669078182317b76fbb2` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionArchive.swift` | `d1131471c39ec30ab080164e70b779442cf63ae5bf18c379b5c11bd86b2b2d29` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `04bc959b8317fb94688b02e325817c143c47f1ae1b73f5767ebb25d40745e93e` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `10d0a6560481747e5f93e34d46703bdd13c1a831cc598acf790ac4f74f25f799` |
