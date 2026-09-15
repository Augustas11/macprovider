# Build 1 v2 storage projection test spec v1

Base: `origin/main` at `894f21ff`.

## Focused Swift tests

Run:

```bash
cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'
```

Required new cases in `ModelCatalogEconomicsTests`:

1. `testV2ProjectionPublishesCleanupTargetFromValidPrivateInventory`
   - Build a valid `ModelPreparationInventoryRecord` with one reclaimable cleanup target and a v2 candidate row whose identity matches that target.
   - Assert storage published/reclaimable/object-count fields are non-null and exact.
   - Assert `cleanup_targets` contains the target with matching action JCS.
   - Assert the matching row has available `cleanup_published` with same artifact digest and bytes.

2. `testV2ProjectionCountsProtectedInventoryWithoutCleanupAction`
   - One protected target with `protected_reason`.
   - Assert published bytes/count include it; reclaimable bytes are zero; no cleanup target and row action unavailable.

3. `testV2ProjectionRejectsBadCleanupBindingFailClosed`
   - Mutate action `estimated_bytes` or `artifact_identity_digest` after constructing otherwise valid data.
   - Assert `storage == unavailable`, empty cleanup targets, row cleanup unavailable.

4. `testV2ProjectionKeepsCleanupUnavailableForAmbiguousRows`
   - Two rows matching one cleanup target, or two reclaimable targets matching one row.
   - Assert top-level cleanup target list may remain if independently valid, but no row receives an available cleanup action.

5. Existing public compatibility tests continue to prove public v1 shape and local status v1 capability only.

## Broader checks

- `git diff --check`
- SPEC PR declaration validation before PR creation.
- Changed-file secret scan for private key / payout key / token patterns.

## Audit gate

After implementation, run independent gpt-5.6-sol code, security, and architecture review lanes over the complete branch diff. Gate: 0 Critical / 0 High / 0 Medium before PR handoff.
