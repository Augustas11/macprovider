# SPEC-017 IMPL prompt — ARCH lane audit, Round 7 (Codex, 2026-06-26T05:07:08Z)

## Summary
- 1 CRITICAL finding
- 2 HIGH findings
- 0 MEDIUM findings
- 0 LOW findings
- 2 INFO

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | FAIL. Step 2 now contains a non-SPEC rebuild shape, and provider-visibility/bucket semantics are not owned cleanly by the rollup step the SPEC pins. |
| B. Prerequisite coverage | FAIL. The prompt discovers a known §5.6/AC-8 production blocker inside Step 4.B instead of making SPEC reconciliation a kickoff/step-entry gate. |
| C. Cross-step structural integrity | FAIL. Step 3 owns AC-19 handler projection, but Step 2 is not told to prove the rollup's required `provider_visibility` left join and bucket boundary computation. |
| D. PR strategy | FAIL. One-PR-per-step is stated, but Step 4.B cannot open until a future SPEC version locks, making the Step 4 PR boundary non-viable as written. |
| E. Audit-loop discipline | PASS. Per-step ARCH/CODE/SECURITY lanes and `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence remain explicit. |
| F. SPEC-prompt fidelity | FAIL. Step 2 instructs Shape C before the locked SPEC admits Shape C; Step 4.B correctly rejects local divergence but leaves the full IMPL prompt knowingly unstartable. |
| G. Honesty about scope | MIXED. Audit cost is honest, but the prompt still presents full v0.1.7 IMPL as executable even though two named surfaces require SPEC v0.1.8 reconciliation. |

## CRITICAL findings

C1. Step 2 instructs a nightly rebuild shape that the locked SPEC does not allow
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:248-263`; locked SPEC `specs/SPEC-017-network-stats-api.md:1997-2020`, `:1511-1556`
   **Finding:** The prompt says SPEC §9.4 names Shape A and Shape B, notes both are not executable under the locked `stats_rollup` grants, then instructs the IMPL author to use "Shape C" until a future SPEC v0.1.8 candidate adds it. The locked SPEC still says two implementation shapes are acceptable and lists only A/B.
   **Why it matters:** This lets a fresh IMPL author ship rollup code outside the locked controlling contract. Shape C may preserve the high-level atomicity goal, but the current SPEC has not admitted it as an acceptable implementation shape. An IMPL prompt cannot extend locked §9.4 by instruction.
   **Suggested fix:** Remove the "MUST use Shape C" implementation directive from the v0.1.7 kickoff. Rewrite the prompt to hard-block Step 2 nightly rebuild implementation until the controlling SPEC reconciles §9.4 with §7.2.2, or scope Step 2 to non-rebuild rollup work with an explicit "not complete / no PR convergence" stop condition. Do not tell the IMPL author to implement Shape C before the SPEC locks it.

## HIGH findings

H1. Step 4.B's known SPEC conflict is not promoted to a kickoff or step-entry gate
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:537-545`, `:557-560`, `:622`, `:650`, `:723`, `:739`; locked SPEC `specs/SPEC-017-network-stats-api.md:1063-1071`, `:2144-2146`
   **Finding:** The prompt correctly says locked §5.6 and locked AC-8 are mechanically inconsistent under plain nginx and that Step 4.B production nginx config is hard-blocked until SPEC v0.1.8 reconciles them. But the top-level flow still presents "4 steps + 4 audit loops," one PR per step, all 21 ACs, and all four step PRs as the normal completion path.
   **Why it matters:** A fresh IMPL author can land Steps 1-3, start Step 4, and only then hit a non-code prerequisite that prevents Step 4.B convergence and full AC-8 verification. That breaks the load-bearing one-PR-per-step strategy and hides a controlling-contract prerequisite in the middle of a DevOps subsection.
   **Suggested fix:** Move the §5.6/AC-8 reconciliation into §1 as a hard pre-kickoff or at least pre-Step-4.B gate. If Steps 1-3 may proceed intentionally, rename the prompt as a partial IMPL kickoff and make the stop condition explicit: Step 4.B, AC-8, final AC sweep, and "all four PRs merged" cannot be claimed until the SPEC reconciliation has locked.

H2. Rollup ownership of provider visibility and bucket computation is under-specified
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:73`, `:181`, `:277-305`, `:431-451`, `:624-647`; locked SPEC `specs/SPEC-017-network-stats-api.md:1214-1223`, `:1262-1273`, `:2198-2205`
   **Finding:** The locked SPEC says the rollup MUST left-join `provider_visibility` when producing the leaderboard projection, and absent rows default to `mode='bucketed'` plus `blocked_from_partner_projection=false`. The prompt's AC-19 ownership and concrete assertions are Step 1 SQL fixture + Step 3 handler integration. Step 2 seeds visibility rows but does not require a rollup assertion that no-row/default/exact/bucketed visibility and §6.2 bucket boundaries are computed into `stats_leaderboard_*`.
   **Why it matters:** This blurs a load-bearing seam. One implementation could defer visibility/default logic to the handler and still pass the listed Step 3 projection tests against hand-seeded leaderboard rows, while another encodes the SPEC-pinned rollup join. That loses the Step 2 audit lane's ability to verify the separate rollup pipeline design pick.
   **Suggested fix:** Add Step 2 rollup requirements and tests: leaderboard refresh jobs MUST left-join `provider_visibility`, treat absence as bucketed/blocked=false, compute `earnings_bucket` from the stored `NUMERIC(18,2)` total per §6.2, and persist the exact/bucket source rows consumed by Step 3. Include boundary fixtures such as `$4.99`, `$5.00`, `$49.99`, and `$50.00`, plus no-row and explicit `bucketed`/`exact` rows. Keep Step 3 as projection/redaction verification, not the first place the defaulting semantics are proven.

## MEDIUM findings

None.

## LOW findings

None.

## INFO

I1. The prior ARCH r6, CODE r7, and SECURITY r4 blockers called out in the user note are otherwise absorbed: invalid Authorization no longer uses the public cache, Path R2 is removed, AC-15 is split by surface, SPEC-014 v0.9 disclosure semantics are separated, malformed-Origin expectations are pinned, the optional writer DSN is conditional, CLI operator DSN guidance exists, HEAD tests are present, and the pre-auth limiter is in the middleware stack.

I2. The four locked advisor picks remain preserved in the prompt: separate rollup pipeline, public overview plus optional partner-key leaderboard, bucketed-default earnings with provider exact opt-in, and coordinator-binary hosting.

## Operator questions

q1. None for the operator. The prompt needs to stop or re-scope around locked-contract reconciliation points; the operator should not be asked to choose local divergence from the locked SPEC.

## Verdict
- ANOTHER DESIGN ROUND NEEDED

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared process/step/audit structure.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r1-audit.md through SPEC-017-r8-audit.md for why locked MUSTs exist.
- [x] Reviewed the latest ARCH/CODE/SECURITY IMPL-prompt audits for closure continuity.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location line range included on every finding.
- [x] Suggested fix for every CRITICAL and HIGH finding.
- [x] Verdict included.
