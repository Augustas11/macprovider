# SPEC-017 IMPL prompt — SECURITY lane audit, Round 3 (Codex, 2026-06-26T03:44:57Z)

## Summary
- 0 CRITICAL findings
- 0 HIGH findings
- 0 MEDIUM findings
- 0 LOW findings
- 4 INFO observations

Round 3 confirms that the current `BUILD_SPEC_017_IMPL_PROMPT.md` closes the round-2 SECURITY blocker and the two LOW prose issues. The prompt now makes the §6.6.2 partner-key exact-dollar disclosure a Step 4.C hard cutover deliverable, fixes the CORS preflight wording so a disallowed keyed GET still returns 401, and separates log prefix allowance from the stricter metric-label boundary.

## Category sweep
| Category | Result |
|---|---|
| A. Token handling | PASS. CLI issuance generates a 47-char `mpk_` token, hashes `sha256(raw_token_utf8_bytes)`, inserts only hash/prefix metadata, prints the raw token once, forbids re-printing, and tests raw-token / `token_hash` / random-body absence. Rotation overlap and next-request revocation are tested. |
| B. Timing-attack resistance | PASS. Every keyed request always hashes and SELECTs by `token_hash`, prefix-mismatch early return is forbidden, secret-derived byte comparisons require `subtle.ConstantTimeCompare`, and AC-18 is a 100+ request variance test for no-match vs revoked. |
| C. Log redaction | PASS. Redaction-context middleware is outermost; recover does its own first-line `Authorization` strip; access logs/traces/metrics read redacted context; nginx strips `Authorization`; CLI issuance checks journalctl. Logs may use id/label/prefix, while metrics may use only integer id and bounded enums. |
| D. Role-grant inventory safety | PASS. The prompt enumerates §7.2.1-§7.2.4, includes sequence grants for insert-capable runtime roles, keeps `partner_keys_id_seq` operator-CLI-only, narrows `partner_keys_writer` to `UPDATE(last_used_at)` plus `SELECT(id)`, and requires one `*sql.DB` per role with no shared pools. |
| E. CORS and CSRF | PASS. OPTIONS is key-agnostic and exactly 204; per-key allowlists are enforced only on GET; sibling-subdomain wildcards are forbidden; `Origin` must not affect dollar exposure; keyed leaderboard responses use `Cache-Control: private` and `Vary: Authorization`, with nginx cache-bypass tests. |
| F. Rate-limit fail-closed semantics | PASS. Public nginx limiting remains primary, in-process buckets remain fallback, partner tier keys on `partner_keys.id`, stale 503s are not debited from success buckets, a coarse abuse limiter remains, and nginx `nodelay` is required to reject instead of queue. |
| G. Earnings privacy | PASS. Bucketed is default/no-row behavior; exact public display requires provider-authenticated portal flow; operator exact-enable is forbidden and AC-20 runs in CI; partner-key exact-dollar exposure for all rows now has OPS copy, SPEC-014 tracker entry, and a production partner-key issuance gate. |
| H. Process isolation | PASS. Recover wraps only `/v1/stats/*`, including OPTIONS and 405 path, logs redacted panic events, returns the §5.9 envelope, and AC-11 uses an injected panic to verify `/healthz` survives. `os.Exit`/`log.Fatal` lint is required under `internal/stats/*`. |
| I. Cross-spec dependency posture | PASS. SPEC-016 re-pin language explicitly forbids silently rewiring `earnings_rewards_usd` if SPEC-016 v0.2 adds a split, and the provider-auth memory is a Step 2 trust-source gate before rollup queries. |
| J. Operational safety | PASS. No in-memory key cache is permitted; revocation is per-request hash+SELECT and next-request effective; rotation runbook revokes predecessor after overlap; emergency earnings suppression allows only `exact -> bucketed`. |

## CRITICAL findings

None.

## HIGH findings

None.

## MEDIUM findings

None.

## LOW findings

None.

## INFO observations

I1. Round-2 SECURITY H1 is closed by the Step 4.C disclosure gate

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 448-456 now require OPS disclosure copy substantially equivalent to SPEC §6.6.2, a SPEC-014 v0.9 onboarding-flow tracker item, and a cutover-runbook checkbox before the first production partner key is issued. It explicitly says this blocks production partner-key issuance, while staging keys are exempt.

