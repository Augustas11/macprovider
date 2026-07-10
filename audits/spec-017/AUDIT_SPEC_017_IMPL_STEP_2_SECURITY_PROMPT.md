# AUDIT_SPEC_017_IMPL_STEP_2 — Security lane

Operator-paste prompt to audit the **Step 2 IMPL code** (rollup
pipeline) from the SECURITY lens — role isolation, identity
trust, secret handling, defense-in-depth, attack surfaces Step
2 makes available to Step 3/4.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_2-security-rM-audit.md` (fresh per
round).

---

```
=== BEGIN PROMPT ===

You are auditing the Step 2 IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) from the SECURITY lens — role
isolation, identity, secret handling, defense-in-depth.

Output: specs/SPEC-017-IMPL-STEP_2-security-rM-audit.md (round
M; fresh per round).

Severity model:
- CRITICAL — Step 2 surfaces exact $ on the public projection
  for a bucketed provider; amplifies unauthenticated provider
  identity into the leaderboard; logs raw tokens or DSNs; uses
  the wrong pool (writes via reader / portal); breaks the
  `actor_kind='operator' AND new_mode='exact'` AC-20 invariant.
- HIGH — defense-in-depth gap that wouldn't immediately leak
  but lets a Step 3/4 bug escalate.
- MEDIUM — hardening that two conforming sessions would resolve
  the same way once flagged.
- LOW — polish.
- INFO — observations.

## Critical constraints

1. **Provider-identity trust source** (Step 1 decision record
   at `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`).
   Rollup MUST join on SPEC-002 v1.4 §7 `provider_tokens`. Any
   fallback to `provider_session` / `provider_handshake` / any
   raw hello-frame source is CRITICAL.
2. **Pool isolation** (§7.2.5). Rollup MUST use ONLY
   `statsPools.Rollup`. Writing via `statsPools.Reader` (no
   write grant) silently silently fails or — if the pool was
   miswired — silently widens. Any rollup code path that uses
   any other pool is CRITICAL.
3. **Bucketed-by-default invariant** (§1.5 C2, §6.1). The
   public leaderboard rows for `mode='bucketed'` providers
   MUST have `exact_earnings = null` in the eventual handler
   projection (Step 3 scope). The rollup MUST NOT bake exact
   $ into a public-projection column. If the rollup writes the
   same `earnings_usd` value into a column that Step 3 will
   surface unconditionally, that's CRITICAL — the bucket vs
   exact split is enforced in the projection, not the
   storage; the storage holds exact $ which Step 3 redacts
   when mode='bucketed'.
4. **AC-20 invariant** (§6.6.3). Rollup MUST NOT insert any
   `provider_visibility_audit` row at all (writes happen via
   `provider_portal` from the SPEC-014 v0.9 candidate, OR via
   emergency-suppression operator action). The rollup's role
   is explicitly denied INSERT on `provider_visibility_audit`
   per §7.2.2.
5. **Log redaction** (§5.4.6 + AC-15). Rollup structured logs
   MUST NOT carry raw tokens, `token_hash`, partner-key prefix,
   Origin string, or DSNs. The rollup doesn't touch
   `partner_keys` (denied) but a drift-detection log including
   a `provider_id` sample is fine (`provider_id` is a
   pseudonymizable identifier, not a credential).
6. **Same-origin uniformity** (§6.4). Rollup MUST produce
   identical output regardless of any per-Origin or per-key
   input. Different inputs producing different storage values
   would violate the projection-uniformity invariant.

## Required reading

1. `specs/BUILD_SPEC_017_IMPL_PROMPT.md` §1 prereqs, §5
   critical constraints, §2 Step 2.
2. `specs/SPEC-017-network-stats-api.md` v0.1.8 §1.5, §6.1,
   §6.4, §6.6.2, §6.6.3, §7.2, §7.3.
3. `specs/SPEC-017-IMPL-STEP_1-trust-source-decision.md`.
4. The Step 2 diff.
5. Memory: `[[provider-auth-unauthenticated-end-to-end]]`,
   `[[audit-loop-catches-billing-ledger-drift]]`,
   `[[c2-gate-gateway-credential-validation-asymmetry]]`.

## Security audit categories

### A. Role + pool isolation
A.1  Rollup queries use ONLY `statsPools.Rollup`. No write to
     `statsPools.Reader`, no write to
     `statsPools.ProviderPortal`. Mis-pool is CRITICAL.
A.2  Rollup does NOT issue INSERT/UPDATE on `partner_keys` or
     `provider_visibility_audit` — both denied in §7.2.2.
A.3  Rollup connection pool tuning matches the existing
     write-pool sizing (no surprise widening for parallelism).

### B. Identity trust
B.1  Every leaderboard row's `provider_id` traces back to a
     JOIN on `provider_tokens` (or a view sourced from it).
     No raw hello-frame source.
B.2  PR description records the trust-source decision
     reference (already done in PR #173; verify it remains).

### C. Bucket / projection invariant
C.1  Storage holds exact $ in `earnings_usd`,
     `earnings_work_usd`, `earnings_rewards_usd` for ALL
     providers (the partner projection in Step 3 reads them);
     the public-projection redaction is Step 3 scope.
C.2  Bucket value is a COMPUTED column at storage time, NOT a
     dynamic rendering on the request path. (Storage-time
     computation gives Step 3 a stable single-column read.)
C.3  Bucket boundaries match §6.2 exactly; no operator
     override at runtime (changing thresholds requires SPEC
     bump per §6.2 v0.1.7).

### D. Drift + late events + AC-20
D.1  Drift event emission goes through zerolog with REDACTED
     context; no DSN, no raw token (rollup doesn't see them
     anyway, but the audit must verify).
D.2  Rollup MUST NOT emit any `provider_visibility_audit`
     row. The locked grants block INSERT, but the code should
     ALSO not attempt the INSERT.
D.3  AC-20 SQL assertion runs on every PR (Step 1 wiring);
     Step 2 fixtures MUST NOT seed any operator-exact audit
     row (would break AC-20).

### E. Configuration safety
E.1  `stats.rollup.usd_per_million_credits` — non-negative,
     fail-closed on missing.
E.2  `stats.rollup.late_events_retention_days` — floor 30 OR
     clamp+warn (matches BUILD §2 Step 2 pinned behavior).
E.3  `stats.rollup.backfill_mode` — one of {partial, full}.
E.4  Drift threshold — operator-MAY-tune within sane bounds,
     defaults to 0.5%.

### F. Provider-rewards-ledger handling
F.1  Rollup queries `provider_rewards_ledger` ONLY for
     rewards_populated EXISTS probe + leaderboard
     `earnings_rewards_usd` aggregation. NOT used for
     anything else.
F.2  `provider_rewards_ledger` queries traverse the
     stats_rollup grant (SELECT) only; no UPDATE or INSERT.

### G. Process isolation
G.1  Rollup goroutine panics are recovered; logged with
     redacted context; coordinator process survives (§7.3 +
     §9.6).
G.2  Per-table panic restarts only that table's job, not the
     entire scheduler.

## Output format

Per-category one-line verdict + per-finding entries. Final
verdict block.

`READY TO LOCK` iff 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
