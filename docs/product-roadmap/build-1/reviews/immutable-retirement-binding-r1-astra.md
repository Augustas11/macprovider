# Immutable retirement binding r1 — independent architecture plan gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 3 Medium, 0 Low.** No binding implementation is approved by this architecture gate.

Exact proposal SHA-256: `82c047edb254d9217a4e742bf1d099f9346f30ab9f1b79ee3f8785899a0baa97` (verified).
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Snapshot: 2026-09-10T08:10:43.325269+00:00. Other retention implementation work is active; hashes below identify this review's inputs.

Read-only review except this artifact. No source edits, subagents or runtime tests. Inspected the proposal, approved retention r4/lock-budget r2 and current primary/result/terminal/index/retirement call graph.

## BIND-ARCH-M1 — pending recovery omits the authorized terminal bookkeeping delta

**Severity:** Medium. **Confidence:** High.

**Evidence:** Proposal line 13 stores the exact successful event and preterminal primary SHA but does not store the terminal record's allowed bookkeeping delta. Lines 19–21 prepare and write a prospective final record including truthful cleanup outcome. Line 30 reconstructs recovery by appending only the stored terminal event to the exact preterminal primary. Current normal terminalization in `ModelCatalogTransactions.swift:682–691` sets `cleanupRequired = cleanupFailed` before appending the event; interrupted-owner reconciliation at `:487–491` similarly computes cleanupRequired from existing state/staging before appending. The immutable success commitment intentionally excludes mutable cleanupRequired, so matching that commitment cannot detect this reconstruction discrepancy.

**Consequence:** Begin with a committed nonterminal primary whose cleanupRequired is false. Owned staging cleanup fails; the authorized final record has cleanupRequired true and an exact succeeded event carrying staging_cleanup_required. Crash after binding fsync but before primary publication. Appending the stored event alone recreates cleanupRequired false. The original success commitment still matches because it binds the warning/event but not that bookkeeping flag. Cleanup projection can omit the unresolved staging even though the recovery reports the warning; alternatively an implementation rejects a recoverable pending transition because exact prospective state was not specified. This violates the approved success-with-cleanup/restart outcome.

**Required correction:** Specify how pending recovery reconstructs the entire authorized terminal transition, without changing the r4 immutable commitment. Either freeze a closed terminal delta in the binding (at least the exact cleanupRequired outcome, with explicit allowed changes), or durably establish the complete nonterminal bookkeeping state before capturing its exact bytes/hash. Define deterministic reconstruction/encoding of the terminal record using the stored event and that authorized state. Recovery must not recompute a new warning/timestamp or silently retain the wrong cleanup flag. Subsequent legitimate cleanup remains allowed to change its existing bookkeeping without changing the immutable binding/event.

**Required tests:** Crash after binding fsync with staging cleanup failure and preterminal cleanupRequired false; compare normal and recovered terminal semantics/bytes, exact event and cleanup projection. Repeat the reverse prior-bookkeeping case where cleanup resolves an existing flag, pending recovery races status/cancel, and subsequent explicit cleanup permits adoption/retirement while preserving binding/result/original event.

## BIND-ARCH-M2 — the proposed historical upgrade cannot produce the required preterminal-byte proof

**Severity:** Medium. **Confidence:** High.

**Evidence:** The sole binding schema at proposal line 13 requires SHA-256 of the exact preterminal primary bytes. Line 49 permits a previously successful unbound generated original plus its exact existing context pointer to seed that same binding. The current `ModelTransactionRecommendationPointer` stores context/UUID/success/result digests, and `successDigest` at `ModelCatalogTransactionRetention.swift:476–488` commits the final successful event and immutable fields. Neither preserves the previous serialized primary bytes/hash. The current terminal write atomically replaces the primary; legitimate cleanup may later change bookkeeping again.

**Consequence:** An old terminal record and matching pointer can prove their existing success/context commitment, but cannot establish the exact bytes present before its historical terminal transition. Removing the last event and re-encoding guesses serialization and preterminal cleanup/cancel state. Filling the new required digest from those guessed bytes fabricates evidence; omitting it violates the closed schema. The promised successful upgrade test has no truthful implementation under the proposed single binding shape.

**Required correction:** Give historical pointer-seeded evidence an explicit closed provenance variant distinct from pending-terminal recovery. It may bind only evidence actually retained by the old pointer/record/result and must never authorize reconstruction of a preterminal transition. Keep exact preterminal SHA and authorized terminal delta mandatory for newly committed pending bindings. Alternatively remove automatic old-pointer upgrade through an explicit reviewed compatibility decision, preserving the approved generation-less legacy and healthy new-history outcomes. Do not invent a preterminal digest or silently make its meaning conditional without a schema discriminator.

**Required tests:** Upgrade an old terminal record whose serialization and cleanup bookkeeping differ from the historical preterminal representation; prove no preterminal proof is manufactured and the historical variant cannot enter pending-terminal recovery. Keep exact pointer/UUID/context/result checks and preserve all old bytes. Missing/mismatched pointer remains protected.

