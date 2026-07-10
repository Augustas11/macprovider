# RESEARCH_LOSSLESSNESS_PROBE_PROMPT

**Purpose:** research + SPEC-drafting prompt for a coordinator-issued
losslessness probe — PLAIN vs. SPEC output comparison via TV distance,
publishable as receipt metadata or telemetry. macprovider's version of shard's
`phase0/specpipe.py --sample-test` on-swarm losslessness proof.

**Status:** research-round, pre-SPEC. **Companion to SPEC-028 (speculative
decoding, v0.2 on `origin/main` at `a1be007`).**

**Author:** drafted 2026-07-05 by Claude Opus 4.7 session (opus-4-7).

**Why it matters now.** SPEC-028's speculative decoding is provably token-exact
only at temperature 0. At buyer-typical temperatures > 0 the guarantee weakens
to distributional equivalence — a claim macprovider cannot back with receipts
today. Adding the probe alongside SPEC-028 while its seam is open is
timing-optimal; grafting it on later means reopening the same coordinator
routing seam. The probe promotes macprovider's public losslessness claim from
"lossless at greedy decoding" to **"empirically lossless within ε across
buyer-typical temperatures, receipt-backed"**.

Note: the probe primitive **also generalizes to non-spec-decode compute-integrity**
checking (probe provider-A's PLAIN output vs. a reference distribution). That
follow-on use is scoped in a separate SPEC (`RESEARCH_COMPUTE_INTEGRITY_RECEIPT_PROMPT.md`);
this SPEC is scoped to the spec-decode losslessness case only, to keep v0.1
tight.

---

# Codex session: research + SPEC losslessness probe for macprovider-poc

## Context

Coordinator issues explicit canary requests to a provider (not covert — overt-only in v0.1). Provider runs the same seed prompt through PLAIN and SPEC decode paths, returns both output distributions (top-K logits per position, or N sampled tokens per position). Coordinator computes empirical TV distance and publishes result as receipt metadata (SPEC-015 v0.4 extension) or telemetry.

## Scope — hard limits

- **Read-only research + SPEC drafting.** No code changes to coordinator, provider, verifier, or receipt schema. No PRs against `origin/main`.
- Do NOT modify SPEC-015 v0.4 (LOCKED settlement receipts). If receipt-adjacent state is needed, propose a v0.5 draft note or an out-of-band telemetry channel — do NOT draft the v0.5 in this SPEC.
- Do NOT re-scope SPEC-028. This is a companion.
- **Overt-canary only** in v0.1. Covert-canary indistinguishability is a v0.2 problem — call the seam, defer.

## Read first

1. `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`.
2. `specs/SPEC-028-*` — the speculative decoding SPEC this SPEC companions.
3. `specs/SPEC-015-*` v0.4 — settlement receipt tuple and `usage` schema; also `phase4-coordinator/internal/billing/settlement_verifier.go` (23-field tuple keys, `expected_catalog_model_hash` pinning).
4. `phase4-coordinator/` — where the coordinator issues requests to providers today; what routing seam a canary would use.
5. Shard's `phase0/specpipe.py --sample-test` upstream (fetch via WebFetch from `github.com/leyten/shard`) — the reference mechanism; note macprovider is single-node, so the swarm-ring analog is per-provider not per-stage.
6. `phase7-verify/` — the existing receipt verifier; may or may not consume this signal.

## Questions to answer (cite files:lines)

### A. Canary issuance mechanism
- Which coordinator subsystem should issue canaries? Cite the file. Options: piggyback on existing scheduled probe path (heartbeat cycle), new dedicated canary scheduler, or on-demand only.
- How does the provider know a request is a canary and should run BOTH paths? Options: new WS message kind, request header, dedicated endpoint. Which is minimally invasive?
- Canary cadence: per hour? per model? per (provider, model) pair? Cite the tradeoff between coverage and cost.

### B. Output representation
- To compute empirical TV distance you need per-position distributions. Options: (i) top-K logits per position (cheap; requires provider to expose logits, MLX supports it); (ii) N iid sampled tokens per position (expensive but no logit exposure). Which is right for macprovider? Cite.
- What K or N is required to bound TV-distance estimation error to ≤ ε₁? Statistical justification, not just a number.
- Wire cost: how much extra bandwidth does a canary payload add? Cite request-per-second budget.

### C. TV-distance computation
- Where does the computation live — provider-side (returns single scalar; smaller wire), coordinator-side (returns raw distributions; auditable but expensive), or both (coordinator recomputes as verification)? Cite security tradeoff.
- What ε threshold triggers a warning vs. a quarantine? Statistical justification.
- How is the threshold model-dependent? (Different models have different intrinsic sampling variance.)

### D. Publishing surface
- SPEC-015 v0.4 `usage` schema extension: can a `losslessness_tv_distance` float fit as a JCS-canonical extension without breaking v0.4 verifiers? Cite `v04SettlementUsageKeys` and JCS rules.
- If v0.4 backward-compat prevents extension: propose exact receipt v0.5 shape delta OR an out-of-band telemetry channel; say which. Justify.
- Where does the per-provider aggregate live? (Buyer-facing dashboard? Public directory?)

### E. Temperature range
- SPEC-028 flag surface: how does the buyer set temperature? Cite. Does the canary probe iterate across a temperature grid (e.g., `{0.0, 0.2, 0.5, 0.7, 1.0}`) or only sample the buyer-typical value?
- What's the receipt/telemetry shape when TV is reported per-temperature vs. aggregate?

### F. Interaction with SPEC-011 warm-swap
- If a provider warm-swaps model mid-probe, does the canary fail loudly or silently invalidate? Cite the safe semantic.
- Should model swap trigger an immediate canary against the newly-loaded model? Cite trust tradeoff.

### G. Covert-canary seam (out of scope for v0.1)
- Sketch what would need to change for covert canaries to be indistinguishable from buyer traffic. Do NOT design it. Just name the seam.

## Deliverables

Branch `research/losslessness-probe` off `origin/main`, three artifacts:

1. **`docs/research/losslessness-probe-2026-07.md`** — research memo answering §A–G with citations.
2. **`specs/SPEC-XXX-losslessness-probe.md`** v0.1-draft — normative FRs (canary issuance, output shape, TV computation, publishing surface, threshold semantics), non-goals (covert canary, compute-integrity companion — those are separate SPECs), open questions, acceptance criteria.
3. **`.omc/logs/losslessness-probe-open-questions-2026-07.md`** — maintainer-input list (ε threshold, temperature grid choice, publish surface decision).

## Definition of done (this research session)

- Every §A–G question answered.
- Statistical justification for K/N and ε (not asserted values).
- Publishing surface decision made — receipt v0.5 field name and type, OR out-of-band channel name.
- SPEC draft passes self-review round.
- No code changes.

## Do NOT

- Modify SPEC-015 v0.4, SPEC-022, or SPEC-028.
- Design covert-canary indistinguishability in v0.1.
- Scope compute-integrity-against-reference in this SPEC (separate SPEC handles it).
- Introduce a dependency on shard's `phase0/specpipe.py` upstream — reuse the mechanism, do not reuse the code.
