# Build 1 catalog read lifecycle — independent Astra plan review r2

Date: 2026-09-10. Reviewer: independent native GPT-6 Astra high security lane.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, branch `codex/product-build-1`.

**Verdict: APPROVED at the scoped security PLAN gate — 0 Critical, 0 High, 0 Medium, 0 Low open findings.**
This is approval of the exact proposed contract, not implementation acceptance. B1-SEC-M1/M2 remain runtime findings until the code and required evidence resolve them. Final whole combined code/security/architecture audits and signed hardware qualification remain required.

## Artifact, scope and method

Reviewed `catalog-read-lifecycle-addendum-r2.md`, exact SHA-256 `e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`. Reviewed the complete r1 contract plus every r2 change, all CR-01–CR-13 requirements, approved plan-r4/test-spec-r4/control-r4/snapshot-r2 contracts, and the relevant existing SPEC-044 capability/UX/recovery requirements. Rechecked actual app capability and refresh routing, production argv, pending control/reconciliation flow, manifest pin comparison, CLI status advertisement and shared-budget call sites. No runtime edits, tests, services or hardware operations were performed. Only this report was written for this task.

## CR-PLAN-M1 — resolved in the plan

**Previous severity/evidence.** Medium. The actual app enters catalog refresh based on the older catalog-economics capability independently of local activation (`ModelManagement.swift:1839–1851,1956,2342–2347`). An old peer cannot implement the new inherited lifetime monitor merely because it supports protocol 1. R1 specified the guarded negotiated path but left the unsupported actual app branch undecided.

**R2 correction.** Section 2a introduces an explicitly advertised `model_catalog_read_lifecycle_v1` capability, requires fresh managed-peer identity plus all relevant manifest tiers at actual dispatch, and does not infer support from the version number. Its matrix covers catalog-only old peers, the same version with/without the capability, partial capability combinations, below-floor versions and stale/absent evidence. Every unsupported app branch is no-helper: no catalog/list/browse/verify/result subprocess and no generic-run fallback. Standalone protocol-1 parsing and operator overrides remain separate.

**Consequence and product tradeoff.** Older pairings lose the app's catalog subprocess feature until compatible software is available. They retain observed current-model/status information and explicit update/repair or stale-status guidance. The amendment does not falsely promise an already released upgrade, call an unavailable cleanup inventory empty, retain actionable cached rows, clear pending custody or rerun a mutation owner. This is a stated compatibility decision preserving the finite read-lifetime requirement, rather than an implicit removal of that requirement. The actual capability manifest implementation already supports explicit advertised-schema/capability conjunction and normalized version floors (`ModelManagement.swift:74–88`); CLI status advertisement has an existing implementation site (`HTTPServer.swift:239–244`). No invented release version is needed.

**Required implementation/validation.** Implement the matrix at real dispatch and amend SPEC-044 consistently, particularly R008's old fallback/failed-projection UX. CR-01/02/06/13 require actual caller spawn/no-spawn, real status advertisement, parser composition and unsupported restart evidence. Those tests must execute the production routes, including result restoration and pending reconciliation, rather than only invoking a capability helper. No extra corrective amendment is required for this finding.

**Disposition/confidence.** Resolved at the plan level; high confidence. Runtime closure is pending implementation and verification.

## Pending controls and truthful recovery

Section 2a explicitly keeps exact pending metadata and the control-r4 authorization rules. Existing `refresh` handles pending before ordinary catalog refresh (`ModelManagement.swift:1913`); `runPendingControl` invokes the separate typed API with `peer: nil` (lines 2196–2208). Therefore the new catalog negotiation must not become an unconditional guard on that control path. Terminal status can be observed while successful completion remains pending for a compatible fresh projection. No new capability can repair a changed config/code pin or authorize a replacement owner.

**INFO — manifest changes also affect old pins.** The source stores the entire checked-in manifest's `controlDigest` in the pin (`ModelTransactionControl.swift:371`) and compares it at control dispatch (line 416); `ModelManagement.swift:65–71` includes all tiers in that digest. Adding the lifecycle tier can therefore block a pre-amendment pin even without changing CLI bytes. R2's requirement that every original pin/control check still pass, and its explicit lack of a transparent upgrade-recovery promise, permit this conservative result. Do not silently recompute the saved digest or claim every old pending operation retains usable controls.

Apply CR-02's pending-state matrix to both cases: a current-manifest valid pinned transaction with unsupported fresh catalog evidence must retain its independently authorized status/cancel path; an old-manifest or otherwise mismatched pin must retain custody, explain blocked recovery and spawn no unauthorized control. The new read gate must never clear either record. This is an implementation/test caveat under existing authorization, not a new Medium finding or permission to change pin semantics.

## R1 capacity and budget observations — addressed

**Final-line capacity.** Section 6a and CR-11 now require real encoding of current and maximum accepted catalog/history shapes, actual row/recovery/byte counts, a high-count positive complete projection, boundary/escaping tests, preflight before hashing, and final output-size validation. The preflight must account for the full prospective target/action/envelope encoding without creating reservations for sizing. A changed final authority/recovery shape still receives the final check. Oversize is explicitly unavailable, preserves pending custody and cannot cause automatic repeat hashing or silent truncation. Standalone diagnostics are identified as an operator surface, not an app lifecycle bypass. These are measurable acceptance requirements; no unsupported assertion that 1,024 active entries imply 1,024 rows or fit under 1 MiB is made.

