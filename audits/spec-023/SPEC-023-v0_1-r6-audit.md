# SPEC-023 v0.1 Round 6 Audit

Date: 2026-07-01
Spec under audit: `specs/SPEC-023-installer-autotune-recommend.md`
Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

## Result

Round 6 did not pass. The three requested audit lanes reported the following critical/high/medium findings:

| Lane | Critical | High | Medium | Low | Status |
| --- | ---: | ---: | ---: | ---: | --- |
| code | 0 | 0 | 2 | 0 | Needs fix pass |
| security | 0 | 0 | 1 | 0 | Needs fix pass |
| architect | 0 | 0 | 0 | 0 | Pass |

## Blocking findings and resolutions

### MEDIUM-CODE-R6-001: `/v1/rate-card` exposure path was not pinned to current routing

Finding: the spec defined public `GET /v1/rate-card`, but the coordinator has split buyer/provider ports and nginx returns 404 for generic `/v1/` unless explicit exceptions are declared before the catch-all block.

Resolution:
- §3.3 now pins the installer fetch URL to `https://coordinator.malibu.tech/v1/rate-card`.
- §3.3 requires the handler to live on the coordinator buyer HTTP mux (`buyer_port: 8443`), not the provider/operator mux (`provider_port: 8444`).
- §3.3 requires an exact nginx `location = /v1/rate-card` allow-through before the generic `/v1/` 404 block.
- AC-37 verifies unauthenticated public reachability through nginx to the buyer mux.

### MEDIUM-CODE-R6-002: stored catalog/rate-card version hashes were not deterministic

Finding: `candidate_catalog_sha256` and `rate_card_version` were used for stale detection without defining their algorithms. Reusing existing broader billing/config hashes would couple recommendation freshness to unrelated state.

Resolution:
- §3.3 now defines `/v1/rate-card.version` as a recommendation-projection SHA-256 hash over only rows, provider share, global multiplier, and `usd_per_million_credits`.
- The rate-card version explicitly excludes unrelated quarantine/force-void, request-log, operator, ledger, and settlement runtime state.
- §9 defines `candidate_catalog_sha256` as SHA-256 over the exact selected catalog JSON bytes after fetched/baked selection and before parsing normalization.
- AC-38 and AC-39 cover these hash/version semantics.

### MEDIUM-SEC-R6-001: undefined custom donor-mode path weakened signed-catalog/digest controls

Finding: AC-11 allowed a "custom donor-mode path" exception that could be interpreted as an arbitrary local model/path override bypassing signed catalog, immutable revision, canonical digest, and path-safety controls.

Resolution:
- AC-11 now removes the arbitrary custom path exception.
- v0.1 has no arbitrary local-model or custom donor-mode path override.
- Any donor-mode selection must still select a row from the signed selected candidate catalog and pass §3.2, §5, §8, and AC-22 controls.

## Round 7 requirement

Run only the requested three Codex audit lanes again:

- code
- security
- architect

Continue fixing and re-auditing until all three lanes report zero critical, high, and medium findings.
