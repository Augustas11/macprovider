# Immutable retirement binding r2 — independent architecture plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 2 Medium, 0 Low.** R2 resolves the three specific r1 mechanisms, but introduces two persistence contracts that need definition before implementation. This is not a zero-C/H/M approval.

Exact proposal SHA-256: `8ba51963aa0af266ef74030fa43fdeadd2d6ab09a64f7ce76362372ea078d0dc` (verified).
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Snapshot time: 2026-09-10T08:28:12.630830+00:00. Sources were read without modification; only this report was written. No subagents or runtime tests. The concurrent Swift run is not claimed as evidence for unimplemented bindings.

## Prior finding disposition

- **BIND-ARCH-M1:** The explicit cleanupRequired delta, canonical prospective primary SHA and exact event replay resolve the omitted-bookkeeping mechanism. Normal and recovery now have an express common terminal representation; later cleanup uses the unchanged r4 commitment, not the temporary full-primary proof.
- **BIND-ARCH-M2:** Removing every old-pointer upgrade resolves the fabricated-preterminal-digest mechanism. Previously unbound generated success stays protected, even with a matching pointer; no historical binding enters pending replay.
- **BIND-ARCH-M3:** Allocated origins, active expected binding digests, pointer cross-links and retained retirement certificates address missing-binding regeneration and post-retirement downgrade for newly allocated work. Migration must establish those expectations correctly; the new migration defect below is not approval of origin baselining as currently specified.

## BIND2-ARCH-M1 — incremental migration has no durable per-UUID classification/progress commitment

**Severity:** Medium. **Confidence:** High.

**Evidence:** Proposal lines 28–30 define a prepared/complete descriptor containing source-index SHA (or inventory digest) and target index version. They then publish origins incrementally, publish the digest-bearing new index only after all origins, and finally complete the descriptor. There is no specified durable per-UUID expected origin/classification digest or migration position/state before that final index. The frozen old index only identifies UUID membership/phase; current `ModelCatalogTransactionRetention.swift:5–13` entries contain ID and phase, and `initializeRetention` at lines 87–134 has no resumable body-classification record to reuse. Unlike ordinary maintenance, migration cannot rely on the current non-authoritative maintenance cursor because classification/provenance itself establishes later retirement eligibility.

**Consequence:** After an origin is created but before the new index is published, crash and remove that origin. At restart the prepared descriptor cannot distinguish that UUID from a later UUID whose origin has not yet been created. If it reclassifies missing origins from current primary bytes, an already-baselined generated/protected record whose generation/evidence was subsequently removed can be accepted as a new legacy snapshot. If it rejects every missing origin, valid interrupted migration cannot finish its untouched suffix. Existing-origin mismatch rejection does not distinguish these missing-file states. Additionally, repeated eight-second passes have no specified durable progress position and can repeatedly consume their budget validating the same completed prefix; pages/yields within a call alone do not establish eventual completion. Source-version/source-SHA matching also needs an exact membership/origin-reference completion proof, not only a target schema match.

**Required correction:** Define a closed durable migration progress protocol. Before publishing each origin, commit the exact classification and expected origin digest/bytes (or an equivalent immutable per-UUID decision) together with the source evidence that authorized it. Restart must use that frozen decision and never reclassify an already-decided UUID from changed primary bytes. Distinguish unclassified, authorized-but-not-published and committed states, including a crash between origin publication and progress acknowledgment. Specify an authoritative bounded progress position/set that resumes without bulk revalidation of every completed primary on each pass. Persist the actual frozen initial UUID set for the no-old-index case; a digest alone cannot reconstruct it after origin writes change the root inventory.

Before publishing/completing the new index, validate exact frozen membership/phases, every expected origin reference and source/migration identity. Pin the intended completed-index contents (or a rigorously equivalent canonical digest/generation link) so prepared+new-index recovery cannot bless an omitted, duplicate, reclassified or wrong-origin entry merely because version/source fields match. State byte/count bounds and publication/fsync ordering for any new progress artifacts; do not silently exceed the stated 16-KiB record limit or reintroduce history enumeration/global-lock body loops.

**Required tests:** Force several migration invocations to exhaust eight seconds after different pages and restart each time; assert forward progress over 1,024 entries without rereading/reclassifying the completed prefix's bodies. Crash before/after each classification decision, origin publication and acknowledgment. Remove a committed/in-flight origin and rewrite the primary as plausible legacy: retain the original classification or block, never rebaseline. Repeat for no-index bootstrap. Prepared+new-index tests must mutate membership, phase, origin digest and migration/source linkage individually; completion must reject them. Corrupt/missing progress cannot restart baselining from scratch. Preserve every UUID and the full legacy capacity outcome.

## BIND2-ARCH-M2 — non-evaluation retirement commitment is not a defined closed value

**Severity:** Medium. **Confidence:** High.

**Evidence:** Proposal line 20 defines exact fields for generated evaluation-success certificates but says other supported generated outcomes pin their “exact immutable original terminal commitment and required result/seal evidence digests.” No such existing generic commitment exists: `ModelTransactionSuccessCommitment` at `ModelCatalogTransactionRetention.swift:45–63` and `successDigest` support only evaluate_model success. The current primary separately contains committed, startedAt, resultSHA256, artifactSealSHA256, cleanupRequired, cancelRequested, events and attemptStartSequence (`ModelCatalogTransactions.swift:108–135`). Approved cleanup can change bookkeeping before retirement. The proposal does not specify the other certificate discriminators, exact commitment fields/encoding, nullable/required result/seal rules or whether resolved cleanup evidence is included.

