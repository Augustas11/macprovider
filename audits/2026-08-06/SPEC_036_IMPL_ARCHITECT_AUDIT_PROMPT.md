# SPEC-036 IMPL — Architecture / spec-fidelity audit (lane 3 of 3)

You are a staff engineer performing an ARCHITECTURE + SPEC-FIDELITY audit of a new
coordinator package implementing SPEC-036 (Compute-Integrity Receipt Companion).

## Scope

- `phase4-coordinator/internal/computeintegrity/*.go` (+ tests). Full landing diff:
  `audits/2026-08-06/SPEC-036-IMPL-fulldiff.patch`.
- Normative spec: `specs/SPEC-036-compute-integrity-receipt.md`.
- Repo conventions: `phase4-coordinator/CLAUDE.md` / root `CLAUDE.md` coding
  principles (simplest impl; longevity on interfaces/wire/state; grow in layers;
  compatibility carve-out for money-path/persisted/external surfaces).

## Context / deliberate scoping decisions to evaluate

- The package is self-contained pure/in-memory logic + 17 AC tests. The live SQLite
  settlement orchestrator and payout SQL views are deliberately NOT mutated in this PR
  (default mode `observe`; SPEC §6.1 says v0.1 enforce is maintainer-gated and not
  reachable at beta supply). Assess whether this scoping is sound and honestly bounded,
  or whether it leaves a load-bearing gap that makes the package misleading.
- JCS canonicalizer is duplicated from `internal/billing/jcs.go` (ported byte-compatible)
  to avoid an import cycle when the gate later wires into billing. Assess this tradeoff
  vs extracting a shared leaf package.

## Focus (report ARCHITECTURE / FIDELITY defects)

1. **Spec fidelity gaps:** any FR requirement or §7 acceptance criterion that is NOT
   actually implemented, or implemented in a way that contradicts the spec's intent
   (not just its letter). Is the money-path AND-gate (`ApplyGate`) semantics correct —
   never relaxes a SPEC-022 non-creditable outcome, never promotes to payable?
2. **Interface/data-model longevity:** are the key algebra (window/overlay/threshold/
   swap-laundering keys), the wire envelopes (`compute_integrity_probe_v1`), the
   threshold record, and the capture struct designed to last, or is there a stopgap
   that will need breaking changes? Wire/digest preimages are settlement-bearing.
3. **Missing seams:** is the package actually usable by the coordinator (does it expose
   the right entry points for a future settlement-wiring PR), or is it an island?
4. **Test topology:** do the 17 AC tests map 1:1 to §7 and cover the load-bearing
   invariants, or are there conspicuous coverage holes (e.g. an FR with no test)?
5. **Consistency / duplication / dead abstractions;** anything over-engineered vs the
   "simplest implementation" principle, or under-built vs "longevity on interfaces".
6. **Naming / cohesion** that would confuse the next implementer.

## Rules

- Findings ranked CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line (or "package-level"),
  the concrete gap, why it matters for a money-path release, and the fix. Bar:
  **0 CRITICAL / 0 HIGH / 0 MEDIUM**.
- Judge against the spec's INTENT and the repo principles, not surface polish. If a
  dimension is genuinely sound, say so rather than inventing a finding.
