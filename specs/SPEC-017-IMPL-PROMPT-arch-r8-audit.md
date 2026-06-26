# SPEC-017 IMPL prompt — ARCH lane audit, Round 8 (Codex, 2026-06-26T05:30:55Z)

## Summary
- 1 CRITICAL finding
- 1 HIGH finding
- 1 MEDIUM finding
- 1 LOW finding
- 2 INFO

## Category sweep
| Category | Result |
|---|---|
| A. Step decomposition correctness | MIXED. The four-step split is mostly coherent, but Step 3's auth-failure limiter wording crosses into partner-tier rate semantics in a way Step 4.B tests would not catch. |
| B. Prerequisite coverage | PASS. Hostname/backfill/SPEC-016/SPEC-014 gates are explicit and no longer block code-write incorrectly. |
| C. Cross-step structural integrity | FAIL. The prompt over-broadens the Step 3 pre-auth limiter and under-tests the Step 4.B nginx keyed-bypass companion required by the SPEC. |
| D. PR strategy | PASS. One-PR-per-step, ordered squash-merge/rebase discipline, and no Step N+1 before Step N merge are explicit. |
| E. Audit-loop discipline | PASS. ARCH/CODE/SECURITY lanes and `0 CRITICAL + 0 HIGH + 0 MEDIUM` convergence remain load-bearing. |
| F. SPEC-prompt fidelity | FAIL. The auth-failure tier prose can cap valid partner traffic below the locked partner tier; one §5.6 test requirement is only present as prose, not a Step 4.B test. |
| G. Honesty about scope | MIXED. Audit cost and SPEC-014 surfaces are honest, but a few stale `21 ACs` references remain after AC-22 was added. |

## CRITICAL findings

C1. Auth-failure limiter prose can silently cap valid partner traffic below the locked partner tier
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:418-423`, `:441-445`; locked SPEC `specs/SPEC-017-network-stats-api.md:1105-1110`, `:1129-1143`, `:1145-1170`
   **Finding:** The prompt's middleware stack says the auth-failure tier limiter runs before auth and "limits" requests that produce 401 **and any request with absent/valid Authorization** because the bucket is keyed only on IP+endpoint. That is broader than locked §5.6, which defines three distinct tiers: anonymous public traffic is public-tier-limited, successful partner traffic is per-`partner_keys.id` limited at 600 rpm, and auth-failure traffic is the 300 rpm per-IP pre-hash bucket.
   **Why it matters:** A fresh IMPL author following this wording can put a 300 rpm pre-auth per-IP cap in front of valid partner-key requests. That breaks the public partner API contract by making a key configured for the default 600 rpm fail at roughly half the promised tier whenever traffic comes from one client IP. It also blurs the v0.1.8 design fix: Authorization-bearing requests bypass nginx public limiting so successful partner traffic is governed by the partner tier, not by an anonymous/auth-failure IP bucket.
   **Suggested fix:** Rewrite middleware step 4 to match the SPEC's tier boundaries. It may inspect Authorization-bearing requests before the hash+SELECT only to protect the failed-auth path required by AC-22; it MUST NOT debit absent-Authorization requests, and it MUST NOT cause successfully authenticated partner requests to 429 below their `partner_keys.rate_limit_rpm` bucket. Add an explicit implementation note that any pre-auth reservation/refund or equivalent algorithm must preserve both AC-22 and the 600 rpm successful-partner contract, with tests proving valid keyed traffic from one IP is not capped by the auth-failure tier.

## HIGH findings

H1. Step 4.B omits the SPEC's keyed-through-nginx bypass companion test
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:553-574`, `:592-602`; locked SPEC `specs/SPEC-017-network-stats-api.md:1145-1170`
   **Finding:** The prompt correctly describes Authorization-aware nginx keying and says valid partner-key traffic flows through nginx unthrottled at the public tier. But the Step 4.B tests only cover anonymous AC-8, cache contamination, invalid Authorization, burstless rejection, subdomain trust, and nginx log redaction. They do not include the locked §5.6 companion test that sends 100+ valid partner-key requests through nginx and asserts the edge public limiter does not reject them.
   **Why it matters:** This is the exact seam v0.1.8 added after the §5.6/AC-8 repair. Without the keyed-through-nginx test, an implementer can place `limit_req` on the shared `/v1/stats/leaderboard` location, pass anonymous AC-8, and still throttle valid partners at 60 rpm before the coordinator's per-key bucket runs. That is a significant public-contract and deploy-shape regression.
   **Suggested fix:** Add a Step 4.B test named as the §5.6 keyed-bypass companion: issue at least 100 valid partner-key requests through the nginx surface from one client IP and assert none are rejected by nginx's public limiter. Keep the request count below the in-process partner tier unless a separate partner-tier test intentionally drives the 601st request.

