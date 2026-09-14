# Retention active-index receipt R1 — independent architecture plan gate

Verdict: **APPROVED AT PLAN LEVEL — 0 Critical, 0 High, 0 Medium, 0 Low.**

Exact reviewed proposal: `retention-active-index-receipt-r1.md`, SHA-256 `17780883c2a224ba7d07f76ee96d03463cf930e9eb479286c22b74b9d6b367b6`. Reviewer: independent native GPT-6 Astra, high reasoning. Base and observed HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`; worktree `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, with current uncommitted Build 1 implementation. Read-only code inspection; only this report was written. No tests, builds, runtime calls or source changes were performed. Concurrent unrelated work makes the source hashes below the review boundary.

This approves the proposed operation-local index receipt and its required tests. It does **not** establish runtime correctness, finite performance acceptance or the complete Build 1 gate. Reservation-search starvation remains a separate unresolved blocker. The Swift30 measurements in the proposal are root-supplied evidence, not a run performed by this reviewer.

## Findings and architectural evidence

No Critical, High, Medium or Low plan finding. The following assessments record the relevant evidence, consequences and implementation obligations already required by the proposal.

### Index authority and metadata CAS

**Evidence:** `ModelCatalogTransactionRetention.swift:144–163` performs complete format/index closed decoding and validates schema, count, uniqueness, UUID, phase and required provenance fields. `snapshotIndex` at 203 additionally validates completed migration lineage. `ModelCatalogTransactionEvidence.swift:22–77` captures bounded bytes from a stable descriptor outside the global lock and checks descriptor plus placement identity, size, ownership, mode, link count and modification/change times. Storage opens reject unsafe ownership, links, symlinks and ACLs (`ModelCatalogTransactionStorage.swift:126–167`); directory identity is checked separately.

**Consequence:** Retaining the exact decoded index is feasible without creating a new authority source. The new receipt can replace repeated body work with the existing descriptor/placement validation, provided the full closed validator runs at capture and every locked use validates format, index, migration source/progress and the bound journal. Matching generation alone is insufficient. Byte-identical replacement invalidates an existing receipt because its pinned inode changes; a fresh operation must fully validate its own evidence.

**Required correction:** None to the plan. Implement Required test 4 against actual final mutation seams, including same-generation membership and origin/binding reference substitutions. Keep the exact reference comparisons currently in `validateActiveReceiptMembership` at 217–230. The generated receipt's selector and primary/provenance checks remain necessary after index metadata CAS; the decoded index is not a replacement for them. Do not retain per-UUID evidence sets for the whole history or introduce cross-call caching.

### Complete maintenance integration and bounded work

**Evidence:** Public maintenance at `ModelCatalogTransactionRetention.swift:360–364` invokes initialization and allocation recovery before the private pass. Existing initialization decodes the index at retention line 101 and migration lines 209/216; recovery snapshots it at retention lines 234–238. The pass then reparses through `retireOne` at 399/429, receipt validation, cursor mutation at 390 and capacity checks at 393. Evaluation retirement calls `indexCompletedEvaluation` at 427; its `captureActiveReceipt` also initializes and snapshots (`ModelCatalogTransactionEvidence.swift:106–112`), and previous-pointer validation snapshots at retention line 555.

**Consequence:** Optimizing only the private retirement loop would leave hidden initialization and nested pointer work. The proposal's one-maintenance-call receipt and actual closed-decode counter requirement cover these integration paths. A completed-journal fast path can capture one fully validated receipt and pass it through initialization validation, allocation recovery and retirement; any authorized index update must replace that receipt only through the prescribed exact recapture. Unfinished migration retains its independently approved bootstrap/WAL rules. Allocation recovery must retain its distinct absent-intent rules, including absence of owner evidence, rather than use a generated-owner receipt.

**Required correction:** None to the plan. Required test 2 must instrument the **public maintenance call**, including completed initialization/recovery and nested evaluation-pointer paths, rather than reset the counter immediately before the private loop. A standalone status API's independent capture is not permission for maintenance to call it and evade this assertion. The original budget must reach all nested helpers and final validations. All index read/hash/encoding work moves outside the global lock as specified; required byte recapture, fsync and metadata checks remain. The plan correctly makes no hard syscall-return guarantee and preserves the independent heartbeat/watchdog obligations.

