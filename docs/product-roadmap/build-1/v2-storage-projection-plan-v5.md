# Build 1 next slice: v2 storage projection from private store inventory

Plan revision: v5.
Base revision: `origin/main` at `894f21ff` (`Productize headless Mini installs with system-domain uninstall (#1494)`).
Supersedes: `v2-storage-projection-plan-v1.md`, `v2-storage-projection-plan-v2.md`, `v2-storage-projection-plan-v3.md`, and `v2-storage-projection-plan-v4.md`.

## Goal

Advance Product Build 1 without enabling public v2 actions: internally project SPEC-044 v0.2.10 managed-v3 storage and cleanup target state from a root-validated private `published_inventory` record read through `ModelPreparationPrivateStore` into `ModelCatalogEconomicsV2Wire`. Public `models catalog-economics --json` and local status remain v1-only. No preparation transaction, adoption, transfer, publication, network admission, settled request, Malibu UI, production activation, or physical acceptance is claimed by this slice.

## Current landed baseline

- `ModelPreparationContracts.swift` defines v22/v0.2.10 private records, including `ModelPreparationInventoryRecord`, `ModelPreparationCleanupTarget`, `ModelPreparationAction`, `ModelPreparationPrivateStateEnvelopeKind.publishedInventory`, `ModelPreparationContracts.validateCleanupBinding`, and artifact identity digest derivation.
- `ModelPreparationPrivateStore.swift` can read `published_inventory` only after root identity validation via `readRecord(kind:rootLocator:)`; wrong root locators and hostile records already fail in store tests.
- `ModelCatalogEconomics.swift` has encode-only `ModelCatalogEconomicsV2Wire`; today it always sets `storage = .unavailable`, `cleanupTargets = []`, and per-row `cleanupPublished` to unavailable.
- `ModelsCatalogEconomicsCommand` emits public v1 only. That remains unchanged.

## Ownership boundaries

- Swift CLI only:
  - `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`
  - `phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift`
  - build-1 docs/review records for this slice
- No coordinator/gateway/Malibu app changes.
- No signed feed, downloader, runtime preparation, config mutation, control-socket mutation, admission-state mutation, or durable private-store write path.
- No cleanup execution, no configured-budget parser, and no row-level cleanup action publication in this slice.

## Dependency graph

1. Existing private store root validation and private inventory decoding.
2. Internal default-budget snapshot computed from a bound volume capacity.
3. Internal v2 economics projection builder.
4. Tests that encode the internal v2 wire and assert storage/target/action semantics.
5. Public v1 compatibility tests.

This slice depends only on landed private-record/store types and does not depend on BYOM runtime transfer/adoption work. Later slices may connect the same internal input to the live scanner, configured budget layering, stale receipt detection, and Malibu/client v2 path after their own gates.

## Normative contracts

- SPEC-044-R002 v2 projection shape: v2 storage, cleanup targets, cleanup action binding, and artifact identity digest fields must be exact and fail closed.
- SPEC-044 top-level cleanup target rule: `cleanup_targets` contains every verified managed-v3 object in the usable inventory exactly once, including protected objects and objects without a current catalog row, sorted by ascending `artifact_identity_digest`.
- SPEC-044 protected/reclaimable rule: a `reclaimable` target carries one available `cleanup_published_artifact` action with matching digest and bytes; a `protected` target carries an unavailable cleanup action and exact non-null `protected_reason`.
- SPEC-044 storage rule: a valid storage object requires valid managed inventory, non-overflow object count, valid legacy-accounting state, valid default budget source, non-null managed-v3 totals, non-null `managed_budget_charge_bytes`, and non-null `available_managed_budget_bytes` satisfying the budget equations. Missing/malformed/wrong-root input yields unavailable storage with `managed_v3_overflow_detected == false`, empty target array, and unavailable row cleanup. Actual overfull managed-v3 inventory yields unavailable managed totals, empty target array, unavailable row cleanup, and `managed_v3_overflow_detected == true`; the projection must not truncate or claim the observed overflow entry is final.
- SPEC-044 default budget rule: in this slice `managed_budget_source` is always `default`, and `global_managed_budget_bytes` must be exactly `min(1099511627776, floor(volume_capacity_bytes * 70 / 100))` using checked unsigned arithmetic. Configured env/YAML budget selection is a future slice; this slice must not emit `configured`.
- SPEC-044 row action rule: if a row-level cleanup action is retained, it must be JCS-identical to the matching top-level target action. This slice does not retain row-level cleanup actions because the current row contract lacks `model_revision`, `artifact_id`, `release_id`, `root_identity_digest`, `receipt_sha256`, and `event_model_key`.
- SPEC-044 secret boundary: projection never exposes raw private paths, root nonce, device/inode, usernames, hardware IDs, feed bodies, credentials, provider identity, or operator secrets. Only `root_identity_digest` may be projected.
- SPEC-044-R007 preparation safety remains unsatisfied by this slice; prepare/adopt/run transactions stay unavailable.

