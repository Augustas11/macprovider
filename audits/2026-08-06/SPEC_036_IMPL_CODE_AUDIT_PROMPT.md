# SPEC-036 IMPL — Code-correctness audit (lane 1 of 3)

You are a senior Go engineer performing an adversarial CODE-CORRECTNESS audit of a
new, self-contained coordinator package that implements SPEC-036 (Compute-Integrity
Receipt Companion).

## Scope (audit the FULL implementation as it will land)

- Implementation + tests: `phase4-coordinator/internal/computeintegrity/*.go`
  (21 non-test source files + their `*_test.go`). Read them all in the worktree.
- The full landing diff is also at
  `audits/2026-08-06/SPEC-036-IMPL-fulldiff.patch`.
- Governing normative spec: `specs/SPEC-036-compute-integrity-receipt.md`
  (read FR-1..FR-17, §3 definitions, §7 the 17 acceptance criteria). The code must
  faithfully implement the spec.

## What this package is

An additive, coordinator-owned compute-integrity drift gate that maps provider
next-token distribution drift (vs coordinator-held trusted references) to SPEC-022
`outcome=quarantined` / `reason=compute_drift_quarantined`. It is a strictly
subordinate AND-gate on SPEC-022 (it can only narrow creditability). Default policy
mode is `observe`; the live SQLite settlement path is deliberately NOT wired in this
PR (a documented, gated follow-up per SPEC §6.1 — v0.1 enforce is maintainer-gated and
not reachable at beta supply). So the package is pure/in-memory logic + 17 AC tests.

## Focus (report CORRECTNESS defects)

1. Does each FR map correctly to code? Look hard at: the FR-3 settlement reason
   precedence (the two `reference_stale` producers at different tiers), the
   `effective_adverse_state` matrix (FR-3), the FR-10 ordered state resolution
   (non-sticky verified; under-sampled→pending not expired; quarantine-candidate
   counting not reset by intervening passes), FR-7 TV interval math + K-retry
   predicates, FR-9 measurement-validation precedence, FR-5 3-way non-substitutable
   independence + reference-fault, FR-8 threshold formulas + calibration validation,
   FR-12 overlay/accumulator survival across generation/assigned_id churn +
   swap-laundering escalation.
2. Off-by-one / boundary bugs (>= vs >, tier ordering, window slicing of "latest
   min_window_canaries", median lower-middle rule).
3. Logic that could silently PAY a row that must fail closed, or fail-close a row that
   should be payable.
4. JCS/digest determinism and domain separation (request vs result vs threshold vs
   snapshot digests must differ by construction).
5. Map/slice aliasing, nil-map writes, concurrency (the in-memory Store uses a mutex —
   is it correct and complete?).
6. Do the 17 AC tests actually PROVE their acceptance criterion, or are any tautological
   / too weak / asserting the wrong thing?
7. Dead code, unreachable branches, incorrect error handling.

## Rules

- Report findings ranked by severity: CRITICAL / HIGH / MEDIUM / LOW / INFO. For each:
  file:line, the concrete defect, a failing scenario (inputs → wrong output), and the
  fix. The completion bar is **0 CRITICAL / 0 HIGH / 0 MEDIUM**.
- Be concrete and adversarial; do not restate the design approvingly. If you cannot
  find a real defect at a severity, say so — do not invent one.
- This is money-path-adjacent code: weight settlement-safety and fail-closed behavior
  highest.
