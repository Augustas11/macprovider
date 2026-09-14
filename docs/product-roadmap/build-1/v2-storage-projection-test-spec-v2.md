# Build 1 v2 storage projection test spec v2

Base: `origin/main` at `894f21ff`.
Plan: `docs/product-roadmap/build-1/v2-storage-projection-plan-v2.md`.

## Focused Swift tests

Run:

```bash
cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'
```

Required new cases in `ModelCatalogEconomicsTests`:

1. `testV2ProjectionPublishesCleanupTargetFromValidPrivateInventory`
   - Build a valid `ModelPreparationInventoryRecord` payload with one reclaimable cleanup target.
   - Assert storage published/reclaimable/object-count fields are non-null and exact.
   - Assert `cleanup_targets` contains exactly that target with available `cleanup_published_artifact`, matching digest, and matching bytes.
   - Assert public v1 projection output remains unchanged by absence of the internal input.

2. `testV2ProjectionPublishesProtectedTargetWithoutCleanupAuthority`
   - Build one protected target with `protected_reason` and an unavailable cleanup action.
   - Assert published bytes/count include it, reclaimable bytes are zero, top-level `cleanup_targets` contains it, and row cleanup is unavailable.
   - Assert protected reason is present and no action artifact digest is exposed.

3. `testV2ProjectionPublishesMixedInventorySortedByDigest`
   - Build protected and reclaimable targets in reverse digest order.
   - Assert encoded `cleanup_targets` are sorted ascending by `artifact_identity_digest`.
   - Assert published bytes are the sum of both and reclaimable bytes include only reclaimable entries.

4. `testV2ProjectionRejectsBadCleanupBindingFailClosed`
   - Mutate action `estimated_bytes`, action `artifact_identity_digest`, `protected_reason`, or `event_model_key` after constructing otherwise valid payload bytes.
   - Assert `storage == unavailable`, empty cleanup target array, and row cleanup unavailable.

5. `testV2ProjectionKeepsRowCleanupUnavailableForAmbiguousAssociation`
   - Provide independently valid top-level target inventory and rows that cannot be associated one-to-one using existing row fields.
   - Assert top-level target list remains available, but no row receives an available cleanup action.

6. Existing public compatibility tests continue to prove public v1 shape and local status v1 capability only:
   - `ModelsSubcommandTests/testModelsCatalogEconomics`
   - `ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract`

## Broader checks

- `git diff --check`
- SPEC PR declaration validation before PR creation if the branch changes product behavior or any governance-required surface.
- Changed-file secret scan for private key / payout key / token patterns.

## Audit gate

After implementation, run independent gpt-5.6-sol code, security, and architecture review lanes over the complete branch diff. Gate: 0 Critical / 0 High / 0 Medium before PR handoff.

## Evidence boundaries

- Passing Swift tests prove internal projection and public v1 compatibility only.
- They do not prove physical Mac preparation, runtime adoption, network admission, settlement, Malibu UX, or production qualification.
- Fixture/private-payload tests are not a substitute for the later managed-root scanner and physical journey.
