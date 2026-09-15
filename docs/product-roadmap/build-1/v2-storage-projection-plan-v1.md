# Build 1 next slice: v2 storage projection from private inventory

Base revision: `origin/main` at `894f21ff` (`Productize headless Mini installs with system-domain uninstall (#1494)`).

## Goal

Advance Product Build 1 without enabling public v2 actions: internally project SPEC-044 v0.2.10 managed-v3 storage and cleanup target state from the existing `ModelPreparationPrivateStore` inventory record into `ModelCatalogEconomicsV2Wire`. Public `models catalog-economics --json` and local status remain v1-only. No preparation transaction, adoption, transfer, publication, network admission, settled request, Malibu UI, production activation, or physical acceptance is claimed by this slice.

## Current landed baseline

- `ModelPreparationContracts.swift` already defines v22/v0.2.10 private records, including `ModelPreparationInventoryRecord`, `ModelPreparationCleanupTarget`, `ModelPreparationAction`, `ModelPreparationPrivateStateEnvelopeKind.publishedInventory`, `ModelPreparationContracts.validateCleanupBinding`, and artifact identity digest derivation.
- `ModelPreparationPrivateStore.swift` can bootstrap an authority/artifact root, read/write all seven private-state envelope kinds, validate root identity, reject hostile durable files, and recover safe state temps.
- `ModelCatalogEconomics.swift` already has encode-only `ModelCatalogEconomicsV2Wire`, but its initializer always sets `storage = .unavailable`, `cleanupTargets = []`, and per-row `cleanupPublished` to unavailable.
- `ModelsCatalogEconomicsCommand` still emits public v1 only. That must remain unchanged in this slice.

## Ownership boundaries

- Swift CLI only:
  - `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`
  - `phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift`
  - build-1 docs/review records for this slice
- No coordinator/gateway/Malibu app changes.
- No signed feed, downloader, runtime preparation, config mutation, control-socket mutation, or admission-state mutation.

## Normative contracts

- SPEC-044-R002 v2 projection shape: v2 storage, cleanup targets, cleanup action binding, and artifact identity digest fields must be exact and fail closed.
- SPEC-044-R007 preparation safety remains unsatisfied by this slice; therefore prepare/adopt/run transactions stay unavailable.
- SPEC-044-R010 secret boundary: never expose raw private paths, feed bodies, credentials, provider identity, or operator secrets.
- v22 cleanup plan/test authority: published cleanup targets derive only from a decoded, root-validated `model_catalog_inventory.v1` payload read through `ModelPreparationPrivateStore`; malformed, missing, wrong-root, or action/target mismatch data yields unavailable storage and zero cleanup targets.

## Implementation steps

1. Add a small internal projection input type, for example `ModelCatalogEconomicsBuilder.PrivateStorageSnapshot`, containing decoded `ModelPreparationInventoryRecord` and optional budget metadata. Keep it constructed by tests for now; do not add CLI flags or public command selection.
2. Extend `ModelCatalogEconomicsV2Wire.init` or `makeProjectionV2` with an optional private inventory input. If absent or invalid, retain the current fully unavailable behavior.
3. Convert `ModelPreparationInventoryRecord.targets` into `ModelCatalogEconomicsV2Wire.CleanupTarget` only when:
   - `keep_set_status == reclaimable`;
   - `ModelPreparationContracts.validateCleanupBinding(rowAction: target.cleanup, target: target)` succeeds;
   - artifact identity digest, receipt SHA, root digest, model tuple fields, estimated bytes, and action binding are already accepted by the private contract decoder;
   - the target has an available `cleanup_published_artifact` action with matching `artifact_identity_digest` and `estimated_bytes`.
4. Set v2 storage from accepted inventory:
   - `managed_v3_published_bytes`: sum of all decoded target `estimated_bytes`, including protected and reclaimable published objects, bounded by JavaScript-safe integer;
   - `managed_v3_reclaimable_bytes`: sum of reclaimable target bytes only;
   - `managed_v3_object_count`: decoded target count;
   - configured legacy fields remain null/unavailable in this slice;
   - managed budget source stays `default`; if the inventory is absent or rejected, keep `Storage.unavailable`.
5. Attach row-level `cleanup_published` only to rows whose immutable model identity matches an accepted reclaimable target by event/model tuple fields or model key when available. If multiple targets match one row, expose no row action and rely on top-level `cleanup_targets` to avoid ambiguous cleanup. If target is protected, expose no cleanup action.
6. Preserve public v1 behavior exactly: `models catalog-economics --json` output and local-status capability advertisement remain unchanged.

## Acceptance criteria

- A valid inventory with one reclaimable published target produces non-null storage counts/bytes, one top-level cleanup target, and a matching row `cleanup_published` action whose JCS equals the target cleanup action.
- A protected target contributes to published bytes/object count but not reclaimable bytes/actions/cleanup target list.
- Malformed inventory, wrong root, bad artifact digest, mismatched action digest/bytes, unavailable cleanup action, duplicate/ambiguous row match, or over-cap byte sum yields fail-closed unavailable storage and no cleanup actions.
- Catalog-only rows and `offer_rejected` rows remain non-actionable and cannot gain cleanup/preparation authority.
- Public v1 CLI/status tests remain green and v2 remains internal test-only.

## Negative tests

- Corrupt/mismatched action binding: no storage, no cleanup target, row cleanup unavailable.
- Protected target: counts as published storage, no cleanup target/action.
- Duplicate row match for one target or duplicate target match for one row: no row cleanup action.
- Wrong root locator or unreadable private store: storage unavailable, warnings include an internal-safe projection warning if implemented, no raw path.
- Missing inventory: exact current unavailable behavior.

## Compatibility and rollback

- Backward compatible because no public v2 CLI/status capability is advertised.
- Rollback is removal of internal v2 projection additions; v1 public behavior remains the release surface.
- Existing private-store bytes are read-only in this slice; no migration or mutation.

## Observability and qualification

- Tests inspect encoded JSON; no new runtime logging.
- Physical Mac preparation → admission → settled request remains blocked and must be recorded as not qualified.
- Production activation, economic activation, release packaging, and Malibu UX remain out of scope.
