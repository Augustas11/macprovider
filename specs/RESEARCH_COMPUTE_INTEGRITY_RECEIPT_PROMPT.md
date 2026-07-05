# RESEARCH_COMPUTE_INTEGRITY_RECEIPT_PROMPT

**Purpose:** research + SPEC-drafting prompt for a compute-integrity receipt
companion to SPEC-015 — extending SPEC-022's settlement outcomes with a
`quarantined_compute_drift` state driven by empirical TV-distance divergence
from a reference distribution. Closes the honest structural gap vs. shard on
the PROVE side.

**Status:** research-round, pre-SPEC. **Explicitly deferred priority** —
not urgent while the fleet is your own hardware; important once
onboarding-v2 opens to arbitrary providers.

**Author:** drafted 2026-07-05 by Claude Opus 4.7 session (opus-4-7).

**Why it matters (eventually).** SPEC-015 v0.4 receipts prove billing-integrity
(correct model+prompt+signer against correct output) but do not prove
compute-integrity (that the output was actually produced by the pinned model).
A malicious provider can sign a valid v0.4 tuple where
`model_hash == expected_catalog_model_hash` while returning outputs from a
cheaper distilled model. Today's fleet is substantially your own hardware —
this attack is theoretical. Once `feat/onboarding-v2-provider-identity` opens
the network to arbitrary providers, this attack is the primary anti-cheat gap.

**Depends on:** the losslessness-probe primitive from
`RESEARCH_LOSSLESSNESS_PROBE_PROMPT.md`. **Do NOT draft this SPEC until the
losslessness probe SPEC is at least v0.1-draft** — the underlying probe
mechanism must exist first.

---

# Codex session: research + SPEC compute-integrity receipt companion for macprovider-poc

## Context

Extend SPEC-022's settlement outcomes model with a `quarantined_compute_drift` state. Providers whose empirical output distribution TV-diverges from a coordinator-held reference by ε over a rolling window enter that state and stop receiving settlement in enforce mode. Reference distribution source is a separate design question (trusted-node reference, N-provider consensus, or hybrid).

## Scope — hard limits

- **Read-only research + SPEC drafting.** No code changes. No PRs against `origin/main`.
- Do NOT modify SPEC-015 v0.4 or SPEC-022 in this SPEC — this is a companion that adds outcomes, not a rewrite.
- Do NOT reuse the losslessness probe SPEC's mechanism design; **build on** its primitive.
- Do NOT scope covert-canary indistinguishability here — that lives in the losslessness probe SPEC's v0.2.

## Prerequisite

**This SPEC is blocked on the losslessness probe SPEC reaching at least v0.1-draft.** If that SPEC is not yet drafted, escalate rather than proceed.

## Read first

1. `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`.
2. `RESEARCH_LOSSLESSNESS_PROBE_PROMPT.md` (companion SPEC — the primitive this one builds on).
3. `specs/SPEC-015-*` v0.4 — settlement outcomes (`pending / verified / quarantined / zero_settled`) and terminal states.
4. `specs/SPEC-022-*` — the money gate that consumes settlement outcomes.
5. `phase4-coordinator/internal/billing/settlement_verifier.go` — the mismatch return-codes (`model_hash_mismatch`, `expected_catalog_model_hash_mismatch`, etc.) which are the current quarantine reasons.
6. Any `feat/onboarding-v2-provider-identity` worktree state — where new-provider gating lives.

## Questions to answer (cite files:lines)

### A. Outcome model extension
- SPEC-022's current settlement outcomes vs. the return-codes in `settlement_verifier.go`. Where does a new `quarantined_compute_drift` code fit? Cite the enum.
- Is drift a settlement-time outcome (per-receipt) or a fleet-time state (per-provider-window)? Suggested: per-provider window; per-receipt outcome inherits from provider state at settlement.
- What settlement-verifier surface changes? Additive only?

### B. Reference distribution source
- Options: (i) coordinator runs a trusted reference node (compute + memory cost, single point of poisoning), (ii) consensus across N ≥ 3 independent providers, (iii) hybrid (majority-consensus with periodic trusted-node audit). Cite adversarial resilience per option.
- How is the reference model_hash pinned to the catalog?
- How often is the reference distribution refreshed for each supported model?

### C. Threshold semantics
- ε₁ (canary-level: single canary is "warn") vs. ε₂ (window-level: N canaries in K days is "quarantine"). Statistical justification for both — not asserted values.
- Model-dependence of ε: high-temperature intrinsic sampling variance differs by model. Should ε be per-model-per-temperature?
- What ratio of TV-warnings triggers quarantine? What ratio of ε₁ warnings clears back to `verified`?

### D. Onboarding integration
- Should new providers face a compute-integrity gate at onboarding — pass N canaries against reference before receiving billable traffic? Cite the seam in `feat/onboarding-v2-provider-identity`.
- What's the failure mode for a new provider that fails onboarding canaries? Retry? Manual review? Permanent block?

### E. Interaction with SPEC-011 warm-swap
- Warm-swap changes the loaded model. Does the compute-integrity window reset? Suggested: reset (drift state is per-model-per-provider).
- If a provider deliberately warm-swaps to escape a drift window, is that detectable? Cite.

### F. Third-party audit surface
- Can a third party (buyer, external auditor) issue canaries against providers and compute their own drift measurement? Cite the coordinator API surface required.
- If yes: is the third-party measurement admissible as evidence for quarantine? Or coordinator-issued only? Cite trust model.

### G. Migration path
- **Warn-only phase** (drift signal reported but never quarantines) → **enforce phase** (drift signal → quarantine → zero_settled). What's the observation window before enforce mode? Cite fleet-scale variance considerations.
- Grandfathering for existing providers when enforce mode activates.

### H. Cost accounting
- Adds inference-cost to the coordinator (reference distribution generation) or to the fleet (consensus). Cite $-per-canary and canaries-per-day for a fleet of 100 providers × 10 models.
- Is this cost passed through to buyers, absorbed by the network, or funded by staker rewards?

## Deliverables

Branch `research/compute-integrity-receipt` off `origin/main`, three artifacts:

1. **`docs/research/compute-integrity-receipt-2026-07.md`** — research memo answering §A–H with citations.
2. **`specs/SPEC-XXX-compute-integrity-receipt.md`** v0.1-draft — normative FRs (outcome extension, reference source, threshold semantics, onboarding gate), non-goals (no probe mechanism — inherit from losslessness probe SPEC), open questions, acceptance criteria.
3. **`.omc/logs/compute-integrity-receipt-open-questions-2026-07.md`** — maintainer-input list (reference source pick, ε threshold, enforce-mode timeline, cost-funding model).

## Definition of done (this research session)

- Every §A–H question answered.
- Threshold statistics justified, not asserted.
- Reference-source decision made with adversarial-model rationale.
- Cost accounting has a concrete number, not "small."
- SPEC draft passes self-review round.
- No code changes.

## Do NOT

- Modify SPEC-015, SPEC-022, or SPEC-011.
- Design the canary probe mechanism — inherit it from the losslessness probe SPEC.
- Proceed if the losslessness probe SPEC is not yet at v0.1-draft.
- Scope covert-canary indistinguishability — that's the probe SPEC's v0.2 problem.
