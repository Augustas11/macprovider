# SPEC-017 IMPL prompt — ARCH lane audit, Round 11 (Codex, 2026-06-26T05:55:23Z)

## Summary
- 0 CRITICAL findings
- 0 HIGH findings
- 0 MEDIUM findings
- 3 LOW findings
- 2 INFO

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | PASS. The four-step split is orthogonal: Step 1 owns schema, grants, partner-key storage, and visibility tables; Step 2 owns the separate rollup pipeline; Step 3 owns embedded coordinator handlers/auth/rate semantics; Step 4 is explicitly subdivided into CLI, nginx, and ops/production-issuance surfaces without making those surfaces preconditions for earlier PRs. |
| B. Prerequisite coverage | PASS with LOW cleanup. Hostname, rollout/backfill, SPEC-016 dependency checks, and SPEC-014 follow-up scope are separated from hard IMPL gates. The prompt now makes SPEC-014 v0.9 non-blocking for v0.1.8 IMPL. |
| C. Cross-step structural integrity | PASS. Step 2 writes rollup snapshots and coordinator config inputs consumed by Step 3; Step 4 nginx examples now align with Step 3 per-endpoint limiter semantics; partner-key handler tests can run before the operator CLI by using database fixtures/operator DSNs. |
| D. PR strategy | PASS. One PR per step, squash-merge/reset, and rebase-before-next-step discipline are explicit and prohibit out-of-order Step N+1 work. |
| E. Audit-loop discipline | PASS. Each step requires ARCH, CODE, and SECURITY lanes with convergence to 0 CRITICAL + 0 HIGH + 0 MEDIUM before PR. The expected audit-round cost is stated plainly. |
| F. SPEC-prompt fidelity | PASS with LOW cleanup. The prompt preserves the four locked design picks and maps the public API, DB, auth, visibility, rate-limit, observability, and acceptance-test surfaces to steps. Residual stale prose references do not change the implementation contract. |
| G. Honesty about scope | PASS. The prompt describes the 4-step/12-36 audit-round cost, splits production partner-key issuance from Step 4.C PR convergence, and keeps done criteria mostly mechanically checkable. |

## CRITICAL findings
None.

## HIGH findings
None.

## MEDIUM findings
None.

## LOW findings

L1. Stale "21 ACs" prose remains after AC-22 was added.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:689`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:744`; controlling SPEC AC-21/AC-22 at `specs/SPEC-017-network-stats-api.md:2329` and `specs/SPEC-017-network-stats-api.md:2336`.
   **Finding:** The prompt still says "AC-1..AC-21 fixture work" and "21 ACs", even though SPEC-017 v0.1.8 has AC-1 through AC-22. The detailed acceptance-test mapping later includes AC-22, so this is a stale count rather than a missing test seam.
   **Why it matters:** A fresh IMPL author is unlikely to omit AC-22 because the Step 4 and final mapping sections include it, but stale counts create avoidable audit churn.
   **Suggested fix:** Change both prose references to "AC-1..AC-22" / "22 ACs", or remove the numeric count where the exact count is not needed.

L2. Stale "burst" wording remains after the no-burst v0.1.8 limiter decision.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:20`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:644`; controlling SPEC rate-limit contract at `specs/SPEC-017-network-stats-api.md:771`.
   **Finding:** The prompt correctly binds the implementation to the v0.1.8 no-burst model and says nginx must not use `burst=`, but two later labels still say "fail-closed burst" and "Burst behavior".
   **Why it matters:** The operative nginx and middleware instructions prevent an actual burst implementation, so this is not architectural drift. It is still confusing vocabulary for a rate-limit surface that the SPEC intentionally made no-burst.
   **Suggested fix:** Rename those labels to "fail-closed hard-limit behavior" and "No-burst hard-limit behavior".

L3. Required-reading pointer for SPEC-006 header stripping references the wrong section.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:750`; relevant SPEC-006 material appears at `specs/SPEC-006-macprovider.md:1067` and `specs/SPEC-006-macprovider.md:1729`.
   **Finding:** The prompt points readers to "SPEC-006 §17 header strip + allowlist". In the current checked-in SPEC-006 v0.9, the relevant request-header strip and response-header allowlist contract is in §5.4, with header-scrubbing guidance also in §8.3.
   **Why it matters:** This does not alter SPEC-017 behavior, but it sends the IMPL author to the wrong dependency location during final required reading.
   **Suggested fix:** Update the reference to "SPEC-006 §5.4 and §8.3 header strip + allowlist".

## INFO

I1. The audit request names SPEC-017 v0.1.6, but the repository now contains SPEC-017 v0.1.8 as the locked controlling contract.
   **Location:** `specs/SPEC-017-network-stats-api.md:3`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:19`.
   **Observation:** I audited against v0.1.8 because both the checked-in SPEC and current IMPL prompt identify v0.1.8 as locked. This matches the v13 fix-pass note and the AC-22/no-burst/per-endpoint-rate-limit changes.

I2. The r10/r11 blocking items called out by the user appear closed.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:144`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:158`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:429`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:437`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:572`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:641`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:691`.
   **Observation:** The prompt no longer creates a `stats_rollup_state` table or related grants, separates Step 4.C PR convergence from production partner-key issuance, marks v0.1.7 deltas historical/superseded, and adds per-endpoint middleware/nginx keying plus isolation tests.

## Operator questions
None.

## Verdict
- READY TO LOCK

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location (line range) on every finding.
- [x] Suggested fix for every CRITICAL and HIGH finding.
- [x] Verdict at end.

## 200-word handback summary
Round 11 finds no remaining CRITICAL, HIGH, or MEDIUM architecture issues in the SPEC-017 IMPL kickoff prompt. The v13 fix pass appears to have closed the prior blockers: `stats_rollup_state` is gone in favor of coordinator config for `partial_history_since` / `backfill_mode`; Step 4.C no longer blocks PR convergence on production partner-key issuance; v0.1.7 notes are now historical/superseded; and nginx plus middleware keying now preserve the v0.1.8 per-endpoint rate-limit contract, including AC-22 coverage.

The four-step decomposition is architecturally viable as a one-PR-per-step series. Step 1 owns schemas/grants/visibility, Step 2 owns the separate rollup pipeline, Step 3 owns embedded coordinator API handlers, and Step 4 owns operator CLI, nginx, and ops/runbook surfaces without forcing out-of-order dependencies. Audit-loop discipline is also aligned: every step requires ARCH, CODE, and SECURITY convergence to 0 CRITICAL + 0 HIGH + 0 MEDIUM before PR.

The only findings are low-severity cleanup: stale "21 ACs" prose after AC-22, stale "burst" wording after the no-burst limiter decision, and a SPEC-006 section pointer that should reference §5.4/§8.3 instead of §17. Verdict: READY TO LOCK.
