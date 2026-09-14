# Reservation search progress R3 — independent architecture plan gate

Verdict: **REJECTED — 0 Critical, 0 High, 2 Medium, 0 Low.** No v4 implementation authorization.

Exact proposal SHA-256: `c27b871e1a5858e0ed381fd16721e7bb46d63af59289e8f493e855dc38665e9f`. Independent native GPT-6 Astra, high reasoning. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`; worktree `/Users/augstar/.codex/worktrees/macprovider/product-build-1`. Reviewed the complete retained R2 design and exact R3 changes, both R2 findings, and actual current allocation/index/owner/storage paths. Only this report was written; no tests, runtime changes or delegation.

## R2 findings independently resolved at plan level

**RSP2-ARCH-M1: closed.** R3 explicitly runs absence-specific allocating-intent recovery before owner probing, requires only fully active source membership, and rechecks phases/membership at the cut. The new probe never uses `O_CREAT`: it retains safely opened existing owner inodes or absence evidence and revalidates them under the final journal lock. Thus neither interrupted allocation nor a failed migration cut manufactures the owner inode that would prevent existing absence recovery. A starter creating an owner after final absence validation cannot publish through the held journal lock and must reject the changed mandatory format before launch. Tests now cover the real pre-v4 crash boundaries, old startup race, all-present/all-absent owner paths, resource limits and original deadline. Actual old-binary ordering and 1,024-descriptor qualification remain required evidence.

**RSP2-ARCH-M2: closed.** R3 defines exact initial primary/origin/class expectations in the allocating entry, orders exclusive file publication before active visibility, rejects generic retry after a partial bundle, and supplies an exhaustive recovery table using owner absence. Present files must match the frozen initial bytes; impossible publication suffixes remain protected. Final allocation CAS must invalidate stale search absence after a competing index mutation. The immutable install graph is historical completion evidence, while later current generations may add generated members or retire validated members without reclassifying the source. Empty-source and repeated post-migration allocation/retirement tests address the original normal-use gap. These rules preserve earlier provenance and crash contracts.

The three R1 resolutions remain intact: primary-first departure never replays a prospective start, per-entry migration publication does not wait for an unrelated owner, and the early mandatory-format fence has an explicit supported-binary qualification boundary. The remaining findings concern the executable closed representation of those protocols.

## RSP3-ARCH-M1 — Initial classifying index contradicts mandatory active-entry class authority

**Severity: Medium.**

**Evidence:** Closed formats item 2 (`reservation-search-progress-addendum-r3.md:75–86`) makes `classSHA256` mandatory for active entries and permits absent expected files only for fresh allocating entries. The cut requires only fully active source entries, then publishes a v4 **classifying** index before classification starts (lines 261–298). The worker and compatible writers subsequently handle unclassified members and publish their classes (lines 344–378). Item 3 separately says the class reference is mandatory for every completed entry, but does not define the classifying-entry exception or a distinct unpublished expectation. Current `decodeActiveIndex` at `ModelCatalogTransactionRetention.swift:149–165` demonstrates that these are real closed schema/phase predicates enforced before a receipt can be used; no v4 implementation currently supplies the missing state.

**Consequence:** A strict implementation of item 2 cannot encode/accept the initial classifying index without inventing class hashes or claiming unpublished class authority. An implementation that merely makes the field optional everywhere risks accepting a missing acknowledged class in a completed journal. The initial and partially classified restart states therefore lack an unambiguous validator, despite being required migration states.

**Required correction:** Define a phase/entry-state matrix for class, left and pending-publication references. Permit genuinely unclassified source entries only while classifying, with explicit absent-versus-expected reference semantics and no reuse/negative authority. Define how a referenced first-class publication transitions that entry to an acknowledged class, and how progress/index cross-checks prevent an acknowledged member from becoming unclassified again. Finalizing/completed active entries must require the durable class; completed allocating entries retain their separately specified expectations. A deleted acknowledged class must fail closed rather than trigger classification. This is a bounded schema clarification, not permission to weaken closed decoding.

**Required tests:** Fresh cut with no classes, post-format/pre-index recovery, partially classified index, pending first-class publication and complete/finalizing indexes through the actual decoder. Remove a class/reference from an acknowledged or completed member and require protected failure. Feed classifying-only combinations into complete phase and reject them. Verify exact restart progress without class fabrication or a completed-member primary rescan.

## RSP3-ARCH-M2 — Pending receipt hash does not identify its UUID-named file

**Severity: Medium.**

**Evidence:** The active entry carries only a `reservationPublication` receipt SHA-256 (item 2, line 83). Item 7 stores receipts under a **unique migration-or-operation UUID filename**, but neither the reference nor a specified derivation supplies that filename. In contrast, install references explicitly carry both `installUUID` and receipt hash. Migration may publish class-only metadata for a queued member and later publish its first left metadata; multiple per-entry operations and unreferenced prepared receipts are retained. Therefore a single assumed filename cannot be inferred safely from the migration UUID or current primary without a selected rule.

**Consequence:** A fresh process with a referenced pending receipt cannot perform the promised bounded exact lookup. It would have to invent a locator convention, scan retained receipt history, or treat an undiscoverable intent as permanently unavailable. Reusing a guessed fixed UUID filename for different immutable publications also conflicts with exclusive creation. The fresh allocator additionally requires absence of this UUID's metadata receipts; that predicate needs a bounded namespace lookup, not a scan of the shared receipt directory.

**Required correction:** Specify a closed, deterministic receipt locator and bind it to the existing SHA and transaction identity. For example, carry the canonical receipt UUID alongside its SHA and place it in a transaction-scoped directory, or use a content-addressed filename beneath a canonical transaction-scoped directory. Derive every path from validated internal identifiers, never a caller path. Define how class-only and later left publications receive distinct immutable names, how restart finds exactly the referenced receipt, and how fresh-UUID collision/absence checks avoid listing all historical receipts. Wrong UUID, hash, transaction or source lineage must reject before mutation; unreferenced receipts remain nonauthoritative history.

**Required tests:** Restart with concurrent pending receipts for two UUIDs; class-only then later left publication for one UUID; multiple retained unreferenced receipts; receipt-name/hash/transaction substitution; and new-allocation collision checks. Instrument the actual direct file opens and assert no history enumeration. Recovery must resolve only the index-named immutable receipt and preserve unrelated pending references.

## Necessity and performance acceptance

The lead reports Swift32 healthy-capacity PASS in 15.368 seconds, mixed history above 2,052 PASS in 84.279 seconds, and the shared single-index-decode test PASS; the complete selection remains pending. These are newer supplied results, not tests run by this reviewer. They supersede the earlier healthy-fixture failure as a rationale for v4. The index correction should finish its own validation and combined review first.

The remaining structural requirement is separate: current `reserveOperation` still reads complete primary bodies before maintenance, so the healthy small-record result does not establish that maximum-shape repeated calls avoid rescanning prior large negatives. R3 preserves the cooperative per-record assumption, original budgets, durable classification progress and no arbitrary-4-GiB/64-second assertion. Keep those tests and measure actual primary/metadata costs. If the smaller implementation can independently satisfy all required outcomes, v4 is unnecessary; a healthy fixture alone neither proves that nor authorizes this larger persistence change.

The proposal otherwise maintains exact tuple/origin authority, multiple plausible candidates, permanent exclusions, no cross-call mutable-negative cache, explicit partial-publication recovery, owner fencing and immutable history. The all-owner cut, full reference graph and installation work still need actual resource/latency qualification; they are not accepted merely because they are structurally bounded. All existing cancellation, cleanup, binding, retention and compatibility tests and complete combined audits remain required.

## Snapshot manifest

SHA-256 values for the inspected shared-worktree files:

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/reservation-search-progress-addendum-r3.md` | `c27b871e1a5858e0ed381fd16721e7bb46d63af59289e8f493e855dc38665e9f` |
| `docs/product-roadmap/build-1/reviews/reservation-search-progress-r2-astra.md` | `ab66394102b2fe9c559e01fde39f3b83189ab9e536a56b3848896a6e93fecac5` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/retention-active-index-receipt-r1.md` | `17780883c2a224ba7d07f76ee96d03463cf930e9eb479286c22b74b9d6b367b6` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `3e1e5d63925a53eb2fc3f1521bb02c6a005643585087a9289b845a874937c875` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `04bc959b8317fb94688b02e325817c143c47f1ae1b73f5767ebb25d40745e93e` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `86ef79bbbafbff366de80d6797b6f33846fd0e9991de8b1f95fa6ac568d001d0` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift` | `6d12d94c1d7bd514bed598670b5bd0c1e438d5496b6173f4684fde91481cb6ff` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `3fdf995460882e8752016aa0679fcdb7668e484d5433b14ec6e74dcbe53d52bc` |
