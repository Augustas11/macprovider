# SPEC-017 v0.1.2 audit report — Round 3 (Codex, 2026-06-25T19:14:22Z)

## Summary
- 0 CRITICAL findings
- 4 MAJOR findings
- 3 MINOR findings
- 0 QUESTIONS

Round 3 focused on whether v0.1.2 closed the round-2 findings and whether the fix pass introduced new lock blockers. The main round-2 CRITICALs are closed in the normative body: partner-key token length is now internally consistent, and `rewards` source semantics are no longer claimed from SPEC-016 v0.1.19. The remaining blockers are stale or newly exposed consistency gaps around DB-role isolation, CORS preflight, a stale SPEC-016 reference, and an open question that contradicts the body.

## Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | Findings M1, M2. No new implementation-package prescription found. |
| B Endpoint contract correctness | Finding M2. Overview, leaderboard, health, error envelope, `limit` bounds, null-vs-missing, and `stale_after` are otherwise internally pinned. |
| C Earnings visibility model | No exact-dollar public leak found. Bucketed default, same-origin uniformity, audit table, and operator override direction are pinned. |
| D Hosting and isolation | Finding M1. Mount path does not collide with SPEC-002 paths; process isolation/import boundary is pinned. |
| E Versioning and deprecation | Finding m2. `/v1` path versioning and 6-month overlap are otherwise pinned. |
| F Rollup pipeline | Findings M1, M3. Cadence, late-event correction, 0.5% drift rationale, freshness budgets, failure modes, and `partial_history_since` are otherwise defined. |
| G Acceptance criteria quality | AC-1 through AC-20 are contiguous and deterministic. Finding M2 because AC-13 does not prove the keyed browser preflight branch. |
| H Cross-spec invariant preservation | Finding M3. No SPEC-002 path collision, no SPEC-005 work-dollar formula redefinition, and no SPEC-014 lock gate found. |
| I Honesty about deferrals | Finding M4. Other §11 questions are genuine v0.2+ design questions. |
| J Spec hygiene | Findings m1, m2, m3. No literal `TBD` found; line-3 version and dependency versions match the current worktree. |

## CRITICAL findings

None.

## MAJOR findings

M1. DB-role isolation wording still contradicts the request-path grant set
    **Location:** §1.5 C4 lines 136-140; §4.2 lines 347-349; §5.4.3 lines 737-740; §7.2.1 lines 1093-1130; §7.2.2 lines 1132-1150; §9.1 lines 1310-1314
    **Finding:** v0.1.2 mostly split the role inventory, but stale invariants still say the stats DB role has `SELECT` on `stats_*` only and that the handler grant list must match the §9.1 table inventory exactly. The actual `stats_reader` role also needs `provider_visibility` and `partner_keys`, excludes `stats_late_events` and `provider_rewards_ledger`, and §5.4.3 optionally updates `partner_keys.last_used_at` despite the role being SELECT-only. §7.2.2 also leaves the rollup grant as a non-executable placeholder (`<OLTP billing/session/pool tables...>`), so the PostgreSQL grant sequence is not mechanically valid end to end.
    **Why it matters:** Isolation is one of SPEC-017's lock-critical safety claims. Two implementers could choose different controlling text: strict `stats_*` only, the broader request-path list, or the §9.1 exact-match rule. That ambiguity will surface during implementation, audits, and DB migrations.
    **Suggested fix:** Make one inventory authoritative. Rename the invariant to "request-path readable tables", remove "stats_* only" where it no longer applies, delete the §9.1 exact-match sentence or scope it to SPEC-017-owned rollup tables, decide whether `last_used_at` is truly v0.1 behavior, and replace the rollup placeholder with an enumerated grant list or a clearly non-SQL contract paragraph.

M2. Partner-key CORS preflight still cannot be implemented unambiguously for browser clients
    **Location:** §5.4.3 lines 716-731; §5.7 lines 824-838; AC-13 lines 1617-1619
    **Finding:** §5.7 says `OPTIONS` mirrors the CORS table "based on the request's Origin and Authorization headers." Browser CORS preflight for `Authorization: Bearer ...` does not normally include the actual bearer token; it sends `Access-Control-Request-Headers: Authorization`. For keys with non-empty `allowed_origins`, the server therefore cannot evaluate the key-specific allowlist during preflight, even though the actual GET path requires that allowlist decision.
    **Why it matters:** This is the partner browser-embed path. A conforming implementation might reject preflight as missing auth, allow all preflights and enforce on GET, or maintain a separate origin-only preflight rule. Partners would see browser CORS failures before the documented 401/200 decision table ever runs.
    **Suggested fix:** Define `OPTIONS` independently from keyed GET auth. For example, preflight may echo an Origin if it matches any configured partner origin (or always answer preflight generically), while the actual GET remains the sole token-specific allowlist enforcement point.

