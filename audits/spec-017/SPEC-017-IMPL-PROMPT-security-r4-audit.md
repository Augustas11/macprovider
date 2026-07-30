# SPEC-017 IMPL prompt — SECURITY lane audit, Round 4 (Codex, 2026-06-26T05:22:00Z)

## Summary
- 0 CRITICAL findings
- 1 HIGH finding
- 0 MEDIUM findings
- 0 LOW findings
- 5 INFO observations

Round 4 re-anchors the IMPL prompt to locked SPEC-017 v0.1.7. The prompt correctly absorbs the v0.1.7 security deltas: no public `totals.earnings_*`, partner projection never emits `Access-Control-Allow-Origin: *`, RFC 6454 Origin normalization, 60-second preflight max-age, three-way AC-18 timing, launch-gated partner-key exact-dollar disclosure, and `blocked_from_partner_projection` as a non-consumed v0.1 stub. I found one prompt-level security gap: the pinned middleware order can make the in-process public fallback limiter ineffective for invalid/revoked/rejected-origin keyed requests when nginx is bypassed.

## Category sweep
| Category | Result |
|---|---|
| A. Token handling | PASS. CLI issuance prints the raw `mpk_` token once, hashes `sha256(raw_token_utf8_bytes)`, inserts only hash/prefix metadata, validates allowed origins, forbids reprint, and tests rotation overlap plus next-request revocation. |
| B. Timing-attack resistance | PASS. Every keyed request hashes and SELECTs by `token_hash`; prefix early-return is forbidden; rejected-Origin 401 is included in the same hash+SELECT path; AC-18 is a 100+ request three-way test for rows 5/6/7. |
| C. Log redaction | PASS. Redaction-context middleware is outermost; recover performs its own first-line `Authorization` strip; nginx, journalctl, traces, metric labels, responses, and panic logs are swept for raw token, `token_hash`, and random-token substrings. |
| D. Role-grant inventory safety | PASS. §7.2.1-§7.2.3 are enumerated; BIGSERIAL sequence grants are present for insert-capable runtime roles; `partner_keys_id_seq` remains operator-CLI-only; `partner_keys_writer` is skipped for v0.1 rather than widened; pools are one role per `*sql.DB`. |
| E. CORS and CSRF | PASS. OPTIONS is key-agnostic; GET enforces per-key allowlists; sibling-subdomain wildcards are forbidden; no `Origin` branch controls dollar exposure; partner-key responses use `private` cache semantics and `Vary: Authorization`; public responses do not vary on Authorization. |
| F. Rate-limit fail-closed semantics | HIGH H1. Nginx remains primary and Step 4.B honestly blocks production config on the §5.6/AC-8 conflict, but the application fallback limiter is placed after auth, so nginx-bypass invalid-key traffic can hit hash+SELECT without the fallback bucket. |
| G. Earnings privacy | PASS. Default/no-row mode is bucketed; public totals strip exact dollars; AC-20 forbids operator exact-enable; emergency suppression is exact-to-bucketed only; partner-key exact-dollar broader exposure is launch-gated on provider disclosure. |
| H. Process isolation | PASS. Recover wraps only the stats subtree, including 405 paths; AC-11 is injection-style; panic logs are redacted; lint forbids `os.Exit`/`log.Fatal` under `internal/stats/*`. |
| I. Cross-spec dependency posture | PASS. SPEC-016 re-pin explicitly forbids silently rewiring `earnings_rewards_usd` if SPEC-016 v0.2 introduces a work/rewards split; provider-authentication source trust remains a Step 2 gate. |
| J. Operational safety | PASS. No in-memory key cache is allowed; revocation is per-request hash+SELECT; rotation runbook revokes predecessor after overlap; OPS covers emergency earnings suppression. |

## CRITICAL findings

None.

## HIGH findings

