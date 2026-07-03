# SPEC-026 R4 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.4 after the R3 rewrite. Read
`SPEC-026-r{1,2,3}-audit.md` first. Do NOT re-flag anything
already fixed.

Your lens is ARCHITECT: cross-spec composition, right-layer
placement of new primitives, evolvability.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.4)
- `beta/DECISION_CRITERIA.md` Entry 102

## Adjacent SPECs

- SPEC-001 v1.6 §6.7 (v2 auth pipeline)
- SPEC-003 FR-C9
- SPEC-005 §11.4
- SPEC-015 §7.5, §12
- SPEC-016 §3
- SPEC-022, SPEC-023, SPEC-025

## What to check in R4

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO. Skip R1-R3.

1. **v0.4 §4.3 `provider_auth_policy` cross-track table.** Verify:
   - Placing this at the coordinator layer is correct — it
     spans both App-track and CLI-track.
   - Naming and column set don't conflict with any adjacent spec.
   - Migration path (auto-populate legacy rows with 7-day
     exemption) doesn't break existing WS connections
     mid-migration.
2. **v0.4 §4.3 CLI-track receipt-key rotation composition with
   SPEC-015.** Verify the flow matches SPEC-015 §7.5 rotation
   sequencing. If SPEC-015 has a specific
   `provider_receipt_public_key_prev` field on the initial
   frame, is v0.4 using it correctly?
3. **v0.4 §4.5 verified-email flow.** New PII-storing coordinator
   surface. Does its introduction change the SPEC-016 owner? Is
   it something SPEC-016 should own instead? Argue.
4. **v0.4 §4.6 signed cancel URL as a public-facing endpoint.**
   Is a public-web GET endpoint acceptable in the coordinator's
   security posture, given SPEC-002's coordinator surface
   guidance?
5. **v0.4 §5.1 `wallet_daily_malibu_emission` aggregate under
   SERIALIZABLE.** Is Postgres SERIALIZABLE isolation a reasonable
   choice against the coordinator's existing DB workload, or
   does adopting it in one hot path affect other operations?
   Note if this needs a config decision.
6. **v0.4 §5.2 economic + additional criterion.** Verify the
   sybil economics argument in §11 is consistent with the new
   criteria structure. If E3 (operator promotion) counts as
   economic, does that undercut the automated sybil defense?
7. **v0.4 §5.5 72h requalification cooldown.** Any adjacent
   spec assumes Trust tier can flip on demand (e.g. reactive
   downgrade in SPEC-016)?
8. **v0.4 §8.4 import/migration dialog** now defined inline in
   SPEC-026. Should this belong to SPEC-025 instead? SPEC-025
   §3.4 is uninstall-only. Argue.
9. **v0.4 §10 deploy checklist step 1** enumerates all v0.4
   migrations. Are these ordered correctly? Does the schema
   migration require a code deploy first (to add the
   corresponding query support) or can it run standalone?
10. **v0.4 Entry 102 accuracy.** Verify the entry summary
    correctly reflects v0.4 (proof-stage frame, cross-track
    `provider_auth_policy` table, 7-day exemption, two-step
    email verification, economic + additional criteria).

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
