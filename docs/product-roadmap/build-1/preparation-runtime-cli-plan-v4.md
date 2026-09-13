# Build 1 Slice 6B plan v4: safe v2 projection foundation without public action advertisement

Base revision: `99ad22cdfa34037e0a4aa7892070640bd5dd87da` (`origin/main` after PR #1495).
Status: revised after implementation audit of v3. v3's public v2 CLI/status and run/cancel grammar are deferred because the transaction worker, storage scanner, reservation writer, cancellation lifecycle, and managed-v3 publication path are not landed in this slice.

## Outcome

Create a reviewable, non-overlapping Build 1 foundation for SPEC-044 preparation UX by adding an internal `model_catalog_economics.v2` projection type and builder that can be exercised by tests, while preserving the current public `models catalog-economics --json` v1 contract and local status v1 capability advertisement.

This slice intentionally does not enable provider-visible Prepare/Run/Cancel actions, does not advertise the v2 flat capability trio, does not mutate model runtime state, does not grant paid admission, and does not alter coordinator admission, settlement, billing, rewards, or release packaging.

## Current implementation classification

- `ModelCatalogEconomicsWire` v1 is landed and remains the public CLI/status contract.
- Coordinator-backed model economics projection is landed for v1 but action execution remains unavailable.
- Signed artifact feed generation, durable artifact store primitives, and BYOM admission work are separate slices; this slice must not duplicate or assume them.
- Public preparation runtime is missing: no transaction reservation, download/stage/publish worker, cancel worker, storage scanner, or action-id lifecycle is complete here.
- v2 projection fields are missing on `origin/main`; this slice adds only an internal encode-only projection foundation.

## User journeys covered by this slice

1. Provider reads existing public catalog economics:
   - `macprovider-cli models catalog-economics --json` emits one v1 object.
   - No v2-only storage, cleanup target, guidance binding, or action-digest fields are exposed publicly yet.
2. Provider local status is consumed by readers:
   - Status advertises the current v1 flat capability tokens.
   - Status does not advertise v2 flat capability tokens until executable v2 transactions exist.
3. Internal projection tests construct v2 rows:
   - Candidate rows bind guidance to either fresh local discovery bytes or fresh coordinator admission status bytes.
   - Catalog-only rows emit a conservative sentinel with no candidate identity, no money, no demand, and no earning claim.
   - Invalid/stale/future/mismatched bindings fail closed.
   - Coordinator `offer_rejected` rows remain non-actionable and use generic action-unavailable copy.

## Ownership boundaries

- Swift CLI only: `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift` and related Swift tests.
- Public command behavior remains owned by the existing `ModelsSubcommand` v1 path.
- Public status capability behavior remains owned by existing `HTTPServer`/`ProviderStatus` contracts and is tested for no v2 advertisement.
- No coordinator, gateway, billing, reward, app, artifact downloader, durable store, release, or spec-index mutation is in scope.

## Normative contracts

- V1 public compatibility: the public CLI and flat local-status capabilities stay on `model_catalog_economics.v1` / `models catalog-economics.v1` only.
- V2 foundation schema: internal `ModelCatalogEconomicsV2Wire` is encode-only in this slice and uses schema `model_catalog_economics.v2` with top-level `storage`, `cleanup_targets`, row `candidate_id`, `provider_guidance`, `guidance_binding`, row `cleanup_published`, and action `artifact_identity_digest` fields.
- Source binding: a v2 candidate row may carry guidance only when the immutable source timestamp satisfies `0 <= projection.generated_at - source_generated_at <= 300 seconds` and the source identity binds to the row candidate/model/catalog identity.
- Coordinator binding: coordinator status must have `admission_state_source == coordinator`, matching `candidate_id`, matching `served_model_ref`, matching `catalog_model_key`, and a fresh generated-at timestamp.
- Local discovery binding: discovery source bytes must encode successfully and be fresh; otherwise guidance/binding are nulled and economics fail closed.
- Fail-closed economics: invalid source binding and coordinator `offer_rejected` null money/demand/rate fields, set pricing/settlement booleans false, make actions unavailable, and preserve no paid-admission assertion.
- Catalog-only sentinel: no candidate/guidance/binding, `runtime_state: catalog`, `action_model_id: null`, `economics_state: unavailable`, `rate_source: none`, null demand/money, conservative local-default `not_offered` admission.

## Phased changes

1. Add encode-only v2 projection data structures and conversion from v1 rows.
2. Add source-binding freshness and identity checks for coordinator status and local discovery guidance.
3. Add fail-closed conversion for invalid bindings and coordinator offer rejection.
4. Keep public command/status on v1 and add regression tests proving v2 action flags are unlanded.
5. Add targeted tests for v2 candidate binding, catalog-only sentinel, offer rejection, stale/future/cross-candidate/cross-model/cross-catalog coordinator status, and stale/future local discovery.

## Acceptance criteria

- Public CLI read still emits v1 with `projection_protocol_version == "1"` and no v2 top-level fields.
- Public status capabilities include v1 economics tokens and exclude v2 economics tokens.
- Internal v2 builder emits schema `model_catalog_economics.v2`, unavailable storage, empty cleanup targets, and fail-closed action objects with null artifact identity digests.
- Fresh coordinator status binds exact guidance and event metadata to the row.
- Stale/future/mismatched coordinator status fails closed with `source_binding_invalid` and no money/demand/rates.
- Stale/future local discovery fails closed with `source_binding_invalid` and no guidance binding.
- Coordinator `offer_rejected` remains non-actionable with generic `action_unavailable` reasons and no authoritative rejection event copy beyond the decoded state.
- `--run` and `--cancel` for `models catalog-economics` remain parse-time unsupported until the real transaction lifecycle lands.

## Negative tests

- Parse `--run` and `--cancel`: throw before command execution.
- Public v1 JSON: assert absence of `storage` and `cleanup_targets`.
- Local status: assert absence of `model_catalog_economics_v2`, `model_catalog_economics.v2`, and `models catalog-economics.v2`.
- V2 invalid coordinator bindings: stale, future, cross-candidate, cross-model, cross-catalog.
- V2 invalid local discovery bindings: stale and future.
- V2 offer rejection: no money/demand, no settlement/pricing booleans, actions unavailable with generic reason.

## Migration, compatibility, rollback

This slice is additive internally and publicly compatible. Rollback is deleting `ModelCatalogEconomicsV2Wire`, `makeProjectionV2`, and their tests; no persisted data, public schema, release artifact, coordinator state, or runtime state depends on it.

## Observability

No production observability is changed. Test evidence is the observability for this foundation slice. Later slices must add transaction events, progress, cancellation, publication receipt, and cleanup telemetry before any public v2 advertisement.

## Hardware requirements

No physical Mac model-preparation journey is claimed by this slice. It needs only Swift unit/CLI tests. Full Build 1 acceptance still requires a physical Mac completing prepare -> valid admission -> correctly settled request after later slices land.

## Non-goals

- No public v2 capability advertisement.
- No `models catalog-economics --run` or `--cancel` runtime.
- No reservation writer, durable action id, storage scanner, HuggingFace transfer, staging, managed-v3 publication, cleanup, adoption, or runtime mutation.
- No paid admission, settlement, billing, reward, or production activation.
- No Malibu app UX changes.
