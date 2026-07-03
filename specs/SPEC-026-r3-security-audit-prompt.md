# SPEC-026 R3 — SECURITY audit lane

You are re-auditing SPEC-026 v0.3 after the R2 rewrite. Read
`specs/SPEC-026-r1-audit.md` and `specs/SPEC-026-r2-audit.md`
first — they list R1 and R2 findings and dispositions. Do NOT
re-flag items already resolved by v0.2 / v0.3.

Your lens is SECURITY: does v0.3 close the R2 HIGH/MEDIUM
findings, and does the rewrite introduce any new attack surface?

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.3)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R3

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **v0.3 fix for R2 SEC-1 (client-reported binary_version):**
   `identity_signature_exempt_until` server-side allowlist. Verify:
   - The one-time migration granting 30-day exemption to every
     pre-cutover `p_` provider_id doesn't create a huge attack
     window for stolen bearer tokens on those legacy identities.
     Argue: is 30 days too generous?
   - Any way a new `p_` provider_id gets added to the allowlist
     accidentally (e.g. via a bug in the admin endpoint)?
2. **v0.3 fix for R2 SEC-2 (auth_request signature timing):** the
   signature is now on the proof-stage frame with a transcript
   hash. Verify:
   - Transcript hash covers ALL replayable inputs. If the
     `binary_version` field is left out of the hash, an attacker
     could substitute a lower version to gain some legacy path.
     v0.3 includes `binary_version` in the signed payload — good.
   - Is the proof-stage frame itself protected against replay in
     a way that consumes `auth_attempt_id`? SPEC-001 v1.6 should
     enforce single-use `auth_attempt_id`; if not, replay across
     sessions is possible.
3. **v0.3 fix for R2 SEC-3 (payout coercion out-of-band):**
   `notification_email` + HMAC-signed cancel URL. Verify:
   - What happens if the user never sets `notification_email`? v0.3
     says coordinator emits a warning but permits the swap. That
     preserves R2's finding — attacker exploits users who didn't
     set the field. Is the App aggressive enough about surfacing
     the setup prompt? v0.3 says "after onboarding completes." Is
     that soon enough? Wallet swaps typically happen only after
     substantial USDC is earned, so the delay may not matter in
     practice. Note if the reasoning holds.
   - The HMAC signing key on the coordinator is a new secret. Its
     rotation/compromise story is undefined. INFO or MEDIUM.
   - Email delivery is asynchronous; if delivery fails, does the
     coordinator abort the swap? v0.3 doesn't say.
4. **v0.3 §5.1 enforcement primitives.** The
   `wallet_daily_malibu_emission` aggregate is a new attacker
   target — atomic upsert on a hot row. Any race condition
   that lets an attacker emit above the cap by racing two
   provider_ids at once?
5. **v0.3 §5.2 continuous 72h balance with randomized checks.**
   Verify:
   - Any window pattern the attacker can predict? "Randomized
     15min-4h" is a range but doesn't say the sampling
     distribution. Uniform vs Poisson makes a difference.
   - Any way to satisfy the 72h clock without holding balance
     the full time? E.g. rapid deposits + withdrawals timed
     between checks.
6. **§4.3 CLI-track proof-stage using receipt_pubkey.** Extending
   the proof-stage flow to CLI-track providers signed by
   `receipt_pubkey`. Any conflict with SPEC-015 receipt-key
   rotation? If the receipt key rotates, the CLI-track auth flow
   requires the new key immediately; is there a re-auth on
   rotation?
7. **v0.3 §4.1 rotate-on-duplicate.** New attack surface:
   attacker with a valid identity signature spams
   `/register` and forces continuous token rotation, causing
   the honest live WS session to be invalidated repeatedly.
   Mitigations? Is `/register` supposed to work while a live
   session is running?
8. **v0.3 §5.5 downgrade path.** A demoted-then-re-promoted
   attacker: satisfy criteria, unlock, demote, re-satisfy,
   re-unlock. Any brake on rapid oscillation?
9. **Notification email is a new PII field.** Is its storage,
   redaction, and log handling specified? INFO.

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
