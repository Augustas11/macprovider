# Build 1 Slice 6B test spec v4: safe v2 projection foundation

Base revision: `99ad22cdfa34037e0a4aa7892070640bd5dd87da`.

## Required checks

1. `cd phase3-binary && swift test --filter 'ModelCatalogEconomicsTests|ModelsSubcommandTests/testModelsCatalogEconomics|ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract'`
   - Must compile the CLI and selected test target.
   - Must execute the selected `ModelCatalogEconomicsTests`, `ModelsSubcommandTests/testModelsCatalogEconomics*`, and `ProviderStatusTests/testStatusResponsePublishesVersionedLocalCapabilityContract` tests with zero failures.
2. `git diff --check`
   - Must report no whitespace errors.
3. Changed-file secret scan using the repository's payout/private-key hygiene pattern.
   - Must return no findings.
4. Independent Sol code, security, and architecture audits over the complete diff against `origin/main`.
   - Gate requires zero Critical, High, and Medium findings across all lanes.

## Assertions covered by Swift tests

- V1 public CLI remains the selected public projection until real preparation transactions land.
- V1 public CLI output lacks v2-only `storage` and `cleanup_targets` fields.
- `--run` and `--cancel` remain unsupported at parse time.
- Public status includes the current v1 economics capability tokens and excludes v2 economics capability tokens.
- Internal v2 projection emits schema, storage placeholder, empty cleanup targets, candidate id, provider guidance, guidance binding, unavailable prepare/switch/adopt/cleanup actions, and null artifact identity digests. Coordinator and local-discovery guidance tests assert `guidance_binding.source_sha256` equals the SHA-256 of the exact encoded source document used for the row.
- Catalog-only internal v2 rows are conservative and carry no candidate/guidance/economics authority.
- Coordinator offer rejection remains non-actionable and strips money/demand/rates with generic action-unavailable reasons.
- Stale, future, cross-candidate, cross-model, and cross-catalog coordinator guidance bindings fail closed.
- Stale and future local discovery guidance bindings fail closed.

## Evidence boundaries

Passing this test spec proves only the public-v1 compatibility and internal-v2 projection foundation. It does not prove artifact preparation, action execution, cancellation, managed storage, physical Mac readiness, valid network admission, or settled paid requests.
