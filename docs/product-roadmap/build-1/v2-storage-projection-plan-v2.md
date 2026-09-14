# Build 1 next slice: v2 storage projection from private inventory

Plan revision: v2.
Base revision: `origin/main` at `894f21ff` (`Productize headless Mini installs with system-domain uninstall (#1494)`).

## Goal

Advance Product Build 1 without enabling public v2 actions: internally project SPEC-044 v0.2.10 managed-v3 storage and cleanup target state from an already validated private `model_catalog_inventory.v1` payload into `ModelCatalogEconomicsV2Wire`. Public `models catalog-economics --json` and local status remain v1-only. No preparation transaction, adoption, transfer, publication, network admission, settled request, Malibu UI, production activation, or physical acceptance is claimed by this slice.

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
- No signed feed, downloader, runtime preparation, config mutation, control-socket mutation, admission-state mutation, or durable private-store write path.

## Dependency graph

1. Existing private inventory contract decoding and cleanup binding validation.
2. Internal v2 economics projection builder.
3. Tests that encode the internal v2 wire and assert storage/target/action semantics.
4. Public v1 compatibility tests.

This slice depends only on landed private-record types and does not depend on BYOM slice 7 runtime transfer/adoption work. Later slices may connect the projection input to the live store scanner and public Malibu/client v2 path after their own gates.

## Normative contracts

- SPEC-044-R002 v2 projection shape: v2 storage, cleanup targets, cleanup action binding, and artifact identity digest fields must be exact and fail closed.
- SPEC-044 top-level cleanup target rule: `cleanup_targets` must contain every verified managed-v3 object in the usable inventory exactly once, including protected objects and objects without a current catalog row, sorted by ascending `artifact_identity_digest`.
- SPEC-044 protected/reclaimable rule: a `reclaimable` target must carry one available `cleanup_published_artifact` action with matching digest and bytes; a `protected` target must carry an unavailable cleanup action and exact non-null `protected_reason`.
- SPEC-044 storage rule: missing/malformed/stale/overflow inventory yields unavailable storage, empty target array, and unavailable row cleanup. Usable inventory may publish managed-v3 logical byte totals with JavaScript-safe integer bounds.
- SPEC-044 row action rule: if a row-level cleanup action is retained, its closed action object must be byte-for-byte JCS identical to the matching top-level target cleanup action and both action digest/bytes must equal the enclosing target.
- SPEC-044 secret boundary: projection must never expose raw private paths, root nonce, device/inode, usernames, hardware IDs, feed bodies, credentials, provider identity, or operator secrets. Only `root_identity_digest` may be projected.
- SPEC-044-R007 preparation safety remains unsatisfied by this slice; therefore prepare/adopt/run transactions stay unavailable.

## Implementation steps

1. Add a small internal projection input type, for example `ModelCatalogEconomicsBuilder.PrivateStorageSnapshot`, built from decoded private inventory payload bytes plus the already validated root context. It must be internal/test-only in this slice; no CLI flag or public command path selects it.
2. Extend `ModelCatalogEconomicsBuilder.makeProjectionV2` or `ModelCatalogEconomicsV2Wire.init` with an optional private inventory input. If absent, missing, malformed, stale, over count, over byte sum, or invalid, retain the current unavailable storage, empty target array, and unavailable row cleanup behavior.
3. Convert every accepted `ModelPreparationInventoryRecord.targets` entry into a top-level `ModelCatalogEconomicsV2Wire.CleanupTarget`, not only reclaimable entries. Sort by ascending `artifact_identity_digest`.
4. For each target, require the private contract decoder and `ModelPreparationContracts.validateCleanupBinding(rowAction: target.cleanup, target: target)` to accept the object. Then enforce slice-level projection invariants again before encoding:
   - `artifact_identity_digest`, `root_identity_digest`, and `receipt_sha256` are lowercase 64-hex;
   - `estimated_bytes` and aggregate sums are within `0...9007199254740991`;
   - `event_model_key` is nonempty;
   - `protected_reason` is non-null exactly for protected entries;
   - reclaimable cleanup action is available with `transaction_kind == cleanup_published_artifact`, matching `artifact_identity_digest`, and matching `estimated_bytes`;
   - protected cleanup action is unavailable and has null `artifact_identity_digest`.
