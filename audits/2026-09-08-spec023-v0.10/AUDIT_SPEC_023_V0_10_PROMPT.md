# SPEC audit — SPEC-023 v0.10.0 "Catalog as a pipeline" (+ SPEC-047 0.1.3 minimal amendment)

METHOD CONSTRAINT: this is a first-party normative-spec review. Do not author exploit payloads. Evaluate by reading the spec diff against the sibling specs and the real feed/generator code; describe gaps abstractly (section + condition).

Review the COMPLETE diff: `git diff origin/main...HEAD` on branch `spec/023-catalog-artifact-sets-class-rates`. Files: `specs/SPEC-023-installer-autotune-recommend.md`, `specs/SPEC-047-network-model-admission.md`, `specs/CONFORMANCE.json`, `specs/README.md`. Read the changed sections in their full surrounding context, and cross-check against SPEC-005 §5.5 (rate resolution), SPEC-010 (~lines 975–1010, model_sha256 admission), SPEC-046-R002/R003, SPEC-044 §2, SPEC-032 FR-HG3/FR-HG4 (admission_policy_sha256), `scripts/catalog-release.py`, and `phase3-binary/catalog/autotune/*.json`.

## What the revision decides (operator decisions, not up for debate — audit the ENCODING, not the direction)
1. Artifact sets: a model key carries a set of verified artifacts (mlx_safetensors / gguf …), each with its own hash; settlement binds to artifact hash, pricing to model key. Delivered as a SEPARATE signed static feed bound to the candidate-catalog release, because the deployed strict decoders reject unknown fields in the candidate catalog (§12.2 / #813 trap). Existing `model_id`/`model_revision`/`model_sha256` stay as the primary MLX artifact.
2. Class rate rows: `rate_class` on candidate rows; rate-card source `classes` expanded by the release generator into the existing published per-model rows and coordinator inline fallback rows; SPEC-005 billing resolution untouched.
3. Listed tier + intake pipeline: `listed` = identity + ≥1 verified artifact, BYOM catalog-matchable, probe/unpriced, never a paid default; `recommendable` additionally needs a rate class + existing operator admission; monthly releases driven by demand (OpenRouter rank + unknown-model-key request counts), aggregated SPEC-047 offer counts, and fleet RAM fit. No open marketplace; non-catalog models stay non-earning.

## Invariants to verify (challenge them)
- No signed candidate-catalog byte change is required for v0.1 consumers; every new field lives in the new feed or in generator SOURCE files. Any path by which an old CLI/coordinator fails closed on the new release is a HIGH.
- Artifact feed: schema closed; hash algorithm per format is explicit and unambiguous (SnapshotManifestV1 vs raw file sha256); primary-artifact consistency rule is enforced at generation AND consumption; digest/fallback/anti-rollback semantics match §3.5/§9 discipline; release binding cannot be satisfied by a feed from a different release.
- Settlement safety: `catalog_priced`/`settlement_capable` still require exact body digest + hash + algorithm + signing-key identity + route-time snapshot (SPEC-047-R003, SPEC-022); a `listed` row or a `declared`/`blocked` artifact can never bind settlement; artifact verification status is operator-signed, never provider-asserted; `admission_policy_sha256` (§3.6) treatment of artifact data is explicit and does not spuriously invalidate SPEC-032 verified admissions.
- Class rates: precedence (explicit model row > class expansion) is unambiguous; a `recommendable` row without a resolvable rate row is a generation failure, not a runtime `default` fallback; the published rate-card `version` projection rule (§3.3) still holds after expansion.
- Intake: signals are aggregate-only (no provider identity, no buyer identity); the unknown-model-key counter is specified as a SPEC-017 field with bounded cardinality (no unbounded attacker-chosen keys); thresholds have defaults; Goodhart FM-1/FM-2 mitigations are concrete; `listed` cannot be reached by provider action alone.
- Cross-spec: SPEC-047 amendment is minimal and consistent (0.1.2 → 0.1.3, changelog, R001/R002/R003 wording); SPEC-010 either untouched with a correct scoping statement or amended; SPEC-005 untouched and the reason stated; no contradiction with SPEC-044 non-goals.
- Governance: line-3 version bumps; CONFORMANCE `specs[]` version and new R004–R006 rows are shape-valid and `pending` with honest gap blocks; README index updated; `gen_spec_index.py --lint` and `check_spec_governance.py` pass; §13 open questions that this resolves are annotated, not silently deleted.

## Lanes to report (this pass is: {{LANE}})
Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO. The lock bar is 0 CRITICAL, 0 HIGH, 0 MEDIUM.
- CODE (code-reviewer): internal consistency of schemas, digests, enums, precedence rules, acceptance criteria vs normative text, testability of every MUST.
- SECURITY (security-reviewer): settlement and identity boundaries, artifact substitution, class mis-declaration, intake-signal gaming, privacy of aggregate signals, key/feed trust.
- ARCHITECTURE (architect): authority boundaries across SPEC-023/047/010/005/044/017/032, single source of truth for identity and pricing, forward-compat/activation discipline, whether the separate-feed design is the right seam.

End with `VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`. Cite section and line. Do not invent issues to fill a lane.
