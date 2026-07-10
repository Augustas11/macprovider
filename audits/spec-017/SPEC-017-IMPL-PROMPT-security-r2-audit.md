# SPEC-017 IMPL prompt — SECURITY lane audit, Round 2 (Codex, 2026-06-26T03:38:42Z)

## Summary
- 0 CRITICAL findings
- 1 HIGH finding
- 0 MEDIUM findings
- 2 LOW findings
- 3 INFO observations

Round 2 confirms that v2 of `BUILD_SPEC_017_IMPL_PROMPT.md` closes the round-1 security blockers around operator exact-enable, central redaction, provider-identity trust, the 7-row partner-key decision table, constant-time comparison, cache isolation, fail-closed nginx rate limiting, stale-503 accounting, rotation overlap, and process-exit linting. The remaining HIGH issue is narrower but still security-relevant: the prompt does not direct an implementation/cutover deliverable for the §6.6.2 disclosure that trusted partner keys expose exact dollars for all providers, including bucketed providers. That omission can let the IMPL author ship the partner projection before the provider-facing disclosure obligation is tracked or operationally gated.

## Category sweep
| Category | Result |
|---|---|
| A. Token handling | No CRITICAL/HIGH/MEDIUM. Issuance prints once, hashes `sha256(raw_token_utf8_bytes)`, stores only hash + prefix, forbids raw-token reprint, and tests raw-token / `token_hash` / random-body absence. Rotation overlap and post-revocation next-request rejection are now tested. |
| B. Timing-attack resistance | No CRITICAL/HIGH/MEDIUM. Step 3 requires hash + SELECT on every keyed request, no early prefix reject, `subtle.ConstantTimeCompare`, and a 100+ request AC-18 variance test for no-match vs revoked. |
| C. Log redaction | LOW L2 only. The central redaction middleware, panic-log rules, nginx access-log stripping, CLI journalctl assertion, and metric-label tests close round-1 H1/M5. One broad "log/metric labels" sentence still mentions prefix where the Step 4 metric rules correctly forbid it. |
| D. Role-grant inventory safety | No findings. The prompt enumerates §7.2.1 through §7.2.4, includes BIGSERIAL sequence grants, keeps `partner_keys_id_seq` outside runtime roles, column-scopes `partner_keys_writer`, and requires separate `*sql.DB` pools. |
| E. CORS and CSRF | LOW L1 only. The prompt now pins key-agnostic 204 preflight, exact-match GET allowlists, absent-Origin rejection, sibling-subdomain wildcard rejection, `Vary: Authorization`, and keyed-response cache tests. A preflight parenthetical is sloppy but overridden by the explicit 7-row GET table and tests. |
| F. Rate-limit fail-closed semantics | No findings. Public nginx and in-process fallback are both retained, nginx `nodelay` is required, stale 503s do not debit the success bucket, and a coarse abuse limiter remains. |
| G. Earnings privacy | HIGH H1. Bucketed default, AC-20, exact-only provider consent, and emergency exact-to-bucketed suppression are fixed. The missing §6.6.2 partner-key exact-dollar disclosure deliverable remains. |
| H. Process isolation | No CRITICAL/HIGH/MEDIUM. Recover wraps the stats subtree, all methods and 405 path are covered, panic tests are injection-style, panic logs are redacted, and `os.Exit`/`log.Fatal` lint is required. |
| I. Cross-spec dependency posture | No findings. SPEC-016 re-pin language explicitly forbids silently rewiring `earnings_rewards_usd`, and the provider-auth memory is now an IMPL-time trust-source gate. |
| J. Operational safety | No findings. Revocation is next-request via per-request hash+SELECT and no in-memory cache; emergency `$` suppression direction is fixed; rotation cadence is in the runbook. |

## CRITICAL findings

None.

## HIGH findings

H1. Partner-key exact-dollar provider disclosure is not a concrete IMPL/cutover deliverable

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 49-52, 413-418, 520-547; locked SPEC §6.6.2 lines 1149-1164.

   **Finding:** The prompt correctly says the SPEC-014 v0.9 portal toggle UI is out of scope and that defaults take effect if it has not landed. It also correctly forbids operator exact-enable and requires emergency `exact -> bucketed` suppression. But it never directs the IMPL author to carry forward the separate §6.6.2 disclosure that trusted partners with operator-issued API keys see exact earnings for all providers, including providers whose public mode is `bucketed`. The only final SPEC-014 follow-up language is generic "portal toggle UI, operator-portal canonical UI, etc." and does not name the broader partner-key exposure disclosure or make it a cutover checklist item.

   **Why it matters:** The locked SPEC intentionally permits partner-key exact-dollar exposure for all rows, but §6.6.2 makes provider disclosure part of the privacy posture. Without a prompt directive, a fresh implementation can ship partner-key exact-dollar projection and partner onboarding while treating SPEC-014 v0.9 as wholly non-blocking, leaving providers without the required disclosure that bucketed public earnings are still exact-visible to trusted keyed partners.

   **Suggested fix:** Add an explicit Step 4.C / final deliverable: `OPS.md` and the SPEC-014 follow-up tracker must include the §6.6.2 disclosure copy, substantially equivalent to the locked SPEC text, before production partner-key issuance or public cutover. If SPEC-014 v0.9 has not landed, the cutover runbook must record how the operator satisfies or blocks on that disclosure obligation; it must not rely on the public bucketed default alone.