I2. Round-2 SECURITY L1 is closed by the preflight/GET split

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 253-264 say preflight is key-agnostic, per-key allowlists are enforced only on GET, and the subsequent GET is evaluated by the 7-row decision table exactly. A keyed GET with a non-empty allowlist and non-matching Origin returns 401 regardless of what preflight returned.

I3. Round-2 SECURITY L2 is closed by separate log and metric allowances

   **Evidence:** `BUILD_SPEC_017_IMPL_PROMPT.md` lines 300-304 now distinguish logs from metric labels. Logs may reference `partner_keys.id`, `partner_keys.label`, and the 8-char prefix; metric labels may reference only integer `partner_keys.id` and bounded enums, and must not include prefix, label text, token hash, raw token, random substring, Origin, or untrusted input. Step 4 metrics and tests reinforce the same boundary at lines 429-435 and 460-462.

I4. The provider-auth standing concern is still preserved as an IMPL-time gate

   **Evidence:** The provider-auth memory says live beta historically accepted attacker-controlled hello-frame identity. `BUILD_SPEC_017_IMPL_PROMPT.md` lines 40-41 and 170-172 require verifying that rollup `provider_id` comes from authenticated `provider_token` plumbing, otherwise filtering to authenticated rows or blocking public cutover, with the trust-source decision documented in Step 2 and reviewed by SECURITY.

## Operator questions

None.

## Verdict

- READY TO KICK OFF IMPLEMENTATION

The r3 IMPL prompt meets the security lock target for this audit lane: 0 CRITICAL + 0 HIGH + 0 MEDIUM. I found no remaining prompt-level security gap that would let a conforming IMPL author weaken the locked SPEC's token handling, timing resistance, redaction, role isolation, CORS/cache boundaries, fail-closed rate limiting, earnings privacy, process isolation, cross-spec dependency posture, or operational revocation/suppression semantics.

## Self-verification

- [x] Read `BUILD_SPEC_017_IMPL_PROMPT.md` fully.
- [x] Read focused locked SPEC-017 v0.1.6 sections: §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6, plus related ACs.
- [x] Read `SPEC-017-r3-audit.md` through `SPEC-017-r7-audit.md` and verified the IMPL prompt does not reopen closed SPEC-round findings.
- [x] Read the provider-auth unauthenticated end-to-end memory and checked the Step 2 trust-source gate.
- [x] Walked Categories A through J.
- [x] Severity per finding.
- [x] Suggested fix for every CRITICAL and HIGH. Not applicable; no CRITICAL or HIGH findings.
- [x] Verdict included.

## 200-word handback summary

Round 3 clears the SECURITY lane. The current IMPL prompt now carries the directives needed to keep SPEC-017's locked security posture intact: partner tokens are generated with CSPRNG entropy, printed once, stored only as `sha256(raw_token_utf8_bytes)`, never cached for auth, and revoked on the next request. Keyed auth always hashes and SELECTs, never early-rejects on prefix mismatch, uses constant-time secret comparison where needed, and tests no-match versus revoked latency with 100+ samples. Redaction is centralized and defense-in-depth: recover strips `Authorization`, logs/traces/metrics/responses/nginx/journalctl are swept for raw token, `token_hash`, and random-token substrings, while metrics are narrowed to integer IDs and enums only.

Role isolation is explicit: exact grant inventories, sequence grants, column-scoped `partner_keys_writer`, and separate `*sql.DB` pools. CORS preflight is key-agnostic, GET enforces per-key origins, sibling wildcards are forbidden, and keyed cache isolation is tested. Rate limiting keeps nginx primary, in-process fallback, `nodelay` rejection, and stale-503 non-debit semantics. Earnings privacy is also closed: bucketed default, no operator exact-enable, emergency exact-to-bucketed only, and a hard §6.6.2 disclosure gate before production partner-key issuance. Provider-auth trust remains a Step 2 gate. No fix prompt is drafted. This r3 audit therefore recommends kickoff without another security prompt fix round under the locked SPEC and current step gates.
