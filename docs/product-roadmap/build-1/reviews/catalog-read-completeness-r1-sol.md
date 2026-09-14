# Build 1 catalog read completeness — independent Sol plan review r1

Date: 2026-09-10. Reviewer: independent native GPT-5.6 Sol adversarial plan lane.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, branch `codex/product-build-1`.

**Verdict: NOT APPROVED FOR IMPLEMENTATION — 0 Critical, 0 High, 3 Medium, 0 Low.**
The proposal correctly identifies the four preliminary runtime defects and gives
sound direction for complete active evidence, post-action recollection, shared
budgets and actual admission/economics sizing. The exact r1 artifact does not yet
close its own acceptance gate: one capacity rule is not a valid upper bound, one
currently suppressed recommendation-index failure is not forced by CC-01–CC-10,
and the relationship between CC-01–CC-10 and the approved lifecycle CR-01–CR-13
suite is not closed. No runtime implementation is approved by this review.

## Scope and method

Reviewed `catalog-read-completeness-addendum-r1.md`, exact SHA-256
`b7a2ce242d20e14e76443bfc90b3125169dc4a39706003159c1f2d9fd5fb8694`,
the approved lifecycle r2 contract and its review, the four preliminary CLI
findings, SPEC-001/SPEC-044, CC-01–CC-10 and the lifecycle CR-01–CR-13 evidence.
Independently traced the current read command, output encoder, signed-input
loaders, admission client, transaction receipts, reconciliation, success binding,
recommendation-pointer publication and cleanup inventory. No tests, services,
network calls or runtime edits were performed. Only this review artifact was
written.

## CR-COMP-M1 — Medium — the fixed envelope margin is not an upper bound

**Severity:** Medium. **Confidence:** High.

**Evidence.** Section 5 acknowledges that current parser rules do not impose the
same cap on all model IDs, catalog strings and historical targets
(`catalog-read-completeness-addendum-r1.md:187-200`), but then retains a fixed
2 KiB envelope margin rather than requiring the preflight to encode the actual
completed event (`:224-232`). `ModelCatalogReadEvents.Event` repeats
`target_model_id` and `model_key` outside `projection`
(`ModelCatalogRead.swift:97-120,153-158`). The projection already contains those
values in row/action fields (`ModelCatalogEconomics.swift:138-178`), so measuring
the projection and adding 2 KiB does not count the repeated escaped bytes.

The signed candidate validator checks status, numeric gates and exact 40/64-byte
revision/hash fields, but it does not bound candidate keys or `model_id`
(`AutotuneRecommend.swift:997-1032`; `AutotuneStrictJSON.swift:30-79`). The signed
loader also has no document-size cap before accepting selected bytes
(`AutotuneRecommend.swift:1664-1754`). Therefore a valid signed target/key pair
can contribute more than 2 KiB to the outer event. A projection can fit the
proposed preflight threshold and still deterministically exceed the 1 MiB final
line once the actual event wrapper is encoded. CC-07's “maximum accepted signed
shapes under current parser rules” is itself undefined for these unbounded
strings; it cannot serve as a finite maximum fixture.

**Consequence.** CR-CLI-M4 remains reproducible for a stable accepted signed
shape: the helper can perform the full artifact hash before the final emitter
discovers an overflow that was already knowable before hashing. The final output
still fails closed, so this is not a readiness or settlement-authority leak, but
it violates the required pre-hash capacity guarantee and repeats the expensive
work/latency defect that the addendum is meant to remove.

**Required correction.** Require preflight to encode the actual prospective
`model_catalog_read_event.v1` completed line, including the exact request UUID,
selected target, selected key, maximum applicable sequence/byte values, null
error, sizing projection and newline, through the production event encoder. Keep
the 2 KiB conservative margin in addition to that measured envelope if it remains
a lifecycle invariant; do not use the margin as a substitute for variable
fields. Replace “maximum accepted signed shapes” with finite boundary-constructed
accepted inputs, or define reviewed parser bounds. Extend CC-06/CC-07 with a
long/escaped signed target and key for which the projection-only measurement
fits but the full completed line crosses the boundary, and require zero measured
artifact bytes. Include below/exact/above full-line cases.

