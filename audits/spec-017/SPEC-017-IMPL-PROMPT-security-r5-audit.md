# SPEC-017 IMPL prompt — SECURITY lane audit, Round 5 (Codex, 2026-06-26T09:35:00Z)

## Summary
- 1 CRITICAL finding
- 1 HIGH finding
- 0 MEDIUM findings
- 0 LOW findings
- 6 INFO observations

Round 5 audited the v8 fix pass on the v0.1.7 IMPL prompt. The previous SECURITY r4 blocker is closed: the prompt now places a pre-auth coarse limiter before the auth dispatcher and tests invalid-key floods below the SQL lookup boundary. The prompt also preserves the v0.1.7 CORS, timing, role-isolation, redaction, and earnings-privacy hardenings. I found two remaining security gaps in prompt directives: nginx cache bypass is used where no-store is required for Authorization-bearing responses, and the direct-to-coordinator fallback limiter may trust spoofable `X-Forwarded-For`.

External reference checked: official nginx [`ngx_http_proxy_module` docs](https://nginx.org/en/docs/http/ngx_http_proxy_module.html) distinguish `proxy_cache_bypass` ("response will not be taken from a cache") from `proxy_no_cache` ("response will not be saved to a cache").

## Category sweep
| Category | Result |
|---|---|
| A. Token handling | PASS. Raw token prints once, stores only `sha256(raw_token_utf8_bytes)`, prefix is limited to 8 chars, constant-time secret-derived comparison is required, rotation overlap plus predecessor revocation is tested. |
| B. Timing-attack resistance | PASS. Keyed requests always hash and SELECT; prefix early-return is forbidden; rejected-Origin/no-row/revoked paths use 100+ sample AC-18 timing below limiter threshold. |
| C. Log redaction | PASS. Redaction-context middleware is outermost; recover strips `Authorization`; Step 3/4 AC-15 split covers handler logs, panic logs, traces, journalctl, nginx logs, and metrics. |
| D. Role-grant inventory safety | PASS. Runtime grants stay enumerated; `partner_keys_writer` is skipped/default-off; `partner_keys_id_seq` remains operator-CLI-only; runtime pools are per role. |
| E. CORS and CSRF | PASS with C1 cache caveat. OPTIONS is key-agnostic; GET enforces per-key allowlists; sibling wildcards are forbidden; no Origin branch controls dollar exposure; partner projection has `private` cache semantics. |
| F. Rate-limit fail-closed semantics | HIGH H1. The pre-auth limiter exists, but its IP-source rule may trust spoofable `X-Forwarded-For` on the direct-to-coordinator path it is meant to protect. |
| G. Earnings privacy | CRITICAL C1. The prompt says partner-key projection must not be cached at nginx, but names `proxy_cache_bypass` as the gate; that directive does not prevent saving a response. |
| H. Process isolation | PASS. Recover wraps only the stats subtree, AC-11 is injection-style, and lint forbids `os.Exit`/`log.Fatal` in stats code. |
| I. Cross-spec dependency posture | PASS. SPEC-016 re-pin and provider-auth trust-source checks are explicit and forbid silently closing rewards or identity gaps in code. |
| J. Operational safety | PASS. No in-memory key cache; revocation is next request; OPS covers rotation, incident revoke, and emergency exact-to-bucketed suppression. |

## CRITICAL findings

C1. Nginx cache directive uses bypass where no-store is required for partner-key responses

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 551, 561-563; locked SPEC §5.4.7 lines 1046-1050 and §7.4 lines 1628-1630.

   **Finding:** The prompt correctly states that the partner-key projection "MUST NOT be cached at nginx," but then says to gate this with `proxy_cache_bypass $http_authorization`. That is the wrong nginx primitive for the no-store half of the requirement. Official nginx docs define `proxy_cache_bypass` as a condition under which a response is not taken from cache, while `proxy_no_cache` is the condition under which a response is not saved to cache. The prompt's cross-contamination tests catch one anonymous-after-keyed leak shape, but the normative directive still teaches the implementer to use a read-bypass as if it were a write-suppression rule.

   **Why it matters:** Partner-key leaderboard responses carry exact `earnings_usd`, `earnings_work_usd`, and `earnings_rewards_usd` for all providers, including providers whose public mode is `bucketed`. Caching those responses in a shared nginx cache violates the locked "nginx-level caches MUST NOT cache the partner projection" rule and can become an exact-dollar data leak if cache key, Vary handling, or future nginx config drift stops separating Authorization variants. It also risks persisting partner-private response bodies on the edge layer after the handler explicitly marks them private.

   **Suggested fix:** Change Step 4.B to require both:
   - `proxy_cache_bypass $http_authorization;` so Authorization-bearing requests are never served from the public cache.
   - `proxy_no_cache $http_authorization;` so Authorization-bearing responses are never saved to nginx cache.

   Also pin a config/test assertion that the partner-key response produces a cache status equivalent to `BYPASS`/`MISS but not stored` and leaves no reusable cache entry for the same URI. Keep `Cache-Control: private` as the handler contract, but do not rely on it as the only nginx no-store mechanism.

## HIGH findings

H1. Direct-to-coordinator fallback limiter can be bypassed if it trusts untrusted `X-Forwarded-For`

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 402, 407, 414, 427.

   **Finding:** The v8 prompt fixed SECURITY r4 H1 by adding a pre-auth coarse limiter before `sha256 + SELECT`. But the limiter key is "client IP (or `X-Forwarded-For` first IP per the existing coordinator pattern)" while its stated threat model is nginx-bypassed direct-to-coordinator traffic. On that direct path, `X-Forwarded-For` is attacker-controlled unless the implementation first proves the immediate peer is a trusted reverse proxy. A flooder can rotate spoofed `X-Forwarded-For` values and avoid the per-IP bucket, restoring the unbounded invalid-bearer `partner_keys` lookup load the fix was intended to close.

   **Why it matters:** This is a fail-open rate-limit hardening gap on the unauthenticated/keyed-auth failure path. It does not weaken token entropy or the normal nginx tier, but it undermines the direct-surface defense-in-depth claim and can drive DB load with invalid/revoked/rejected-Origin probes.

   **Suggested fix:** Pin trusted-proxy IP handling. The pre-auth limiter must key on `RemoteAddr` unless the immediate peer IP is in an explicit trusted proxy allowlist; only then may it parse the first `X-Forwarded-For` hop. Add a direct-to-coordinator test that sends 350 invalid-key requests from one socket while rotating `X-Forwarded-For`; the 301st request must still 429 and SQL SELECT count must remain capped. Add a separate nginx-surface test proving real proxied requests still group by the intended client IP.

## MEDIUM findings

None.

## LOW findings

None.

## INFO observations

I1. SECURITY r4 H1 is substantively closed: the pre-auth limiter now runs before auth, covers absent/present/invalid/revoked/rejected-Origin requests, and caps SQL lookups in the nginx-bypass flood test.

I2. The v8 prompt correctly removed the prior edge-cache invalid-Authorization bug: `Bearer garbage` must bypass public cache, reach the handler, and return 401.

I3. Step 4.B now hard-blocks production nginx rate-limit config on SPEC v0.1.8 reconciliation; no operator waiver path remains.

I4. AC-15 ownership is now split by surface: Step 3 handler/panic/trace, Step 4.A journalctl, Step 4.B nginx access logs, Step 4.C metrics.

I5. Partner-key exact-dollar exposure remains launch-gated on SPEC-014 v0.9 disclosure and operator sign-off before production partner-key issuance.

I6. The provider-auth standing concern is preserved: Step 2 must verify authenticated `provider_token` sourcing or filter/block public cutover.

## Operator questions

None. Both findings are IMPL-prompt hardening fixes and do not require changing locked SPEC-017.

## Verdict

- READY WITH FIX PASS

Do not begin implementation from this prompt until C1 and H1 are fixed. The required changes are narrow: add nginx `proxy_no_cache` alongside `proxy_cache_bypass` for Authorization-bearing requests, and pin trusted-proxy handling for limiter client-IP derivation.

## Self-verification

- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read focused locked SPEC-017 sections: §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6, §7.4, and AC-1 through AC-21.
- [x] Read `SPEC-017-r1-audit.md` through `SPEC-017-r8-audit.md` and checked that closed security-shaped findings were not reopened except the new prompt-level cache/IP-source gaps above.
- [x] Read prior IMPL-prompt ARCH r6, CODE r7, SECURITY r4 findings and verified v8 closure of those CRITICAL/HIGH/MEDIUM items.
- [x] Read the provider-auth unauthenticated end-to-end memory and checked the Step 2 trust-source gate.
- [x] Walked Categories A through J.
- [x] Severity per finding.
- [x] Suggested fix for every CRITICAL and HIGH.
- [x] Verdict included.

## 200-word handback summary

Round 5 confirms the v8 prompt absorbed the prior SECURITY r4 blocker: the pre-auth coarse limiter now sits before partner-key hashing/SELECT and tests invalid-key floods against the direct coordinator surface. The prompt also keeps the important locked security posture: raw tokens print once and are hashed as UTF-8 bytes, prefix early-reject is forbidden, AC-18 is a 100+ sample three-way timing test, redaction spans handler logs, panic logs, traces, journalctl, nginx logs, and metrics, DB roles stay enumerated, CORS is key-agnostic on OPTIONS and per-key on GET, exact earnings remain bucketed by default publicly, and provider-auth trust source remains a Step 2 gate.

Two prompt fixes are still needed before implementation kickoff. First, Step 4.B says the partner-key projection must not be cached at nginx but uses only `proxy_cache_bypass $http_authorization`. nginx documents that bypass prevents reading from cache; `proxy_no_cache` prevents saving. Add both directives and assert Authorization responses are not stored. Second, the pre-auth limiter may trust first-hop `X-Forwarded-For` even on direct-to-coordinator traffic. Pin trusted-proxy handling: use `RemoteAddr` unless the immediate peer is a trusted proxy, and add a spoofed-XFF flood test.

No SPEC change is required.
These fixes preserve the locked design while closing deploy-time leak and DoS paths cleanly.
