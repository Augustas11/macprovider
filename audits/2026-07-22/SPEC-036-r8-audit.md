# SPEC-036 — Round-8 codex verification + subordination/preserved-state matrix

**Date:** 2026-07-22 · **Reviewed revision:** `ffe89f5e`

## Round-8 result (codex; Claude lanes converged to 0 C/H/M at R7)

| Lane | C | H | M |
|---|---:|---:|---:|
| codex code | 0 | 3 | 3 |
| codex security | 0 | 1 | 0 |
| codex architect | 0 | 1 | 3 |

All three codex lanes converged on ONE root design tension: the R6/R7
preserved-adverse-state exception conflicted with the core SPEC-022 subordination
(FR-3) — the same `quarantined`/`blocked` value could be telemetry-only or
money-blocking with no stored provenance, and "SPEC-036 has no effect when SPEC-022
isn't enforce" contradicted "preserved state keeps blocking under warn_only."

Per the repo's audit discipline (audit-as-design-discovery; stop patching and rethink
the churning interaction), this round makes ONE decisive reconciliation rather than
another patch.

## Fixes
- **Authoritative mode × origin matrix (FR-3):** every overlay/breaker adverse state
  carries an immutable `adjudication_origin` (`enforce_preserved` | `telemetry_only`),
  captured+digested in FR-4. A state's money/routing EFFECT is active iff
  origin=enforce_preserved AND provider-attributable/breaker AND the SPEC-022
  conjunction is currently true. A SPEC-036-only downgrade keeps the conjunction true
  (preserved state still blocks — the R6/R7 fix); a SPEC-022 downgrade makes even
  enforce_preserved state dormant (SPEC-036 has no independent money authority),
  resuming on return to enforce; coordinator-attributable blocks are dormant for
  routing during an availability downgrade; telemetry_only never blocks. §3 warn-only
  exception, FR-16 breaker paragraph, and FR-12 aligned to the matrix.
- **provider_inconclusive identity contradiction (codex code-H):** the strict
  identity-equality rejection applies only to `measurement` results; a
  `provider_inconclusive` (e.g. model_swap) is the sanctioned changed/null-identity
  channel and maps via FR-9, not `identity_reject`.
- **Per-position generation binding (architect-M):** inherit SPEC-030 §FR-2; every
  measurement position result carries actual hash/generation; mixed-generation →
  `inconclusive:model_swap`.
- **FR-12 swap-laundering scoped to provider-attributable state** (not
  coordinator-attributable blocks).

## Convergence
The matrix resolves the churning subordination/preserved-state interaction with a
single provenance field and one gating rule. Round-9 confirms.
