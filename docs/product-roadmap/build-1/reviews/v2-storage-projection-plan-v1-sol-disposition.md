# Build 1 v2 storage projection plan v1 Sol review disposition

Reviewer: `/root/b1_v2_storage_plan_sol` using `gpt-5.6-sol`, high reasoning.
Scope reviewed: `v2-storage-projection-plan-v1.md`, `v2-storage-projection-test-spec-v1.md`, current SPEC-044 and Swift code.

## Findings and resolutions

- High: v1 excluded protected inventory from `cleanup_targets`. Resolved in plan/test v3 by requiring every verified managed-v3 target, including protected entries, in the top-level target array with protected entries carrying unavailable cleanup actions and exact `protected_reason`.
- High: v1 claimed private-store authority but only required test-constructed decoded records. Resolved in v3 by requiring an internal loader that calls `ModelPreparationPrivateStore.readRecord(kind: .publishedInventory, rootLocator:)`, decodes through `ModelPreparationContracts`, verifies the root locator, and tests missing/wrong-root/malformed-store behavior.
- High: v1 under-specified row-level cleanup matching and allowed current `model_key` association. Resolved in v3 by removing row-level cleanup publication from this slice; every row action remains unavailable until a future audited row identity contract carries the full immutable tuple or join key.
- Medium: v1 under-specified storage budget fields. Resolved in v3 by requiring explicit valid budget metadata, non-null charge/available/global fields, and exact SPEC budget equations for any available storage projection. Without valid budget metadata the projection fails closed.
- Medium: v1 did not cover all stated fail-closed criteria. Resolved in v3 test spec by adding wrong-root/store-loader, malformed payload, bad protected/action/event binding, invalid budget, integer overflow, disappeared/current-catalog ambiguity, offer-rejected, and public compatibility tests.

Plan gate status after this disposition: not yet approved. Plan/test v3 require a fresh independent review.
