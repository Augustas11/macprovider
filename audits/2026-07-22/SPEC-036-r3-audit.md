# SPEC-036 — Round-3 SPEC audit (5 lanes)

**Date:** 2026-07-22
**Reviewed revision:** `09141dbb` (post round-2)
**Method:** FIVE independent lanes — three codex (code/security/architect) plus, at
the operator's request, two Claude subagents: an **adversarial verificator** (critic,
money-path hostile) and a **product-design critic** (analyst). Bar: 0 C / 0 H / 0 M.

## Round-3 result

| Lane | C | H | M | L |
|---|---:|---:|---:|---:|
| codex code | 0 | 1 | 9 | 0 |
| codex security | 0 | 1 | 1 | 0 |
| codex architect | 0 | 1 | 3 | 1 |
| claude adversarial | 0 | 2 | 1 | 2 |
| claude product-design | 0 | 7 | 5 | 2 |

Architecture re-validated by every lane ("serious, defensively-written"; "the hard
parts are locked down"). Findings concentrated on (a) FR-10 positive-state precision,
(b) circuit-breaker flag/state modeling residuals, (c) multi-reference probe schema,
(d) determinism preimages, and (e) product enforce-reachability/proportionality.

## Resolutions (all C/H/M fixed in-branch)

Money-path correctness (adversarial + codex + security):
- **FR-10 sticky-state leak (adv-H1):** positive state is now recomputed on every
  finalized eligible canary; a below-threshold `quarantine_candidate` drops payable
  → `pending`; any non-{verified,warn,quarantined,blocked} window is `pending`.
- **verified-window freshness TTL undefined (adv-H2):** added
  `positive_state_freshness_ttl_hours` (default 24) + pass-rule age bound to `window_size_days`.
- **Circuit-breaker flag/state (codex code-H1/M7, security-M, arch parts):** breaker
  is a captured non-null `circuit_breaker_active` flag (+closed nullable scope);
  reason derived; missing/malformed → unreadable; warn_only reconciled via effective-enforce gating.
- **Reason precedence undefined (codex code-M2, adv-L2):** total precedence order added; drift outranks breaker.
- **Coordinator final-inconclusive enum (codex code-M10):** closed enum with counter effects.
- **Sybil precondition (adv-M1):** enforce refuses unless SPEC-026 hardware-attested new-identity cost holds.
- **bounded settlement deadline (adv-L1):** bound to the SPEC-022 route-snapshot deadline.

Laundering residuals:
- **Abusive/onboarding blocks not carried across hash/tokenizer churn (security-H, codex code-M3):**
  second `(stable_provider_identity, model_id)` swap-laundering overlay, consulted first;
  escalation triggers on provider-originated hash/tokenizer/generation *change* while any
  active risk/accumulator exists (benign reconnects/same-hash reloads exempt — also product-H4).
- **FR-11 dropped profile dim (codex code-M4):** onboarding uses the canonical overlay key.
- **Clear "new generation key" contradiction (arch-M4):** generation never clears; explicit dual-approved overlay transition.

Schema/determinism:
- **Multi-reference support not representable (arch-H):** request carries `reference_top_k_sets[]`;
  support unions all references; per-reference TV over combined support; length ≤ (N+1)K.
- **provider_top_k length (codex code-M6, arch-M3):** `min(k, vocab_size)`.
- **position_set_digest ordering (codex code-M5):** fixed JCS array shape + total sort order.
- **reference_fault_check_version (codex code-M8), quiet_window (codex code-M9), digest preimages
  (codex code-M11), >= boundary (arch-L):** all defined.
- **Reference independence contradiction (arch-M2, product-H6):** closed independence predicate;
  golden-fixture substitutes only for runtime-build, never hardware/operator domain; budget aligned.

Product-design (proportionality/honesty):
- **Enforce unreachable at beta + proportionality (product-H1/H7):** new §6.1 records the decision that
  v0.1 enforce is maintainer-gated and not claimed reachable at current supply; honest time-to-enforce
  disclosure; enforce ratification preconditions (supply/burst, measured FP, independent refs, disclosure).
- **Hardware-class false positives (product-H2):** `hardware_runtime_class` added to threshold key; v0.1
  enforce class-restricted + disclosed.
- **Honest work voided on coordinator lapse (product-H3/H5):** `coordinator_attributable_lapse_mode`
  (`fail_closed` default / `degrade_to_spec022`) + optional `reference_unavailable_auto_degrade`;
  provider-attributable conditions never degrade.
- **Measured-FP gate (product-M3):** enforce requires a measured (not aspirational) false-quarantine rate ≤ budget.
- **Probe contention priority (product-M2), reference cardinality cap (product-M4), labeling honesty
  (product-M5):** all added.

Round-4 convergence check (all 5 lanes) recorded separately.
