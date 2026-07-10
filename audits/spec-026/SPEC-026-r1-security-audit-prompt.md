# SPEC-026 R1 — SECURITY audit lane

You are auditing a specifications-only PR that adds
`specs/SPEC-026-browserless-provider-onboarding.md`, a new provider
onboarding flow for the `Malibu.app` App track. No code changes ship
in this PR.

Your lens is **SECURITY**: sybil economics, identity threat model,
auth-surface changes, replay + rate-limit correctness, key-material
handling, and settlement / payout-binding trust boundaries.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md`
- `beta/DECISION_CRITERIA.md` Entry 102

## Threat model to hold in mind

The pre-existing state: provider onboarding requires a GitHub OAuth step
at `portal.streamvc.live/onboard`. That step is being retired for the
App track. The claim SPEC-026 makes is that a layered stack (§5, §11)
replaces the sybil resistance the GitHub gate was providing.

The buyer marketplace pays providers in USDC + $MALIBU based on verified
receipts (SPEC-022) that are settled on Base. The economic prize the
attacker is after is $MALIBU emissions (capped at 25/day/provisional
identity) and USDC from real inference work performed to pass
`macprovider-verify`.

## What to check

Rank each finding CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **Sybil economics.** §5.1 says 25 MALIBU/day + 7-day payout delay is
   the provisional cap. Multiply out the attacker economics:
   - N identities × 25 MALIBU/day × 7 days = 175 MALIBU per identity
     before first payout unlocks
   - Attack cost per identity = one App Attest bypass OR unattested
     rate-limit-bump loss + any inference cost to pass SPEC-022
     receipt verification
   - Is the attacker's realizable per-identity profit positive after
     first payout unlocks? If yes, the sybil economics are broken;
     flag HIGH or CRITICAL depending on magnitude.

2. **App Attest bypass paths.** §5.3 makes App Attest "opportunistic
   but bumps rate limits 3× and counts as one unlock criterion." Ways
   this fails:
   - Can an attacker replay one legitimate App Attest object across N
     `/register` calls? The spec says `nonce` is 32 bytes and rate
     limits are per-IP/ASN, but does it say `app_attest_object` MUST
     bind to the `provider_id` / `nonce` / `identity_pubkey`? If not,
     replay is CRITICAL.
   - `DCAppAttestService.attestKey(_:clientDataHash:)` binds the
     attestation to a `clientDataHash`. Does §5.3 specify what
     `clientDataHash` must contain? Missing spec → HIGH.

3. **`identity_signature` on WS `hello` (§4.3).** The field is
   optional. Coordinator falls back to bearer-only auth when absent.
   Threats:
   - Downgrade attack: attacker with only a stolen bearer token but
     no identity key omits `identity_signature`. Coordinator accepts.
     Is elevated-rate-limit gating enough to make this uninteresting,
     or does the bearer token grant real earnings authority the
     identity key gates elsewhere? If the two grant equivalent
     authority, this field adds nothing; if not, downgrade is HIGH.
   - The signature covers `{auth_attempt_id, provider_id, binary_version, ecdh_pubkey}`.
     Is `auth_attempt_id` freshness-guaranteed by the coordinator
     (server-issued)? Client-generated → HIGH (replay across sessions).

4. **Nonce + timestamp replay windows.** §4.1 step 3 rejects
   `|now - ts_utc| > 60s` OR replayed `(provider_id, nonce)`. Verify:
   - 60s window is defensible against clock skew, doesn't let an
     attacker replay for hours
   - Nonce replay cache must be at least 60s deep; is TTL/eviction
     policy specified?
   - `(provider_id, nonce)` replay key — what about
     `(new_provider_id, same_nonce)` from a spam-registration
     attacker? Not covered.

5. **Payout-address binding trust boundary (§4.2).** The signature is
   over `JCS({provider_id, wallet, chain_id, nonce, ts_utc, coordinator_domain})`.
   - `coordinator_domain` is included — good, prevents cross-domain
     replay. Is it a canonical string the App and coordinator both
     agree on? "coordinator.streamvc.live" vs
     "https://coordinator.streamvc.live" vs with-trailing-slash = fork.
   - Is `chain_id` bound into the settlement contract call, or only
     into the identity signature? An attacker controlling the
     coordinator (insider threat) with a valid identity signature but
     wrong chain_id could settle on the wrong chain. HIGH if the
     settlement contract doesn't verify chain_id independently.

6. **Wallet swap rate-limits (§9.3).** 24h cooling + 30-day floor.
   Threats:
   - Coercion: attacker holds user's Keychain (root on the Mac). They
     can sign a swap. The 24h delay is the only speed bump. Does §9.3
     require the App to notify the user out-of-band of a pending
     swap? Missing notification = HIGH.
   - Grief: legitimate user loses wallet, tries to swap, hits 30-day
     floor. §9.4 says "out of scope" — acceptable, but does that
     leave a support surface with too-easy social-engineer path?
     Note as MEDIUM.

7. **Key material handling on export (§3.2, §7.1).** The App exports
   the raw 32-byte Ed25519 private key to the CLI via
   `MACPROVIDER_RECEIPT_KEY_RAW` env var.
   - `ps eww` prints envs on macOS. Other users on the same Mac
     (rare on macOS, common on shared machines) can read the key.
     Is a per-user-only Mac assumed? Spec should say so explicitly.
   - Core dumps of the CLI would include the env-var block. Is core
     dumping disabled? Not specified.
   - Any process the CLI spawns inherits the env var unless the CLI
     scrubs it. Is that scrubbing specified?

8. **`app_attest_object` verification failure mode (§4.1 step 5).**
   "Missing or invalid attestation is NOT a rejection — it means
   `trust.attested = false`." An attacker sends a garbage but
   structurally valid CBOR — does the coordinator log-and-continue
   or error? Log-and-continue leaks nothing but eats CPU; error
   without rejection is confusing. Either way, is DoS via oversized
   `app_attest_object` payloads bounded?

9. **`provider_id` as public label (§3.3).** The `p_` prefix + short
   display are shown to buyers. A `provider_id` collision is
   cryptographically impossible (SHA-256), but a look-alike attack
   (unicode homoglyph in display copy) is possible. Base32 lowercase
   alphabet is [a-z2-7] — no homoglyphs. Note as INFO unless the
   display layer allows unicode overrides anywhere.

10. **Rate-limit metric scoping (§10 checklist).**
    `provider_register_rate_limit_hits{scope="ip"}` and `scope="asn"`.
    An attacker who can predict the ASN partition can distribute
    across ASNs to stay under. Is the ASN limit low enough to matter?
    30/min/ASN × ~70k routable ASNs = 2.1M/min theoretical ceiling.
    That is not a defense; document as INFO or MEDIUM depending on
    whether the coordinator has other layers (e.g. residential-IP
    reputation).

11. **Entry 102 security claim drift.** The decision-log entry
    summarizes the security stack. Cross-check every security claim
    (e.g. "receipt-key reuse is the load-bearing invariant") against
    the spec's actual normative text.

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
