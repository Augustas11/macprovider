# SPEC-017 IMPL prompt — SECURITY lane audit, Round 1 (Codex, 2026-06-26T03:25:01Z)

## Summary
- 1 CRITICAL finding
- 6 HIGH findings
- 5 MEDIUM findings
- 1 LOW finding
- 2 INFO observations

The IMPL kickoff prompt mostly preserves the locked SPEC-017 v0.1.6 security posture: hashed partner-key storage, request-path role isolation, no handler OLTP access, key-agnostic preflight, same-Origin uniformity, bucketed default earnings, and the round-6 BIGSERIAL sequence closure are carried forward. The blocking issue is a runbook directive that points the emergency visibility flow in the forbidden direction: operator fallback for `bucketed` -> `exact`. Several other prompt gaps leave non-obvious security controls too implicit for a fresh implementation session, especially redaction breadth, edge-cache handling for `Authorization`, nginx fail-closed rate limiting, provider-identity source trust, rotation overlap closure, and the full partner-key CORS decision table.

## Category sweep
| Category | Result |
|---|---|
| A. Token handling | HIGH H5; MEDIUM M1, M4; INFO I1. Issuance hash/print-once is present, but rotation closure and constant-time comparison guidance are under-specified. |
| B. Timing-attack resistance | MEDIUM M1. Same hash + SELECT and 100+ request AC-18 test are present; constant-time compare guidance is absent. |
| C. Log redaction | HIGH H1; MEDIUM M5. The prompt states no raw token broadly, but Step 3/4 tests and logging directives do not force a central redaction layer across recover, access, metrics, traces, and default server logs. |
| D. Role-grant inventory safety | INFO I1. The grant inventory matches §7.2, including sequence grants and separate pools; no silent role widening found. |
| E. CORS and CSRF | HIGH H2, H6; MEDIUM M2. Key-agnostic OPTIONS is preserved, but the prompt undercalls absent-Origin rejection, no wildcard subdomain policy, and edge-cache `Vary: Authorization` behavior. |
| F. Rate-limit fail-closed semantics | HIGH H3; MEDIUM M3. Both tiers are retained, but nginx burst queueing and 503 accounting are not pinned. |
| G. Earnings privacy | CRITICAL C1; HIGH H4. Bucketed default and AC-20 are present, but the runbook says the opposite of the emergency suppression rule and omits the partner-key broader-exposure disclosure deliverable. |
| H. Process isolation | HIGH H1; MEDIUM M4. Stats-subtree recover and injection test are present; panic-log redaction and `os.Exit` / `log.Fatal` guardrails are missing. |
| I. Cross-spec dependency posture | HIGH H4; INFO I2. SPEC-016 re-pin is handled well; the known provider-authentication standing concern is not turned into an IMPL-time trust-source gate. |
| J. Operational safety | CRITICAL C1; HIGH H5. No in-memory key cache is implied by per-request hash+SELECT; emergency `$` suppression and rotation revocation cadence need prompt fixes. |

## CRITICAL findings

C1. Operator runbook points the emergency visibility flow in the forbidden direction

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 145, 236; locked SPEC §6.6.3 lines 1171-1181.

   **Finding:** Step 4 directs `OPS.md` runbook entries for "flipping a provider from `bucketed` -> `exact` via the SPEC-014 v0.9 portal (or operator CLI fallback for emergencies)." SPEC-017 §6.6.3 permits the opposite emergency action: operator may flip `'exact' -> 'bucketed'` to suppress public exact-dollar exposure, and MUST NOT flip a provider to `'exact'` unless provider consent is recorded with `actor_kind = 'provider'`. The prompt's "operator CLI fallback for emergencies" creates an implementation path that can bypass provider consent and expose exact dollars for a non-opted-in provider.

   **Why it matters:** This is a direct earnings-privacy break. A fresh IMPL author could add an operator CLI or runbook path that writes `new_mode = 'exact'` with `actor_kind = 'operator'`, silently violating AC-20 and publishing exact `$` for a provider that never opted in.

   **Suggested fix:** Rewrite the Step 4 and final-deliverable runbook directive to: "emergency exact-dollar suppression: operator may flip `exact` -> `bucketed`; operator MUST NOT flip `bucketed` -> `exact`; CI must assert no `provider_visibility_audit` row with `new_mode = 'exact' AND actor_kind = 'operator'`." Put the normal `bucketed` -> `exact` path solely under the authenticated SPEC-014 provider portal consent flow.

## HIGH findings