## Implementation steps

1. Add internal projection input types, for example:
   - `ModelCatalogEconomicsBuilder.PrivateStorageSnapshot`, containing decoded `ModelPreparationInventoryRecord`, a valid computed default budget, and overflow status.
   - `ModelCatalogEconomicsBuilder.PrivateStorageBudget.default(volumeCapacityBytes:)`, which computes `globalManagedBudgetBytes = min(1099511627776, floor(volumeCapacityBytes * 70 / 100))`, rejects zero/negative/effectively unavailable capacity, rejects arithmetic overflow, and sets `managedBudgetSource = "default"`. No `configured` constructor is added in this slice.
2. Add an internal loader, for example `loadPrivateStorageSnapshot(store:rootLocator:volumeCapacityBytes:overflowDetected:)`, that calls `ModelPreparationPrivateStore.readRecord(kind: .publishedInventory, rootLocator:)`, decodes the payload with `ModelPreparationContracts.decode(ModelPreparationInventoryRecord.self, maxBytes: inventoryMaxBytes)`, verifies `record.root == rootLocator`, computes the default budget from the supplied bound volume capacity, and maps nil/missing, store errors, decode errors, wrong-root errors, and invalid volume capacity to an unavailable projection with `managed_v3_overflow_detected == false`; maps explicit overflow to an unavailable projection with `managed_v3_overflow_detected == true`; and never leaks raw paths.
3. Keep valid storage unavailable unless the store inventory and default budget are both valid. Budget rules in this slice:
   - all emitted integers are JavaScript-safe nonnegative integers;
   - `global_managed_budget_bytes` is the computed default budget;
   - `managed_budget_source == default`;
   - configured legacy remains `not_configured` with both legacy byte fields `0`;
   - `managed_budget_charge_bytes = managed_v3_published_bytes`;
   - `available_managed_budget_bytes = max(0, global_managed_budget_bytes - managed_budget_charge_bytes)`.
4. Convert every accepted `ModelPreparationInventoryRecord.targets` entry into a top-level `ModelCatalogEconomicsV2Wire.CleanupTarget`, sorted by ascending `artifact_identity_digest`. Do not drop protected entries.
5. Validate each target according to its status before encoding:
   - for every target, rely on successful `ModelPreparationCleanupTarget` decode and recheck lowercase digest fields, JavaScript-safe bytes, nonempty `event_model_key`, and protected-reason nullability;
   - for reclaimable targets, require `ModelPreparationContracts.validateCleanupBinding(rowAction: target.cleanup, target: target)` plus available `cleanup_published_artifact`, matching digest, and matching bytes;
   - for protected targets, do not call `validateCleanupBinding` because the cleanup action is required to have null digest/bytes; instead require `cleanup.available == false`, null transaction/action fields, null artifact digest/bytes, and non-null `protected_reason`.
6. Keep every row-level `cleanup_published` unavailable with the current `cleanup_unavailable_without_private_store` reason, even when top-level targets are available. This avoids unsafe row association until the row contract carries the full immutable target tuple or an audited join key.
7. Preserve public v1 behavior exactly: `models catalog-economics --json` output and local-status capability advertisement remain unchanged.