**Consequence:** Independent implementers can choose incompatible meanings: a whole mutable record digest, an incomplete terminal event digest, or the evaluation-success helper that rejects prepare/failure outcomes. The first can conflict with allowed cleanup changes if captured at the wrong phase; the second can omit outcome/commitment evidence required to make archived direct-UUID validation meaningful; the third prevents healthy prepare/failed/cancelled/timed-out history from retiring and exhausts active capacity. Archive behavior must remain executable for every supported outcome after index expectations disappear, not depend on a generic undefined commitment.

**Required correction:** Enumerate the closed certificate outcome variants and exact fields/encoding for prepare success and supported non-success original outcomes, as well as evaluation success and legacy. Define immutable original authority/terminal fields, optional versus required result/seal commitments, treatment of original event history and cleanup/cancel bookkeeping, and the point at which any whole-primary/cleanup-stream digest is frozen. A valid minimal option is a retirement-time exact terminal-primary/evidence snapshot for non-adoption outcomes only after all cleanup is resolved, with an explicit rule that no later primary mutation is authorized; another is a fully specified immutable terminal commitment with separately validated cleanup evidence. Preserve r4's successful-evaluation commitment and its allowed cleanup exclusions. Do not let a failed or intent-only prepare certificate claim successful publication. Define missing/changed evidence behavior both before and after membership removal.

**Required tests:** Cover prepare succeeded, failed, cancelled and timed_out, and evaluation non-success with supported present/absent result/seal evidence. Resolve legitimate cleanup before retirement, interrupt certificate→membership removal, restart and validate direct archived diagnostics/eligibility with no active entry or owner recreation. Alter each defined immutable field/evidence digest and remove origin/certificate/required sidecars: block eligible archived use without rewriting history. Complete more than 2,052 mixed healthy supported outcomes, not evaluation successes alone, without a lifetime-cap regression.

## Other revised-contract assessment

The normal allocated-origin/binding/certificate chain is coherent: origin authority precedes active allocation; binding precedes expected-index reference, which precedes successful primary; required pointer publication precedes certificate and membership removal. A crash before expected binding reference can pin only the exact pending preterminal/result/origin-bound transition; terminal success without that reference is protected. Missing binding with expected reference cannot be regenerated. Dispatching origin/binding evidence before mutable state/generation prevents success→failure and generated→legacy branch bypasses.

The terminal replay contract now authorizes exactly cleanupRequired assignment plus the stored event and requires the canonical complete-primary digest. The current primary has no separate state or updatedAt stored fields: its state derives from the last event. The parenthetical reference to such fields must be implemented through the actual existing representation, not used to add undeclared primary fields. Recovery must preserve false→true and true→false cleanup transitions exactly; later legitimate cleanup may change only already-approved bookkeeping.

After index removal, successful generated direct eligibility requires origin + retirement certificate + binding + result + immutable commitment. That closes the missing active-index expectation seam at plan level. Deleting those proofs or replacing classification must produce unavailable eligibility; weaker generic historical reads may expose retained diagnostics only and may not construct a new action or certification. A missing origin/certificate must not trigger migration of an archived UUID. The plan explicitly prohibits such history enumeration/reconstruction. Exact archived tests must remain separate from active-index tests, as required by test 5.

No previous-target owner is acquired during pointer validation; the current owner remains held. Every new evidence file joins receipt metadata CAS and allocation/expiry absence checks. Bulk decoding/hashing/encoding remains outside journal locks, with bounded constant-size durability bundles and owner fencing. New schema/index changes must extend all existing closed parsers and recovery paths together. The disclosed protection of earlier unreleased generated/unresolved evidence must not become a hidden lifetime cap for supported generation-less legacy or healthy newly allocated mixed outcomes.

All nine proposed test groups plus inherited r4/budget/owner/cleanup tests remain required. No physical MLX, signed execution or economic acceptance is inferred from this persistence plan. A new exact-digest gate and full combined implementation review remain necessary after the two corrections.

## Verification snapshot

Verified the proposal SHA; inspected current index/format/migration, generic primary fields, evaluation-only commitment and retirement seams against the r1 evidence and approved contracts. No binding/origin implementation or runtime validation was performed.

Manifest SHA-256: `1e5ce42bac5d0617c5466d8cfab267076c4e60d01d73a333b095edd9091d73d1`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/immutable-retirement-binding-r2.md` | `8ba51963aa0af266ef74030fa43fdeadd2d6ab09a64f7ce76362372ea078d0dc` |
| `docs/product-roadmap/build-1/reviews/immutable-retirement-binding-r1-astra.md` | `8590dccc476c2d332cbb53802d68eb010c3c4d52206e64d26c9a4a767d19ed68` |
| `docs/product-roadmap/build-1/transaction-retention-addendum-r4.md` | `caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc` |
| `docs/product-roadmap/build-1/retention-lock-budget-r2.md` | `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `9fbfb11f271f120b32e1034bbbdee81a0e2cac55b3d6702d9f284c8c6b3e1caf` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `2ead8096b77014d60d63b24b25b73b88ef600787c65546d5eba4c094e320e031` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `8e48fd37f63e7634bc3138edf7f1438e4c3c9fa72ec1389da7e45ff824e3bbdc` |
