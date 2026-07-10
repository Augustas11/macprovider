# SPEC-026 R6 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.6 after the R5 cleanup pass.
Read `SPEC-026-r{1,2,3,4,5}-audit.md` first. Do NOT re-flag
anything already fixed.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.6)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R6

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§5.1 Postgres projection introduces a new coordinator
   subsystem** (replication worker + projection table + staleness
   monitoring). Is this the right layer for the introduction?
   Should it belong to a new SPEC (e.g. "coordinator cross-DB
   projections") or is a §5.1 sub-section acceptable?
2. **§4.6 `provider_wallet_swaps` addendum to SPEC-016.** The
   SPEC-016 addendum is called out but not co-committed. Does
   the current PR need to include a preview or is
   "impl PR gates on this" sufficient?
3. **§7.3 `malibu-app://` scheme.** Does introducing a distinct
   scheme (vs reusing `malibu://` with path-based dispatch)
   fragment the user's URL-scheme allowlist? Note tradeoff.
4. **§4.5 `provider_email_change_requests` state machine.**
   Verify the state machine composes cleanly with SPEC-016's
   payout-address swap state machine — an in-flight email
   change AND an in-flight wallet swap concurrently could
   interact.
5. **§9.3 fresh-install ratification** — does this add a
   coordinator-side dependency between the SPEC-016 §3
   binding path and the SPEC-026 email path that SPEC-016
   doesn't know about? Argue.
6. **§10 Phase 1a schema list.** With all the new tables
   (`provider_auth_policy`, `provider_auth_policy_pending`,
   `provider_email_change_requests`, `provider_emission_state`,
   `provider_payout_addresses_projection`,
   `provider_wallet_swaps`, `wallet_daily_malibu_emission`,
   plus the `provider_rewards_ledger` extension), is this too
   much surface for one SPEC? Argue whether v0.6 should split
   into multiple SPECs.

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec §>
Concern: <what breaks or drifts>
Blast radius: <who is affected>
Fix: <concrete change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
