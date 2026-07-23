# SPEC-036 — Round-2 SPEC audit

**Date:** 2026-07-22
**Reviewed revision:** `323ef319` (post round-1 fixes)
**Method:** three fresh independent codex lanes (code / security / architect),
same dimension prompts, ROUND-2 note. Bar: 0 C / 0 H / 0 M.

## Round-2 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| code | 0 | 2 | 8 | 0 |
| security | 0 | 1 | 0 | 1 |
| architect | 0 | 0 | 4 | 3 |

Convergence: round-1's ~10 distinct HIGH collapsed to 2 distinct HIGH, both
refinements of round-1's own fixes. All lanes re-confirmed the round-1 fixes
(compose boundary, SPEC-022 subordination, immutable settlement, admissibility→reason,
FR-17 funding exclusion, coordinator-owned reference computation).

## Findings and resolutions (all HIGH/MEDIUM/LOW fixed in-branch)

1. **Accumulator key ownership ambiguous across 3 tuples (code-H, security-H, arch-M)** —
   §3 now defines a single canonical **overlay key** (window key minus
   `target_generation`, scope-consistent on the profile dimension) as the sole owner
   of active quarantine/block + the three accumulators; FR-10 rewritten to name
   window-key vs overlay-key ownership and drop ambiguous "same key" language;
   FR-12 broadens `blocked:swap_laundering_suspected` to `(stable_provider_identity,
   model_id)` scope on repeated hash/tokenizer/generation flips after adverse results.
2. **Circuit-breaker hold used as an undeclared state (code-H, security-L, arch-M)** —
   FR-3/FR-4 reworked: the breaker is a separately captured `circuit_breaker_active`
   flag (an additional non-payable AND-gate) over a preserved underlying state; the
   `compute_integrity_circuit_breaker_hold` reason is *derived* from the flag, not a
   state-enum member. AC-5 aligned.
3. **Reference event can't hold provider-dependent union evidence (code-M, arch-M)** —
   §3 reference-event positions[] now store the reference's own top-K probabilities +
   a `reference_full_distribution_ref` sufficient to recompute reference probability
   for any provider-selected union; per-verdict union probabilities/tail live in
   per-verdict evidence bound to the reference-event digest.
4. **Closed result schema conditional fields (code-M, arch-L)** — FR-6 result payload
   made a discriminated union on `result_kind`; `provider_inconclusive` variant adds
   `identity_unavailable_reason` + nullable identities; `validation_metadata` scalar
   verdict is a named nullable field, not an open allowance.
5. **Small-vocab request contradiction (code-M)** — request `reference_top_k_token_ids`
   length is `min(k, vocab_size)`.
6. **`catalog_changed` had no producer (code-M)** — FR-4 captures `signed_catalog_digest`
   and re-evaluates it; a signed-catalog rotation without a hash change expires via
   `catalog_changed`.
7. **Reference-pair retry/tail had no admissibility mapping (code-M)** — FR-5: a pair
   that can't resolve below fault thresholds due to K-retry failure or high tail is
   `reference_fault` (fail closed) → `compute_integrity_blocked_reference_fault`.
8. **Flapping metric formulas undefined (code-M)** — FR-10 defines
   `median_tv_lower_margin_to_quarantine` / `max_position_tv_lower_margin_to_quarantine`
   as clamped margins below the quarantine thresholds, with lookback aggregation and `<=` boundary.
9. **SPEC-022 subordination only at activation (arch-M, code-M)** — FR-3 adds a runtime
   conjunction invariant: a SPEC-022 rollback makes SPEC-036 warn-only/no-effect for
   new admissions in the uncovered scope (no routing/onboarding authority beyond SPEC-022).
10. **Missing ACs (code-M×3)** — AC-4 (flapping numeric fixtures + overlay accumulator
    ownership), AC-5 (SPEC-022 subordination + post-start immutability + breaker-flag),
    AC-6 (FR-17 accounting across all three workload classes), AC-8 (hash/tokenizer
    laundering + swap-laundering scope) extended.
11. **FR-4 still described as inherited (arch-L)** — §2 and FR-1 clarified: SPEC-036
    owns its digest/replay/carrier/result framing; only §FR-3/§FR-7/§FR-9 algorithm
    layer is inherited.
12. **Reference-refresh throughput floor omitted replica multiplicity (arch-L)** —
    FR-17 floor is `covered_key_cardinality * active_reference_replicas / freshness_ttl`.

Round-3 re-audit recorded separately once run.
