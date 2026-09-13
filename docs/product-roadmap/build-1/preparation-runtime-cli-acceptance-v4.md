# Build 1 Slice 6B v4 acceptance report

Base revision: `99ad22cdfa34037e0a4aa7892070640bd5dd87da` (`origin/main` after PR #1495).
Scope: safe internal v2 model-catalog economics projection foundation; public v1 CLI/status compatibility preserved.

## Newly implemented in this slice

- Added encode-only internal `ModelCatalogEconomicsV2Wire` with v2 schema fields for candidate id, provider guidance, guidance binding, unavailable storage, empty cleanup targets, cleanup-published action, and action artifact identity digest.
- Added `ModelCatalogEconomicsBuilder.makeProjectionV2` for tests/future slices without wiring v2 into public CLI/status surfaces.
- Added source-binding freshness and identity checks for coordinator admission status and local discovery source documents.
- Added fail-closed behavior for stale/future/mismatched bindings, catalog-only rows, and coordinator `offer_rejected`.
- Preserved public `models catalog-economics --json` v1 behavior and local-status v1 capability advertisement.

## Verification evidence

Plan gate:

- `docs/product-roadmap/build-1/preparation-runtime-cli-plan-v4.md` sha256 `d05b8750fcab170c06280f94fd2415467edd93a5387ccd5d1492b87da84752d9`
- `docs/product-roadmap/build-1/preparation-runtime-cli-test-spec-v4.md` sha256 `b095fdd861bea1fe748038198883c589ad92b7e3039ea4c549eec2afd9a7a182`
- Independent Sol plan gate: 0 Critical, 0 High, 0 Medium; one Low fixed.

Tests and checks:

- `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'`
  - Result: 18 tests, 0 failures.
- `git diff --check`
  - Result: passed, no output.
- Changed-file secret scan using the repository's payout/private-key hygiene pattern.
  - Result: passed, no findings.

Implementation audit gate:

- Code audit: 0 Critical, 0 High, 0 Medium, 0 Low after fixes.
- Security audit: 0 Critical, 0 High, 0 Medium, 0 Low.
- Architecture audit: 0 Critical, 0 High, 0 Medium, 0 Low after documentation/test-command fix.

## Acceptance status

Completed for this slice:

- Public v1 compatibility: locally verified.
- Internal v2 projection foundation: locally verified by unit/CLI tests.
- Source-binding fail-closed behavior: locally verified by stale, future, cross-candidate, cross-model, cross-catalog, and local-discovery tests.
- Rejected-offer non-actionability: locally verified with generic action-unavailable copy and nil guidance/binding.

Not completed by this slice and still Build 1 blockers:

- Public v2 capability advertisement.
- `models catalog-economics --run` / `--cancel` transaction lifecycle.
- Durable reservation writer, storage scanner, HuggingFace transfer/staging, managed-v3 publication, cleanup, and recovery.
- Malibu provider UX for executable preparation/adoption.
- Physical Mac journey: preparation -> valid admission -> correctly settled request.
- Production qualification, release verification, admission/settlement activation, and paid economics activation.
