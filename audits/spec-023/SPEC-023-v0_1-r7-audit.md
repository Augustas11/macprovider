# SPEC-023 v0.1 Round 7 Audit

Date: 2026-07-01
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md`
Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

## Result

Round 7 passed. The three requested audit lanes reported zero critical, high, and medium findings.

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 0 | 0 | 0 | Ready to lock |
| security | 0 | 0 | 0 | 0 | Ready to lock |
| architect | 0 | 0 | 0 | 0 | Ready to lock |

## Closure evidence

Code lane verified:

- `/v1/rate-card` is pinned to the coordinator buyer mux and nginx allow-through path.
- Recommendation rate-card lookup avoids the coordinator `default` fallback unless the candidate key is literally `default`.
- `rate_card_version` and `candidate_catalog_sha256` are deterministic and testable.
- Bandwidth-tier mapping and ordering are deterministic.
- Candidate catalog fallback and canonical artifact hash rules are internally consistent.
- Command names match current repo surfaces: `macprovider-cli autotune`, `macprovider-cli update`, and `macprovider-cli status`.

Security lane verified:

- Static JSON integrity uses Ed25519 detached signatures, release-pinned key metadata, stale/future fallback rules, and explicit stale warning names.
- Candidate/model trust requires a signed catalog, immutable `model_revision`, canonical `model_sha256`, and rejection of non-regular/path-escaping model snapshot entries.
- Donor mode has no arbitrary local/custom path bypass and remains local-only for non-recommendable rows without paid network registration.
- HMAC identity handling uses a local CSPRNG secret, protected storage, domain separation, and no secret/raw-fingerprint emission.
- Threat model covers static JSON tampering/replay, benchmark gaming, donor abuse, fingerprint leakage, misleading earnings, and clean-room boundaries.

Architecture lane verified:

- Non-goals preserve boundaries: no auto-switching, no rate-card content change, no gateway billing/coordinator settlement change, no live demand endpoint, and no production-incident claim.
- `/v1/rate-card` is a read-only recommendation projection and not a money-path mutation.
- Retune/status lifecycle, static JSON freshness, deterministic stored hashes, bandwidth tiers, immutable artifact lifecycle, donor-mode boundaries, and diversification pool are architecturally consistent.

## Stop condition

The requested stop condition is satisfied: code, security, and architect Codex audit lanes have zero critical/high/medium findings remaining.
