HIGH — Buyer-serving evidence covers only one of eight re-hashed rows

`docs/releases/coordinator-release-train.md:141` requires a strict-pinned buyer request only for `z-ai/glm-4.5-air`, while `audits/2026-09-24-1735-catalog-hash-sweep/sweep.json` records eight mismatches and all eight candidate rows remain recommendable.

This can pass with GLM working while a corrected Qwen, Gemma, or GPT row fails routing or settlement. The decision tree explicitly requires buyer-serving evidence for rows “re-hashed vs live” (`docs/runbooks/catalog-release-decision-tree.md:145-149`).

MEDIUM — New Tier-2 identity can revoke unchanged-row admissions without being checked

The new Tier-2 `catalog_id` is correct for changed Tier-2 entries (`phase3-binary/catalog/autotune/tier2-catalog.json:2-4`), but existing admissions compare the current Tier-2 catalog identity and body digest. A changed identity triggers `boundDrift` and revocation even when the model row is unchanged (`phase4-coordinator/internal/ws/model_admission_binding.go:959-985`). Existing tests document this exact behavior (`phase4-coordinator/internal/ws/model_admission_binding_test.go:604-612`).

The new step-4 evidence only checks `catalog_incompatible` and provider routability (`docs/releases/coordinator-release-train.md:141`). A provider can remain connected and routable while its paid/model admission is revoked, causing buyer routing or settlement capacity to disappear until re-admission.

MEDIUM — Old-hash continuity handling remains point-in-time only

The release note records that no currently observed providers serve the eight affected rows and references `.row-continuity-target` (`docs/releases/coordinator-release-train.md:141`). However, SPEC-023 defines row identity to include `model_sha256` and says old sessions become `catalog_incompatible` when that identity changes (`specs/SPEC-023-installer-autotune-recommend.md:824-831`, `:864-880`).

An offline provider can reconnect advertising an old hash after the snapshot. The release can still pass current activation coverage while that provider is fenced or closed, with no explicit post-deploy evidence that it refreshed to the corrected row. R015 permits this point-in-time gap, but the #1735 closure evidence does not describe the required recovery/refresh verification.

LOW — Audit artifacts fail whitespace validation

`git diff --check origin/main...HEAD` reports trailing whitespace in `audits/2026-09-25-1735-signing-cut/result-architecture-r1.md:1,8,15,22` and `result-code-r1.md:1-5`. This is non-functional, but can fail a whitespace gate and contradicts the R1 artifact’s claim that diff validation passed.

INFO — Positive checks

- The lane-summary correction is now accurate at `docs/releases/coordinator-release-train.md:64`.
- Independent checks found all eight candidate hashes equal their sweep `recomputed_sha256`; no `MATCH` row changed.
- Tier-2 `(model_id, sha256, min_ram_gb)` tuples equal candidate rows.
- Synthetic compare-live classified the release as `descends`, with the expected predecessor.
- Catalog verification and the cited test suites passed.

VERDICT: C=0 H=1 M=2 L=1
