# SPEC-017 IMPL prompt — SECURITY lane audit, Round 6 (Codex, 2026-06-26T09:58:00Z)

## Summary
- 0 CRITICAL findings
- 0 HIGH findings
- 0 MEDIUM findings
- 0 LOW findings
- 6 INFO observations

Round 6 audits the v9 IMPL kickoff prompt re-anchored to locked SPEC-017 v0.1.8. The two SECURITY r5 findings are absorbed: Step 4.B now requires `proxy_no_cache` alongside `proxy_cache_bypass` for Authorization-bearing requests, and Step 3 now pins trusted-proxy allowlist handling before trusting `X-Forwarded-For` for the auth-failure limiter. I found no remaining prompt-level security gap that would let a conforming IMPL author weaken the locked token-handling, timing-resistance, log-redaction, role-isolation, CORS/cache, fail-closed rate-limit, earnings-privacy, process-isolation, cross-spec, or operational-safety posture.

## Category sweep
| Category | Result |
|---|---|
| A. Token handling | PASS. CLI issuance prints the raw `mpk_` token once, computes `sha256(raw_token_utf8_bytes)`, stores only hash/prefix metadata, forbids `--burst`, forbids token reprint, validates allowed origins, and tests rotation overlap plus predecessor revocation. |
| B. Timing-attack resistance | PASS. Every keyed request hashes and SELECTs by `token_hash`; prefix early-return is forbidden; rejected-Origin/no-row/revoked paths are covered by the same hash+SELECT rule; AC-18 is a 100+ sample three-way test run below limiter thresholds. |
| C. Log redaction | PASS. Redaction-context middleware is outermost; recover performs its own `Authorization` strip; handler logs, panic logs, traces, journalctl, nginx access logs, response bodies, and metric labels are swept for raw token, `token_hash`, and random-token substrings. |
| D. Role-grant inventory safety | PASS. The prompt enumerates §7.2.1-§7.2.3, skips `partner_keys_writer` by default instead of widening it, keeps `partner_keys_id_seq` operator-CLI-only, includes required BIGSERIAL sequence grants, and requires one `*sql.DB` per active role with no shared pools. |
| E. CORS and CSRF | PASS. OPTIONS is key-agnostic and exactly 204; GET enforces per-key origins; sibling subdomain wildcards are forbidden; no `Origin` branch controls `$` exposure; partner-key projections never use `ACAO: *`; keyed responses are `private` and vary on `Authorization`. |
| F. Rate-limit fail-closed semantics | PASS. v0.1.8 removes burst from public and partner tiers, pins nginx `nodelay`, keeps nginx public limiting primary, keeps in-process fallback, adds the pre-hash auth-failure limiter, and verifies spoofed `X-Forwarded-For` cannot bypass direct-to-coordinator limiting. |
| G. Earnings privacy | PASS. No-row/default mode is bucketed; public projection omits exact totals; operator exact-enable is forbidden; emergency suppression is only `exact -> bucketed`; partner-key exact-dollar exposure remains gated on SPEC-014 v0.9 disclosure and operator sign-off. |
| H. Process isolation | PASS. Recover wraps only `/v1/stats/*`, including OPTIONS and 405 paths; AC-11 is injection-style and verifies `/healthz`; panic logs are redacted; lint forbids `os.Exit`, `log.Fatal`, `log.Fatalf`, and equivalents under `internal/stats/*`. |
| I. Cross-spec dependency posture | PASS. SPEC-016 re-pin language forbids silently rewiring `earnings_rewards_usd` if SPEC-016 v0.2 introduces a split, and the provider-auth memory is preserved as a Step 2 trust-source gate before rollup queries. |
| J. Operational safety | PASS. No in-memory key cache is allowed; revocation takes effect on the next request through per-request hash+SELECT; rotation runbook revokes the predecessor after overlap; OPS covers incident revocation and emergency earnings suppression. |

## CRITICAL findings

None.

## HIGH findings

None.

## MEDIUM findings

None.

## LOW findings

None.

## INFO observations

