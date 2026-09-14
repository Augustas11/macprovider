# Build 1 v2 storage projection test spec v5

Base: `origin/main` at `894f21ff`.
Plan: `docs/product-roadmap/build-1/v2-storage-projection-plan-v5.md`.

## Focused Swift tests

Run:

```bash
cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'
```

Required new cases in `ModelCatalogEconomicsTests`:

1. `testV2ProjectionPublishesCleanupTargetFromRootValidatedPrivateStore`
   - Bootstrap a `ModelPreparationPrivateStore`, write a valid `published_inventory` record with one reclaimable cleanup target, load it through the internal store loader using the matching `rootLocator`, and provide a bound `volumeCapacityBytes`.
   - Assert storage published/reclaimable/object-count, budget charge, available budget, computed default global budget, `managed_budget_source == default`, overflow flag, and legacy-accounting fields are non-null/exact.
   - Assert `cleanup_targets` contains exactly that target with available `cleanup_published_artifact`, matching digest, and matching bytes.
   - Assert row cleanup remains unavailable.

2. `testV2ProjectionPublishesProtectedTargetWithoutCleanupAuthority`
   - Use the store loader with one protected target, `protected_reason`, unavailable cleanup action, and valid volume capacity.
   - Assert published bytes/count include it, reclaimable bytes are zero, top-level `cleanup_targets` contains it, row cleanup is unavailable, protected reason is present, and no action artifact digest/bytes are exposed.

3. `testV2ProjectionPublishesMixedInventorySortedByDigestAndDefaultBudget`
   - Use protected and reclaimable targets in reverse digest order.
   - Assert encoded `cleanup_targets` are sorted ascending by `artifact_identity_digest`.
   - Assert published bytes are the sum of all targets, reclaimable bytes include only reclaimable entries, budget charge equals published bytes, computed default budget is `min(1TiB, floor(volumeCapacityBytes * 70 / 100))`, and available budget is clamped to zero when charge exceeds global budget.

4. `testV2ProjectionRejectsWrongRootAndMalformedStoreInventory`
   - Read with a drifted/wrong `ModelPreparationRootLocator` and assert unavailable storage plus empty targets.
   - Write malformed `published_inventory` payload bytes through the store where possible or inject malformed payload at the decode boundary, then assert unavailable storage plus empty targets.
   - Assert no raw path-like value appears in encoded projection warnings or fields introduced by this slice.

5. `testV2ProjectionRejectsBadCleanupBindingFailClosed`
   - Mutate reclaimable action `estimated_bytes`, action `artifact_identity_digest`, protected cleanup availability, `protected_reason`, or `event_model_key` after constructing otherwise valid payload bytes.
   - Assert `storage == unavailable`, empty cleanup target array, and row cleanup unavailable.

6. `testV2ProjectionRejectsInvalidVolumeCapacityAndIntegerOverflow`
   - Use valid store inventory with invalid volume capacity, over JavaScript-safe estimated bytes, or aggregate overflow that is not an explicit managed-v3 directory overflow signal.
   - Assert unavailable storage, `managed_v3_overflow_detected == false`, empty target array, null managed totals/charge/available budget, and row cleanup unavailable.

7. `testV2ProjectionReportsExplicitManagedInventoryOverflow`
   - Provide the explicit overflow signal corresponding to observing a 257th managed-v3 entry.
   - Assert unavailable storage, `managed_v3_overflow_detected == true`, all managed-v3 totals/charge/available budget null, empty target array, and row cleanup unavailable.
   - Assert the projection does not publish a truncated target list.

8. `testV2ProjectionNeverAttachesRowCleanupByCurrentCatalogFields`
   - Provide independently valid top-level target inventory with same `model_key` but different artifact/release/receipt, disappeared catalog row, duplicate current rows, and an `offer_rejected` row.
   - Assert top-level target list remains available when inventory/default budget are valid, but every row keeps cleanup unavailable.

9. Existing public compatibility tests continue to prove public v1 shape and local status v1 capability only:
   - `ModelsSubcommandTests/testModelsCatalogEconomics`
   - `ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract`

## Broader checks

- `git diff --check`
- SPEC PR declaration validation before PR creation if the branch changes product behavior or any governance-required surface.
- Changed-file secret scan for private key / payout key / token patterns.

## Audit gate

After implementation, run independent gpt-5.6-sol code, security, and architecture review lanes over the complete branch diff. Gate: 0 Critical / 0 High / 0 Medium before PR handoff.

## Evidence boundaries

- Passing Swift tests prove internal projection, private-store/root validation at the loader boundary, default-budget computation, and public v1 compatibility only.
- They do not prove physical Mac preparation, runtime adoption, network admission, settlement, Malibu UX, configured budget layering, stale receipt detection, or production qualification.
- Fixture/private-store tests are not a substitute for the later managed-root scanner and physical journey.
