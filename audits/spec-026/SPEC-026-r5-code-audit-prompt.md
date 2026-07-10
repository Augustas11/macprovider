# SPEC-026 R5 — CODE audit lane

You are re-auditing SPEC-026 v0.5 after the R4 cleanup pass. Read
`SPEC-026-r{1,2,3,4}-audit.md` first — those list what R1-R4
already surfaced and how each version resolved. Do NOT re-flag
anything already fixed.

Your lens is CODE: correctness of citations, buildability of
proposed Swift/Go/SQL surface, consistency with the working tree.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.5)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R5

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§4.3 proof-stage frame example matches SPEC-001 v1.6 §6.7
   literal.** Verify field list (`type`, `version`, `stage`,
   `auth_attempt_id`, `provider_id`, `attestation_token`) is
   accurate and no ECDH field survives in the proof frame body.
2. **§4.5 deep-link scheme `malibu-app://`.** Verify the App's
   `Info.plist` (or wherever URL schemes are declared) supports
   registering an additional scheme, and whether `malibu://` and
   `malibu-app://` collide with anything. If `malibu://` is
   being retired per §7.3, is a fresh scheme cleaner?
3. **§4.6 GET/POST split.** Verify the CSRF-binding-to-GET-page
   pattern is well-defined; usually a hidden field seeded on the
   GET response and validated on POST. Any race between GET and
   POST if the swap-cooling window expires between them?
4. **§5.1 `provider_rewards_ledger` `amount_usd NOT NULL` drop.**
   Verify:
   - Existing consumer code paths for the stats table (any query
     that assumes `amount_usd IS NOT NULL`)
   - Rollup jobs that sum `amount_usd` — do they cope with NULL?
5. **§8.4 marker filename `.installed-by-app`.** Now consistent
   across the spec. Verify.
6. **§8.4 Import flow atomicity.** Verify the roll-back steps
   are actually reversible (Keychain items are user-scoped;
   deletion of a Keychain item that was just written is fine).
7. **§10 Phase 1a / 1b split.** Verify no consumer expects
   `provider_auth_policy` rows immediately after Phase 1a; the
   auth-verifier code shouldn't reference the table until Phase
   1b runs.
8. **`provider_auth_policy_pending` schema.** Verify:
   - `pending_id UUID` is Postgres-native; the coordinator's
     schema is Postgres per the rest of the spec.
   - The `approved_by != requested_by` invariant enforceable
     via a plain check constraint or requires application-level
     enforcement.
9. **§4.5 `provider_email_change_requests` table.** New table
   introduced. Any naming conflict?
10. **§9.3 `cap_replay_pending` flag.** Verify:
    - `provider_identities` is the right home for this flag
      (it's App-track-only). Does the wallet-binding path for
      CLI-track providers also need a similar flag? CLI-track
      providers don't run through App-track onboarding but
      might still have unbound emissions if the CLI-track
      supports them.
11. **§7.3 test file path unchanged from v0.3.** Re-verify.
12. **Entry 102 accuracy.** Verify.

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