## MEDIUM findings

None.

## LOW findings

L1. Preflight parenthetical can be read as public fallback for a non-allowlisted keyed GET

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 222-243.

   **Finding:** The 7-row table correctly says valid key + non-empty allowlist + wrong Origin returns 401, and tests cover one fixture per row plus sibling-subdomain rejection. However, the preflight paragraph says a non-allowlisted Origin gets `*` "AND the public projection on subsequent GET per the §5.4.3 row 1 default." Row 1 is absent Authorization only; a subsequent GET carrying the key must hit row 5 and return 401.

   **Why it matters:** The stronger table and tests prevent a MEDIUM ambiguity, but the parenthetical is security-relevant prose drift from the closed CORS finding. It should say the public projection applies only if the actual GET is anonymous.

L2. Central redaction prose allows prefix in metric labels before Step 4 correctly forbids it

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 274-280, 403-406, 422-426.

   **Finding:** Step 4 metrics correctly use `partner_key_id` only and the metric hygiene test asserts no prefix appears in metric labels. Earlier central-redaction prose says allowed "log/metric labels" include the optional 8-character prefix. This is more permissive than the Step 4 metric rules and the audit category's desired posture.

   **Why it matters:** The later metric contract and tests are clear enough to prevent a MEDIUM implementation ambiguity, but the earlier sentence should distinguish logs from metrics: prefix may appear in logs where permitted, not metric labels.

## INFO observations

I1. Round-1 SECURITY C1 closed: operator exact-enable is now forbidden

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 413-418, 422-425, 493-498, and 532 require only `exact -> bucketed` operator suppression, reject any operator path to `exact`, and keep AC-20 in CI.

I2. Round-1 SECURITY H1/H2/H3/H5/H6 and M1-M5 are materially closed

   **Evidence:** Central redaction and panic-log redaction are explicit at lines 266-280 and 303; cache `Vary: Authorization`, `Cache-Control: private`, nginx cache bypass, and cross-contamination tests are at lines 253-263 and 373-389; nginx `nodelay` and stale-503 non-debit behavior are at lines 251 and 373-389; rotation overlap/revoke tests are at lines 359-368; the 7-row table, no early prefix reject, and constant-time compare are at lines 222-238 and 311-314.

I3. Provider-authentication standing concern is now a kickoff gate

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 40-41 and 160-162 require verifying that rollup `provider_id` is sourced from authenticated `provider_token` plumbing, otherwise filtering to authenticated rows or blocking public cutover, with the decision documented in the Step 2 PR and verified by the SECURITY lane.

## Operator questions

None requiring SPEC changes. H1 can be fixed in the IMPL prompt / cutover checklist without reopening locked SPEC-017 v0.1.6.

## Verdict

- READY WITH FIX PASS

The prompt has reached the target for CRITICAL and MEDIUM but still has one HIGH privacy/disclosure gap. Do not kick off implementation until H1 is added to Step 4.C/final deliverables. L1 and L2 can be cleaned in the same text pass and do not require another SPEC round.

## Self-verification

- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read focused locked SPEC-017 v0.1.6 sections: §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6, plus AC-1 through AC-21.
- [x] Read `SPEC-017-r1-audit.md` through `SPEC-017-r7-audit.md` and verified v2 does not reopen the closed SPEC-round findings, except for the prompt-level disclosure gap above.
- [x] Read the provider-auth unauthenticated end-to-end memory and checked the Step 2 trust-source gate.
- [x] Walked Categories A through J.
- [x] Severity assigned per finding.
- [x] Suggested fix included for every CRITICAL and HIGH finding.
- [x] Verdict included.

## 200-word handback summary

Round 2 is substantially cleaner than round 1. The v2 IMPL prompt now carries the security controls that were missing before: operator exact-enable is forbidden, emergency visibility only goes `exact` to `bucketed`, partner-key issuance hashes `sha256(raw_token_utf8_bytes)` and prints once, keyed requests always hash and SELECT with no prefix early-return, token-derived compares use `subtle.ConstantTimeCompare`, the 7-row auth/CORS table includes absent-Origin rejection, and the AC-18 timing test is multi-sample. Redaction is now central and covers panic logs, nginx, traces, metrics, response bodies, CLI issuance, and random-token substrings. Nginx rate limiting is fail-closed with `nodelay`; stale 503s do not debit the success bucket; keyed responses carry private cache semantics and are bypassed at nginx. DB grants, sequence grants, connection-pool isolation, `partner_keys_writer` column scope, and the provider-identity trust gate are also explicit.

The blocker is §6.6.2 disclosure. The prompt ships partner-key exact-dollar projection for all providers but does not make the required provider disclosure copy a Step 4.C or cutover deliverable. That can let partner keys go live while SPEC-014 disclosure remains a vague follow-up. I also noted two LOW prose cleanups: CORS preflight public-fallback wording and prefix-in-metric-label wording. No fix prompt is included; this file stops at requested audit findings and verification only.
