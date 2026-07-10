# SPEC-017 IMPL prompt — ARCH lane audit, Round 9 (Codex, 2026-06-26T05:38:21Z)

## Summary
- 0 CRITICAL findings
- 2 HIGH findings
- 1 MEDIUM finding
- 0 LOW findings
- 2 INFO

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | MIXED. The four-step split is still mostly coherent, but `partial_history_since` storage is not pinned in Step 1 even though Step 2 writes it and Step 3 reads it. |
| B. Prerequisite coverage | MIXED. Hostname, backfill, SPEC-016 re-check, provider-auth trust, and SPEC-014 surface split are mostly clear, but the final done list re-blurs the SPEC-014 disclosure gate. |
| C. Cross-step structural integrity | FAIL. Step 3 names `rollup_state.partial_history_since` without Step 1 schema/grants or a Step 2 write contract for that storage. |
| D. PR strategy | PASS. One PR per step, ordered squash-merge/rebase discipline, and Step N+1 gating remain explicit. |
| E. Audit-loop discipline | PASS. ARCH/CODE/SECURITY lanes and `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence remain mandatory. |
| F. SPEC-prompt fidelity | MIXED. Most v0.1.8 deltas are encoded, but the final SPEC-014 follow-up bullet can weaken the locked §6.6.2 production partner-key gate. |
| G. Honesty about scope | MIXED. Audit cost and Step 4 subsections are honest; the remaining risks are checklist ambiguity and one misleading rate-limit test sentence. |

## CRITICAL findings
None.

## HIGH findings

H1. `partial_history_since` storage crosses Step 1/2/3 without a pinned schema and grant seam
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:140-158`, `:278`, `:307`, `:335`; locked SPEC `specs/SPEC-017-network-stats-api.md:716-725`, `:2187-2225`
   **Finding:** Step 1 pins all stats schemas and role inventories, including the implementation-authored `rewards_populated` storage. It does not pin any storage or grants for `partial_history_since`. Step 2 then says Path A writes persisted rollup-state metadata, "e.g. a `rollup_state.partial_history_since` row, or equivalent persisted source the handler will read." Step 3 stops being generic and requires the handler to read `rollup_state.partial_history_since`.
   **Why it matters:** This is a load-bearing cross-step seam. A conforming Step 1 PR can merge with no table/grant for the value, a conforming Step 2 PR can choose an ungranted metadata shape, and Step 3 can then discover that its named `rollup_state` source does not exist or is not readable by `stats_reader`. That either pushes schema/grant work into the handler PR or forces a retroactive Step 1/2 fix, losing the audit-lane separation the prompt is trying to protect.
   **Suggested fix:** Pin the `partial_history_since` storage in Step 1 the same way the prompt pins `rewards_populated`: either define a concrete table such as `stats_rollup_state(window TEXT PRIMARY KEY, partial_history_since TIMESTAMPTZ, generated_at TIMESTAMPTZ)` with `stats_rollup` write grants and `stats_reader` read grants, or explicitly choose an existing-table denormalization. Then update Step 2 to write that exact source and Step 3 to read that exact source.

