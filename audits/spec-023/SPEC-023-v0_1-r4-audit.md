# SPEC-023 v0.1 Round 4 Audit

Date: 2026-07-01
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md`
Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

## Result

Round 4 did not pass. The three requested audit lanes reported the following critical/high/medium findings:

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 0 | 1 | 0 | Needs fix pass |
| security | 0 | 0 | 1 | 0 | Needs fix pass |
| architect | 0 | 0 | 1 | 1 | Needs fix pass |

## Blocking findings and resolutions

### MEDIUM-CODE-R4-001: candidate catalog fallback rules were internally contradictory

Finding: §3.2 said a missing/invalid/unsigned/stale fetched catalog made rows ineligible, while §3.5 and AC-6 said the CLI must reject the fetched catalog and use the baked snapshot.

Resolution:
- §3.2 now separates catalog selection from row eligibility.
- If the fetched catalog fails integrity/freshness checks, the CLI rejects it, uses the baked catalog, and emits `candidate_catalog_fallback_used`.
- Only after selecting a valid fetched or baked catalog can a row be marked ineligible for missing metadata in that selected catalog.

### MEDIUM-SEC-R4-001: artifact binding verification was not explicit on the paid path

Finding: §3.2 required an artifact binding but did not explicitly require pre-benchmark/pre-run verification for paid recommendations. Donor-mode AC-22 had clearer digest wording than the default paid path.

Resolution:
- v0.1 no longer supports a separate `artifact_manifest_sha256` mode.
- §3.2 now requires every downloadable row to include immutable `model_revision` and canonical `model_sha256`.
- §3.2 defines the canonical artifact-set hash algorithm over sorted relative file path, file size, and file SHA-256 entries.
- A mismatch fails closed before benchmark, recommendation, local donor-mode commit, or provider run.
- AC-16, AC-22, AC-32, and AC-34 encode the same rule.

### MEDIUM-ARCH-R4-001: artifact-manifest lifecycle was undefined

Finding: `artifact_manifest_sha256` introduced another lifecycle without specifying source, schema, signature/hash verification, downloaded-file checks, or persistence.

Resolution:
- Removed `artifact_manifest_sha256` from v0.1.
- Required direct canonical `model_sha256` verification for all downloadable rows.
- The threat model now names immutable `model_revision` plus canonical `model_sha256` as the v0.1 defense.

## Low findings handled opportunistically

- Replaced undefined `top-K` wording with `diversification_band`.
- §4 now defines `recommendation_pool` as all eligible rows within 85% of the best raw score.
- AC-9 and Goodhart M1 now use the same diversification-band vocabulary.

## Round 5 requirement

Run only the requested three Codex audit lanes again:

- code
- security
- architect

Continue fixing and re-auditing until all three lanes report zero critical, high, and medium findings.
