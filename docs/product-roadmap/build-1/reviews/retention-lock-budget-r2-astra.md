# Retention lock budget r2 — independent architecture plan gate

Verdict: **APPROVED at plan level — 0 Critical, 0 High, 0 Medium, 0 Low.** RETENTION-LOCK-M1 from the r1 review is closed by the revised contract and mandatory tests. No new blocking architectural finding was identified. This is the architecture lane's approval of the exact proposal, not an implementation-completion, combined-audit or physical-acceptance verdict.

Proposal SHA-256: `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21` (verified).
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Snapshot time: 2026-09-10T07:44:58.621517+00:00.
Read-only review of the complete revised contract/test specification and relevant current call graph; only this report was written. No source edits, subagents, runtime tests or production actions. Code remains pre-implementation for this addendum.

## Finding closure

**RETENTION-LOCK-M1 — closed. Previous severity: Medium.**

**Evidence:** R2 lines 17–23 remove universal selector/owner/membership preconditions. The exhaustive variants at lines 31–35 distinguish generated active mutations, absent-primary allocating recovery, present-primary allocating recovery, supported resolved legacy retirement and read-only original evidence. Each has explicit constructor and commit authority. The allocation variants never create `.owner-<uuid>`; their only transitions are removing an exactly absent unexposed intent or activating an exactly validated untouched primary. Legacy retirement uses actual historical bytes without synthesizing generation, pointer, action or success commitment. Read-only archived evidence does not recreate active membership or owner files.

The correction matches the actual constraints: `ModelCatalogTransactions.swift:138–155` creates owner files through `O_CREAT`, `ModelCatalogTransactionRetention.swift:170–196` requires owner absence for allocation recovery, and `:268–271` omits generation-scoped pointer indexing for supported generation-less success. R2 line 37 keeps the allocator's pre-encoded intent → primary → active bundle under one continuous global lock, preventing a new recovery race across an unlocked live-allocation gap. A crashed allocator releases that lock; recovery still requires exact phase/index-generation and absence/body CAS.

**Prior consequence removed:** Generic receipt construction can no longer poison an empty intent with its own owner file, prevent legacy history from retiring merely because it lacks generation, or deny archived evidence through an active-membership requirement. The narrow variants do not weaken generated mutation authority.

**Required correction:** None outstanding at plan level. Mandatory r2 tests 8–10 explicitly prove no owner creation during absent-intent recovery, live allocator exclusion at all three durability boundaries, retirement of 1,024 supported legacy records followed by allocation, preservation of historical bytes, and archived pointer/result reads without regenerated membership or authority. Implementation must satisfy these tests before completion is claimed.

## Full revised-contract assessment

**Namespace, ownership and byte identity.** Common observations are evidence, not mutation authority. Generated mutation retains its actual owner and current-stream generation; old cleanup streams remain read-only. All indexed commits recheck captured index generation and variant-specific phase/identity. Captured descriptor placement and full identity/size/nanosecond mtime/ctime/permission/link metadata prevent supported atomic writers from replacing evidence unnoticed. Actual read stability must be maintained around descriptor reads, so the recorded digest remains tied to the validated bytes. Root replacement, unknown schema, failed inspection and ambiguous sidecars invalidate eligibility. This is feasible under the stated trusted-UID boundary and does not claim resistance to privileged metadata forgery.

**Pointer publication and owner lifetime.** R2 line 49 removes the r1 suggestion to release a live owner while ordering a second owner lock. The current operation keeps its owner throughout terminalization/indexing. The prior pointer's original is read-only, validated outside the global lock and rechecked by placement/metadata in the final CAS; it needs no owner lock or active membership. Concurrent legitimate cleanup invalidates the observation and requires fresh validation of the immutable commitment. Same-UUID indexing reuses existing evidence. This preserves pointer-before-retirement, deterministic newest-valid ordering and fail-closed corrupt-pointer behavior without introducing a two-owner deadlock or a false owner-loss window.