I1. SECURITY r5 C1 is closed by nginx no-store directives

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` Step 4.B now explains that `proxy_cache_bypass` prevents cache reads but not cache writes, and requires both `proxy_cache_bypass $http_authorization;` and `proxy_no_cache $http_authorization;`. It also requires a test proving a successful partner-key request leaves no reusable cache entry for that URL+Authorization combination.

I2. SECURITY r5 H1 is closed by trusted-proxy IP derivation

   **Evidence:** Step 3's auth-failure limiter now uses `r.RemoteAddr` unless the immediate peer is in an operator-configured trusted-proxy allowlist. The test rotates spoofed `X-Forwarded-For` values from one direct socket and requires the 301st request to return 429, then separately verifies trusted localhost nginx parsing.

I3. v0.1.8 rate-limit reconciliation is carried into implementation guidance

   **Evidence:** The prompt anchors to SPEC-017 v0.1.8, removes `partner_keys.rate_limit_burst` and `--burst`, requires public `rate=60r/m` with no `burst=` parameter, requires `limit_req ... nodelay`, and adds AC-22 for the auth-failure tier.

I4. Authorization-aware nginx keying is now explicit

   **Evidence:** Step 4.B says the public `limit_req_zone` MUST NOT throttle Authorization-bearing requests at the edge, and provides map-based or split-location shapes so valid partner traffic is not capped by the public 60 rpm tier before the coordinator can apply the per-key 600 rpm bucket.

I5. Prior SPEC-round security-shaped findings remain closed

   **Evidence:** The prompt keeps the 47-character token format, deferred rewards-source posture, key-agnostic CORS preflight, exact role inventories, BIGSERIAL sequence grants, operator-CLI-only `partner_keys_id_seq`, and no silent SPEC-016 Q13 closure.

I6. Provider-authentication standing concern remains a kickoff gate

   **Evidence:** The prompt requires verifying that rollup `provider_id` is sourced from authenticated `provider_token` plumbing, not raw hello-frame payloads. If production remains unauthenticated, the IMPL author must filter to authenticated rows or block public cutover, and document the decision for Step 2 SECURITY review.

## Operator questions

None.

## Verdict

- READY TO KICK OFF IMPLEMENTATION

The v9 / v0.1.8 IMPL prompt meets the SECURITY lane target: 0 CRITICAL + 0 HIGH + 0 MEDIUM. No fix prompt is drafted.

## Self-verification

- [x] Read `specs/BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read focused locked SPEC-017 v0.1.8 sections: §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6, plus §7.4 and AC-1 through AC-22 where needed for security coverage.
- [x] Read `SPEC-017-r1-audit.md` through `SPEC-017-r7-audit.md` and checked that closed security-shaped SPEC findings are not reintroduced by the IMPL prompt.
- [x] Reviewed current v0.1.8/r9/r10 context and prior IMPL-prompt SECURITY rounds r1 through r5 for closure continuity.
- [x] Read the provider-auth unauthenticated end-to-end memory and checked the Step 2 trust-source gate.
- [x] Walked Categories A through J.
- [x] Severity per finding. No findings required severity assignment beyond zero-count sections.
- [x] Suggested fix for every CRITICAL and HIGH. Not applicable; no CRITICAL or HIGH findings.
- [x] Verdict included.

## 200-word handback summary

Round 6 clears the SECURITY lane for the v9 IMPL prompt anchored to SPEC-017 v0.1.8. The prompt now preserves the locked partner-key lifecycle: 47-character `mpk_` tokens, CSPRNG entropy, `sha256(raw_token_utf8_bytes)`, print-once stdout handling, no raw-token persistence, no token reprint, rotation overlap, and next-request revocation. It keeps the timing controls: every keyed request hashes and SELECTs, rejected-Origin/no-row/revoked 401 paths share work, no prefix early-return is allowed, and AC-18 uses 100+ samples below limiter thresholds.

The prior r5 blockers are fixed. Authorization-bearing nginx responses now use both `proxy_cache_bypass` and `proxy_no_cache`, so partner-key exact-dollar responses are neither read from nor saved into the public cache. The direct-to-coordinator auth-failure limiter now keys client IP through a trusted-proxy allowlist and ignores spoofed `X-Forwarded-For` when the immediate peer is untrusted. v0.1.8 also removes burst ambiguity, adds Authorization-aware nginx keying, and adds AC-22.

Redaction, metric-label hygiene, role inventories, sequence grants, CORS preflight/GET split, partner projection cache privacy, operator no-exact-enable, SPEC-014 disclosure gate, process isolation, SPEC-016 re-pin, and provider-auth trust-source gate all remain explicit. No CRITICAL/HIGH/MEDIUM/LOW findings remain. No fix prompt is drafted. That scope matches the requested audit target: the IMPL prompt itself, not the locked SPEC, and stops at audit findings without drafting remediation or proposing changes.
