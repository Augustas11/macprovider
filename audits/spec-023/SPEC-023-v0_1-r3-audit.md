# SPEC-023 v0.1 Round 3 Audit

Date: 2026-07-01
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md`
Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

## Result

Round 3 did not pass. The three requested audit lanes reported the following critical/high/medium findings:

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 0 | 2 | 0 | Needs fix pass |
| security | 0 | 1 | 1 | 1 | Needs fix pass |
| architect | 0 | 0 | 0 | 1 | Pass on blocking threshold |

## Blocking findings and resolutions

### HIGH-SEC-R3-001: mutable model artifacts were trusted when `model_sha256` was null

Finding: a signed candidate catalog could point to a mutable model-host repository while `model_sha256` was null, allowing the downloaded artifact to differ from what the catalog author intended.

Resolution:
- §3.2 now requires every downloadable row to include a content-addressed immutable `model_revision`.
- §3.2 also requires at least one artifact binding: `artifact_manifest_sha256` or `model_sha256`.
- The CLI must download by immutable revision, not mutable branch or tag.
- Rows missing immutable revision or artifact binding are ineligible before download or benchmark, including donor mode.
- AC-16 and AC-32 cover this fail-closed behavior.
- The threat model now treats mutable model artifacts as a v0.1 defended threat, not a deferred digest problem.

### MEDIUM-SEC-R3-002: HMAC identity privacy depended on unspecified key scope

Finding: `diversification_id` and `hardware_identity_hash` were HMAC-derived, but the key source, storage, and domain separation were unspecified.

Resolution:
- §3.1 now requires a per-install CSPRNG-generated local secret.
- The secret must be stored in Keychain or a `0600` local file and must never be emitted, logged, bundled, or sent to coordinator/gateway.
- Diversification and cache identity use separate HMAC domain labels.
- Missing/unreadable local secret causes regeneration and marks previous recommendation cache stale.
- AC-28 and AC-33 cover the secret handling and domain separation.

### MEDIUM-CODE-R3-001: spec named nonexistent `macprovider` commands

Finding: the repo installs and exposes `macprovider-cli`, while the spec still used `macprovider autotune --recommend` and `macprovider status`.

Resolution:
- Live command references now use `macprovider-cli autotune --recommend`, `macprovider-cli update`, and `macprovider-cli status`.
- AC-1, AC-24, and AC-26 now use `macprovider-cli`.

### MEDIUM-CODE-R3-002: donor-mode `runtime_status` rules contradicted each other

Finding: §8 said donor mode may not bypass `runtime_status != "blocked"` but then narrowed donor rows to `candidate` or `listed`, excluding below-threshold `recommendable` rows. AC-22 only required non-blocked status.

Resolution:
- §8 now allows donor-mode local commit for signed candidate metadata with `runtime_status` equal to `candidate`, `listed`, or `recommendable`.
- `blocked` rows remain forbidden.
- AC-22 now describes non-recommendable or below-threshold local donor-mode commit with the same non-blocked rule.

## Low findings handled opportunistically

- §3.5 and AC-31 now reject fetched static JSON whose `generated_at` is more than 10 minutes in the future.
- §9 stale warning copy now says recommendation inputs changed, matching the full stale trigger set.

## Round 4 requirement

Run only the requested three Codex audit lanes again:

- code
- security
- architect

Continue fixing and re-auditing until all three lanes report zero critical, high, and medium findings.
