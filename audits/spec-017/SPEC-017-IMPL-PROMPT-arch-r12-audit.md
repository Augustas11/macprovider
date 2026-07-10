# SPEC-017 IMPL prompt — ARCH lane audit, Round 12 (Codex, 2026-06-26T05:59:55Z)

## Summary
- 0 CRITICAL findings
- 0 HIGH findings
- 0 MEDIUM findings
- 3 LOW findings
- 2 INFO

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | PASS. The v14 CORS row-number edit is confined to Step 3 handler/CORS guidance and does not move handler, schema, rollup, nginx, CLI, or ops responsibilities across step boundaries. |
| B. Prerequisite coverage | PASS. Hostname/backfill confirmation, SPEC-016 re-check, provider-identity trust, and the SPEC-014 surface split remain code-gate vs cutover-gate accurate. |
| C. Cross-step structural integrity | PASS. Step 3 still consumes Step 1 schema/fixtures and Step 2 snapshots/config without requiring Step 4 CLI/nginx first; Step 4 nginx remains downstream of handler semantics. |
| D. PR strategy | PASS. One PR per step, squash-merge/reset, and rebase-before-next-step rules remain explicit and ordered. |
| E. Audit-loop discipline | PASS. Every step still requires ARCH, CODE, and SECURITY lanes converged to 0 CRITICAL + 0 HIGH + 0 MEDIUM before PR. |
| F. SPEC-prompt fidelity | PASS with unchanged LOW cleanup. The corrected CORS text now matches locked SPEC §5.7 row semantics: anonymous public row 2 may emit `*`; partner-key projection rows must not. |
| G. Honesty about scope | PASS. The prompt still states the 4 PR / 12-36 audit-round cost, final AC sweep, and production partner-key issuance cutover gate clearly. |

## CRITICAL findings
None.

## HIGH findings
None.

## MEDIUM findings
None.

## LOW findings

L1. Stale "21 ACs" prose remains after AC-22 was added.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:689`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:744`; controlling SPEC AC-22 at `specs/SPEC-017-network-stats-api.md:2333`.
   **Finding:** The prompt still says `AC-1..AC-21 fixture work` and "21 ACs", even though SPEC-017 v0.1.8 has AC-1 through AC-22. The binding AC matrix and final checklist include AC-22, so this is stale prose rather than missing coverage.
   **Why it matters:** A fresh IMPL author is unlikely to drop AC-22, but stale counts create avoidable audit churn.
   **Suggested fix:** Change both references to `AC-1..AC-22` / "22 ACs", or remove the hardcoded count.

L2. Stale "burst" wording remains after the no-burst v0.1.8 limiter decision.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:74`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:644`; controlling SPEC rate-limit contract at `specs/SPEC-017-network-stats-api.md:1111`.
   **Finding:** Operative nginx and middleware text correctly forbids `burst=`, but labels still say "fail-closed burst" and "Burst behavior."
   **Why it matters:** This does not authorize burst semantics, but it is confusing vocabulary on a surface the SPEC intentionally made hard-limit/no-burst.
   **Suggested fix:** Rename to "fail-closed hard-limit behavior" and "No-burst threshold behavior."

L3. Required-reading pointer for SPEC-006 header stripping references the wrong section.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:750`.
   **Finding:** The prompt points readers to "SPEC-006 §17 header strip / X-MacProvider-* allowlist." In the current checked-in dependency, the relevant header-strip and response-header allowlist material is not at §17.
   **Why it matters:** This does not alter SPEC-017 behavior, but it sends the IMPL author to a stale dependency location during required reading.
   **Suggested fix:** Update the pointer to the current SPEC-006 header-strip / response-header allowlist sections after re-checking the dependency line-3 version at IMPL time.

## INFO

I1. The v14 CORS row-number fix does not introduce an ARCH regression.
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:385-390`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:496`; controlling SPEC CORS table at `specs/SPEC-017-network-stats-api.md:1183-1191`.
   **Observation:** The prompt now says partner-key projection rows 3, 4, and 5 must never emit `Access-Control-Allow-Origin: *`, while explicitly preserving `ACAO: *` on the public no-key `/leaderboard` row 2. That closes CODE r12 H1 without creating a new architecture-level split or step leak.

I2. The audit request names SPEC-017 v0.1.6, but HEAD now contains SPEC-017 v0.1.8 as locked.
   **Location:** `specs/SPEC-017-network-stats-api.md:3`, `specs/BUILD_SPEC_017_IMPL_PROMPT.md:19`.
   **Observation:** I audited against v0.1.8 because the checked-in SPEC and IMPL prompt both identify v0.1.8 as the locked controlling contract. The v0.1.8 additions, including Shape C, no-burst hard limits, Authorization-aware nginx keying, and AC-22, remain reflected in the prompt.

## Operator questions
None.

## Verdict
- READY TO LOCK

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Read SPEC-017-r1-audit.md through SPEC-017-r7-audit.md.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location (line range) on every finding.
- [x] Suggested fix for every CRITICAL and HIGH finding.
- [x] Verdict at end.

## 200-word handback summary
Round 12 finds no new CRITICAL, HIGH, or MEDIUM architecture issue in the SPEC-017 IMPL kickoff prompt. The v14 CORS edit fixes the CODE r12 row-number problem cleanly: anonymous public `/leaderboard` row 2 is still allowed to emit `Access-Control-Allow-Origin: *`, while successful partner-key projection rows 3, 4, and 5 are correctly called out as never-star responses. That correction stays inside Step 3 handler/CORS guidance and does not disturb Step 1 schema/grants, Step 2 rollup production, or Step 4 nginx/ops ownership.

The four-step decomposition remains viable as a one-PR-per-step series. The prompt preserves the locked design picks: separate rollup pipeline, public overview plus optional partner keys, bucketed-default earnings with opt-in exact, and coordinator-binary embedding. PR sequencing, rebase discipline, and per-step three-lane audit convergence remain explicit and mechanically checkable.

Only unchanged LOW hygiene items remain from ARCH r11: stale "21 ACs" prose despite AC-22, stale "burst" labels after the no-burst v0.1.8 limiter decision, and a stale SPEC-006 section pointer. They do not block implementation, cutover planning, step audit prompt authoring, or the audit-loop handoff, and they can stay deferred under the user's LOW-skipping instruction. No fix prompt was drafted, and no SPEC change is recommended from this pass. Verdict: READY TO LOCK.
