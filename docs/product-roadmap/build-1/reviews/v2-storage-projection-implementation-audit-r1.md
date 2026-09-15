# Build 1 v2 storage projection implementation audit round 1

Branch: `codex/build1-v2-storage-projection`.
Initial audited head: `587d73e9`.
Auditors: native Codex subagents using `gpt-5.6-sol`, high reasoning.

## Results

- Security/trust-boundary lane `/root/b1_v2_storage_security_audit_sol`: PASS, zero Critical, High, Medium, Low, or Info findings.
- Architecture/product-contract lane `/root/b1_v2_storage_arch_audit_sol`: PASS for gate, zero Critical/High/Medium findings. One Low finding on overflow-prone default-budget arithmetic for extremely large volume capacities.
- Code-correctness lane `/root/b1_v2_storage_code_audit_sol`: REQUEST CHANGES, one Medium finding.

## Medium finding and resolution

Finding: `PrivateStorageBudget` and `PrivateStorageSnapshot` exposed synthesized same-module memberwise initializers. A future same-target caller could construct a snapshot without the private-store loader and emit arbitrary budget source strings such as `configured`.

Resolution:
- Added explicit non-public initializers so memberwise construction is suppressed.
- Fixed `managedBudgetSource` to the constant `default` instead of storing caller-provided text.
- Kept snapshot construction confined to this builder source file while preserving the existing decode-boundary test seam.

## Low architecture finding and resolution

Finding: default-budget calculation multiplied `volumeCapacityBytes * 70` before division, so an enormous capacity could overflow and fail closed instead of producing the capped 1 TiB default budget.

Resolution:
- Replaced multiplication-before-division with a quotient/remainder calculation that computes `floor(volume_capacity_bytes * 70 / 100)` without overflowing for valid `Int64` capacities.
- Added coverage for `Int64.max` volume capacity, asserting the emitted global budget is capped to `ModelPreparationContracts.maxEstimatedBytes` and `managed_budget_source` remains `default`.

## Post-fix validation

- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests/testV2ProjectionRejectsInvalidVolumeCapacityAndReportsExplicitOverflow'` — passed, 1 test, 0 failures.
- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'` — passed, 26 tests, 0 failures.

Round 2 required: rerun code/security/architecture audit over the amended final diff. Gate remains open until all lanes report zero Critical/High/Medium findings.

## Round 2 Medium follow-up resolution

Round 2 code audit accepted the memberwise-construction fix but found one remaining Medium: `loadPrivateStorageSnapshotPayload` was still an internal raw-payload API that same-module callers could use without `ModelPreparationPrivateStore.readRecord`.

Resolution:
- Made `loadPrivateStorageSnapshotPayload` private to `ModelCatalogEconomicsBuilder`.
- Reworked malformed inventory and bad cleanup-binding tests to write hostile durable envelopes under the private store and call the store-backed `loadPrivateStorageSnapshot(store:rootLocator:volumeCapacityBytes:)` path. The hostile envelopes carry matching payload SHA values, so failures occur through the same durable-envelope/private-store validation boundary used by production reads.

Post-fix validation:
- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests/testV2ProjectionRejectsWrongRootAndMalformedStoreInventory|ModelCatalogEconomicsTests/testV2ProjectionRejectsBadCleanupBindingFailClosed'` — passed, 2 tests, 0 failures.
- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'` — passed, 26 tests, 0 failures.
