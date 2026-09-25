HIGH — Missing mandatory buyer-serving E2E evidence
`docs/releases/coordinator-release-train.md:191-196`, `docs/runbooks/catalog-release-decision-tree.md:145-149`, `specs/SPEC-023-installer-autotune-recommend.md:1297-1298`

The branch correctly routes this re-hash through the runtime lane because content-lane evidence (e) is `NO_GO`. However, the post-merge checklist only requires health, `compare-live`, retention-window, and rollout verification. It does not explicitly require a strict-pinned buyer request plus settlement-row proof for the corrected hashes.

Failure scenario: deployment records `descends` and passes health checks, but the corrected rows fail at buyer routing or settlement; the release is marked complete without proving the actual buyer path.

MEDIUM — Release-train lane summary is misleading
`docs/releases/coordinator-release-train.md:63`, `docs/releases/coordinator-release-train.md:140`

The generic table says model hash/Tier-2 corrections belong to the content lane, while the specific #1735 row correctly says this cut must use the runtime lane because the re-hashed buyer-serving rows cannot satisfy content-lane evidence (e). The exception is present, but the summary can cause an operator to select the wrong workflow.

Failure scenario: an operator follows the generic lane table, attempts a content release, receives the expected `NO_GO`, and delays or misclassifies the signing cut.

MEDIUM — Connected-provider impact is not explicit enough
`docs/releases/coordinator-release-train.md:140`, `docs/releases/coordinator-release-train.md:191-196`, `specs/SPEC-023-installer-autotune-recommend.md:824-831`, `specs/SPEC-023-installer-autotune-recommend.md:864-867`

Changing `model_sha256` changes row identity. Providers advertising the old release/hash may remain covered by R015’s release-level `(catalog_release_id, candidate_sha256)` coverage, but R010 requires the old session to close as `catalog_incompatible` when the selected row identity or `PolicyEquivalent` changes. The train checklist does not explicitly require verifying that affected providers are closed, restarted/reconciled, and able to advertise the corrected row.

Failure scenario: `compare-live=descends` and coverage pass, but connected providers serving one of the eight affected rows are closed after activation and remain unavailable until an untracked restart or artifact rematerialization.

INFO — Runtime cut and Tier-2 re-sign shape are correct
`docs/releases/coordinator-release-train.md:114-116`, `docs/releases/coordinator-release-train.md:140`, `phase3-binary/catalog/autotune/tier2-catalog.json:2-4`

The live release is the predecessor recorded in the ledger, so R014 `descends` semantics are valid. A new Tier-2 `catalog_id` is appropriate because model-entry hashes changed; this is not merely expiry renewal.

INFO — Hash and semantic invariants verified

- All eight `MISMATCH` rows in `audits/2026-09-24-1735-catalog-hash-sweep/sweep.json` match their new `recomputed_sha256`.
- No `MATCH` row changed.
- Candidate/source hashes agree.
- All Tier-2 `(model_id, sha256, min_ram_gb)` tuples equal candidate rows.
- No pricing, runtime status, RAM, bench gate, revision, demand, or rate-card semantics changed.
- `python3 scripts/catalog-release.py verify` passed.
- `bash scripts/test-catalog-release.sh` passed.
- `git diff --check origin/main...HEAD` passed.

VERDICT: C=0 H=1 M=2 L=0
