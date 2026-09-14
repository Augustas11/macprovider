# Catalog read CLI — preliminary independent code/security review r1

Date: 2026-09-10. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`.

**Preliminary verdict: changes required — 0 Critical, 0 High, 4 Medium findings.**
This bounded CLI review is not the final combined code/security/architecture gate. App work remains in progress and is outside this review. No runtime files were changed, no tests executed, and no subagents delegated. The source manifest below identifies the inspected runtime snapshot independently of concurrent fixture edits. Root's running test suite is not claimed as review evidence.

Read repository AGENTS.md and CLAUDE.md, the exact approved lifecycle addendum r2 (SHA-256 `e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`), its scoped plan review, and the relevant SPEC-001/SPEC-044 amendments. Approval of that plan does not establish implementation correctness. Findings below are source-established paths; proposed regression cases have not been executed by this reviewer.

## CR-CLI-M1 — Missing active primary is treated as a complete absence

**Severity:** Medium. **Confidence:** High.

**Evidence:** `ModelCatalogTransactionRetention.swift:541–562`, especially line 548, retains `guard let bytes = primary.bytes else { continue }` inside `cleanupRecordsFromIndex`, even when `requireComplete: true`. Only thrown errors reach the new fail-closed catch. `makeCompleteModelCatalogRecoveries` at lines 733–749 requests this complete mode but cannot detect the skipped entry. Index receipt validation proves index identity; it does not prove the missing primary carried no cleanup obligation.

**Trigger/consequence:** A valid active index entry whose primary is absent (including deletion between initialization and evidence capture) disappears from the supposedly complete cleanup inventory. With no other obligations, the new owned read can emit `recoveries: []`. The absence of the primary prevents determining whether its staging needs cleanup; it is not evidence of an empty inventory. This violates the amendment's all-or-error recovery rule and can mislead catalog recovery reconciliation.

**Required correction:** In complete mode, reject missing active primary evidence, and any other undecidable active entry, with an explicit incomplete/unavailable result. Preserve established standalone behavior where required. Add a valid-index/missing-primary fixture and a boundary deletion fixture proving no complete projection, false empty recovery, or pending-clear authorization is emitted.

## CR-CLI-M2 — Action construction can create recoveries after the final inventory was collected

**Severity:** Medium. **Confidence:** High.

**Evidence:** `ModelCatalogReadCommand.swift:90–92` captures `recoveries` before `makeCompleteModelCatalogLocalActions`. The latter's adoption branch calls `indexedRecommendation` (`ModelCatalogTransactions.swift:1247–1262`). `prepareRecommendationIndex` calls `reconcile` for nonterminal target evaluations (`ModelCatalogTransactionRetention.swift:679`). For an abandoned started evaluation, `reconcile` observes staging, sets `cleanupRequired`, and commits a failed or succeeded terminal (`ModelCatalogTransactions.swift:552–574`). No recovery recollection or inventory-change validation follows before document construction at `ModelCatalogReadCommand.swift:96–101`.

**Trigger/consequence:** Begin with an abandoned nonterminal evaluation and retained staging for the verified target. The initial recovery scan excludes it because it is not terminal. Adoption lookup then makes it terminal with cleanup required. The emitted projection still carries the earlier empty recovery list, despite this same read having established a new cleanup obligation. This requires no hostile concurrent actor. It also makes preflight's recovery shape optimistic for this deterministic state transition.

**Required correction:** Ensure optional action work cannot invalidate the complete recovery evidence used for publication. For example, finish required reconciliation before the complete inventory phase, or detect such transitions and collect/revalidate complete recovery evidence again under the original budget before emission. Do not simply omit the new obligation or revert the journal transition. Add an abandoned-evaluation-with-staging fixture exercising the actual verify/action path and require the emitted recovery or an explicit incomplete result.

## CR-CLI-M3 — Recommendation reconciliation escapes the shared request budget

**Severity:** Medium. **Confidence:** High.

**Evidence:** `ModelCatalogTransactionRetention.swift:667–685` accepts the caller's `ModelTransactionWorkBudget`, but line 679 invokes `_ = try? reconcile(selector)` with neither shared read budget nor equivalent shared check. `reconcile` explicitly defaults to a fresh eight-second deadline and nil `readBudget` (`ModelCatalogTransactions.swift:481–484`), and creates fresh default evidence/index budgets on that path. The catalog adoption caller did supply a shared budget (`ModelCatalogTransactions.swift:1261–1262`); it is lost at this nested boundary. The surrounding primary-read catch at retention line 677 also suppresses storage/decoding failures whenever the budget itself has not expired.

**Consequence:** A near-expiry catalog phase can begin journal reconciliation using renewed deadlines and no request cancellation checks at its commit boundaries. The independent 50 ms lifetime monitor still bounds the owned process; this finding does not claim an indefinitely surviving app-owned child. It does mean the normative cooperative shared deadline and interruption semantics are absent inside this helper, so stale work can continue or mutate until external termination and errors can be mistaken for an unavailable recommendation in an otherwise complete projection.

**Required correction:** Propagate an equivalent original request/phase/helper minimum through the complete recommendation/reconcile chain, including recovery, evidence and commit checks. For projection use, distinguish stable absent recommendation from interrupted or unreadable evidence and propagate the latter. Add injected-expiry cases inside recommendation reconciliation, including immediately before its commit, and an IO-failure case proving no complete document or post-expiry reservation/publication.

## CR-CLI-M4 — Verification preflight is not an upper bound on the actual response

**Severity:** Medium. **Confidence:** High.

**Evidence:** `ModelCatalogReadCommand.swift:60–64` builds the preflight document with `admissionStatuses: [:]`; actual admission status is first loaded after hashing at lines 88–89. `ModelCatalogReadOutput.preflight` at lines 153–175 replaces action fields and action model IDs only. It neither includes nor bounds the final admission's `coordinator_event_id`/`state_observed_at` strings or the economic fields that become populated for coordinator-authorized rows (`ModelCatalogEconomics.swift:64–92, 648–705, 734–751`). The admission status validator (`BYOMDiscovery.swift:900–958`) imposes no corresponding string-length upper bounds. The fixed 2 KiB margin and extra unavailable-action inflation do not constitute an upper bound for these variable per-row values.

**Trigger/consequence:** A stable, accepted coordinator status with sufficiently long echoed event/time fields, or a high-row trusted economics shape near the limit, can fit the preview yet exceed the final 1 MiB line. The final emitter correctly fails closed, so this is not readiness leakage. It nevertheless performs the expensive full hash before discovering a deterministic supported response overflow, defeating the expressly required pre-hash capacity check and its retry/latency guarantee.

**Required correction:** Preflight actual current admission/runtime/economic shapes before hashing, plus a conservative complete-result template for fields that may expand, or enforce and encode real parser bounds for every omitted field. Preserve the final check for authority changes. Add near-limit real-encoder cases with accepted long/escaped admission fields and trusted economics; prove stable oversized states reject before any measured artifact bytes. Record positive accepted capacity separately, as CR-11 requires.

## Observed safeguards and remaining verification

The inspected code uses an early independent read lease monitor, exact read FD numbers, fixed lock inode/mode checks and parent-pipe termination; it retains the inherited lock without explicitly unlocking it. Quick discovery does not read weight contents and does not promote historical seals. Exact verification streams one target through descriptor-relative no-follow reads and checks file metadata, full snapshots and retained placement before publication. Discovery and action construction consume the same request-local inspection, and a final target/feed identity comparison and consumed-config revalidation precede emission. Closed verify events have bounded counts/bytes and one terminal under a serial lock. These are positive source observations, not runtime proofs or signed qualification.

No App codec/runner/pending gate acceptance is implied. Actual parsed argv composition, slow real reads, parent death, failure/reap ordering, capacity measurements, shared-budget boundary tests and the complete combined landing-diff audit remain required. No fixture or test result was inferred from the implementation or plan approval.

## Inspected source SHA-256 manifest

Captured at 2026-09-10T10:59:16.964191+00:00. Paths are relative to the worktree.

```text
661f47f41e57c01b72c4c8d516283af3ad46466c2aa140b026cde387ab7007c6  phase3-binary/Sources/macprovider-cli/ModelCatalogRead.swift
f2e39f62223ed1c35760366c8b92ebb70fecbe400162ac64dcff799a8d7dfdf5  phase3-binary/Sources/macprovider-cli/ModelCatalogReadCommand.swift
8ef08ed41a92ad4942268238a30fadfd6f272c516dac52e7985e4a4e57cbc965  phase3-binary/Sources/macprovider-cli/ModelCatalogLocalInspection.swift
f39668509c4df5577e9641710d63ae410b237370fc33c9e65a4f60b2567843c1  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
53c6dbbd661acd586b71b38909d133b4bfb5588152990a933113205b40f2f1ff  phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
cfe7d52d9be3219b8f64e3da346d855d36ca6d983dfdcbafc7ced1affb2f2287  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
8140d9ee9f6d76b9784a1d92da73653b8c6a5c573ad40794c99d23d10886665f  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
f4019fa681a312ea9eb8aebb4df7dabbfdeaedf94f1fa321fe7ca28473e85caa  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
35868f5affbe669f22e9d7bf459d51dde2bb92031f3fb2d831aee061ad106a9c  phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
03c2810bc61c833dfbf96930c255db3f6f37c41d1be3386e8000e7069af835cc  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
b6804e760a6ad1693eff0234e4a80ac82be3d250441627532446b07b1cee5c91  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
3e7ac61544517c306bb0b21fdf4ebcad53d6dc53ce5a86cb1b781c14f7a02396  phase3-binary/Sources/macprovider-cli/ModelCatalogArtifactSeal.swift
836a36c37322e3b29d27f69821491c6879431bfe1a81cbabf51bd9e2d7508ff8  phase3-binary/Sources/macprovider-cli/ModelCommandExecutionContext.swift
6ad1f28f47a044cad5e21c21f098916ee3240ba2f7b2a3249f655ca0e54fdec6  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
a3d8ee021eaa6979d028cc13b4d9bf8c06be02368d6bafcf2a7bb2e5ab65b361  specs/SPEC-001-phase3-binary.md
5b555f34a1b29955b29b2e8491010ea2fda2759b4ebc4ede93d05152e0d135cf  specs/SPEC-044-malibu-model-catalog-economics.md
e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954  docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r2.md
```
