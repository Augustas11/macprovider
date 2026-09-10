# SPEC audit — BYOM v0.2 slice 3: SPEC-010 v1.7 multi-artifact identity, SPEC-023 v0.10.3, SPEC-047 v0.1.4 (#1453)

METHOD CONSTRAINT: this is a SPEC-text review on the money path (model identity, route-time verification, settlement). Do NOT modify the worktree. Review the COMPLETE diff `git diff origin/main...HEAD` on branch `feat/byom-v02-slice3-gguf-settlement-identity` — every file (SPEC-010, SPEC-023, SPEC-047, CONFORMANCE.json, specs/README.md). Read the amended sections in their full surrounding context, not only the diff hunks: SPEC-010 §3.7 (R001–R007), SPEC-023 §3.2, §3.3, §3.7 (all subsections), §3.7.7 R004, AC-CAT-6/7/16/17, §13 Q14; SPEC-047 §R001 (the `[amended v0.1.3]` catalog-matched paragraph), R002, R003; SPEC-022 route-time snapshot minimum fields; SPEC-046-R003 `identity_state`; SPEC-005 (must be untouched).

## What the revision does
1. SPEC-010 v1.7: R002 names `macprovider.gguf-file.v1` as a canonical wire pair; new **R007 — Artifact-feed identity**: a model key's identity is the set of `verified` artifacts of the release-bound SPEC-023 §3.7 artifact feed (primary member = the row's `model_sha256`); (a) GGUF digest computed by the CLI over the local complete file bytes, never adopted from a runtime report; (b) expected identity = that set, exact pair equality, fail-closed exclusions (declared/blocked artifact, candidate/blocked row, missing/stale/integrity-failed/unbound feed, unnamed algorithm); (c) resolution by the globally unique pair to one `(model_key, artifact_id)`, provider-asserted key disagreement fails closed, pricing model-key scoped, tier/admission gates unchanged; (d) six-value route-time evidence + fail-closed settlement re-verification for a non-primary member; (e) lifts the primary-only restriction; serving a non-MLX artifact is a runtime-path concern, not defined here. R004 and R006 amended accordingly.
2. SPEC-023 v0.10.3: §3.7 intro paragraphs, §3.7.4 `hash_algorithm` bullet and the "which artifacts may settle" bullet, §3.7.7 R004 tail + the following paragraph, AC-CAT-7, AC-CAT-17, §13 Q14 — all now cite SPEC-010-R007 instead of restating primary-only.
3. SPEC-047 v0.1.4: §R001 amended paragraph (non-primary match may advance under R007), R003 settlement-boundary primary-only sentences replaced by an R007 citation; §3.7.2 signer-scoping citation aligned with SPEC-023 v0.10.2.
4. CONFORMANCE: SPEC-010 v1.7 + pending R007 row; SPEC-023 v0.10.3; SPEC-047 v0.1.4.

## Invariants to challenge
- One authority: identity is decided by SPEC-010 only; SPEC-023 and SPEC-047 cite, never restate. Find any remaining sentence in either SPEC (including ACs, §13, change logs are history and exempt) that still asserts primary-only or contradicts R007.
- Fail-closed completeness: every exclusion in R007(b) is stated once and consistently across the three SPECs; no path lets a `listed` row reach `catalog_priced`, a `declared` artifact settle, a runtime-reported digest count as computed, or a feed of another release supply the expected identity.
- Money path: nothing changes a SPEC-005 formula or a SPEC-023 tier gate; pricing remains model-key scoped; `catalog_priced`/`settlement_capable` still require `recommendable` and the SPEC-022/SPEC-047-R003 preconditions.
- Route-time binding: R007(d) and SPEC-047-R003's six values agree exactly (names and count); the primary member needs no six-value record — is that consistent with SPEC-047-R003 as written?
- SPEC-010 internal consistency: R001/R004/R006/R007 do not contradict; a release WITHOUT an artifact feed is byte-for-byte v1.6 behaviour; R005 bridge untouched.
- Implementability: can a coordinator implement R007(b) from the artifact feed it already loads (`LoadAutotuneFeeds`) and the admitted release (`tier2` route-snapshot material), and can a CLI implement R007(a) for an Ollama-served blob without SPEC-046 proxying buyer traffic? Name anything the text leaves undefined that an implementer would have to invent.
- Terminology drift: `artifact_feed_sha256`, `artifact_feed_signer_key_id`, `catalog body digest`, `release-bound` — used identically to SPEC-023 §3.7.4/§3.7.2 and SPEC-047-R003.

## Lanes to report (this pass is: {{LANE}})
CRITICAL / HIGH / MEDIUM / LOW / INFO; merge bar 0 C / 0 H / 0 M.
- code-reviewer: textual precision, cross-reference correctness, AC testability, CONFORMANCE row shape.
- security-reviewer: fail-closed gaps, identity substitution or replay, digest adoption, cross-release/wrong-signer evidence, anything that could widen settlement beyond the stated conditions.
- architect: authority boundaries across SPEC-010/023/047/022/046, implementability against the existing coordinator/CLI shapes, what slice 3's implementation and slice 4's decision path will need that the text does not give them.

End with `VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`. Cite SPEC:line. Do not invent issues to fill a lane.
