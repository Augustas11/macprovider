# SPEC-017 IMPL prompt — ARCH lane audit, Round 1 (Codex, 2026-06-26T03:24:52Z)

## Summary
- 1 CRITICAL finding
- 5 HIGH findings
- 3 MEDIUM findings
- 1 LOW finding
- 2 INFO

The IMPL prompt is close to a usable four-step implementation kickoff, but it is not ready to hand to a fresh author unchanged. The main blockers are not SPEC defects: they are prompt instructions that would either violate the locked privacy invariant, soften the step/audit/PR discipline, or make the step boundaries non-mechanical.

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | HIGH findings H2, H3, H4; MEDIUM finding M3 |
| B. Prerequisite coverage | MEDIUM finding M1 |
| C. Cross-step structural integrity | HIGH findings H2, H4 |
| D. PR strategy | HIGH finding H1 |
| E. Audit-loop discipline | HIGH finding H5 |
| F. SPEC-prompt fidelity | CRITICAL finding C1; HIGH finding H4; LOW finding L1 |
| G. Honesty about scope | HIGH finding H3; MEDIUM finding M2 |

## CRITICAL findings

C1. Step 4's visibility-toggle runbook admits an operator exact-mode path forbidden by the locked SPEC
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 141-146; controlling SPEC §6.6.3 lines 1171-1181; AC-20 lines 1836-1838.
   **Finding:** Step 4 asks for OPS.md entries covering "flipping a provider from `bucketed` → `exact` via the SPEC-014 v0.9 portal (or operator CLI fallback for emergencies)." The parenthetical permits an operator CLI fallback for the exact-enable direction. The locked SPEC says an operator MUST NOT flip a provider to `exact`; any `new_mode = 'exact'` audit row with `actor_kind = 'operator'` is a contract violation.
   **Why it matters:** This would cause the IMPL author to ship operator tooling or runbook text that violates the privacy/consent invariant behind bucketed-default earnings. It directly undermines AC-20 and the locked Q3 design pick.
   **Suggested fix:** Rewrite the Step 4 runbook bullet to: exact enable is only via a provider-authenticated SPEC-014 v0.9 flow, or a test fixture that records `actor_kind = 'provider'`; emergency operator tooling may only force `exact` → `bucketed`, never `bucketed` → `exact`. Add an explicit Step 4/AC-20 test that an operator exact-enable attempt is rejected or absent.

## HIGH findings

H1. One-PR-per-step and rebase discipline are described as recommended, not mandatory/mechanical
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 29-34, 157-168, 224-239; SPEC-016 analog lines 1209-1233.
   **Finding:** The prompt says the PR grouping "mirrors the steps 1:1" as "recommended" and says to rebase each PR, but it lacks SPEC-016's concrete branch/merge/reset workflow and does not explicitly forbid combining steps, opening a PR from a stale base, or merging a later step before the prior step has landed.
   **Why it matters:** The user's constraint makes one-PR-per-step and rebase ordering load-bearing after `pr-rebase-silent-dependency-regression`. Soft wording is enough for a fresh session to collapse two steps or stack on stale pre-squash commits, losing the intended audit boundary.
   **Suggested fix:** Add a "PR workflow" section matching SPEC-016's specificity: create `impl/spec-017-step-N` from the merged tip of step N-1, one PR per step is mandatory, `git fetch origin && git rebase origin/main` before push/open, step N+1 must not open until step N is squash-merged and local main reset to `origin/main`.

H2. Step 1's import-graph lint conflicts with Step 2's rollup imports
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 39, 59, 67; controlling SPEC §4.2 lines 400-407 and §7.6 lines 1390-1401; AC-16 lines 1815-1819.
   **Finding:** Step 1 tells the author to enforce a CI rule rejecting `internal/stats/* → internal/billing|internal/explorer|internal/ws`. Step 2 then creates `internal/stats/rollup/` and says it MAY import billing/session/pool read-only. A recursive `internal/stats/*` deny rule would fail Step 2; weakening it later would silently mutate the Step 1 boundary.
   **Why it matters:** This is a cross-step structural break. Either Step 2 cannot go green independently, or the implementation dilutes AC-16 after the schema PR has supposedly converged.
   **Suggested fix:** Rewrite the lint instruction to distinguish request-path packages from the rollup package: deny billing/explorer/ws/auth imports from `internal/stats/handlers`, `internal/stats/store`, and any request-path package; separately assert `internal/stats/rollup` is not imported by handlers/store and may only read approved source packages through the `stats_rollup` role.

