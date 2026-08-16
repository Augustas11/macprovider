# AUDIT_SPEC_017_IMPL_PROMPT — Security lane

Operator-paste prompt to audit `BUILD_SPEC_017_IMPL_PROMPT.md` from the security lens.

Severity model: CRITICAL / HIGH / MEDIUM / LOW / INFO. Lock target: 0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes a fresh file: `specs/SPEC-017-IMPL-PROMPT-security-rN-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the IMPL kickoff prompt
/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_IMPL_PROMPT.md
from the SECURITY lens.

Your audit target is the IMPL prompt itself, NOT the SPEC. The SPEC
(`specs/SPEC-017-network-stats-api.md` v0.1.6) is LOCKED. Your job
is to find security gaps in the IMPL prompt — missing isolation
directives, missing log-redaction directives, missing timing-attack
mitigations, missing role-grant safety, missing CSRF / CORS hardening,
missing rate-limit fail-closed semantics, missing token-handling
hygiene.

Output: /Users/augstar/macprovider-spec-017/specs/SPEC-017-IMPL-PROMPT-security-r1-audit.md
(round N writes SPEC-017-IMPL-PROMPT-security-rN-audit.md; new file each round.)

Severity:
- **CRITICAL** — would cause IMPL author to ship code with a
  privilege-escalation, data-leak, replay, or token-theft
  vulnerability. Or would cause the IMPL author to silently widen
  the §7.2 grant inventory, leak the raw partner token, or expose
  exact $ to a non-opted-in provider.
- **HIGH** — would cause IMPL author to ship code with a
  significant security hardening gap (timing-attack window, rate-
  limit fail-open, log redaction missing on a non-obvious surface,
  CORS allowlist not enforced).
- **MEDIUM** — ambiguity in the IMPL prompt that two conforming
  authors could resolve such that one is hardened and one is not.
- **LOW** — security-relevant prose hygiene.
- **INFO** — observations.

## Critical constraints to honor while auditing

1. The SPEC is LOCKED. Any finding that would require a SPEC
   change is HIGH or CRITICAL.
2. The four locked design picks (separate rollup, public+keyed
   leaderboard, bucketed default + opt-in exact, embed) are NOT
   security tradeoffs to re-litigate — but the IMPL prompt MUST
   not weaken the security stance the SPEC pins.
3. The SPEC pins:
   - Hashed token storage (§5.4.1) — raw token never persists
     server-side.
   - Timing-attack resistance (§5.4.3, AC-18) — equal latency
     for "no match" / "revoked".
   - Log redaction (§5.4.6, AC-15) — no raw token, no
     `token_hash`, no random-portion substring in any log.
   - DB role isolation (§7.2.1-§7.2.5) — request-path role can
     never reach billing/session OLTP.
   - Process isolation (§7.3, AC-11) — recover middleware
     contains stats panics.
   - CORS uniformity (§5.7) — no Origin-conditional `$` exposure.
   - Earnings privacy (§6.1, §6.3, §6.6) — bucketed default;
     exact only with explicit provider opt-in via authn'd portal.
4. Any IMPL-prompt directive that would let the IMPL author
   accidentally or deliberately weaken any of these is CRITICAL or
   HIGH.

## Required reading

1. `/Users/augstar/macprovider-spec-017/specs/BUILD_SPEC_017_IMPL_PROMPT.md`
   — the document under audit.
2. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-network-stats-api.md`
   v0.1.6 — focus on §3.7, §5.4, §5.6, §5.7, §6.6, §7.2, §7.3, §7.6.
3. `/Users/augstar/macprovider-spec-017/specs/SPEC-017-r1-audit.md`
   through `SPEC-017-r7-audit.md` — many round findings were
   security-shaped (round-1 C3 storage assumption, round-2 C1
   token format, round-3 M2 CORS preflight, round-5 M2 grant
   gap). Verify the IMPL prompt doesn't re-introduce any closed
   round-finding.
