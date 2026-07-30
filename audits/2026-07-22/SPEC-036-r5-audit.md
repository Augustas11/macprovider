# SPEC-036 — Round-5 SPEC audit (5 lanes) + convergence fixes

**Date:** 2026-07-22
**Reviewed revision:** `b2953e28` (post round-4 consolidation)
**Method:** five independent lanes (3 codex + adversarial + product-design).

## Round-5 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code | 0 | 1 | 0 | 0 |
| codex security | 0 | 1 | 1 | 0 |
| codex architect | 0 | 1 | 3 | 0 |
| claude adversarial | 0 | 0 | 1 | 1 |
| claude product-design | 0 | 0 | 2 | 2 |

**Both Claude lanes at 0 HIGH.** The three codex HIGHs are the SAME single "sweep
both sides" residual: the round-4 FR-5 tightening ("golden fixture never substitutes
for runtime-build independence") was not propagated to §3/FR-4/FR-13/AC-2/AC-15,
which still encoded the substitutable "OR" — AC-15 directly contradicted FR-5. This
is one clean sweep, not new architecture. Convergence trend: R3 (18H) → R4 (11H) →
**R5 (3H, all one issue; 0H on both adversarial+product lanes)**.

## Convergence fixes (all C/H/M addressed)

- **Golden-fixture substitution sweep (HIGH ×3 codex + product-M-B):** §3
  reference-event schema, FR-4 capture, FR-13 auditor bundle, AC-2 now require BOTH
  `runtime_build_provenance_digest` AND `golden_fixture_validation_digest`
  (non-substitutable); AC-15 rewritten to prove shared runtime-build/kernel fails
  quorum (`independence_failed`) even when both pass golden fixture, and that each of
  the two digests independently fails admission when missing.
- **Auto-downgrade releases adjudicated quarantines (adversarial M1):** added a
  carve-out — the `reference_unavailable_auto_downgrade` window suspends only
  new-verdict capability and MUST continue to exclude keys with active
  provider-attributable state (drift/swap-laundering/manual-review/abusive), so an
  induced outage cannot launder an adjudicated quarantine.
- **Provider `reference_unavailable` suppresses abusive counter (security M):** a
  provider-supplied `reference_unavailable` now counts as abusive unless the
  coordinator independently confirms an outage (not self-authenticating).
- **Breaker admit contradiction (architect M):** FR-16 `active` now evaluates the
  breaker atomically before forwarding; active-scope paid attempts are rejected (not
  admitted-then-non-payable); the flag/reason path is defensive-only.
- **Calibration diversity floor optional (architect M):** the 10-distinct-identity
  floor is now a hard enforce minimum (below-floor keys stay warn-only); "when
  available" removed; burst≠diversity stated.
- **Reference event ↔ K-retry binding (architect M):** every reference event binds an
  ordered top-256; K=64 is the prefix; retries reuse the same reference-event digest.
- **FR-5(c) vs FR-8 class band (product-M-A):** `hardware_runtime_class` reconciled
  as a numeric-equivalence band; independent builds within the band still agree
  within `tau_reference_fault`; honest statement of the bounded correlated-bug
  protection and the retained golden-fixture role.
- **Vestigial FR-6 "identical two-arm" sentence (product-L1):** removed.
- **Voided-work compensation cap (adversarial L1):** pinned to the FR-17 capped
  instrument's per-provider caps + anti-Sybil, as a distinct category.
- **Auto-downgrade sharded granularity (product-L2):** trigger scope SHOULD match the
  reference-staleness scope.

## Convergence assessment

After five rounds and five independent lanes, both money-path adversarial and
product-design lanes are at 0 CRITICAL / 0 HIGH, and the codex HIGHs collapsed to a
single mechanical sweep now applied. A round-6 verification is the final check.