H3. Step 3 claims ownership of every AC, including Step 1/Step 4 and SPEC-014-candidate ACs
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 113-121; Step 1 tests lines 53-59; Step 4 tests lines 148-153; controlling SPEC AC-1 through AC-21 lines 1763-1842.
   **Finding:** Step 3's tests say "every AC-1 through AC-21" must have deterministic fixture-driven tests. That improperly pulls Step 1 role/isolation ACs, Step 4 CLI/nginx ACs, and AC-10/AC-20 provider-visibility audit behavior into the handler PR. The prompt also does not explicitly assign AC-10 and AC-20 to a concrete test harness if SPEC-014 v0.9 has not landed.
   **Why it matters:** The step boundary loses audit-lens benefit: Step 3 either blocks on future Step 4/SPEC-014 surfaces or fakes them in a way that can diverge from the later implementation. AC-10/AC-20 are privacy/consent checks and cannot be hidden behind a generic "all ACs" sentence.
   **Suggested fix:** Add an explicit AC-to-step matrix. Suggested ownership: Step 1 covers AC-9, AC-16, and DB-fixture coverage for AC-19/AC-20; Step 2 covers rollup freshness/late/drift prerequisites; Step 3 covers AC-1-7, AC-11-15, AC-18, AC-19, AC-21 with seeded tables; Step 4 covers AC-8, AC-17, nginx smoke, and an end-to-end AC sweep on merged main. For AC-10, state that SPEC-017 IMPL verifies the transaction shape via a provider_portal-role fixture unless the SPEC-014 v0.9 handler exists.

H4. SPEC-014/UI follow-up scope is ambiguous enough to become a hidden implementation dependency
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 145, 178-181, 237-249; controlling SPEC §1.4 lines 165-178, §6.3 lines 1077-1097, §11 Q12 lines 1906-1916.
   **Finding:** The prompt correctly says SPEC-014 v0.9 owns the visibility-toggle UI, but later Step 4 and final done criteria refer to portal rendering, console rendering, and flipping via the SPEC-014 v0.9 portal without stating these are non-blocking when that follow-up has not landed.
   **Why it matters:** This can cause scope creep into SPEC-014 or the unresolved canonical UI consumer question Q12. A fresh implementation session could decide it must build portal/console UI to finish SPEC-017, silently closing v0.2 questions in code.
   **Suggested fix:** Add a hard sentence: SPEC-014 v0.9 and the canonical UI consumer are not prerequisites for SPEC-017 IMPL; SPEC-017 ships storage, API behavior, and compatibility smoke only. If no UI consumer exists at merge time, record Q12 as a follow-up and do not block the API PRs.

H5. Audit convergence target is weaker than the implementation severity model and SPEC-016 precedent
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 61, 89, 123, 155, 157-168, 240-243; SPEC-016 analog lines 396-401 and 1055-1065.
   **Finding:** The prompt loops audits until `0 CRITICAL + 0 MAJOR` and says MINOR may be deferred. This audit's severity model is CRITICAL/HIGH/MEDIUM/LOW, and SPEC-016's implementation prompt required 0 CRITICAL / 0 MAJOR / 0 MEDIUM before PR.
   **Why it matters:** For a public partner API with wire contracts, role isolation, privacy toggles, and partner keys, deferring MEDIUM-class ambiguity can create two conforming implementations or a first-month v0.2 patch. The user's constraint says weakening the per-step/lane audit loop is HIGH.
   **Suggested fix:** Standardize the prompt to `0 CRITICAL + 0 HIGH + 0 MEDIUM` for this audit vocabulary, or `0 CRITICAL / 0 MAJOR / 0 MEDIUM` if the step audit prompts keep SPEC-016's naming. LOW findings may be deferred only with explicit tracking.

## MEDIUM findings

