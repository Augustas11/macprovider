# SPEC-017 IMPL prompt — ARCH lane audit, Round 10 (Codex, 2026-06-26T05:45:48Z)

## Summary
- 1 CRITICAL finding
- 1 HIGH finding
- 1 MEDIUM finding
- 1 LOW finding
- 1 INFO

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | CRITICAL C1. Step 1 now owns a schema/grant seam the locked SPEC does not permit; otherwise the 4-step split remains coherent, and Step 4 is viable as one PR because 4.A/4.B/4.C are explicit audit subsections. |
| B. Prerequisite coverage | HIGH H1. The SPEC-014 disclosure gate is mostly split correctly, but one Step 4.C convergence sentence still turns a production issuance gate into a PR/audit convergence gate. |
| C. Cross-step structural integrity | CRITICAL C1. Step 2/3 agree on `stats_rollup_state`, but the agreement is prompt-local and conflicts with the locked DB-role inventory. |
| D. PR strategy | No finding. One-PR-per-step, branch order, rebase before PR, and "Step N+1 MUST NOT open" are stated as mandatory. |
| E. Audit-loop discipline | No finding. The prompt requires ARCH/CODE/SECURITY for every step and converges at `0 CRITICAL + 0 HIGH + 0 MEDIUM`. |
| F. SPEC-prompt fidelity | CRITICAL C1, MEDIUM M1, LOW L1. The AC matrix maps AC-1 through AC-22, and §11 Q1-Q13 are present, but one stale v0.1.7 Shape A/B bullet and one stale "21 ACs" reference remain. |
| G. Honesty about scope | HIGH H1. Audit cost is explicit; final done criteria are mostly mechanical, but the Step 4.C sign-off wording is still not mechanically scoped to production partner-key issuance only. |

## CRITICAL findings
C1. `stats_rollup_state` adds a prompt-only `stats_*` table and grants outside the locked SPEC inventory

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 144-159, 167-170, 323, 351, 508; locked SPEC `SPEC-017-network-stats-api.md` lines 1574-1585, 1626-1648, 1654-1658, 1840-1848, 2187-2225.

   **Finding:** The v11 prompt fix pins a new `stats_rollup_state` table, gives `stats_rollup` `SELECT, INSERT, UPDATE` on it, and gives `stats_reader` `SELECT` on it. The locked SPEC's `stats_reader` grant list does not include that table, the locked `stats_rollup` grant list does not include it, and §7.2.2 explicitly says any non-OLTP additional grant added to `stats_rollup` is a contract violation. The table also uses the `stats_*` namespace even though SPEC §9.1 says every `stats_*` table is defined there.

   **Why it matters:** This would instruct the IMPL author to widen the DB-role contract without a SPEC change. That is a locked isolation invariant, not an implementation detail. The prompt repaired the Step 1/2/3 seam locally, but did so by creating architectural drift from the single controlling contract.

   **Suggested fix:** Remove `stats_rollup_state` and its grants from the IMPL prompt. Encode `partial_history_since` without widening §7.2 grants: for example, persist `stats.rollup.backfill_mode`, `stats.rollup.backfill_started_at`, and the operator-defined `all` floor in coordinator config, have Step 2 use that config for Path A/B behavior, and have Step 3 derive `partial_history_since` from config + requested window while querying only SPEC-granted tables. If the operator insists on DB-persisted rollup state, the prompt must STOP rather than author the table under the locked SPEC.

## HIGH findings
H1. Step 4.C still contradicts the intended SPEC-014 disclosure gate timing

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 76-84, 676-689, 822-825; locked SPEC lines 1494-1518.

   **Finding:** The pre-flight section correctly says the SPEC-014 §6.6.2 disclosure UI is not a Step 4.C PR convergence prereq, and the final done criteria correctly make it hard-blocking before first production partner-key issuance. But Step 4.C still says the cutover-runbook entry "MUST be a checked box" and the Step 4.C convergence file "MUST include the verbatim sign-off text." That can be read as requiring the live SPEC-014 v0.9 deployment SHA/date before the Step 4 PR can converge.

   **Why it matters:** This reintroduces the ARCH r9 gate ambiguity in a different location. A conforming IMPL author could block Step 4 PR merge on a live portal deployment that the locked SPEC scopes only to production partner-key issuance, causing avoidable step-sequencing drift and an unnecessary fix round.

   **Suggested fix:** Rewrite line 689 to: "The Step 4.C PR MUST add the runbook checkbox and verbatim sign-off template. The convergence file MUST quote that template and state whether live production sign-off is already satisfied; if not, it remains a cutover prerequisite before first production partner-key issuance, not a PR merge prerequisite."

