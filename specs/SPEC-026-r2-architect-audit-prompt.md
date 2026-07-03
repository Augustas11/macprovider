# SPEC-026 R2 — ARCHITECT audit lane

You are re-auditing SPEC-026 v0.2 after the R1 rewrite. Read
`specs/SPEC-026-r1-audit.md` first for the R1 findings and v0.2
dispositions.

Your lens is ARCHITECT: does v0.2 compose cleanly with adjacent
SPECs, does it hold under evolution, are the abstractions placed at
the right layer, does the migration story survive contact with users
mid-flight?

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.2)
- `beta/DECISION_CRITERIA.md` Entry 102 (updated)

## Adjacent SPECs to read for consistency

- `specs/SPEC-001-phase3-binary.md` (esp. v1.6 §6.7 v2 `auth_request`
  and any challenge frame that precedes it)
- `specs/SPEC-003-open-onboarding.md` (FR-C9 self-mint + TOFU)
- `specs/SPEC-015-receipts.md` (§12 receipt key + rotation)
- `specs/SPEC-016-payout-pipeline.md` (§3 EIP-712 wallet
  proof-of-possession + cooling + swap semantics)
- `specs/SPEC-022-verified-model-settlement.md`
- `specs/SPEC-023-installer-autotune-recommend.md`
- `specs/SPEC-025-native-mac-app.md`

## What to check in R2

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO. Do NOT re-flag
R1 findings that v0.2 resolved — flag only:

1. **Cross-spec consistency after v0.2 changes.** v0.2 pushed a lot
   of authority to adjacent SPECs (SPEC-016 for wallet binding,
   SPEC-001 v1.6 for v2 auth_request, SPEC-023 for on-device
   autotune, SPEC-005/016 for unpaid ledger backlog). Verify each:
   - SPEC-016 §3 accepts an `Authorization: Bearer` from an
     App-track `provider_token` and does the EIP-712 check without
     needing changes.
   - SPEC-001 v1.6 §6.7 v2 `auth_request` already carries
     `provider_id`, `binary_version`, and `ecdh_pubkey`, or has
     room for them. If SPEC-026 §4.3 example shape doesn't match
     the existing v1.6 frame layout, that's HIGH.
   - SPEC-023 local `autotune --recommend --json` doesn't require
     coordinator input that v0.2 §6.1 step 7c is missing.
2. **`provider_id` derivation and settlement compatibility.**
   SPEC-022 settles on receipt-key-signed receipts. SPEC-026
   `provider_id` is derived from a DIFFERENT key (identity). Does
   any part of SPEC-022 or SPEC-016 look up provider_id from the
   receipt key or receipt signature? If yes, the two-key world
   creates a lookup gap.
3. **Identity-key rotation deferral (§13, §3.2).** Spec explicitly
   defers rotation. What's the failure mode if Ed25519 is
   compromised industry-wide? Emergency migration is undefined.
   Flag as MEDIUM only if the risk is realistic on the SPEC-026
   time horizon.
4. **Migration matrix (§8.1).** Verify:
   - Fresh + flag-on runs SPEC-026 §6 flow — obvious.
   - v1-complete + flag-on is "live" with an optional migration
     button — is the migration itself defined anywhere? Answer:
     "future spec; no-op in v0.2." Is that acceptable, or does
     v0.2 need to at least state what migration would require
     (both `provider_id`s coexist? old is redirected?)?
   - v2-partial + flag-off runs "Complete Malibu onboarding" —
     but the user just downgraded via Sparkle; how do they know
     to click a menu-bar action? A stranded v2-partial user
     with flag off may just uninstall.
5. **Deploy checklist ordering (§10).** Step 2 depends on step 1
   (schema before register endpoint). Step 3 depends on step 2
   (App Attest verify uses the register endpoint's clientDataHash
   context). Step 4 depends on step 2 AND SPEC-016 §3 being
   already-deployed (does the coordinator already have SPEC-016 §3
   at prod?). Verify each dependency is captured.
6. **CLI-track retirement observability (§4.4).** Retirement
   trigger is "portal counter < 10/day for 14 consecutive days."
   That's fine as a rate but doesn't say who owns pulling the
   trigger. Unassigned action items rot. Note as LOW.
7. **`identity_signature` optional-forever for CLI track (§4.3).**
   CLI track continues bearer-only forever. That's a permanent
   trust-boundary asymmetry between the two tracks. Is the CLI
   track's trust boundary weaker than App track's, and if so, does
   anything downstream (SPEC-022 settlement, SPEC-016 payout)
   distinguish? If not, the App-track hardening is theater against
   attackers who just target CLI-track. Note as MEDIUM.
8. **Provisional $MALIBU non-withdrawable enforcement.** Where in
   the spec-network is this actually enforced — SPEC-005 accounting,
   SPEC-016 payout runner? v0.2 declares it but doesn't cite the
   enforcement path.
9. **Per-wallet emission cap (§5.1) enforcement.** Same question.
   Cap crosses `provider_id` boundaries, so accounting has to sum
   at the wallet layer. Is this a new SPEC-016 primitive?
10. **New `earnings` endpoint (§9.1).** Introduced offhand:
    `GET /v1/providers/{id}/earnings`. Not called out in §4 as a
    new API. Should be explicit if it's new.
11. **Trust-tier chip (§5.3) buyer UI surface.** Reference to a
    "green verified Mac hardware chip on buyer-facing UI" — is
    there a spec for the buyer UI? If not, this is a UX assertion
    without a home; note as INFO.
12. **Multi-Mac same-wallet emission cap (§9.2).** Per-wallet cap
    at 100 MALIBU/day means a legit operator with 10 Macs earning
    modestly is throttled at wallet level. Verify the cap number
    is chosen with real-world honest operators in mind, not just
    sybil defense.

## Output format

For each finding:

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec §>
Concern: <what breaks or drifts>
Blast radius: <who is affected and how>
Fix: <concrete spec-text change>
```

End with:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW/INFO ship with
PR-body callout.
