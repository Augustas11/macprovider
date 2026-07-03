# SPEC-026 R2 — SECURITY audit lane

You are re-auditing SPEC-026 v0.2 after the R1 rewrite. Read
`specs/SPEC-026-r1-audit.md` first for the R1 findings and v0.2
dispositions.

Your lens is SECURITY: sybil economics, identity threat model,
auth-surface changes, replay + rate-limit correctness, key-material
handling, and payout binding trust boundaries.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.2)
- `beta/DECISION_CRITERIA.md` Entry 102 (updated)

## What to check in R2

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO. Do NOT re-flag
R1 findings that v0.2 resolved — flag only:

1. **New attack surface v0.2 introduced.** The rewrite touched key
   separation (§3.2), payout delegation to SPEC-016 (§4.2), v2
   `auth_request` (§4.3), App Attest `clientDataHash` binding (§5.3),
   per-wallet emission cap (§5.1), continuous-recheck downgrade
   (§5.5). Any of these open a new hole?
2. **v0.2 fixes that don't actually fix.** For each R1 finding,
   verify the v0.2 disposition closes it:
   - SEC-2 CRITICAL App Attest replay → §5.3 clientDataHash binding
     + key_id uniqueness. Does the binding include every
     un-guessable-per-attacker input? Nonce is 32 bytes random;
     provider_id is derived; ts_utc is timestamp. If an attacker
     controls a legitimate device and captures its attestation
     bound to (their real provider_id, their real nonce), can they
     still reuse it? The spec says key_id uniqueness closes that —
     verify the key_id is actually stable-per-key (i.e. an
     attacker can't produce N different attestations from one SEP
     hardware key with different key_ids).
   - SEC-3 HIGH bearer downgrade → §4.3 hard reject on
     `p_`-prefixed provider_ids from v1.9.0. Any pre-v1.9.0
     `p_`-prefixed install still exists as an attack surface?
     Spec says "logs `app_track_pre_v190_bearer_only` for
     observability" but the cutover doesn't force upgrade — check
     residual risk.
   - SEC-5 HIGH payout binding chain/domain ambiguity → v0.2 §4.2
     delegates to SPEC-016. Read SPEC-016 §3 EIP-712 domain
     definition and verify it actually pins `chainId`,
     `verifyingContract`, and canonical string. If SPEC-016 leaves
     any of those ambiguous, SPEC-026 inherits the gap.
   - SEC-6 HIGH payout coercion via Keychain → v0.2 §9.3 adds
     UNUserNotification + cancel action during SPEC-016 cooling
     window. Is macOS UNUserNotification a reliable out-of-band
     channel when the attacker already has root? If not, this
     mitigation is theater — flag HIGH.
   - SEC-7 HIGH raw key export via env → v0.2 removes the env-var
     handoff entirely (§7.1 dropped `exportRawForCLI`). Verify no
     other path (crash dumps, logs, `NSLog`, temp files) leaks
     the identity key.
3. **Continuous wallet-balance recheck (§5.5).** The re-check
   happens "on every payout batch cycle." What frequency does
   SPEC-016 run its batch cycle? If it's weekly, a Trusted provider
   can hold 100 USDC for one day per week and stay Trusted six days
   out of seven — is that acceptable? If daily, is it enough?
4. **Non-withdrawable provisional $MALIBU (§5.1).** How is
   "non-withdrawable" enforced? The spec doesn't say. If it's
   ledger-only (the row is written but SPEC-016 payout runner skips
   it), does the runner check `trust_tier` on every row, or is
   there a separate "hold" flag? Unspecified enforcement = MEDIUM.
5. **Per-wallet emission cap (§5.1).** 100 MALIBU / bound wallet /
   day. Enforced how? The coordinator would need per-wallet
   accounting across `provider_id`s. Does SPEC-016 already have a
   `provider_payout_addresses` → provider_id → ledger join that
   makes this cheap, or is this a new query pattern?
6. **App Attest key_id uniqueness across provider_ids (§5.3).** The
   spec says coordinator rejects `409` on cross-`provider_id`
   reuse. This is one-way DB unique constraint. What if an attacker
   registers first with `provider_id_1` + attestation_key_A, then
   later legitimately loses their identity Keychain (Mac wipe), and
   tries to re-register the SAME `attestation_key_A` from the same
   physical Mac under `provider_id_2`? Legitimate honest re-onboarding
   gets rejected. Is this an accepted tradeoff or a bug? If accepted,
   spec should say so.
7. **JCS canonical `coordinator_domain` (§5.3).** Defined as
   "bare host, lowercase, no scheme, no trailing slash." Attacker
   changes the App bundle's coordinator URL to include a scheme or
   trailing slash → JCS canonicalizer disagrees between App and
   coordinator → attestation binding fails legitimate providers.
   Does the App target hardcode `coordinator_domain` or read it
   from a settings file the attacker can influence? INFO or MEDIUM.
8. **Wallet-balance criterion (§5.2 #3) — where does the coordinator
   query the balance?** Base RPC endpoint choice. If SPEC-016
   doesn't define this, SPEC-026 inherits the gap. If SPEC-026
   introduces a new RPC dependency, note it.
9. **`GET /v1/providers/{id}/earnings` (§9.1).** New endpoint
   introduced by v0.2 that exposes `unpaid_ledger_backlog_usdc` and
   `unpaid_ledger_backlog_malibu`. Auth model? If it's `provider_id`
   in the URL with no auth header, it's a data-leak: attacker can
   enumerate provider_ids (they're 54-char public strings shown in
   receipts) and learn each provider's unpaid backlog.
10. **Auth-attempt-id source (§4.3).** Spec says "issued by the
    coordinator in the preceding challenge frame; the client MUST
    NOT self-generate it." Verify SPEC-001 v1.6 §6.7 actually has
    a coordinator-issued challenge frame before `auth_request`,
    since that's a structural claim about the SPEC-001 protocol.

## Output format

For each finding:

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec § or file:line>
Threat: <one-line attacker capability + goal>
Attack: <concrete steps>
Fix: <spec-text change that closes the gap>
```

End with:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**. LOW/INFO ship with
PR-body documentation.
