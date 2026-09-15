# Build 1 v2 storage projection acceptance report

Slice: internal SPEC-044 v2 storage projection from private `published_inventory` records.
Branch: `codex/build1-v2-storage-projection`.
Base after rebase: `50b647960cda1cfc794f870f5685c2615b838f5c`.

## Scope completed

- Added an internal root-validated private storage snapshot loader for `ModelPreparationPrivateStore` `published_inventory` records.
- Added internal default managed-budget calculation using `min(1 TiB, floor(volume_capacity_bytes * 70 / 100))` with checked arithmetic and fail-closed handling for invalid capacity or overflow.
- Projected valid private managed-v3 inventory into `ModelCatalogEconomicsV2Wire.storage` with published bytes, reclaimable bytes, object count, budget charge, available budget, default source, and explicit overflow state.
- Projected every verified managed-v3 cleanup target into top-level `cleanup_targets`, including protected targets and catalogless targets, sorted by artifact identity digest.
- Required reclaimable targets to carry a valid cleanup action binding; required protected targets to carry unavailable cleanup action fields and a non-null protected reason.
- Preserved public v1 `models catalog-economics --json` and provider status behavior. Row-level cleanup actions remain unavailable because current row identity lacks the full immutable target tuple required for safe binding.

## Plan and review gate

- Approved plan: `docs/product-roadmap/build-1/v2-storage-projection-plan-v5.md`
- Approved test spec: `docs/product-roadmap/build-1/v2-storage-projection-test-spec-v5.md`
- Independent verifier: `/root/b1_v2_storage_plan_sol_r4`, `gpt-5.6-sol`, high reasoning
- Result: zero Critical, High, or Medium plan findings before implementation.
- Rebase reconciliation: `docs/product-roadmap/build-1/reviews/v2-storage-projection-rebase-1509-reconciliation.md`

## Fresh local verification

Post-rebase local commands:

- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests/testV2ProjectionPublishesCleanupTargetFromRootValidatedPrivateStore|ModelCatalogEconomicsTests/testV2ProjectionPublishesProtectedTargetWithoutCleanupAuthority|ModelCatalogEconomicsTests/testV2ProjectionPublishesMixedInventorySortedByDigestAndDefaultBudget|ModelCatalogEconomicsTests/testV2ProjectionRejectsWrongRootAndMalformedStoreInventory|ModelCatalogEconomicsTests/testV2ProjectionRejectsBadCleanupBindingFailClosed|ModelCatalogEconomicsTests/testV2ProjectionRejectsInvalidVolumeCapacityAndReportsExplicitOverflow|ModelCatalogEconomicsTests/testV2ProjectionNeverAttachesRowCleanupByCurrentCatalogFields'` — passed, 7 tests, 0 failures.
- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'` — passed, 26 tests, 0 failures.
- `git diff --check` — passed.
- Changed/untracked-file secret scan for private-key/env-assignment/high-entropy credential patterns — passed across 18 files.

Implementation audit lanes are required before PR handoff: code, security, and architecture, each with zero Critical, High, or Medium findings.

## Qualification limits

This slice is not Product Build 1 acceptance. It does not implement public v2 CLI/status, artifact-feed consumption, artifact preparation/adoption/cancellation, cleanup execution, network admission, authoritative pricing/settlement, Malibu UI, production activation, or a physical Mac preparation -> admission -> settled-request journey.

Physical Mac Build 1 acceptance remains blocked on later slices that connect live scanner/runtime state, public provider UX, admission/probe semantics, and settlement verification.