5. Set v2 storage from the accepted usable inventory:
   - `managed_v3_published_bytes`: sum of all target `estimated_bytes`, protected plus reclaimable;
   - `managed_v3_reclaimable_bytes`: sum of reclaimable target bytes only;
   - `managed_v3_object_count`: accepted target count;
   - `managed_v3_overflow_detected`: false for usable inventory and true only if the input explicitly reports a 257th-or-later observed entry;
   - configured legacy fields remain null and `configured_legacy_accounting_state == not_configured`;
   - budget source remains `default`; `global_managed_budget_bytes` remains the current default constant; budget charge/available fields stay null unless already backed by landed authoritative budget metadata.
6. Attach row-level `cleanup_published` only when exactly one top-level reclaimable target can be safely associated with exactly one candidate row using existing row fields, without inventing identity from display text. The available row action must be encoded from the same internal action object as the matching top-level target cleanup. If no exact one-to-one association exists, if the target is protected, or if the row is non-actionable for another reason, publish the row action as unavailable and rely on top-level `cleanup_targets` to keep reclaimable current-catalogless identities reachable.
7. Preserve public v1 behavior exactly: `models catalog-economics --json` output and local-status capability advertisement remain unchanged.

## User journeys

- Internal Malibu/client v2 preflight can render truthful managed-v3 storage totals from a verified private inventory without gaining public cleanup authority.
- Internal diagnostic JSON can list protected and reclaimable managed-v3 objects without revealing paths or root identity secrets.
- A current-catalogless reclaimable object remains represented in the top-level target list for a later confirmed cleanup flow.
- A provider using today's public CLI sees no changed command shape or new promised readiness.

## Acceptance criteria

- A valid inventory with one reclaimable target produces available storage counts/bytes, one top-level cleanup target with available cleanup action, sorted target ordering, and no public v1 output change.
- A valid protected target produces available storage counts/bytes, a top-level cleanup target with unavailable cleanup action and exact `protected_reason`, zero reclaimable bytes, and row cleanup unavailable.
- A mixed protected/reclaimable inventory produces published bytes equal to all targets, reclaimable bytes equal to only reclaimable targets, object count equal to all targets, and top-level targets sorted by digest.
- If a row-level action is emitted, its JCS bytes are identical to the matching top-level target cleanup action; ambiguous or unsupported row association keeps row cleanup unavailable without dropping the top-level target.
- Missing, malformed, overflowed, bad digest, bad protected reason, bad event key, mismatched action digest/bytes, unavailable reclaimable action, or available protected action yields fail-closed unavailable storage, empty cleanup target array, and unavailable row cleanup.
- Catalog-only rows and `offer_rejected` rows remain non-actionable and cannot gain cleanup/preparation authority.
- Public v1 CLI/status tests remain green and v2 remains internal test-only.

## Negative tests

- Corrupt/mismatched action binding: unavailable storage, empty target array, row cleanup unavailable.
- Protected target: appears in top-level target list with unavailable action and protected reason; no row action.
- Mixed targets: sorted by digest and storage sums exact.
- Ambiguous row association: top-level target remains; row cleanup unavailable.
- Overflow/count/byte cap: unavailable storage, empty targets, no truncation claim.
- Missing inventory: exact current unavailable behavior.

## Migrations, compatibility, and rollback

- No migration: this slice reads decoded private inventory payloads in tests/internal builders only and writes no private files.
- Backward compatible because no public v2 CLI/status capability is advertised.
- Rollback is removal of internal v2 projection additions; v1 public behavior remains the release surface.

## Observability and qualification

- Tests inspect encoded JSON; no new runtime logging is required.
- Physical Mac preparation -> admission -> settled request remains blocked and must be recorded as not qualified.
- Production activation, economic activation, release packaging, and Malibu UX remain out of scope.

## Explicit non-goals

- No public v2 CLI flag, status capability, or Malibu UI.
- No durable scanner hookup, transfer, adoption, cancellation, or cleanup execution.
- No network admission, settlement, reward, payout, or production enforcement.
- No operator secret read/write and no d-inference source inspection.