## User journeys

- Internal Malibu/client v2 preflight can render truthful managed-v3 storage totals and top-level target records from a verified private inventory without gaining public cleanup authority.
- Internal diagnostic JSON can list protected and reclaimable managed-v3 objects without revealing paths or root identity secrets.
- A current-catalogless reclaimable object remains represented in the top-level target list for a later confirmed cleanup flow.
- A provider using today's public CLI sees no changed command shape or promised readiness.

## Acceptance criteria

- A valid root-validated store inventory with one reclaimable target and valid bound volume capacity produces available storage counts/bytes/budget fields and one top-level cleanup target with available cleanup action.
- A valid protected target produces available storage counts/bytes/budget fields, a top-level cleanup target with unavailable cleanup action and exact `protected_reason`, zero reclaimable bytes, and row cleanup unavailable.
- A mixed protected/reclaimable inventory produces published bytes equal to all targets, reclaimable bytes equal to only reclaimable targets, object count equal to all targets, budget charge equal to published bytes, available budget equal to `max(0, min(1TiB, floor(volume_capacity_bytes * 70 / 100)) - charge)`, and top-level targets sorted by digest.
- Missing inventory, unreadable store, wrong root, malformed payload, bad digest, bad protected reason, bad event key, mismatched reclaimable action digest/bytes, unavailable reclaimable action, available protected action, invalid volume capacity, or integer overflow yields fail-closed unavailable storage with `managed_v3_overflow_detected == false`, empty cleanup target array, and unavailable row cleanup. An explicit overflow marker yields fail-closed unavailable storage with `managed_v3_overflow_detected == true`, all managed-v3 totals/charge/available budget null, empty cleanup target array, and unavailable row cleanup.
- Catalog-only rows and `offer_rejected` rows remain non-actionable and cannot gain cleanup/preparation authority, even with valid top-level cleanup targets.
- Public v1 CLI/status tests remain green and v2 remains internal test-only.

## Negative tests

- Missing inventory through the store loader: unavailable storage and empty targets.
- Wrong root locator through the store loader: unavailable storage and empty targets, with no path in the projection.
- Malformed private payload: unavailable storage and empty targets.
- Corrupt/mismatched reclaimable action binding: unavailable storage, empty target array, row cleanup unavailable.
- Protected target: appears in top-level target list with unavailable action and protected reason; no row action.
- Mixed targets: sorted by digest and storage/default-budget equations exact.
- Same `model_key` but different artifact/release/receipt, disappeared catalog row, duplicate current rows, or offer-rejected row: top-level target remains available; row cleanup stays unavailable.
- Overflow marker: unavailable storage, `managed_v3_overflow_detected == true`, all managed-v3 totals/charge/available budget null, empty targets, no truncation claim.
- Non-overflow count/byte/default-budget cap: unavailable storage, `managed_v3_overflow_detected == false`, empty targets.

## Migrations, compatibility, and rollback

- No migration: this slice reads existing private inventory through the store in tests/internal builders and writes no private files.
- Backward compatible because no public v2 CLI/status capability is advertised.
- Rollback is removal of internal v2 projection additions; v1 public behavior remains the release surface.

## Observability and qualification

- Tests inspect encoded JSON; no new runtime logging is required.
- Physical Mac preparation -> admission -> settled request remains blocked and must be recorded as not qualified.
- Production activation, economic activation, release packaging, and Malibu UX remain out of scope.

## Explicit non-goals

- No public v2 CLI flag, status capability, or Malibu UI.
- No configured env/YAML budget source publication.
- No stale receipt detection beyond the already decoded usable inventory contract.
- No row-level cleanup publication.
- No durable scanner hookup, transfer, adoption, cancellation, or cleanup execution.
- No network admission, settlement, reward, payout, or production enforcement.
- No operator secret read/write and no d-inference source inspection.