4. `/Users/augstar/.claude/projects/-Users-augstar-macprovider-poc/memory/provider-auth-unauthenticated-end-to-end.md`
   — the operator's standing concern about identity authentication
   end-to-end. Verify the IMPL prompt does not introduce new
   classes of this problem.

## Security audit categories

### A. Token handling
A.1  Raw partner token never persists server-side (SPEC §5.4.1).
     Verify the IMPL prompt §2 step 4 CLI directive prints once to
     stdout, hashes, and discards.
A.2  Token hash storage is `sha256(token_utf8)` (SPEC §5.4.2).
     Verify the IMPL prompt cites the same input encoding (UTF-8
     bytes) to avoid hash-key-domain confusion.
A.3  Token prefix (8 chars, includes `mpk_`) MAY appear in logs;
     full token MUST NOT. Verify the IMPL prompt's redaction
     directives match.
A.4  Token comparison is constant-time? The IMPL prompt SHOULD
     direct the author to compare via `subtle.ConstantTimeCompare`
     or equivalent. If it doesn't, MEDIUM.
A.5  Rotation flow: predecessor key remains valid during overlap
     (§5.4.4). Verify the IMPL prompt directs the operator runbook
     to set revoked_at on the predecessor after rotation, and the
     CI test asserts the overlap window.

### B. Timing-attack resistance
B.1  Same hash + SELECT pattern for "no match" and "revoked"
     paths (§5.4.3 step 2, AC-18). Verify the IMPL prompt step 3
     directives produce identical SQL+hash latency profile for
     both cases.
B.2  No early-return on prefix mismatch. The IMPL prompt should
     direct: always hash + always SELECT, regardless of prefix.
     If it permits an "early reject on prefix mismatch" optimization,
     HIGH.
B.3  AC-18 statistical test variance ≤ 20%. Verify the IMPL prompt
     directs a multi-sample test (100+ requests), not a one-shot
     probe.

### C. Log redaction
C.1  No raw token in journalctl (AC-15). Verify the IMPL prompt
     step 3 + step 4 directives include explicit middleware that
     strips `Authorization` from every log emission, not just the
     stats handler's structured log.
C.2  No raw token in metric labels. The IMPL prompt directs
     `partner_keys.id` as the metric label, NOT the prefix or
     raw token. Verify.
C.3  No raw token in nginx access logs. The IMPL prompt step 4
     directs `Authorization` header strip in nginx. Verify the
     directive is normative, not optional.
C.4  No raw token in error responses. The IMPL prompt §5.9 error
     envelope rules MUST be respected. Verify.
C.5  No raw token in the §7.3 recover-middleware panic log.
     Verify the IMPL prompt directs the recover middleware to
     redact `Authorization` before logging.

### D. Role-grant inventory safety
D.1  `stats_reader` SELECT inventory matches §7.2.1 exactly. The
     IMPL prompt MUST NOT direct the author to widen this set,
     even "temporarily for debugging".
D.2  `stats_rollup` write inventory matches §7.2.2 exactly. The
     IMPL prompt MUST NOT permit writes to `partner_keys` or
     `provider_visibility_audit` from this role.
D.3  `provider_portal` write inventory matches §7.2.3 exactly.
     No `stats_*` grants. No OLTP grants.
D.4  `partner_keys_writer` is column-scoped UPDATE on
     `last_used_at` only. Verify the IMPL prompt §2 step 1
     directive doesn't accidentally widen to row-level UPDATE.
D.5  BIGSERIAL sequence grants (USAGE+SELECT). Verify the IMPL
     prompt step 1 directives include these for every BIGSERIAL
     INSERT path.
D.6  `partner_keys_id_seq` is operator-CLI-only. Verify the IMPL
     prompt does NOT grant this sequence to any runtime role.
D.7  Connection-pool isolation: separate `*sql.DB` per role
     (§7.2.5). The IMPL prompt MUST NOT permit a "shared pool
     for convenience" optimization.