H2. Final done criteria re-blur the SPEC-014 disclosure gate as a non-blocking follow-up
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:76-84`, `:660-675`, `:786-790`, `:806-807`; locked SPEC `specs/SPEC-017-network-stats-api.md:1494-1518`
   **Finding:** The prerequisite section and Step 4.C correctly split the three SPEC-014-related surfaces: visibility-toggle UI is not a cutover gate, the canonical UI consumer is not a cutover gate, and the §6.6.2 disclosure UI is a hard gate before first production partner-key issuance. The final checklist then says "the three SPEC-014 follow-up items ... are documented in OPS.md as non-blocking follow-ups, not as cutover gates" immediately after saying the §6.6.2 gate is discharged.
   **Why it matters:** That final done list is the last instruction a fresh IMPL session sees before declaring completion. It can let the IMPL author or operator file the disclosure UI as merely non-blocking follow-up work, which contradicts the locked launch-sequencing precondition for production partner-key issuance. This does not require a SPEC change; it requires the prompt to keep the three SPEC-014 surfaces separated through the final checklist.
   **Suggested fix:** Replace the final bullet with an explicit split: visibility-toggle UI and Q12 canonical UI consumer are non-blocking follow-ups; §6.6.2 disclosure UI is non-blocking for public bucketed API cutover but BLOCKING before first production partner-key issuance, with the sign-off checkbox and verbatim sign-off text recorded.

## MEDIUM findings

M1. Valid-partner scoping test says the 501st request would be rejected under a 600 rpm tier
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:433-438`; locked SPEC `specs/SPEC-017-network-stats-api.md:1105-1121`
   **Finding:** The corrected auth-failure scoping test sends 500 valid partner-key requests in 60s and correctly requires all 500 to succeed under `rate_limit_rpm = 600`. The same bullet then says "The 501st request would be rejected by the partner tier (600 rpm)," which is mathematically inconsistent with a hard 600 req/min tier.
   **Why it matters:** The main assertion is good, so this is not a HIGH. But a fresh test author could copy the explanatory sentence into a 501st-request assertion and accidentally encode a partner tier lower than the locked 600 rpm contract. This is exactly the rate-limit boundary the v10 fix pass was meant to protect from the auth-failure limiter.
   **Suggested fix:** Change the sentence to "The 601st request would be rejected by the partner tier" or delete it and keep only the 500-request non-cap assertion.

## LOW findings
None. Prior low-count / stale-wording cleanup was intentionally skipped per handoff scope and does not change this round's readiness assessment.

## INFO

I1. The v10 fix pass substantively closed the prior ARCH r8 / CODE r9 blockers: auth-failure limiter scoping is now Authorization-present only, reserve-then-refund is pinned, absent Authorization is skipped, valid keyed traffic has explicit tests, Step 4.B has the keyed-through-nginx and `proxy_no_cache` tests, Step 2's Shape C rebuild test is Shape-C-specific, and nginx Shape (b) is now a named-location dispatch.

I2. The checked-in controlling SPEC is v0.1.8, superseding the older v0.1.6 wording in the audit template. The current prompt correctly anchors to v0.1.8 and preserves the four locked advisor picks: separate rollup pipeline, public overview plus optional partner keys on leaderboard, bucketed-default earnings plus provider exact opt-in, and coordinator-binary hosting.

## Operator questions
q1. None. Both HIGH fixes are IMPL-prompt rewrites against the locked SPEC; they do not ask the operator to reopen a design decision.

## Verdict
- READY WITH FIX PASS

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared conceptual seams.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r1-audit.md through SPEC-017-r7-audit.md for why locked MUSTs exist.
- [x] Reviewed latest ARCH/CODE/SECURITY IMPL-prompt audit continuity where referenced by the handoff note.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location line range included on every finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.

## 200-word handback summary

Round 9 is ready with a narrow fix pass, not another design round. The v10 prompt absorbed the prior auth-failure limiter scoping defect, keyed-through-nginx bypass test, `proxy_no_cache` test, Shape C rebuild test, and named-location nginx dispatch fix. I found two remaining HIGH architecture prompt issues.

First, `partial_history_since` has no pinned Step 1 schema/grant seam even though Step 2 writes persisted rollup-state metadata and Step 3 names `rollup_state.partial_history_since` as the handler source. That leaks schema/grant work across Step 1, Step 2, and Step 3 and can break one-PR-per-step audit isolation. Pin a concrete rollup-state storage shape and grants in Step 1, then make Step 2 write it and Step 3 read it.

Second, the final done criteria re-blur the SPEC-014 surfaces by saying the three follow-up items are non-blocking follow-ups, even though §6.6.2 disclosure UI is a hard gate before first production partner-key issuance. Keep visibility UI and canonical UI non-blocking, but preserve the disclosure gate in the final checklist.

One MEDIUM remains: the valid partner-key rate-limit test says the 501st request would fail under a 600 rpm tier. It should say 601st or be deleted. No SPEC change or operator question is needed. All fixes stay local to the prompt.