H1. Log-redaction directives are too handler-local for the surfaces that can leak `Authorization`

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 110, 120, 139, 141-143, 196; locked SPEC §5.4.6 lines 854-860 and §7.3 lines 1352-1357.

   **Finding:** The prompt repeats the redaction invariant and tests journalctl for raw `Authorization`, but it does not require a central HTTP/logging middleware that strips or redacts `Authorization` before every log emission. The gap is most visible around `stats_handler_panic`: Step 3 says recover logs the panic, while Step 4 lists `stats_handler_panic` structured logs, but neither says the recover middleware must redact request headers before logging. The same issue applies to default access logs, tracing spans, rate-limit logs, and metrics/debug labels that may be emitted outside the stats handler's normal structured log path.

   **Why it matters:** SPEC §5.4.6 forbids raw token, `token_hash`, and random-token substrings in application, nginx, journald, metric label, or trace span output. A handler-only redaction test can pass while a panic or access-log path leaks the bearer token.

   **Suggested fix:** Add a Step 3/4 directive to install a request-scoped redaction middleware before recover, access logging, tracing, and handler logs. It must remove `Authorization`, must not log `token_hash`, and may only log `partner_keys.id`, `partner_keys.label`, and optionally the stored 8-character prefix. Add tests that force a panic and a 401/429 path with a real token and assert no raw token, `token_hash`, or random-token substring appears in journalctl, nginx logs, structured logs, traces, or metric labels.

H2. Edge-cache hardening for keyed leaderboard responses is left implicit

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 107, 139, 192; locked SPEC §5.2 lines 638-650 and §5.4.7 lines 862-868.

   **Finding:** Step 4 says "cache directives per §5.1 / §5.2 / §5.3 response headers" but does not explicitly require `Vary: Authorization`, `Cache-Control: private` for partner-key projections, and nginx/CDN non-caching of partner responses. The locked SPEC is precise here because the partner projection includes exact `$` for all providers regardless of `provider_visibility.mode`.

   **Why it matters:** If nginx or a CDN caches a partner-key leaderboard response without varying on `Authorization` or honoring `private`, exact-dollar partner data can be served to a different key or to an anonymous public request.

   **Suggested fix:** In Step 3 and Step 4, explicitly require: public leaderboard emits `Vary: Accept-Encoding, Origin, Authorization`; partner projection emits `Cache-Control: private, max-age=30, s-maxage=30`; nginx `proxy_cache` is disabled/bypassed whenever `Authorization` is present; edge caches must not store partner projections; smoke tests must prove a keyed response is not served to an anonymous follow-up request.

H3. Public-tier nginx burst behavior is not pinned fail-closed

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 111, 139, 152; locked SPEC §5.6 lines 881-894 and §7.4 lines 1363-1371.

   **Finding:** The prompt preserves nginx `limit_req_zone` as the primary public limiter, but it does not direct nginx `limit_req` burst behavior. Without an explicit fail-closed setting, an implementation can use delayed queueing semantics that hold requests and serve them later instead of quickly returning 429.

   **Why it matters:** Queue-and-delay is a poor security posture for this public unauthenticated surface. It can tie up worker capacity during abuse and makes AC-8's "61st request returns 429" less deterministic.

   **Suggested fix:** Add a Step 4 nginx directive requiring fail-closed burst handling, e.g. `limit_req ... burst=<pinned> nodelay` or an equivalent config that returns 429 quickly rather than queueing. The nginx integration test should verify the excess request is rejected promptly with `Retry-After`, not delayed and eventually served.

H4. Provider identity trust is not an IMPL-time security gate despite the standing auth concern

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 42, 67, 83, 87, 175-180; provider-auth memory `XSEC-1`.

   **Finding:** The prompt tells the implementer to source rollups from provider/session/billing state and to key visibility/pseudonyms by `provider_id`, but it does not add an IMPL-time gate that the source `provider_id` is authenticated end-to-end. The required memory warns that live beta provider identity has been unauthenticated end-to-end: provider tokens are not sent, `require_provider_tokens=false`, and attacker-controlled hello frames can impersonate pinned providers and poison billing stats.

   **Why it matters:** SPEC-017 should not create a new provider-auth surface, but its leaderboard would amplify poisoned or impersonated provider identity into a public and partner-facing contract. If rollup inputs trust unauthenticated provider IDs, attackers can spoof provider rows, corrupt pseudonyms, and influence exact/bucketed earnings presentation.

   **Suggested fix:** Add a pre-flight or Step 2 security directive: before rollup implementation, verify the OLTP source fields used for `provider_id`, provider visibility joins, pseudonyms, and earnings are derived from authenticated provider-token plumbing, not attacker-controlled hello payloads. If current production still has `require_provider_tokens=false`, block public cutover or explicitly gate stats rollup to authenticated records only.