**Shared work budgets.** Existing per-candidate `reserveOperation` creates a fresh default budget, and the default is eight seconds. R2 explicitly passes the request/phase/helper minimum through input fetches, discovery, context/snapshot checks, reservations, recommendation lookup and recovery, while preserving standalone defaults and retention policy. Complete cleanup evidence precedes optional action reservations. Interrupted IO/budget work propagates incomplete/error instead of `try?` becoming an empty recovery array or a complete-looking partial document. CR-12 checks deadline propagation and expiry at each boundary, plus a positive complete high-count fixture. Prior atomically published reservations remain journal-owned; the app cannot authorize them from an incomplete read.

Neither observation was a demonstrated capacity/latency defect in the r1 plan review. R2 makes their feasibility and honest-failure acceptance criteria explicit. Implementation must report actual positive capacity/time evidence; overflow-only and injected-clock-only tests do not qualify normal recovery throughput. If those measurements fail a required supported journey, reopen the design rather than declaring the journey complete because failure was bounded.

## Full-contract security assessment

- **Binding:** The app's actual spawn argv is passed unchanged through the parsed CLI fixture, with genuine descriptors. Fixed config is the authority; forbidden overrides remain rejected before setup/hash/reservation. Fresh result mode retains exact selector, kind, generation and consumed-context checks; pinned offline result keeps control-r4 semantics.
- **Current integrity:** Quick reads zero weight bytes and never asserts verified readiness. One exact-target full inspection is shared by discovery and action construction. Descriptor-relative no-follow reads, metadata/placement checks, final signed-authority refresh and final context validation address current source identity and TOCTOU. Saved seals and current-serving labels are not local byte proof. Finalization must implement the explicit changed-config rejection rather than assume the current prepared-context helper alone proves it.
- **Bounded ownership:** Reservation before preflight, nonce revocation, separate read lease, early child lifetime monitor, strict stream limits, exact child TERM/KILL and reap-before-replacement cover the proposed supported process path. Parent death and slow reads receive actual process tests. Transaction controls remain independent; no saved PID or process group is signaled. Heartbeats cannot replace actual measured-byte progress.
- **Network/finalization:** One request deadline includes remote input loading and the final authority/admission/runtime/hardware refresh, not only hashing. Initial/final phase deadlines cannot restart the total budget. Authority expiry or bounded failure remains incomplete and cannot publish ready actions. CR tests and final audits must validate the actual production await paths.
- **UI/recovery:** A terminal mutation alone cannot clear pending. A final verified completion projection is the fresh evidence and is not immediately replaced by another hash/quick read. Cancelled/cleanup recovery uses complete quick projection when byte readiness is unnecessary. A stopped or limited read retains pending and offers read retry after child exit; it never reruns the owner or merges stale verified/recovery bits into a newer document.

No additional C/H/M issue was identified in this complete proposed contract. That conclusion depends on implementing its stated outcomes, not merely adding the new option names, timer or capability advertisement.

## Exact artifact and observed-source SHA-256 manifest

Direct file hashes at report generation identify the evidence snapshot. Neighboring files were inspected for the described call sites; this manifest does not substitute for a complete combined runtime audit.

```text
e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954  docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r2.md
9d98dbf4ea3acd639005ec04f1275e68197ce5158dd9e9b8a2f40eb5b58cb16d  docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r1.md
88d0c5bda446d8919cfff5bbe9429a7ed67f34d29ac02ce4f826c3cb6688bea4  docs/product-roadmap/build-1/reviews/catalog-read-lifecycle-r1-astra.md
a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d  docs/product-roadmap/build-1/plan-r4.md
20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be  docs/product-roadmap/build-1/test-spec-r4.md
3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3  docs/product-roadmap/build-1/transaction-control-addendum-r4.md
4f00c0e3f4c91d6dffcb234f1bd7aa3ef122e19d1cdb7e13707c6c10cd76b015  docs/product-roadmap/build-1/snapshot-resources-r2.md
12505b4c3acfc38ac14b393e97a8cc26e642da7d2e77114d6e9b78ae24b5a9d5  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
5a98a8d2e963a97789514adef788298b5fc966e7e6aef6605819bbbddc359398  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
921bd69a4da1b8b72e51da9de0a9953d742f7f4c5367ebaf649ccbe0b3205d04  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
01d1a5a54ca96a6cbae7fddb8e7a22bb46dd00db396acf7411feef90e309230f  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
04bc959b8317fb94688b02e325817c143c47f1ae1b73f5767ebb25d40745e93e  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
e7f5b9da2ec4be6ab9baa7713318fc34a0524c8796de42c116f4901e53a7f3a6  phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
f9605c97d5728634492c7aaaebfeac52bc184ae00546640e79072464bdf4d994  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
91fd91b8d769a5bd50a7ac3caa80eb30b63f8fbd0fb12081cbdc074bf7684df9  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
dc5a867aaab1fc85b1e4822a9c3c9ffed16b3a701f94e4add79466d78f548377  phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
397817cebf43cd56b6c6e007d679e8ea22b9de3bc4b61a840b6845040aff06b7  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
6b2c9896af35bb0a764643790bbd85e0a5432d51f5f9a490524959ff62357793  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
63b48848570125b1d329d8810fd85d0e38919ba2b71d84d3e9fa08a72287d1de  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
d9b3542a3226ad50280af4c1f7bb956847a7c471a9806471901834bbfa1ea5e8  specs/SPEC-044-malibu-model-catalog-economics.md
```
