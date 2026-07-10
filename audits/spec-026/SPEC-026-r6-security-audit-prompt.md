# SPEC-026 R6 — SECURITY audit lane

You are re-auditing SPEC-026 v0.6 after the R5 cleanup pass.
Read `SPEC-026-r{1,2,3,4,5}-audit.md` first. Do NOT re-flag
anything already fixed.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.6)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R6

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§9.3 fresh-install re-ratification flow (SEC HIGH from R5
   closure).** Verify:
   - Ratification EIP-712 payload names the `pending_change_id`
     bound to the current fresh-install email — attacker can't
     get an honest user to sign a payload naming
     `pending_change_id` for a DIFFERENT email.
   - What happens if the fresh-install email is
     `alice@attacker.com` and the honest user's browser wallet
     signs the ratification EIP-712? The signature by the
     honest user would ratify the attacker's email. Does the
     App-side EIP-712 prompt clearly show the email being
     ratified (via `new_email_sha256` domain-separated
     display)? If the App silently signs, this is HIGH.
2. **§5.1 Postgres projection staleness attack.** During the
   60s stale window, coordinator refuses to emit. Any way an
   attacker can DoS the replication worker to prolong the
   staleness window and prevent honest emissions?
3. **§4.5 `provider_email_change_requests` immutability.** Are
   the create-and-cancel-and-recreate loops rate-limited even
   if the first row is soft-deleted or expired?
4. **§4.6 CSRF token binding.** v0.6 says `TTL <= min(URL exp,
   remaining cooling window)`. If URL exp is at the cooling
   window's end, the CSRF token could be valid for the full
   cooling window. Is that intentional?
5. **§7.3 `malibu-app://` URL scheme handler.** Attacker
   crafts a URL with a valid-looking host and query params
   that trick the App into POSTing a signed request to a
   different endpoint. Is the host allowlist enumerated?
6. **§9.3 EIP-712 replay across chains.** `chainId: 8453` is
   fixed to Base mainnet; if the user's wallet is on the wrong
   chain, does the signature attempt fail cleanly?

## Output format

```
Severity: CRITICAL | HIGH | MEDIUM | LOW | INFO
Where: <spec § or file:line>
Threat: <attacker capability + goal>
Attack: <concrete steps>
Fix: <spec-text change>
```

End:

```
TOTALS: C=<n> H=<n> M=<n> L=<n> I=<n>
```

Merge gate: **0 CRITICAL, 0 HIGH, 0 MEDIUM**.
