# SPEC-023 v0.1 — Round 1 Audit

Date: 2026-07-01

Scope: three-lane Codex audit only: code, security, architect. No product-design lane was run per operator instruction.

Target: `specs/SPEC-023-installer-autotune-recommend.md`

## Round verdict

NEEDS FIX PASS.

Aggregate blockers before fix pass:

- CRITICAL: 0
- HIGH: 9
- MEDIUM: 6
- LOW: 0

## Lane verdicts

| Lane | Verdict | Counts |
|---|---|---|
| Code | NEEDS FIX PASS | 0C / 5H / 1M / 0L |
| Security | NEEDS FIX PASS | 0C / 2H / 3M / 0L |
| Architect | NEEDS FIX PASS | 0C / 2H / 2M / 0L |

## Findings and fixes applied

### Code lane

- HIGH-CODE-001: Earnings formula used ambiguous rate units and omitted credits-to-USD conversion.
  - Fix: §3.3 now includes `usd_per_million_credits`; §4 defines `usd_per_million_completion_tok` from `completion_rate_per_mtok`, `global_multiplier_ppm`, and `usd_per_million_credits`.
- HIGH-CODE-002: Paid recommendation threshold contradicted happy-path eligibility.
  - Fix: §5, §6, §7, and AC-19 now consistently require `expected_net_usd_per_hour >= 0.0050` for a paid recommendation.
- HIGH-CODE-003: `/v1/rate-card` fetch lacked endpoint contract.
  - Fix: §3.3 now locks `GET /v1/rate-card` as read-only, public-read, non-mutating, and sourced from the effective coordinator rate-card snapshot.
- HIGH-CODE-004: Current `RateFor` default fallback could silently enable unknown models.
  - Fix: §3.3 and AC-15 now require recommendation-specific lookup: exact key, then `normalizeModelKey`, with no `default` fallback except literal `default`.
- HIGH-CODE-005: Candidate metadata source and values were not locked.
  - Fix: §3.2 now defines signed `autotune-candidates.json`, baked fallback, schema, fail-closed behavior, and v0.1 baked rows.
- MEDIUM-CODE-006: Demand-rank checksum/signature validation format was deferred.
  - Fix: §3.5 now locks Ed25519 detached-signature validation over exact JSON bytes.

### Security lane

- HIGH-SEC-01: Static demand-rank control-plane verification was not locked.
  - Fix: §3.5 locks the v0.1 Ed25519 verification mechanism, replay/staleness behavior, release-pinned key ID, and fallback behavior.
- HIGH-SEC-02: Donor-mode non-recommendable rows were not partitioned from paid routing/settlement.
  - Fix: §8 and AC-23 require donor-mode config/heartbeat and paid routing/settlement exclusion for non-recommendable donor rows.
- MEDIUM-SEC-03: Candidate model metadata trust boundary was undefined.
  - Fix: §3.2 locks signed candidate metadata, allowlisted model IDs, optional digest, and fail-closed no-download behavior.
- MEDIUM-SEC-04: Threat model section was missing.
  - Fix: §14 now enumerates static JSON tampering/replay, untrusted metadata, benchmark gaming, donor abuse, fingerprint leakage, misleading earnings, and clean-room boundaries.
- MEDIUM-SEC-05: Fingerprint privacy guardrail was too narrow.
  - Fix: §3.1, §9, AC-28, and §14 require HMAC-derived identities only and ban raw fingerprint persistence/output.

### Architect lane

- HIGH-ARCH-01: Candidate/admission metadata was an implicit control plane with no source or version lifecycle.
  - Fix: §3.2 defines the signed candidate/admission catalog; §9 stores and invalidates on candidate catalog version/hash.
- HIGH-ARCH-02: Paid recommendation threshold was internally contradictory.
  - Fix: same as HIGH-CODE-002.
- MEDIUM-ARCH-03: Demand-rank signature validation was required but not specified.
  - Fix: same as HIGH-SEC-01.
- MEDIUM-ARCH-04: Stored recommendation freshness ignored benchmark, binary, hardware, and candidate metadata invalidation.
  - Fix: §9 and AC-25/AC-27 now persist and compare candidate catalog hash, benchmark ID/time, binary version, and HMAC-derived hardware identity hash.

## Accepted LOWs

None.

## Next round target

Re-run code, security, and architect lanes only. Lock condition remains 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.
