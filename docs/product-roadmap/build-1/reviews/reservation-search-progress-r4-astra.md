# Reservation search progress R4 — independent architecture plan gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.** Both R3 findings are independently resolved. No additional blocking defect was identified in the exact proposed protocol.

Exact proposal SHA-256: `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21`. Independent native GPT-6 Astra, high reasoning. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`; worktree `/Users/augstar/.codex/worktrees/macprovider/product-build-1`. Reviewed the retained complete protocol, exact R4 changes, prior findings and current allocation/index/storage/migration/owner seams. Only this report was written. No runtime edits, tests, services or delegation. Concurrent smaller-correction work is bounded by the source manifest below.

This approves the structural fallback's design and test requirements. It does not establish its necessity from the healthy fixture, prove performance/compatibility, waive the index-correction prerequisite or close the complete Build 1 gate.

## RSP3-ARCH-M1 — closed

**Prior severity:** Medium.

**Evidence:** R4's closed phase/entry/reference matrix distinguishes unclassified source members, pending first-class publication, acknowledged class, finalizing/complete active membership and complete allocating expectations. Initial progress is explicitly empty and published after the mandatory format fence but before the initial classifying index. Post-format recovery can complete only that initial state while the original source index remains unchanged; an installed v4 index cannot reset progress.

The progress document now acknowledges every classified member, including members beyond the contiguous prefix. First-class publication orders receipt/index intent, class/optional left, progress acknowledgment, then final entry references. A pending entry may therefore coexist with an already-published acknowledgment, but recovery must match the exact pending next refs. A non-null acknowledged class without its progress entry during classification is an impossible ordered state. First-left publication strengthens the same map before clearing the pending reference. Finalization requires complete equal membership/ref evidence and no pending entries.

**Consequence:** The initial classifying index has a valid closed representation without fabricating durable class authority. A member classified by a live writer beyond the worker's current prefix cannot become unclassified merely by losing its current index reference. The prefix is derived scheduling/progress information; the all-member map and retained files carry the acknowledgment evidence. Completed active entries cannot accept the classifying null case, and fresh allocating entries retain their separate ordered missing-file exceptions.

**Required correction:** None remaining at plan level. Implement the matrix as actual decoder plus authority-graph validation, not permissive optional fields followed by selective checks. The new R4 tests correctly cover every state, acknowledgment before final index, removal inside/beyond prefix, forbidden complete/null combinations and no acknowledged-primary rescan. Missing or changed acknowledged files remain protected; recapture of a shared progress document must validate exact prior evidence and preserve other entries rather than rebaseline them.

## RSP3-ARCH-M2 — closed

**Prior severity:** Medium.

**Evidence:** R4 derives a single receipt path from canonical transaction UUID and the index's lowercase receipt digest: `.reservation-migration/receipts/<transactionUUID>/<receiptSHA256>.json`. It requires exact byte hash, repeated body UUID/generation/source lineage and origin/primary observations. Class-only and later left publications have distinct immutable content names. Recovery reads only the referenced receipt; prepared unreferenced files remain nonauthoritative.

Fresh UUID allocation checks absence of the transaction-scoped receipt directory itself, alongside existing sidecars/owner evidence. It neither enumerates historical receipt files nor adopts an orphan directory. Allocation recovery never creates this directory. Existing active members may retain it after pending clears, so directory existence is not confused with a pending operation.

Current storage supports this shape: `ModelTransactionDirectory.child`, `validateName`, `metadata` and `openFile` (`ModelCatalogTransactionStorage.swift:105–140`) provide validated components, directory identity and no-follow/private file checks. `ModelTransactionFileEvidence` retains the open file and placement metadata for final CAS; the receipt's filename is a locator, not substitute content authority.

**Consequence:** Restart can resolve the exact pending publication in bounded direct lookups without inventing a UUID locator or scanning history. The allocation collision predicate is likewise a direct namespace check. Wrong directory/filename/body identity cannot authorize a different transaction's metadata, and concurrent unrelated pending entries remain independent.

**Required correction:** None remaining at plan level. Run the new concurrent-pending, class-then-left, orphan-history, direct-open-count and substitution tests. All path components must come from validated journal identifiers; no arbitrary path field or discovery-based authority is introduced. Preserve exclusive immutable publication and exact matching reuse of the same frozen receipt.

## Full protocol assessment

The earlier accepted corrections remain coherent. Pre-cut allocation recovery uses the existing absence-specific path before a noncreating owner probe, and only fully active membership can enter the frozen source. Current `recoverAllocations` explicitly avoids acquiring owner locks because owner-path absence is evidence; R4 preserves that behavior. Old startup after final absence validation must fail its final mandatory-format check before launch. Actual old-binary qualification, descriptor limits and original eight-second cut are required; the design does not authorize terminating healthy old owners to force migration.

Primary-first departure leaves truthful started/cancelled state before exclusion publication. Metadata receipts cannot mutate the primary or launch work. The original live starter retains custody through its bundle and may acknowledge/launch only after successful durable completion and lifetime recheck. Ownerless recovery completes exact metadata and then uses existing success-binding/result/seal or interrupted-owner reconciliation. Generic retries after partial publication remain forbidden. Queued cancellation and live-owner cancellation retain their explicit distinct custody rules.

Per-entry pending references plus the all-member acknowledgment map permit unrelated UUID writers to continue without acquiring each other's owners or waiting for the migration prefix. Shared index/progress changes still require fresh outside-lock capture and exact CAS; the merge may update only the authorized entry and must preserve current binding refs and other pending/acknowledged entries. A receipt freezes per-entry metadata, not an obsolete whole shared progress document. All bulk reading, hashing and encoding remain outside the global lock, and final metadata/write bundles retain the original deadline.

Finalizing installation binds exact prepared completed-index bytes and source/progress evidence. After completion, progress becomes immutable historical evidence; subsequent departures and fresh allocations must not update its install-bound digest. Dynamic membership keeps the same completion lineage while validating current classes and exclusions independently. Fresh allocation uses exact primary/origin/class expectations before active visibility and its ordered absence recovery, without owner creation or reuse of a stale search-absence conclusion. Legacy/protected membership cannot be manufactured by a new allocation. Retained origins/classes/exclusions and ordinary retirement certificates keep distinct roles.

**Required correction:** None at plan level. The inherited and added tests cover the meaningful corruption, crash, concurrency, identity and bounded-progress cases. Implementation must exercise every participating direct writer and actual control path; helper-only fixtures cannot demonstrate owner/heartbeat integration. Exact format-size derivations, descriptor/resource qualification, short-control latency and unchanged lifetime guards remain substantive acceptance conditions.

## Necessity and acceptance limits

The lead's newer evidence reports healthy-capacity and legacy progress passing after the smaller index correction; earlier reported healthy capacity was 15.368 seconds, mixed history above 2,052 was 84.279 seconds, and the shared single-index-decode check passed. The lead also reports one remaining test with four fixture assertions awaiting correction/retest. These are supplied results, not reviewer-run tests, and the complete smaller-correction gate is not declared passed here.

The healthy-capacity failure is no longer a reason to implement v4. Complete the index correction's validation first, then measure the remaining maximum-shape repeated-primary work against the actual required progress contract. If a smaller solution satisfies every required outcome, do not add this persistence layer. Conversely, passing the small-record healthy fixture does not waive maximum-shape classification progress or prove the existing all-primary search avoids rescanning.

R4 retains the explicit cooperative per-record profile and requires durable completed classifications to survive bounded calls without rereading their large primary bodies. It makes no arbitrary 4 GiB/64-second throughput promise. The healthy eight-call/64-second fixture, original eight-second budget, protected-evidence behavior, all prior migration/binding/retirement/cancellation/cleanup tests, and combined code/security/architecture audits remain required. This plan-level zero does not establish physical, release or whole-build acceptance.

## Snapshot manifest

SHA-256 values for inspected shared-worktree files:

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/reservation-search-progress-addendum-r4.md` | `3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21` |
| `docs/product-roadmap/build-1/reviews/reservation-search-progress-r3-astra.md` | `55871a03095ceef0b8abc668bda9e5748934c7ef6dc5f3472d5b2b2a2341e1ef` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/immutable-retirement-binding-r3.md` | `ab9179ecc17c31c733ad21705b7ad0a8db2b99d8739eb7ec8d892a06bb7318f8` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `8140d9ee9f6d76b9784a1d92da73653b8c6a5c573ad40794c99d23d10886665f` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `86ef79bbbafbff366de80d6797b6f33846fd0e9991de8b1f95fa6ac568d001d0` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `3fdf995460882e8752016aa0679fcdb7668e484d5433b14ec6e74dcbe53d52bc` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `cfe7d52d9be3219b8f64e3da346d855d36ca6d983dfdcbafc7ced1affb2f2287` |