## BIND-ARCH-M3 — old-format upgrade is indistinguishable from deleted new binding

**Severity:** Medium. **Confidence:** High.

**Evidence:** Proposal lines 41 and 60 require missing bindings after generated success to fail closed and prohibit regeneration through indexing/retirement. Line 49 nevertheless allows a missing binding to be created whenever the current original and its exact context pointer match. No persisted format/eligibility discriminator distinguishes a record produced before the new contract from a newly bound record whose sidecar was deleted. The current generation-bearing primary schema is uniformly `model_catalog_transaction_journal.v1` (`ModelCatalogTransactions.swift:108–130`) and the proposal does not change or otherwise pin that classification.

**Consequence:** Complete a new valid evaluation through binding, terminal and pointer, then remove only its success-binding. The remaining original and pointer meet the stated old-format upgrade predicate exactly. Maintenance can regenerate the binding and retire it, contrary to the required missing-binding corruption behavior. The same ambiguous fallback exists for archived pointer reads. Calling the input an older record does not establish that fact from retained evidence.

**Required correction:** Define independently verifiable, persisted upgrade eligibility and strict format dispatch before implementation. New-format records must never enter the old-unbound upgrader solely because the binding is missing; deleting or corrupting their binding must protect membership and block generated adoption. If backward compatibility cannot safely distinguish the formats within the approved bounded namespace, explicitly protect ambiguous unbound generated records instead of guessing. Coordinate this discriminator with M2's truthful historical provenance variant and specify downgrade handling. No history enumeration, guessed creation epoch, generated selector or sidecar deletion may establish eligibility.

**Required tests:** Complete new work with a valid pointer, delete the binding, then run projection, maintenance and archived lookup; no binding is recreated, no active membership removed and no action becomes eligible. Exercise attempted new-to-old classification downgrade. Separately prove only truly eligible old evidence reaches the historical upgrade, without broadening generation-less legacy authority.

## Confirmed direction and implementation obligations

The direct UUID binding addresses the actual relocation gap. Current `indexCompletedEvaluation` derives a new context filename from current original fields, and `retireOne` calls it before removing membership. A changed artifact-feed digest/signer can therefore evade comparison to an old context pointer by selecting a previously absent filename. A durable independently addressed binding prevents this without a history scan, provided every mutation/index/retirement path validates it before using changed classification or context.

The new binding must be inspected before deciding that an original is merely failed/cancelled/non-generated: a stored successful binding plus a rewritten terminal state or removed generation cannot bypass checks by taking the failed/legacy retirement branch. The proposal's full immutable-field substitution test requires that outcome. Include the binding in exact receipt observations and all fresh-allocation/queued-reuse/expiry absence sets. Unknown or unsafe sidecars stay protected. No bare result, binding presence alone or newly empty context is success authority.

Binding-before-terminal ordering, exclusive publication, exact stored-event replay, nonblocking owner custody, outside-lock parsing/hashing and short metadata/fence/write bundles are compatible with lock-budget r2. Every writer must honor pending bindings before heartbeat/cancel/failure append, including the current interrupted reconciliation paths. A partial binding/terminal bundle must retain committed evidence for exact reconciliation; it cannot be rewritten into a different failed terminal. Pointer comparison retains the current owner and uses the prior target only as read-only pinned evidence. Restoration and paid authority remain separate from success-binding truth.

The explicit generation-less legacy retirement path, 1,024 unresolved cap, 2,052-plus healthy-history continuation and no-history-scan constraints remain required. The proposal truthfully discloses unsupported pre-binding development journals that cannot be safely upgraded; no capacity recovery may erase or guess evidence. The three corrections above must not silently narrow those approved supported outcomes. All new binding tests and inherited owner/storage/cleanup/projection tests remain mandatory. No physical or economic acceptance follows from this plan review.

## Verification and snapshot

Verified the proposal digest, inspected the current normal/recovery terminal changes, current pointer/commitment fields, retirement branches and record validation, and checked the existing retention test seams. No runtime suite was executed for this document-only gate. Implementation remains separately gated; final combined code/security/architecture review is still required.

Manifest SHA-256: `8f5231e4a9641f8817d54ed49d694ec4b9b59948e80777152a38a10f66e9bb01`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/immutable-retirement-binding-r1.md` | `82c047edb254d9217a4e742bf1d099f9346f30ab9f1b79ee3f8785899a0baa97` |
| `docs/product-roadmap/build-1/transaction-retention-addendum-r4.md` | `caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc` |
| `docs/product-roadmap/build-1/retention-lock-budget-r2.md` | `65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `bc237e4a398970a0883bf90784f7f3dd27a2c4e3c4443b199b5da0e4ed86b497` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `3462aa8ba30ac36c6ece8958934a81330a61b050ee022a359632a4fc7612983f` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `8e48fd37f63e7634bc3138edf7f1438e4c3c9fa72ec1389da7e45ff824e3bbdc` |