M1. The hard pre-flight gates overstate decisions that the locked SPEC already resolves or treats as cutover-time configuration
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 16-27; controlling SPEC §7.1 lines 1188-1198 and §9.7 lines 1728-1753.
   **Finding:** Items 1 and 2 are marked hard pre-code gates. Hostname pattern is already pinned to "both" by §7.1, and backfill supports Path A default plus Path B opt-in without requiring code to choose only one.
   **Why it matters:** A fresh IMPL session may block unnecessarily or invite a v0.1.7 re-open before writing code. The code should implement both-host behavior and both backfill modes, with operator choice applied at cutover/config.
   **Suggested fix:** Make hostname a confirmation of the locked default, not a decision gate. Make backfill a required implementation of Path A default plus Path B option; operator selection is needed before production cutover, not before Step 2 coding.

M2. The prompt hides the likely audit-round cost compared with the closest analog
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 29-34 and 157-168; SPEC-016 analog lines 1177-1195.
   **Finding:** SPEC-016 includes a budget/cadence section with expected audit rounds. SPEC-017 says "4 steps + 4 audit loops" but does not state that three lanes per step can mean roughly 12 audit surfaces plus re-audits.
   **Why it matters:** This does not change the contract, but it undercuts planning honesty for a partner-facing surface. Operators may expect four quick reviews rather than per-step ARCH/CODE/SECURITY convergence.
   **Suggested fix:** Add a short budget section: four PRs, three lanes per PR, expect 1-3 rounds per lane depending on findings, and do not schedule public cutover until all lane convergence files exist.

M3. Step 4 is viable as one PR only if it has internal sub-seams
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 125-155.
   **Finding:** Partner-key CLI, nginx config, and observability/runbooks are different operator surfaces. Keeping them in one final ops PR is reasonable, but the prompt lacks sub-checklists that prevent nginx/rate-limit work from masking CLI secret-handling or observability gaps.
   **Why it matters:** Two conforming Step 4 authors could organize verification differently, and the SECURITY lane may over-focus on the CLI while missing nginx cache/rate-limit behavior.
   **Suggested fix:** Keep one PR, but split Step 4 audit scope into three required subsections: partner-key CLI lifecycle, edge/nginx/rate-limit behavior, and observability/runbook/changelog.

## LOW findings

L1. Some handler test bullets rely on the generic AC sweep instead of naming SPEC-pinned edge cases
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 95-121; controlling SPEC AC-2 lines 1766-1768 and AC-13 lines 1805-1808.
   **Finding:** The handler section names `limit=0/101`, 304, timing, 405, and log redaction, but does not explicitly name `window` defaulting to `24h` or the full AC-13 preflight header set including empty body. The generic "AC-1 through AC-21" sentence covers them, but that sentence is already over-broad per H3.
   **Why it matters:** This is easy to fix and improves deterministic test authorship.
   **Suggested fix:** Add those edge cases to Step 3's handler-specific test bullets after H3's AC matrix rewrite.

## INFO

I1. Step 4's one-PR grouping is acceptable if H1/H5/M3 are fixed. SPEC-016's final step also bundled operational surfaces, and SPEC-017 is structurally simpler.

I2. The §6 deferral list includes Q1 through Q13. I found no missing §11 question in `BUILD_SPEC_017_IMPL_PROMPT.md` lines 203-215.

## Operator questions

q1. None requiring operator design input. All findings above are prompt rewrite issues against the locked SPEC; they do not require reopening SPEC-017 v0.1.6.

## Verdict

- READY WITH FIX PASS

The IMPL prompt should not be locked until the CRITICAL privacy/runbook wording is removed and the HIGH step/audit/PR issues are rewritten. No additional SPEC design round is needed if the fix pass stays within the locked v0.1.6 contract.

## Self-verification
- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read `SPEC-017-network-stats-api.md` v0.1.6 fully.
- [x] Read `BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` and compared structure for drift.
- [x] Read `SPEC-017-advisor-round-2026-06-25.md`.
- [x] Skimmed `SPEC-017-r1-audit.md` through `SPEC-017-r7-audit.md` for closure rationale.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions in the prompt.
- [x] Location line range included on every finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.
