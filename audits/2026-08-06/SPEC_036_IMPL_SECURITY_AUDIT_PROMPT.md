# SPEC-036 IMPL — Security / money-path audit (lane 2 of 3)

You are a security engineer performing an adversarial SECURITY + MONEY-PATH audit of a
new coordinator package implementing SPEC-036 (Compute-Integrity Receipt Companion).

## Scope

- `phase4-coordinator/internal/computeintegrity/*.go` (+ tests). Read them in the
  worktree. Full landing diff: `audits/2026-08-06/SPEC-036-IMPL-fulldiff.patch`.
- Normative spec: `specs/SPEC-036-compute-integrity-receipt.md` (FR-1..FR-17, §3, §7).

## Threat model to attack

SPEC-036 is a subordinate AND-gate on SPEC-022 paid settlement. A malicious provider
wants to get PAID while serving a drifted/swapped model; a malicious actor wants to
launder an adjudicated quarantine, or make an honest provider fail closed. Settlement
is a pure function of the immutable FR-4 request-start capture.

## Focus (report SECURITY / money-path defects)

1. **Can any code path settle a covered enforce row PAYABLE when it must fail closed?**
   Trace `Evaluate` (settlement.go) exhaustively: unreadable/breaker-inconsistent/
   unknown-admissibility/uncovered-profile/blocked/expired/pending must never be
   payable in enforce; only fresh verified/warn with admissible refs and no breaker.
2. **Replay / nonce / expiry / digest binding** (FR-6): probe request/result digest
   domain separation; duplicate-digest replay; identity echo binding; the K=256
   `retry_of_probe_id` binding (can a provider substitute a different measurement on
   retry?); can a provider supply reference-side probabilities (must be coordinator-
   recomputed)?
3. **Laundering (FR-12):** can an assigned_id/target_generation/admission-key churn
   reset accumulators or shed an active quarantine? Does request-start capture consult
   the swap-laundering overlay BEFORE the per-key overlay? Can artifact-cycling escape
   provider-attributable risk? Is the escalation trigger correct (benign reconnect /
   same-hash reload exempt; risky change escalates)?
4. **effective_adverse_state matrix (FR-3):** can a `telemetry_only` state ever block
   money, or an `enforce_preserved` provider/breaker state ever be wrongly dormant
   while SPEC-022 still enforces? Observe must behave identically to warn_only.
5. **Reference independence (FR-5):** can two non-independent references (shared
   operator / failure domain / runtime-build) satisfy quorum? Is golden-fixture ever
   allowed to substitute for the 3-way independence? Missing provenance / missing
   golden fixture must each independently fail admission.
6. **Fund/accounting (FR-17):** any path that could create buyer debit / provider
   credit / uncapped reward from probe/reference/consensus work.
7. **Fail-open on unknown enum values** anywhere (must fail closed to unreadable).
8. Auditor bundle leaking raw prompts/output (FR-13).

## Rules

- Findings ranked CRITICAL/HIGH/MEDIUM/LOW/INFO with file:line, a concrete exploit
  scenario (attacker inputs → unearned payment / laundered quarantine / false
  fail-closed), and the fix. Bar: **0 CRITICAL / 0 HIGH / 0 MEDIUM**.
- Adversarial and concrete. Do not invent findings; if a class is clean, say so.