## CR-COMP-M2 — Medium — CC coverage does not force recommendation-index failures to propagate

**Severity:** Medium. **Confidence:** High.

**Evidence.** Section 3 correctly requires indexing failures to propagate as an
incomplete owned projection and names `indexCompletedEvaluation` in the transitive
budget audit (`catalog-read-completeness-addendum-r1.md:93-127`). The current
reconcile path, however, suppresses failures from `indexCompletedEvaluation`
both after recovered committed success and after terminal commit
(`ModelCatalogTransactions.swift:500-507,557-575`). The pointer helper performs
result/provenance/pointer reads and the final pointer write/validation
(`ModelCatalogTransactionRetention.swift:626-660`). Those are distinct from the
primary read/decode suppression at `prepareRecommendationIndex`
(`ModelCatalogTransactionRetention.swift:667-685`).

CC-04 requires a clock/cancellation view at bulk capture, binding recovery,
staging and precommit boundaries and says an IO/closed-decode failure must not
become an absent recommendation. It does not require injected failure at either
of the two current recommendation-index catches, the pointer-directory/write
boundary, or the post-write acknowledgement boundary. CC-05's positive committed
recommendation can use an already valid pointer. CC-02's abandoned evaluation
with retained staging normally terminalizes as failed cleanup and need not enter
successful recommendation indexing. Consequently all stated cases can pass while
one or both catches continue converting an index storage/publication failure into
a completed `measured_recommendation_required` action.

**Consequence.** CR-CLI-M3 can remain open even with nominal CC-01–CC-10 success.
A read can durably recover an evaluation success, fail to publish or validate its
recommendation pointer, suppress that error, and emit a complete-looking catalog
whose adoption action says only that no measurement is available. Expiry after
a durable pointer write but before acknowledgement is also not distinguished
from a clean absent recommendation.

**Required correction.** Extend CC-04 or add a dedicated case that injects each
current index-publication failure class: result/provenance/pointer read or closed
decode, pointer-directory metadata/create, pre-write validation, pointer write,
and expiry/failure after durable write but before the read may acknowledge it.
Exercise both reconcile call sites that currently catch
`indexCompletedEvaluation`. Require no completed projection or absent-recommendation
result. If an exact pointer write became durable, require the read to fail while
leaving that truth available to the ordinary bounded recovery path. Count the
original request, phase and incoming helper deadlines through these boundaries
and prove none was renewed.

## CR-COMP-M3 — Medium — CC-01–CC-10 are not explicitly additive to lifecycle CR-01–CR-13

**Severity:** Medium. **Confidence:** Medium-high.

**Evidence.** The approved lifecycle r2 contract makes CR-01–CR-13 required
before completion (`catalog-read-lifecycle-addendum-r2.md:496-528`). They cover,
among other things, the full compatibility matrix, real parent-death/lock
exclusion, filesystem substitution, adversarial JSONL parsing and capability
advertisement. The new proposal labels CC-01–CC-10 “Required acceptance evidence”
(`catalog-read-completeness-addendum-r1.md:256-269`) but never states that the
entire earlier CR-01–CR-13 suite remains mandatory and additive. Its opening
preserves the final combined audit, but not explicitly the full earlier test
matrix. CC-10 names parsed argv, several transaction/pending cases, relevant
suites and final audits; “relevant” does not require every previously approved
CR case or its evidence artifacts.

**Consequence.** An implementation report can plausibly treat CC-01–CC-10 as the
replacement acceptance list and omit previously mandatory lifecycle evidence
unrelated to a narrowly selected targeted suite. That weakens the approved
security/ownership/compatibility gate while correcting the four Medium findings,
contrary to the addendum's stated bounded scope.

