# SPEC-026 R1 — ARCHITECT audit lane

You are auditing a specifications-only PR that adds
`specs/SPEC-026-browserless-provider-onboarding.md`. No code ships in
this PR; the SPEC is the deliverable.

Your lens is **ARCHITECT**: does the design compose cleanly with
existing SPECs, does it hold under evolution, are the abstractions
placed at the right layer, does the migration story survive contact
with users mid-flight?

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md`
- `beta/DECISION_CRITERIA.md` Entry 102

## Adjacent SPECs to read for consistency

Every consistency claim in SPEC-026 needs to survive re-reading these:

- `specs/SPEC-001-*` — WS coordinator↔provider `hello` frame shape
  (spec §4.3 adds a field to this)
- `specs/SPEC-003-open-onboarding.md` — FR-C9 self-mint + TOFU
  (spec §4.1 step 7 delegates to this)
- `specs/SPEC-015-receipts.md` — receipt key algorithm and Keychain
  slot (spec §3.2 REUSES this key)
- `specs/SPEC-022-verified-model-settlement.md` — on-chain settlement
  keying (spec §4.2 calls `updatePayoutAddress` on this contract)
- `specs/SPEC-023-*` — autotune recommendation surface
  (spec §4.1 step 8 populates `recommended_model` from this)
- `specs/SPEC-025-native-mac-app.md` — App-track first-run
  (spec §6.1 REPLACES §3.1 of SPEC-025; spec §6.5 EXTENDS §3.4)

## What to check

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **Receipt-key reuse invariant.** SPEC-026 §3.2 declares the receipt
   key (SPEC-015) IS the identity key. This is the load-bearing
   simplification. Verify:
   - SPEC-015 §12 does not already commit to a rotation schedule or
     algorithm choice that SPEC-026 breaks
   - SPEC-022 keys settlement off the receipt key; SPEC-026 keys
     `updatePayoutAddress` off the identity key; if these two must
     be the same in a re-key event, the spec should say so explicitly
   - If SPEC-015 later needs to rotate receipt keys for a
     cryptographic reason (e.g. Ed25519 → Ed448), SPEC-026's identity
     rotates with it; is that acceptable, or does the spec need a
     "keys diverge at rotation" plan?

2. **FR-C9 reuse.** SPEC-026 §4.1 step 7 says "mint via existing FR-C9
   self-mint path." FR-C9 was designed to serve tokenless CLI
   admissions with TOFU enforcement.
   - Does FR-C9 currently expect an admission attempt shape (WS
     `hello` frame) rather than an HTTP POST to `/register`? If yes,
     wiring a new HTTP endpoint to reuse the same mint mechanism is
     more than "reuse" — it's a new caller, and TOFU semantics may
     race differently.
   - The TOFU key in FR-C9 is `(provider_id, first_pubkey_seen)`.
     SPEC-026 asks the coordinator to `409 CONFLICT` on the same
     `provider_id` with a different `identity_pubkey`. Is that
     symmetrical with FR-C9.4's stated behavior?

3. **WS `hello` additive field lifecycle (§4.3).** The spec adds
   `identity_signature` as OPTIONAL, with fallback to bearer-only.
   - What's the deprecation path? When does the field become
     required? Without a version bump plan, the field lives forever
     as "optional" and adds attack surface (§SECURITY lane's
     downgrade concern).
   - Does SPEC-001 already have a version-negotiation mechanism, or
     does this quietly assume one?

4. **Payout-wallet binding as coordinator responsibility (§4.2).**
   - Settlement contract is on Base (SPEC-022). Coordinator makes an
     `updatePayoutAddress` call. That means the coordinator holds a
     Base-signing key or has a relayer. Which? SPEC-022 should
     already resolve this; verify SPEC-026's assumption matches.
   - Chain of trust: the identity signature proves the Mac agrees to
     the wallet binding. The coordinator forwards this to a
     settlement contract that ideally verifies the identity
     signature on-chain. Does the contract? If not, coordinator is a
     trust boundary that can silently rewrite `payout-address`; is
     that acceptable, and if so, is it called out?

5. **SPEC-025 §3.1 replacement (§6).** SPEC-026 says it replaces
   §3.1 of SPEC-025 wholesale. Verify:
   - Nothing else in SPEC-025 depends on §3.1 semantics (e.g. §3.2
     steady-state assumes onboarding produced a specific state
     shape)
   - The onboarding-window vs menu-bar-window separation SPEC-025
     documents is preserved by SPEC-026's flow

6. **Migration: `MALIBU_ONBOARD_V2` flag (§8).** Flag defaults off,
   Sparkle flip to on. What breaks?
   - "Existing installs that already completed browser OAuth are
     treated as `.live` on next launch regardless of flag" — how
     does the code decide "already onboarded" without inspecting
     v1's onboarding state? The persistence schemas differ (§7.5 vs
     whatever v1 wrote).
   - Rollback path: if the flag is flipped to `on` and a bug is
     found, is there a Sparkle-flip-back to `off`? Users who
     onboarded via v2 have a Keychain-only `provider_id` and no
     browser-issued equivalent. Flip-back leaves them on v1 code
     paths that can't find the identity.

7. **Cross-track parity (§4.4).** Retiring GitHub OAuth for the App
   track but keeping it for the CLI track means the coordinator
   supports two auth flows for the same product surface indefinitely.
   - When does CLI track migrate? Missing plan → MEDIUM (technical
     debt accretion) or LOW (explicit non-goal).
   - Are there any observability signals to know when CLI-track
     traffic drops to zero, so retirement can be triggered?

8. **Provisional-tier upgrade race (§5.2).** "Trust unlock is
   one-way." What if a provider hits the two-criteria threshold,
   unlocks, then fails one criterion (e.g. wallet balance drops
   below 50 USDC)? Spec says one-way. Is that a griefing surface
   (attacker deposits 50 USDC to unlock, withdraws, keeps trusted
   tier) or an intentional simplification?

9. **Deployment ordering (§10).** The checklist is presented as
   "blocking gate for the App-side flag flip." Verify each item is
   actually gate-able independently or in a specific order:
   - Can `/v1/providers/register` deploy before
     `/v1/providers/{id}/payout-address`? Any App-side code path
     that assumes both endpoints exist together?
   - `provider_identities` schema migration must precede `/register`
     deploy; the checklist doesn't order these.

10. **Escrow model (§4.2, §9.1).** Coordinator holds unclaimed
    earnings in escrow until first bind. Verify:
    - Is there a spec for coordinator-side escrow accounting today,
      or is SPEC-026 the first spec to require it?
    - Is escrow bounded per-provider (to prevent an attacker running
      a long-lived provisional identity accumulating a big pot to
      settlement-drain later)? §9.1 says loss on wipe if unbound;
      that IS the boundedness argument, but the spec should say so.

11. **Terminology consistency.** SPEC-026 §7.4 mandates "node" →
    "provider" rename across App-track sources. Grep the spec itself
    for "node" — does the spec use "node" anywhere in its own text?
    Also check every claim in Entry 102 lines up with SPEC-026
    section numbers.

12. **Non-goals scope.** §1.2 lists non-goals. Any of these that a
    follow-up spec MUST address before the whole story is coherent?
    In particular: wallet-signing UX is deferred; is the
    identity-signed EIP-712-shape adequate replacement, or is it
    obviously placeholder shape a future spec has to rework?

## Output format

For each finding:

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec §>
Concern: <what breaks or drifts>
Blast radius: <who is affected and how>
Fix: <concrete spec-text change or added §>
```

End with:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW/INFO ship with
PR-body callout.