## MEDIUM findings
M1. A stale v0.1.7 Shape A/B bullet remains labeled "still binding"

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 20-24, 27-45, 271-286.

   **Finding:** The v0.1.8 section correctly says Shape C is the only v0.1 default executable under locked grants. Later, the v0.1.7 context list says §9.4 pins Shape A or Shape B and labels the whole list "still binding." A full read resolves this in favor of v0.1.8, but the local wording is stale and contradictory.

   **Why it matters:** Nightly rebuild atomicity has already been an audit-sensitive seam. Stale "still binding" language increases the chance that an IMPL author or audit prompt repeats Shape A/B language even though the current locked default is Shape C.

   **Suggested fix:** Change the line-27 heading to "historical v0.1.7 deltas, superseded where v0.1.8 says otherwise" and mark the §9.4 Shape A/B bullet as superseded by Shape C for v0.1.8.

## LOW findings
L1. The required-reading list still says "21 ACs" after AC-22 was added

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 729, 742, 811, 819.

   **Finding:** The matrix and final checklist correctly name all 22 ACs, including AC-22, but the "Files you should read" bullet still says the locked SPEC has 21 ACs.

   **Why it matters:** Low polish issue only; the authoritative matrix is correct.

   **Suggested fix:** Replace "21 ACs" with "22 ACs."

## INFO
I1. Current locked contract is v0.1.8, not the audit task's stale v0.1.6 reference

   **Location:** locked SPEC lines 3-5; IMPL prompt lines 19-26.

   **Finding:** The user audit prompt says SPEC-017 v0.1.6 is locked, but the checked-in SPEC is v0.1.8 LOCKED and the IMPL prompt is anchored to v0.1.8. I treated v0.1.8 as the controlling contract.

## Operator questions
None.

## Verdict
- READY WITH FIX PASS

The prompt is not ready to lock while C1 remains. The fix can stay prompt-only if the prompt removes the new table/grants and derives `partial_history_since` from existing config/state without widening locked DB roles. If DB-persisted rollup state is deemed mandatory, implementation must stop rather than silently exceed the SPEC.

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-advisor-round-2026-06-25.md fully.
- [x] Read SPEC-017-r1-audit.md through SPEC-017-r7-audit.md.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location (line range) on every finding.
- [x] Suggested fix for every CRITICAL and HIGH finding.
- [x] Verdict at end.

## 200-word handback summary
ARCH r10 is a focused fix-pass audit, and the prompt is close but not lockable. The main blocker is the new `stats_rollup_state` seam: it gives Step 1 a concrete table and grants for Step 2/3, but the locked v0.1.8 SPEC does not grant either `stats_reader` or `stats_rollup` access to that table, and §7.2.2 explicitly treats non-OLTP extra grants to `stats_rollup` as a contract violation. That is CRITICAL because it tells the implementer to widen a locked role boundary from the IMPL prompt. The safe prompt fix is to remove that table/grant shape and derive `partial_history_since` from existing coordinator config or other already-granted state; if DB persistence is mandatory, implementation should stop rather than silently exceed the SPEC.

One HIGH remains: Step 4.C mostly separates SPEC-014 disclosure UI from PR merge, but a convergence-file sentence still reads as requiring live portal sign-off before the Step 4 PR can close. Rewrite it as a runbook template plus cutover gate. I also noted a stale Shape A/B v0.1.7 bullet and one stale "21 ACs" reference. No operator questions were raised; the next pass should be a narrow prompt rewrite only, not a SPEC rewrite or implementation draft yet. Verdict: READY WITH FIX PASS.
