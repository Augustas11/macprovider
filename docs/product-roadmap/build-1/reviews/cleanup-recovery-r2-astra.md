# Cleanup recovery addendum r2 — independent Astra architecture gate

Verdict: APPROVED for the focused cleanup design. 0 Critical, 0 High, 0 Medium, 0 Low.

Exact reviewed artifact: `docs/product-roadmap/build-1/cleanup-recovery-addendum-r2.md`.
SHA-256: `beac13d8f14cff9d71ce8a6de3c8e8c7fec4c300838fb8c14a3faaedebd9dab5`.
Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
No source edits or subagents. Read-only plan/source/test inspection; no new test execution claimed.

## R1 Medium closure

CLEANUP-M1 is closed at the design level. The top-level protocol-2-only `recoveries` array avoids manufacturing a model row or admission source. Its three closed fields carry a canonical cleanup target, a historical transcript key, and an exact cleanup Action. The plan preserves protocol 1 by omitting/rejecting the new key there, while new consumers accept absent recoveries for older protocol-2 peers.

Oldest-createdAt/UUID selection provides deterministic one-per-target recovery, and prefixed UUID UI identity avoids collision with ordinary rows. Multiple valid leftover transactions are sequentially exposed instead of silently dropped. Existing catalog/discovery rows retain their identity, current classification, readiness and economics. Historical keys have no joining or aliasing role. Moving cleanup off ordinary rows directly removes the existing category-priority failure.

## Source-grounded implementation obligations

These are checks required by the approved design, not newly inferred authority or additional findings:

- `MalibuModelCatalogEconomicsDocument` currently rejects unknown top-level keys before source validation. Add the explicit protocol-aware recovery decode/validation, rather than globally relaxing unknown-key handling. A present null/non-array, duplicate target/UUID, foreign action kind, unknown field, or invalid selector must yield no executable recovery. Protocol 1 must reject even an empty recoveries key.
- The current app derives list readiness solely from model rows and `performCatalogAction` requires row membership. Recovery dispatch must have its dedicated entry membership/freshness/confirmation predicate and work when rows are empty or view-only. It must not inherit rate, fit, supported-model, admission, or row.id gates. It still requires compatible authenticated CLI custody and no pending mutation.
- Current `MalibuModelRow` prioritizes cleanup over `.current`; remove available cleanup from ordinary protocol-2 rows as specified. The separate recovery section must preserve ordinary row mapping byte-for-byte/semantically, including current target and old-key/new-target collision cases.
- Current reconciliation accepts cleanup success after a newer projection without requiring weights. Adapt it to require the matching cleanup operation terminal and a newer validated recovery projection. Record disappearance alone, a corrupt projection, or a late result from another operation is not success. Failed cleanup remains recoverable; successful cleanup reveals the next eligible leftover for the same target.
- Existing app cleanup tests inject cleanup into a normal row. Replace/extend these with separate-array producer/consumer tests and a fixture reaching the actual CLI owner, including feed failure, no model rows, multiple leftovers, restart/cancellation and preserved incumbent/published bytes. Existing tests are not proof of this new protocol yet.
- Secure enumeration and execution must retain exact filename/record/event/target identity, bounded private no-follow reads, owner exclusion, deterministic selection, and preservation of unsafe/corrupt records. Enumeration does not repair or delete record bytes or artifacts. The typed cleanup command remains the only mutation.

## Explicit unresolved dependency

The addendum intentionally depends on the separately reviewed transaction-control Action operation selector/generation contract. `transaction-control-addendum-r2.md` was not yet present at this review, and no exact selector fields or cleanup-attempt generation semantics are assumed approved here. This focused approval establishes the recovery-array/identity/ownership design only.

Combined cleanup/control implementation must remain gated until that exact transaction-control revision passes independently. Afterward verify that its Action encoding, immutable operation generation, cleanup retry attempts, transcript binding, persisted app recovery and typed status/cancel/result calls compose with this array. If the separately approved Action changes require changes to this addendum's closed shape or semantics, freeze and review the resulting delta before implementing it. This is an acknowledged sequenced prerequisite, not a waiver or an implicit approval of unfinished schema.

## Acceptance boundary

The design resolves the CODE-M1 recovery visibility defect without introducing artifact, network, price, admission, or current-model authority. Implementation and fresh tests remain outstanding, along with the final full-diff gate. This review does not close CODE-M2, physical B1-T10/B1-T11 evidence, release qualification, or other architecture findings.
