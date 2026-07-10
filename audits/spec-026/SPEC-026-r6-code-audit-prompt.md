# SPEC-026 R6 — CODE audit lane

You are re-auditing SPEC-026 v0.6 after the R5 cleanup pass. Read
`SPEC-026-r{1,2,3,4,5}-audit.md` first. Do NOT re-flag anything
already fixed.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.6)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R6

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§2 grounding text matches proof-stage placement.** Verify.
2. **§4.3 CHECK constraint syntax** on `provider_auth_policy_pending`.
   Verify valid Postgres.
3. **§5.1 `provider_emission_state` cross-track table.** Verify:
   - No naming collision.
   - Migration path is coherent.
   - `provider_id` primary key without a foreign key allows
     rows for provider_ids that no longer exist elsewhere;
     is that OK, or should we FK to a cross-track providers
     table?
4. **§5.1 Postgres projection of `provider_payout_addresses`.**
   Verify:
   - Replication worker approach is buildable (SQLite WAL is
     readable via `sqlite3_wal_checkpoint` or similar).
   - The 60s staleness threshold is measured correctly.
5. **§4.6 `provider_wallet_swaps` DDL.** Verify:
   - State enum is complete for all documented transitions.
   - `provider_id` doesn't need a foreign key.
6. **§4.5 `provider_email_change_requests` DDL** (added to §10
   Phase 1a). Verify the columns match §4.5 prose usage
   (`pending_change_id`, `authority_state`, etc).
7. **§7.3 `CFBundleURLTypes` snippet.** Verify YAML shape is
   correct for `project.yml` and that `LSHandlerRank` is a
   valid key.
8. **§9.3 fresh-install ratification path** — verify:
   - `email_authority_state` column exists on the right table
     (should be `provider_email_change_requests` or its
     confirmed sibling on `provider_identities`).
   - The 500 USDC threshold is the same one referenced in the
     fail-closed rule.
9. **AC-026-12 v0.6 rewrite.** Verify all four bullet points
   are enforceable.
10. **Entry 102 update.** Verify accuracy against v0.6.

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <file:line or spec §>
Claim: <one-line summary>
Evidence: <what you found>
Fix: <concrete change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