H5. Partner-key rotation lacks a revocation-cadence runbook and overlap assertion

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 137-138, 145, 150; locked SPEC §5.4.4 lines 832-844 and §5.4.5 lines 846-852.

   **Finding:** Step 4 includes `rotate-from` and `revoke` commands, but does not require the operator runbook to set `revoked_at` on the predecessor after the intended overlap, nor does it require a test proving both keys are valid during overlap and the predecessor is rejected immediately after revocation. SPEC §5.4.4 says the old row remains unrevoked initially and the operator must document the revocation cadence in onboarding mail.

   **Why it matters:** Rotation without a closure step becomes indefinite parallel-valid credentials. That widens replay and stale-token exposure after partner migration or incident response.

   **Suggested fix:** Add Step 4 tests for rotation overlap and post-revocation rejection: old and new tokens both unlock during overlap; after `partner-keys revoke --id <old>`, the old token returns 401 on the next request while the new token still works. Add an OPS/onboarding directive requiring an explicit predecessor revocation cadence.

H6. The prompt miscounts the partner-key auth decision table and undercalls the absent-Origin reject path

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 100-104; locked SPEC §5.4.3 lines 788-831 and §5.7 lines 897-930.

   **Finding:** Step 3 describes the §5.4.3 auth flow as a "6-row branch" and calls out only the "non-empty + Origin not in allowlist -> 401" row. The locked SPEC table has seven rows, including the security-relevant case where `allowed_origins` is non-empty and `Origin` is absent: that request must return 401. The prompt also does not restate that preflight permissiveness is not authorization for the actual GET.

   **Why it matters:** Missing the absent-Origin branch lets a key intended for browser-side embedding work from non-browser/server contexts without an Origin header. That weakens the per-key origin restriction and can leak the partner projection outside the intended embedding environment.

   **Suggested fix:** Change "6-row branch" to "7-row decision table" and enumerate both non-empty-allowlist reject cases: absent Origin and Origin not in allowlist both return 401. Add tests for non-empty `allowed_origins` with absent Origin, wrong Origin, right Origin, and OPTIONS preflight.

## MEDIUM findings

M1. Constant-time token comparison guidance is absent

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 100-102, 119, 195; locked SPEC §5.4.3 lines 807-823.

   **Finding:** The prompt correctly requires hash + SELECT for every keyed request and a 100+ request timing test, but it does not direct the author to use `subtle.ConstantTimeCompare` or an equivalent constant-time primitive for any in-process byte comparison that remains after database lookup.

   **Why it matters:** The SPEC's main timing control is the same hash + SELECT pattern, but explicit constant-time guidance prevents a weaker fallback implementation if an author compares computed/stored hashes in Go or adds a future in-memory fixture/auth path for tests.

   **Suggested fix:** Add: "Any in-process comparison of token-derived bytes MUST use `subtle.ConstantTimeCompare` or equivalent; do not use `==`, `bytes.Equal`, or string comparison for secret-derived values."

M2. CORS origin matching does not explicitly forbid subdomain wildcards

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 103-104, 153; locked SPEC §5.4.1 lines 751-754 and §5.7 lines 897-930.

   **Finding:** The prompt says to enforce `allowed_origins` and smoke-test one allowlist origin, but does not restate the locked exact-match origin requirement or forbid wildcard sibling-subdomain trust such as `*.malibu.tech`.

   **Why it matters:** `console.malibu.tech`, `portal.malibu.tech`, and `stats.malibu.tech` are sibling subdomains with different trust roles. Wildcard matching would let a compromise or future app on one sibling origin satisfy another origin's allowlist.

   **Suggested fix:** Add exact-origin matching language and tests for sibling-origin rejection: allow `https://portal.malibu.tech` only when that exact string is configured; reject `https://evil.malibu.tech`, scheme changes, suffix matches, and wildcard patterns.

M3. 503 stale responses are not pinned for rate-limit accounting

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 108, 111; locked SPEC §5.6 lines 881-894 and §5.8 lines 934-950.

   **Finding:** The locked SPEC does not pin whether stale-rollup 503 responses count against per-IP/per-key buckets, and the IMPL prompt does not choose a behavior. Two conforming authors can count them or not count them.

   **Why it matters:** Counting stale 503s can turn a rollup outage into rate-limit exhaustion for healthy clients; not counting them can allow polling floods during an outage. The prompt should force an explicit fail-closed-but-not-self-amplifying choice.

   **Suggested fix:** Pin a behavior in the prompt, e.g. "stale 503 responses are generated after cheap auth/CORS validation but do not debit the per-IP/per-key success bucket; a separate coarse abuse limiter still caps repeated stale polling." Add tests for the chosen behavior.