**Crash, migration and capacity.** Retirement removes only index membership after required pointer persistence; UUID evidence remains in place. Supported legacy retirement is the explicit pointer-free exception already approved in retention r4. Allocation durability ordering remains intact. Bootstrap enumeration stays outside the journal lock under a stable bootstrap lock, with a final unchanged-root and absent-format check; initialized mutation cannot bypass the initialization gate or reconstruct corrupt indexes from history. The bounded cursor affects scan order only. Busy/corrupt entries remain counted; partial projection does not return an older pointer as proof of completed recovery.

**Bounded work and heartbeat failure.** The specified bulk-validator seams cover current reservation, allocation recovery, cleanup enumeration, retirement, normal terminalization, reconciliation, prior-pointer validation and final adoption lookup. The allowed bounded active-index/format decode is now explicitly distinguished from forbidden bulk primary/result/seal parsing in test 2. A constant-size allocation publication bundle is compatible with the lock budget; it does not permit a multi-record validation loop under that lock. Eight-second cooperative work budgets and independent ten-second short-control leases remain distinct from healthy-filesystem heartbeat guarantees.

The revised owner failure contract explicitly covers prepare, evaluate and cleanup; uses monotonic successful-fsync acknowledgments; fences mutations at eight seconds; and requires independent owner exit by ten seconds when failure exit cannot complete. It preserves committed truth, candidate parent-death handling and pipe-driven launchd restoration without claiming that restoration succeeded after exit. The current control lease is a possible implementation seam, not evidence that the new owner watchdog exists. The current separate cleanup heartbeat and runner wall-clock logic still require implementation changes. No ordinary user cancellation is converted into process-kill cancellation.

**Authority and acceptance.** Receipts and recommendation pointers remain local historical evidence. No relaxation of fresh full artifact verification at readiness/use, actual measured recommendation provenance, signature/freshness/config checks, admission authority or settlement proof is authorized. All ten deterministic test groups are required, including real subprocess stalls/crashes, 1,024-entry load, 2,052-history regressions and immutable commitment substitution. Fixtures remain storage/command evidence; they cannot establish physical B1-T10 MLX serving or settlement acceptance.

## Verification limits and handoff

The proposal digest and source snapshot hashes were checked. The r1→r2 document diff and current allocation/legacy/heartbeat/lease seams were reread. All previously inspected core retention/storage/runner/parent-guard/restore-guard files were unchanged from the r1 snapshot; `ModelTransactionContext.swift` had changed and its relevant lifetime section was reread. No runtime tests were run for this document-only gate. Source changes must receive the complete combined code/security/architecture review and the required deterministic execution evidence. Independent owner/security coordination and any other outstanding plan gates remain prerequisites; this report does not approve unrelated custody changes.

## Exact input snapshot

Manifest SHA-256: `b0953f733e0c6723e50fdfb6e048ad6cae3293ce2b635db9e3c419b17a194a38`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/retention-lock-budget-r2.md` | `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/transaction-retention-addendum-r4.md` | `caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc` |
| `docs/product-roadmap/build-1/long-hash-control-addendum-r3.md` | `19286de938b886e788792ec0d2f3d8e9ec019f8ba26501e400c78d953659db4e` |
| `docs/product-roadmap/build-1/reviews/retention-lock-budget-r1-astra.md` | `3288fd0bbb3a3e3696162ed8416aa58b81abf3f884cfa901ab7c40998d4eec56` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `8977729e96b2828641d8ded82279be62d9b9728aea40310132c587bc9663f35f` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `e74b19b37159da4897199da0295f856454372b719920687964ece9010efad51a` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `eee2d11a4942ce270322e755118bed424b1d2687025295487f68439eb38b1607` |
| `phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift` | `dc5a867aaab1fc85b1e4822a9c3c9ffed16b3a701f94e4add79466d78f548377` |
| `phase3-binary/Sources/macprovider-cli/CandidateParentLifetimeGuard.swift` | `42f1c3ed58d2200cdfa92965895348432bfe4f064716e208051e8df6b58f6241` |
| `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift` | `de1b6478ebe27c078bf0f39ed9333e156834d70308b7514ad3d8d10527fff34e` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `38ceec90183a065f1962a5001c88501e117620592b325ad59669b121d6570e8c` |