### E. CORS and CSRF
E.1  Preflight (`OPTIONS`) is key-agnostic per §5.7. The IMPL
     prompt MUST NOT direct the author to evaluate `Authorization`
     during preflight (the browser doesn't send it).
E.2  Per-key `allowed_origins` enforced on GET, not OPTIONS.
     Verify the IMPL prompt's CORS-handler directives are
     consistent.
E.3  No Origin-conditional `$` exposure (§6.4). Verify the IMPL
     prompt forbids `Origin == portal.malibu.tech` special-case
     branches.
E.4  CSRF: stats endpoints are GET-only and idempotent, so CSRF
     is N/A for state. BUT the partner-key projection is
     `Cache-Control: private`. Verify the IMPL prompt's
     `Vary: Authorization` directive is consistent with edge-cache
     behavior to prevent cross-key leakage.
E.5  Subdomain trust: `console.malibu.tech`, `portal.malibu.tech`,
     and `stats.malibu.tech` are sibling subdomains. The IMPL
     prompt CORS allowlist directives MUST NOT permit any
     subdomain wildcards.

### F. Rate-limit fail-closed semantics
F.1  Public tier nginx `limit_req_zone` is primary, in-process
     bucket is fallback (§5.6). Verify the IMPL prompt step 4
     directives don't accidentally remove either tier.
F.2  Rate limit on the 503-error response: does the IMPL prompt
     direct counting 503 stale responses against the per-IP
     bucket, or NOT? The SPEC doesn't pin this; the IMPL prompt
     should pin it explicitly to prevent a "stale-rollup floods
     rate limit, healthy clients can't get through" failure mode.
F.3  Burst handling: nginx `nodelay` vs `delay` semantics.
     The IMPL prompt MUST direct fail-closed (429 quickly) rather
     than fail-slow (queue + serve after delay).

### G. Earnings privacy
G.1  Default `mode = 'bucketed'` for new providers (§6.1). The
     IMPL prompt MUST NOT direct any path that defaults to
     `exact`.
G.2  `provider_visibility_audit.new_mode = 'exact' AND
     actor_kind = 'operator'` is forbidden (§6.6.3, AC-20). The
     IMPL prompt MUST direct a CI assertion test for this.
G.3  Partner-key projection exposes exact `$` for all rows
     regardless of `mode` (§6.6.2). Verify the IMPL prompt
     directs the OPERATOR-onboarding disclosure copy that the
     SPEC requires, NOT just the per-provider opt-in disclosure.

### H. Process isolation
H.1  Recover middleware wraps the stats subtree only (§7.3). The
     IMPL prompt MUST NOT direct the recover middleware to wrap
     other coordinator surfaces (would mask non-stats panics).
H.2  AC-11 verifies /healthz survives a stats panic. Verify the
     IMPL prompt directs an injection-style test, not a "log
     manual panic" test.
H.3  Stats handler MUST NOT call os.Exit / log.Fatal. The IMPL
     prompt should direct a lint or convention against this.

### I. Cross-spec dependency posture
I.1  SPEC-016 re-pin (§1 prereq 3). The IMPL prompt directs the
     author to re-check SPEC-016 line 3 at IMPL time. Verify the
     directive is unambiguous about the SECURITY implication of
     "what if SPEC-016 v0.2 splits work/rewards" — silently
     rewiring `earnings_rewards_usd` to the new source would
     close §11 Q13 in code without operator approval.

### J. Operational safety
J.1  Partner-key revocation takes effect on next request, not
     N+1 (§5.4.5). Verify the IMPL prompt directs no in-memory
     key cache that would survive revocation.
J.2  Operator runbook for emergency $-suppression: if a provider
     reports their exact-mode opt-in was wrong, operator MAY
     flip exact → bucketed unilaterally (§6.6.3). Verify the
     IMPL prompt OPS.md directive covers this.

## Output format

Same shape as ARCH lane.

## Self-verification

- [ ] Walked Categories A through J.
- [ ] Severity per finding.
- [ ] Suggested fix for every CRITICAL and HIGH.
- [ ] Verdict.

Print a 200-word handback summary. Do NOT begin drafting a fix
prompt.

=== END PROMPT ===
```
