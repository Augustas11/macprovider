# SPEC-017 IMPL prompt — ARCH lane audit, Round 3 (Codex, 2026-06-26T03:45:43Z)

## Summary
- 1 CRITICAL finding
- 2 HIGH findings
- 0 MEDIUM findings
- 0 LOW findings
- 2 INFO

Round 3 confirms the named Round 2 ARCH blockers are mostly absorbed: Postgres DSN deploy gating is explicit and fail-closed behind `stats.enabled`; `partial_history_since` response assertions moved to Step 3; middleware order is pinned; log-vs-metric token allowances are split; CORS GET behavior is no longer downgraded by preflight prose; and `stats_components_health` bootstrap is specified. The remaining blockers are new or newly visible prompt problems, not SPEC defects.

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | HIGH finding H1 |
| B. Prerequisite coverage | PASS |
| C. Cross-step structural integrity | HIGH finding H1; HIGH finding H2 |
| D. PR strategy | PASS |
| E. Audit-loop discipline | PASS |
| F. SPEC-prompt fidelity | CRITICAL finding C1; HIGH finding H2 |
| G. Honesty about scope | PASS |

## CRITICAL findings

C1. Prompt instructs an extra `partner_keys_writer` SELECT grant that the locked SPEC does not allow
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 133-136; controlling SPEC §7.2.4 lines 1323-1340.
   **Finding:** The locked SPEC grants `partner_keys_writer` only `UPDATE (last_used_at)` on `partner_keys` and says the role has column-scoped UPDATE on `partner_keys.last_used_at` only. The IMPL prompt instead says the implementation "must add" column-scoped `SELECT` on `partner_keys (id)` so the worker can run `UPDATE partner_keys SET last_used_at = $1 WHERE id = $2`. That may be technically motivated, but it is still a prompt-authored widening of a locked role inventory.
   **Why it matters:** SPEC-017 v0.1.6 is locked and role isolation is part of the controlling contract. A fresh IMPL author following the prompt would ship a migration that does not match the locked §7.2.4 grant block, silently using the implementation prompt to amend the SPEC. Because `last_used_at` is optional in the SPEC, the implementation can remain compliant without re-opening the SPEC by omitting this update path.
   **Suggested fix:** Remove the mandatory `SELECT(id)` instruction. Rewrite the prompt to say: v0.1 may omit `last_used_at` updates unless/until a future SPEC revision pins an executable narrowed grant or stored-procedure pattern; if the operator chooses to skip it, do not create `partner_keys_writer` and do not start the worker. If the implementation still wants `last_used_at`, surface a SPEC v0.2 candidate instead of widening grants in the IMPL prompt.

## HIGH findings

H1. Step 2 still requires health-handler behavior before the handler step exists
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 187-189 and 208-212; AC matrix lines 477 and 493.
   **Finding:** Step 2 now correctly pins `stats_components_health` bootstrap, but it still says a Step 2 test must prove `/v1/stats/health` derives `status = "down"` by calling `GET /v1/stats/health`, "or run against a Step 3 stub if Step 3 has not landed." The AC matrix assigns AC-7 to Step 3, and Step 2 is supposed to land only the rollup pipeline and its table state.
   **Why it matters:** This reintroduces the same kind of step-boundary bleed Round 2 found for `partial_history_since`: Step 2 cannot go green independently without landing handler code early or building a stub that later may diverge from Step 3. The natural seam is table-state production in Step 2 and JSON/status derivation in Step 3.
   **Suggested fix:** Keep Step 2 tests to migration/bootstrap and rollup-state assertions: the six component rows exist, first failure preserves valid NOT NULL `generated_at` / `last_ok_at`, error columns update, and aged component timestamps are available as fixtures. Move all `GET /v1/stats/health` JSON status assertions to Step 3, seeded from the Step 2 fixture. Update the AC matrix note for AC-7 to avoid implying a Step 2 handler stub.

H2. AC-15 ownership points at the wrong Step 4 subsection and leaves nginx log redaction under-tested
   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 327, 396-416, 429-435, 458-462, and AC matrix line 485; controlling SPEC AC-15 lines 1812-1814 and §5.4.6 lines 854-860.
   **Finding:** AC-15 is mapped to "Step 3 + Step 4.A" even though the AC sweep includes nginx logs and metric labels. Step 4.A is the partner-key CLI subsection; nginx log redaction belongs to 4.B, and metric-label hygiene belongs to 4.C. The detailed Step 4.B tests validate nginx config and cache/rate behavior, but do not require a dynamic request with `Authorization` followed by an access-log scan.
   **Why it matters:** AC-15 is a locked redaction acceptance criterion. With the current ownership matrix, an implementation can satisfy Step 4.A CLI journalctl checks and Step 4.C metric checks while never proving the nginx access log strips `Authorization` under live stats traffic. That is a structural AC coverage gap across Step 4 subsections.
   **Suggested fix:** Change the matrix to `AC-15 | Step 3 + Step 4.A + Step 4.B + Step 4.C`. Add a Step 4.B test: send a keyed `/v1/stats/leaderboard` request through nginx, then scan the nginx access log and assert it contains no raw token, no `Authorization` value, no `token_hash`, and no random-portion substring. Keep Step 4.C's metric-label scan as a separate test.

## MEDIUM findings

None.

## LOW findings

None.

## INFO

I1. The Round 2 Postgres deploy-gate issue is closed in substance. The prompt now names role/DSN provisioning as hard before any Pearl deploy of stats code and gates fail-closed startup behind `stats.enabled`.

I2. The §6 deferral list includes §11 Q1 through Q13. I found no missing v0.2 question in `BUILD_SPEC_017_IMPL_PROMPT.md` lines 541-553.

## Operator questions

q1. None requiring a SPEC design decision. C1 should be handled by narrowing the IMPL prompt to the locked optional/no-op `last_used_at` path unless the operator explicitly opens a future SPEC revision.

## Verdict
- READY WITH FIX PASS

The prompt should not lock at Round 3. The fix pass can stay entirely in `BUILD_SPEC_017_IMPL_PROMPT.md`: remove the prompt-authored `partner_keys_writer` grant widening, keep Step 2 health checks at the table/rollup seam, and assign AC-15 redaction verification to the correct Step 4 subsections.

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared process/step/audit structure.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r3-audit.md through SPEC-017-r7-audit.md for why locked MUSTs exist.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location line range included on every finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.