### Publication, contention and partial failure

**Evidence:** Retirement currently publishes a validated immutable certificate before removing active membership (`ModelCatalogTransactionRetention.swift:440–451`). `ModelCatalogTransactionArchive.swift:19–100` constructs the five existing outcome variants from exact evidence and requires an existing certificate to match the new proof byte-for-byte. The maintenance loop currently catches per-UUID errors before attempting cursor publication at retention line 380.

**Consequence:** The proposed old-receipt CAS prevents a competing allocation or binding publication from being overwritten. After our index write, exact equality between recaptured bytes and the preencoded next index is sufficient to reuse the already-generated decoded value; an in-memory intended value alone is insufficient. If another owner writes between publication and recapture, equality failure ends this pass and its durable update survives. A certificate published without index removal remains recoverable only by the existing exact-certificate path on a fresh call. Format or completed-migration replacement invalidates retained evidence throughout the call.

**Required correction:** None to the plan. Do not preserve the current catch-and-continue behavior for receipt invalidation or a partially published retirement. Tests 4–6 must prove there is no subsequent cursor, primary, pointer or retirement mutation after these failures; normal busy/protected-record cursor advancement remains allowed only with valid unchanged receipt authority. Exercise thrown failures as well as the inherited real child-death boundaries. The fresh restart validates durable state; it does not reconstruct authority or reinterpret a missing binding/origin/certificate as legacy. Previous pointer targets remain separately verified and read-only.

## Finite acceptance and scope

The actual legacy fixture at `ModelCatalogTransactionRetentionTests.swift:461–525` creates 1,024 generation-less successful records and results, forces three eight-second migration expirations with a strictly advancing persisted prefix, then allows sixteen maintenance calls. It requires an empty active index, no pointers, unchanged original/result bytes, absent legacy selectors and successful fresh allocation. Required test 3 preserves this fixture and adds per-pass timing/progress. This is an adequate finite acceptance criterion; the proposed reduction in repeated decoding is plausible, but the remaining encoding, hashing, durable writes and evidence validation mean success must be measured.

Required tests 1–7 retain immutable binding r3, migration receipt r1, protected and generated/legacy distinctions, exact crash recovery, no history scans, mixed history above 2,052 entries, cleanup compatibility, concurrent owner writes and unchanged deadlines. Those tests, plus `test-spec-r4.md` and previously approved corrections, are sufficient at plan level. A failed three-plus-sixteen result still blocks acceptance; raising pass counts, increasing budgets or shrinking fixtures is not authorized. The separate eight-attempt reservation failure remains open and is not waived by this zero-severity verdict. Full combined implementation code/security/architecture review and fresh test evidence remain required.

## Snapshot manifest

All digests are SHA-256, captured from the named current files. Paths below are relative to the reviewed worktree.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/retention-active-index-receipt-r1.md` | `17780883c2a224ba7d07f76ee96d03463cf930e9eb479286c22b74b9d6b367b6` |
| `docs/product-roadmap/build-1/immutable-retirement-binding-r3.md` | `ab9179ecc17c31c733ad21705b7ad0a8db2b99d8739eb7ec8d892a06bb7318f8` |
| `docs/product-roadmap/build-1/migration-receipt-budget-r1.md` | `a8d22c7680f7eaa026966615eda86c51a53350154b0fe910ac859eda918bb49b` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/reviews/gate-log.md` | `2cc6547c2e4674179309e51ae6baf92e5611fea56a97a681fbfda5a15867d1d1` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `224ae2eb6245076a15ff4d0f2a6ac56ecacf5734ee43d5575798a6abc9ec757b` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `df84197a779b94cde8ab6cd51ba5678d8888304a0ca92d16af202b7dfcd92d15` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `afede2efc30cb131643ed188e4ce660d42395beed765382768eb52618e5ac5ba` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionArchive.swift` | `ea320282dc712518936efa88eac0e4b28bcf232dda738739609b7678e3c8d0aa` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift` | `923493e28d749859f686d2cd0b2af4d2735c7f8546bd80bbfe28d2f3816464b5` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `3fdf995460882e8752016aa0679fcdb7668e484d5433b14ec6e74dcbe53d52bc` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `6039d85db7aaf3464150135e81cd10c585c98a1c0cfd14051d97d21bbb883cb4` |