M4. Stats code is not forbidden from `os.Exit` / `log.Fatal`

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 110, 121, 197; locked SPEC §7.3 lines 1352-1357 and AC-11 lines 1799-1802.

   **Finding:** The prompt requires recover middleware around the stats subtree and an injection-style panic test, but does not forbid stats handlers, rollup jobs, or middleware from calling `os.Exit`, `log.Fatal`, or equivalent process-terminating APIs.

   **Why it matters:** Recover middleware cannot contain explicit process exits. A lint rule keeps the process-isolation guarantee from being bypassed by a convenience fatal path in stats code.

   **Suggested fix:** Add a CI lint or static check forbidding `os.Exit`, `log.Fatal`, `Fatalf`, and equivalent process-terminating calls under `internal/stats/`.

M5. Metric-label hygiene is less explicit than log hygiene

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 141-143, 196; locked SPEC §5.4.6 lines 854-860.

   **Finding:** Step 4 lists Prometheus metrics without any key label, and the critical constraints forbid raw token/token-hash/random substrings in logs. The locked SPEC also covers metric labels and trace spans, but the prompt does not explicitly state that any partner-key metric label must use `partner_keys.id` rather than prefix, token text, token hash, label text containing secrets, or origin.

   **Why it matters:** Metrics tend to be copied to external observability systems with wider retention and access. A token-derived label would be a durable secret leak and a high-cardinality footgun.

   **Suggested fix:** Add a metric-label rule: allowed partner-key labels are `partner_key_id` or coarse `tier`, never raw token, token hash, prefix, origin, or untrusted label text.

## LOW findings

L1. AC-15 is narrower than the redaction invariant in the prompt wording

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 120, 196; locked SPEC AC-15 lines 1812-1815.

   **Finding:** The prompt's critical constraint correctly says no raw token, no `token_hash`, and no random-portion substring in any log line. The Step 3 test bullet only says to assert no raw `Authorization` header value appears in journalctl.

   **Why it matters:** This is mostly covered by H1, but even after a central redaction fix the test wording should be widened so it proves the whole invariant, not just the raw header value.

   **Suggested fix:** Expand the AC-15 implementation test to scan for raw token, `token_hash`, and random-token substrings across all configured log sinks.

## INFO observations

I1. Role-grant inventory closures remain preserved in the IMPL prompt

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 46-51, 56-59.

   **Observation:** The prompt carries forward the round-5 and round-6 role/grant fixes: `stats_reader` is request-path SELECT-only on the §7.2.1 inventory, `stats_rollup` has SELECT/INSERT/UPDATE/DELETE on rollup-owned tables and the `stats_late_events_id_seq` grant, `provider_portal` gets `provider_visibility_audit_id_seq`, and `partner_keys_writer` is column-scoped to `last_used_at`. It does not grant `partner_keys_id_seq` to runtime roles.

I2. SPEC-016 re-pin language correctly avoids silently closing Q13

   **Location:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 22, 179, 215.

   **Observation:** The prompt is explicit that if SPEC-016 v0.2 defines a work/rewards split, the author must surface it and must not silently rewire `earnings_rewards_usd` to that new source. This preserves the locked §9.1a/Q13 deferral.

## Operator questions

None beyond the fixes above. The only operator policy decision surfaced by this audit is the prompt-level fix direction for stale-503 rate-limit accounting; it can be pinned in the IMPL prompt as an implementation hardening choice without reopening the locked SPEC.

## Verdict

- READY WITH FIX PASS

The prompt should not kick off implementation until C1 and the HIGH findings are corrected. The locked SPEC itself does not need to reopen for these findings; the fixes are IMPL-prompt hardening and runbook/test directives that keep the implementation aligned with v0.1.6.

## Self-verification

- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read focused locked SPEC-017 v0.1.6 sections: §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6, plus endpoint/cache/error/AC text needed for the security sweep.
- [x] Read `SPEC-017-r1-audit.md` through `SPEC-017-r7-audit.md` and verified the prompt does not re-open the major closed SPEC-round findings except where called out as prompt gaps.
- [x] Read the provider-auth unauthenticated end-to-end memory and checked for new trust-source risk.
- [x] Walked Categories A through J.
- [x] Severity assigned per finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.