**Required correction.** State explicitly that CC-01–CC-10 are additive to every
CR-01–CR-13 requirement in lifecycle r2 at SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`.
Require a final evidence matrix mapping both ID sets to commands, logs and
artifacts, and identify which earlier cases must be rerun because the corrected
read orchestration, event sizing, recovery witnesses and shared-budget paths
changed. Replace CC-10's “relevant” suite language with that closed mapping. This
does not require duplicating unchanged tests; it requires preserving their
mandatory acceptance status and fresh evidence where the landing diff affects
them.

## Nonblocking observations

- Sections 2 and 4 give a coherent plan-level correction for CR-CLI-M1/M2: every
  active entry must be decidable, reconciliation precedes the first complete
  inventory, and a final complete capture plus action-evidence validation follows
  the last journal-mutating lookup. CC-01–CC-03 exercise the known missing-primary,
  deterministic abandoned-evaluation and unchanged-membership mutation cases.
- The proposed compact witness must be implemented without retaining primary
  bodies. The final validation must remain bounded and avoid long bulk work under
  the global journal lock, as the proposal states. CC-07's 1,024-entry positive
  and wall-time evidence should report descriptor/high-water usage and confirm a
  concurrent transaction owner can still publish its required heartbeat; this is
  a feasibility caveat under the existing owner-fence contract, not an additional
  blocking finding in this review.
- Binding exact candidate/artifact/rate/demand selected bytes, signer, version,
  fallback/trust/freshness class before and after hashing is the correct direction
  for the economics template. Implementation should compare every authorization-
  relevant warning/trust classification, including integrity/update-required
  fallback distinctions that can share the same baked bytes.

## Gate disposition

The exact r1 plan fails the zero-Critical/High/Medium gate. Revise the proposal,
hash the new artifact and obtain a new independent plan review before runtime
corrections. The four preliminary findings remain runtime-open until an approved
plan is implemented and the additive acceptance plus final combined audits pass.

## Exact reviewed-artifact and source SHA-256 manifest

```text
b7a2ce242d20e14e76443bfc90b3125169dc4a39706003159c1f2d9fd5fb8694  docs/product-roadmap/build-1/catalog-read-completeness-addendum-r1.md
e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954  docs/product-roadmap/build-1/catalog-read-lifecycle-addendum-r2.md
fb0ffa38641044059113efffd6f546739db37436a79c0d3b54832bfa8c0edb70  docs/product-roadmap/build-1/reviews/catalog-read-cli-preliminary-r1-astra.md
a3d8ee021eaa6979d028cc13b4d9bf8c06be02368d6bafcf2a7bb2e5ab65b361  specs/SPEC-001-phase3-binary.md
5b555f34a1b29955b29b2e8491010ea2fda2759b4ebc4ede93d05152e0d135cf  specs/SPEC-044-malibu-model-catalog-economics.md
f2e39f62223ed1c35760366c8b92ebb70fecbe400162ac64dcff799a8d7dfdf5  phase3-binary/Sources/macprovider-cli/ModelCatalogReadCommand.swift
661f47f41e57c01b72c4c8d516283af3ad46466c2aa140b026cde387ab7007c6  phase3-binary/Sources/macprovider-cli/ModelCatalogRead.swift
8140d9ee9f6d76b9784a1d92da73653b8c6a5c573ad40794c99d23d10886665f  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
cfe7d52d9be3219b8f64e3da346d855d36ca6d983dfdcbafc7ced1affb2f2287  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
e79db53d8e7dd6d3bbe2bcc0554a05a33f13e5a22ad732a24b9b731a6a861f53  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
6d12d94c1d7bd514bed598670b5bd0c1e438d5496b6173f4684fde91481cb6ff  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift
b6804e760a6ad1693eff0234e4a80ac82be3d250441627532446b07b1cee5c91  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
f39668509c4df5577e9641710d63ae410b237370fc33c9e65a4f60b2567843c1  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
f4019fa681a312ea9eb8aebb4df7dabbfdeaedf94f1fa321fe7ca28473e85caa  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
03c2810bc61c833dfbf96930c255db3f6f37c41d1be3386e8000e7069af835cc  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
c2c42457baca745f21c59c73ad7e2ada70055c9a5a2b407d89ec879b0c65eba4  phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift
```