H1. In-process fallback rate limiting can fail open for invalid keyed traffic when nginx is bypassed

   **Location:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md` lines 381-390, 400-404, 422-424, 436; locked SPEC §5.6 lines 1063-1074.

   **Finding:** The prompt says the public nginx limiter is primary and the in-process public bucket is a defense-in-depth fallback if nginx is bypassed. But the pinned middleware stack places the auth dispatcher before the in-process rate-limit middleware. The auth dispatcher hashes and SELECTs every keyed request, then enforces the 7-row table. Invalid tokens, revoked tokens, and rejected-Origin valid tokens return 401 in auth before the rate-limit middleware can key a public fallback bucket. That means a direct-to-coordinator request path during a debugging window can drive unbounded hash+SELECT work with `Authorization: Bearer ...` probes, even though the prompt claims the in-process bucket is the fallback when nginx is absent.

   **Why it matters:** This is a rate-limit fail-open gap on the most expensive unauthenticated auth path. It does not make token brute force realistic because token entropy is high, and it does not weaken AC-18 while traffic is below the limiter. It does, however, let malformed or revoked-key floods bypass the very fallback limiter the prompt relies on for nginx-bypass safety, increasing DoS risk and DB load on the `partner_keys` lookup path.

   **Suggested fix:** Split application limiting into two layers. Add a coarse pre-auth per-IP limiter before `sha256 + SELECT` for every `/v1/stats/*` request, including absent, invalid, revoked, and rejected-Origin Authorization paths. Keep the post-auth success bucket for public/partner accounting so stale 503s still do not debit healthy-client success quotas. Add tests against the direct coordinator surface: repeated invalid-key requests must hit 429 after the fallback threshold, and AC-18 latency samples must run below that threshold so timing equivalence remains measured on non-limited 401s.

## MEDIUM findings

None.

## LOW findings

None.

## INFO observations

I1. v0.1.7 CORS hardening is carried into Step 3

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 310-349 require the 7-row auth table, hash+SELECT before rejected-Origin evaluation, RFC 6454 normalization, key-agnostic 204 preflight, Max-Age 60, exact sibling-origin matching, and partner projection responses that never use `ACAO: *`.

I2. v0.1.7 public earnings-total leak is closed in the IMPL prompt

   **Evidence:** Lines 297-302 and 415 require public leaderboard responses to omit all `totals.earnings_*` keys while the partner-key projection still exposes per-axis exact dollars. Lines 439-441 add negative public-response assertions.

I3. Partner-projection broader exposure is now a hard launch gate

   **Evidence:** Lines 566-581 require OPS disclosure copy, SPEC-014 v0.9 tracker work, and a blocking production partner-key issuance gate with recorded sign-off before any real production key is delivered.

I4. The provider-auth standing concern remains preserved

   **Evidence:** Lines 57-60 and 222-224 require verifying that rollup `provider_id` comes from authenticated `provider_token` plumbing, otherwise filtering to authenticated rows or blocking public cutover, with a Step 2 PR decision and SECURITY review.

I5. The Step 4.B nginx conflict is surfaced rather than silently weakened

   **Evidence:** Lines 508-517 block production nginx rate-limit config until the §5.6/AC-8 conflict is reconciled by a SPEC v0.1.8 candidate or an explicit operator-recorded divergence. The CI-only no-burst harness is labeled non-production.

## Operator questions

None. H1 is an IMPL-prompt hardening fix and does not require changing locked SPEC-017 v0.1.7.

## Verdict

- READY WITH FIX PASS

The prompt should not kick off implementation until H1 is fixed. The locked SPEC does not need to reopen: the prompt already claims nginx-bypass fallback protection, and the fix is to make the application middleware/test directives mechanically enforce that protection for invalid/revoked/rejected-Origin keyed requests.

## Self-verification

- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read focused locked SPEC-017 v0.1.7 sections: §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6, plus related endpoint/cache/error/AC text.
- [x] Read `SPEC-017-r1-audit.md` through `SPEC-017-r8-audit.md` and verified the IMPL prompt does not reopen closed SPEC-round findings except the prompt-level fallback-limiter gap called out above.
- [x] Read the provider-auth unauthenticated end-to-end memory and checked the Step 2 trust-source gate.
- [x] Walked Categories A through J.
- [x] Severity per finding.
- [x] Suggested fix for every CRITICAL and HIGH. H1 includes a suggested fix; no CRITICAL findings.
- [x] Verdict included.

## 200-word handback summary

Round 4 mostly clears the v0.1.7 security re-anchor. The IMPL prompt now preserves the locked token lifecycle, raw-token non-persistence, UTF-8 SHA-256 hash input, no prefix early reject, three-way rejected-origin/no-row/revoked timing test, and central redaction across recover, logs, traces, metrics, nginx, journalctl, and responses. It also carries the v0.1.7 CORS fixes: RFC 6454 normalization, 60-second preflight Max-Age, key-agnostic OPTIONS, exact GET allowlists, no sibling wildcard trust, and no `Access-Control-Allow-Origin: *` on partner-key projections.

The remaining blocker is rate-limit placement. The prompt says nginx is primary and the in-process public bucket is the fallback if nginx is bypassed, but the pinned middleware order runs auth before the in-process limiter. Invalid, revoked, and rejected-Origin keyed requests can therefore hash and SELECT against `partner_keys` and return 401 before any fallback bucket runs. That is a HIGH fail-open hardening gap for direct-to-coordinator/debug-window traffic and a DB DoS risk.

Fix the prompt by adding a coarse pre-auth per-IP limiter before hash+SELECT while keeping post-auth success-bucket semantics for normal public/partner accounting and stale-503 non-debit behavior. No SPEC change is required. No fix prompt is drafted.

The blocker is narrow, testable, and belongs in the IMPL prompt because the SPEC already requires fallback enforcement there before implementation begins.