M3. The round-2 `rewards` fix leaves a stale SPEC-016 rewards-semantics citation
    **Location:** header line 5; §9.1a lines 1420-1456; §12 lines 1741-1743
    **Finding:** The header and §9.1a correctly say SPEC-016 v0.1.19 does not define a work-vs-rewards split and defer `earnings_rewards_*` to `provider_rewards_ledger` plus Q13. But §12 still cites `specs/SPEC-016-payout-pipeline.md §5.1 (rewards-$ semantics)`, which is exactly the claim round 2 C2 rejected.
    **Why it matters:** The normative body is now honest, but the reference table still points implementers at the wrong locked spec for a money field. That reopens predictable confusion about whether `earnings_rewards_usd` is zero/defaulted, operator-ledger sourced, or SPEC-016-derived.
    **Suggested fix:** Reword the §12 entry to cite SPEC-016 only for payout-pipeline context, and point rewards-source semantics to §9.1a / §11 Q13 instead.

M4. §11 Q2 says self-serve partner issuance is not forbidden, but §5.4.2 forbids it for v0.1
    **Location:** §5.4.2 lines 692-696; §11 Q2 lines 1663-1665
    **Finding:** §5.4.2 says v0.1 issuance is "operator-driven only" and defers self-serve issuance to a future SPEC-014 v0.10+ candidate. §11 Q2 then says v0.1 pins operator-issued only "by default" but "does not normatively forbid self-serve." The body has already decided the v0.1 rule.
    **Why it matters:** Open questions must not hide pinned decisions. This would make the audit loop and implementer handoff disagree on whether a self-serve key endpoint is allowed under v0.1.
    **Suggested fix:** Rewrite Q2 as a v0.2+ question: when and how to add self-serve issuance after v0.1, not whether v0.1 permits it.

## MINOR findings

m1. Required source advisor artifact path is still absent from this worktree
    **Location:** §12 lines 1746-1747; filesystem path `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`
    **Finding:** The checked-in mirror `specs/SPEC-017-advisor-round-2026-06-25.md` exists and preserves the four locked decisions, but the original `.omc/artifacts/ask/...` path named by the audit prompt is absent.
    **Why it matters:** Minor reproducibility gap only; the mirror is sufficient for this audit.
    **Suggested fix:** Make the prompt and spec cite only the checked-in mirror, or commit the source artifact if `.omc` artifacts are meant to be review inputs.

m2. Deprecation-header cleanup is incomplete
    **Location:** §8.3 lines 1275-1279; §8.4 lines 1285-1297
    **Finding:** §8.4 correctly cites RFC 9745 for `Deprecation`, but §8.3 still says the `Deprecation` header is "per RFC 8594." The example `Deprecation: @1782518400` is also labeled as 2026-06-22T00:00:00Z, but that Unix timestamp is 2026-06-27T00:00:00Z.
    **Why it matters:** Protocol hygiene. Header examples tend to get copied directly into public docs and implementation fixtures.
    **Suggested fix:** Change the §8.3 citation to RFC 9745 for `Deprecation`, keep RFC 8594 for `Sunset`, and correct either the example timestamp or the prose date.

m3. Minor §11 cross-reference and numbering hygiene drift
    **Location:** §6.6.2 lines 1051-1054; §11 lines 1707-1726
    **Finding:** §6.6.2 points to "Q1' in §11" for partner-projection opt-out, but the actual question is Q11. §11 also places Q13 before Q12.
    **Why it matters:** This does not affect the v0.1 contract, but it makes the open-question list harder to scan and cite during the next fix pass.
    **Suggested fix:** Replace `Q1'` with `Q11` and order Q12/Q13 numerically.

## Operator questions surfaced

None beyond existing §11 open questions.

## Verdict

- READY WITH FIX PASS

v0.1.2 is closer than v0.1.1 and has no architectural CRITICAL remaining, but it is not ready to lock while DB-role isolation, keyed CORS preflight, stale rewards citation, and partner-key issuance deferral text remain inconsistent. These are narrow text/spec fixes; no design round appears necessary.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.2 (§§1-12, ACs 1-20).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through J. Categories without direct findings are marked in the category sweep.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location (section number and line range where applicable) on every finding.
- [x] Suggested fix for CRITICAL findings; no CRITICAL findings remain.
- [x] Verdict included.