## MEDIUM findings

M1. Step 2's rebuild success-test text still examples Shape A/B, not the v0.1.8 Shape C default
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:255-270`, `:308`; locked SPEC `specs/SPEC-017-network-stats-api.md:2093-2148`
   **Finding:** The directive correctly says v0.1 IMPL MUST use Shape C unless grants are widened, but the later rebuild test still says "v0.1.7" and examples success assertions for Shape B and Shape A cleanup. It never states the default Shape C success assertion directly.
   **Why it matters:** The main instruction is strong enough to avoid a HIGH finding, but the stale test prose can make two audit prompts differ: one tests the v0.1.8 DELETE+INSERT transaction directly, another chases A/B cleanup artifacts that should not exist under default grants.
   **Suggested fix:** Rewrite the test bullet for Shape C: successful rebuild commits new rows atomically, no reader observes an empty table, and a failed transaction leaves the pre-rebuild rows intact. Move A/B cleanup examples behind an explicit "only if operator widened grants" note.

## LOW findings

L1. Stale `21 ACs` references remain after AC-22 was added
   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md:644`, `:699`
   **Finding:** The prompt elsewhere correctly says v0.1.8 has 22 ACs, but two lines still refer to `AC-1..AC-21` fixture work / "21 ACs."
   **Why it matters:** Low risk because the AC matrix and final done criteria say 22, including AC-22. Still, fresh-session reading lists should not preserve stale counts on a locked public API prompt.
   **Suggested fix:** Change both stale references to `AC-1..AC-22` / "22 ACs" or avoid hardcoding the count.

## INFO

I1. The prior ARCH r7, CODE r8, and SECURITY r5 blockers called out in the handoff note are substantively absorbed: Shape C is SPEC-pinned, burst is removed, AC-22 exists, `proxy_no_cache` is present, trusted-proxy IP derivation is present, Step 2 owns bucket computation, and the 304 header exception is narrowed.

I2. The four locked advisor picks remain preserved: separate rollup pipeline, public overview plus optional partner keys on leaderboard, bucketed-default earnings with provider exact opt-in, and coordinator-binary hosting.

## Operator questions

q1. None. The fixes are IMPL-prompt rewrites/tests against the locked v0.1.8 contract, not new operator choices.

## Verdict
- READY WITH FIX PASS

## Self-verification
- [x] Read BUILD_SPEC_017_IMPL_PROMPT.md fully.
- [x] Read SPEC-017-network-stats-api.md fully.
- [x] Read BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md fully and compared conceptual seams.
- [x] Read SPEC-017-advisor-round-2026-06-25.md.
- [x] Skimmed SPEC-017-r1-audit.md through SPEC-017-r10-audit.md for why locked MUSTs exist.
- [x] Reviewed latest ARCH/CODE/SECURITY IMPL-prompt audit continuity where referenced by the handoff note.
- [x] Walked each Category A through G.
- [x] Severity for each finding chosen against the definitions above.
- [x] Location line range included on every finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.

## 200-word handback summary

Round 8 is ready with a fix pass, not a design reset. The v0.1.8 re-anchor absorbed the prior Shape C, burst, proxy cache, trusted-proxy, and rollup-ownership blockers, and the four locked advisor picks remain intact. I found one remaining CRITICAL prompt defect: the Step 3 middleware wording says the auth-failure pre-auth IP bucket limits absent or valid Authorization requests too. That can make valid partner traffic hit a 300 rpm IP cap before the locked 600 rpm per-key tier, breaking the partner API contract. The prompt should scope that limiter back to the failed-auth protection required by AC-22 and explicitly test that successful partner traffic is not capped by it.

One HIGH remains in Step 4.B: the prompt describes Authorization-aware nginx keying but does not add the SPEC-required keyed-through-nginx companion test. Add a test with 100+ valid partner-key requests through nginx proving the public 60 rpm limiter is bypassed. One MEDIUM stale-test issue remains around Shape C: the rebuild test still examples A/B cleanup instead of the default DELETE+INSERT transaction. One LOW stale-count issue remains: two references still say 21 ACs after AC-22. No operator question or SPEC change is needed. The fix pass should be narrow and local only.
