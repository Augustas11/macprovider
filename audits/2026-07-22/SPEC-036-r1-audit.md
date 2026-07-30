# SPEC-036 Compute-Integrity Receipt Companion — Round-1 SPEC audit

**Date:** 2026-07-22
**Reviewed revision:** `f0b31687` (post renumber/rewire/open-question resolution)
**Method:** three independent codex lanes (code / security / architect) via
`omc ask codex`, prompts under `audits/2026-07-22/SPEC_036_R1_*_AUDIT_PROMPT.md`,
framed as proof-review of an existing spec. Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

## Round-1 result

| Lane | C | H | M | L | INFO |
|---|---:|---:|---:|---:|---:|
| code | 0 | 7 | 6 | 1 | 0 |
| security | 0 | 1 | 1 | 0 | 0 |
| architect | 0 | 2 | 3 | 0 | 1 |

No CRITICAL. All three lanes validated the core **compose** decision (support
selection + TV math are valid reuse points; the distinct `compute_integrity_probe_v1`
wire constant is justified; the dependency graph is acyclic; receipt/usage shape is
preserved; onboarding follows identity registration; disclaimers are proportionate).
The findings clustered on (a) an over-claim that SPEC-036 *inherits* SPEC-030's
wire-level framing when the settlement profile actually *owns* it, and (b) genuine
money-path under-specification.

## Findings and resolutions (all HIGH/MEDIUM fixed in-branch)

1. **Digest algorithm contradicts SPEC-030 (code-H2, arch-M3)** — FR-6 reframed:
   SPEC-036 composes on the *algorithm/policy* layer and **owns its settlement-bearing
   wire framing**; the `{type, schema_version, payload}` digest is a deliberate
   domain-separated override, not an inheritance of SPEC-030 §FR-4's inner-payload digest.
2. **No encrypted carrier for the distinct profile (code-H3, arch-M3)** — FR-6 now
   defines the Tier-2 `compute_integrity_probe_v1.*` encrypted carrier (frames, AAD,
   plaintext envelopes) by substituting the profile discriminator into SPEC-030's structure.
3. **Aggregate per-provider probe concurrency undefined (arch-M3)** — FR-6: compute-integrity
   concurrency is 1, tracked separately, aggregate across both profiles ≤ 2, yields to buyer load.
4. **Laundering via generation/key churn (security-H, code-H4, arch-M5)** — new
   **stable-identity risk overlay** (§3) keyed without `assigned_id`/`target_generation`/
   `sampling_profile` carries active quarantine/block + the three accumulators across warm
   swaps, reloads, reconnects, generation churn, and admission-key rotation; FR-11 onboarding
   cannot run over an active overlay quarantine; FR-12 swap-laundering escalation SHOULD→MUST;
   `stable_provider_identity` bound to the durable SPEC-026 provider account row (§3).
5. **SPEC-036 enforce not subordinated to SPEC-022 (arch-H1)** — FR-1 precondition: SPEC-036
   enforce valid only where SPEC-022 is enforce with subsuming coverage; FR-3/FR-4 capture an
   atomic composite-policy snapshot at request start; SPEC-015 verifier preservation SHOULD→MUST.
6. **Settlement-time circuit breaker violates request-start immutability (arch-H2, code-H1)** —
   breaker state captured at request start; settlement is a pure function of captured state; a
   breaker that activates after request-start stops NEW admissions rather than reclassifying
   delivered work; warn_only-captured rows never money-affected; overrides route only
   operator-funded non-buyer traffic; post-start emergency clawback explicitly deferred.
7. **Fail-closed reasons missing for admissibility sub-states (code-H5)** — FR-3 adds a
   deterministic reference-set-admissibility→reason table (`independence_failed`,
   `provenance_missing`, `schema_invalid`, unknown, key-mismatch all map to closed reasons).
8. **Probe payloads not exact schema (code-H6)** — FR-6 request/result payloads tightened to
   closed key sets with types, `positions[]` arrays, `result_kind`, and the inconclusive enum.
9. **Reference-fault predicate undefined (code-H7)** — FR-5 defines the exact pairwise
   `tv_upper` reference-fault predicate with median/position thresholds, K/tail handling.
10. **Validation diverges from SPEC-030 (code-M8)** — FR-6/FR-7 restore the small-vocabulary
    exception, the fixed `1e-5` tolerance, and the `>=` warn-retry boundary.
11. **Expiry causes (code-M9)** — under-sampled stays `pending` (not `expired`); target-hash
    change expires via `target_generation_changed`; enum declared closed.
12. **Flapping trigger + clear conflict (code-M10)** — FR-10 defines the exact trigger
    conjunction and reconciles the `clear_pass_count_sequence` exception with the general
    manual-review clear rule.
13. **Circuit-breaker determinism (code-M11)** — FR-1 `circuit_breaker_policy` closed object
    (window, event-time basis, dedup, model/fleet thresholds, `>=` boundary, scope precedence).
14. **Auditor bundle signature (code-M12)** — FR-13 defines the signed-bundle envelope,
    `bundle_digest`, detached signature, and key discovery/rotation lifecycle.
15. **Reference-event granularity/quorum (arch-M4)** — §3 reference event carries a closed
    `positions[]` + `position_set_digest`; quorum counts distinct sources with identical position sets.
16. **Disclosure copy version (code-M13)** — FR-1/FR-15 bind `disclosure_copy_version`/digest
    and define the staleness/activation-refusal comparison.
17. **Reward/MALIBU exclusion only covered consensus (security-M)** — FR-17 prohibits earnings,
    payout, and uncapped MALIBU for all three SPEC-036 workload classes.
18. **SPEC-030 pin (code-L14)** — header pins `SPEC-030 v0.1-draft` to match FR-1 and the SPEC-030 header.
19. **Entry 181 forward reference (arch-INFO)** — numbering note reworded to reflect that
    Entry 181 lands in this delivery's decision-log PR (merged last), not that it already exists.

Round-2 re-audit (three fresh independent lanes) recorded separately once run.
