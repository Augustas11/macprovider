# SPEC-026 R4 — SECURITY audit lane

You are re-auditing SPEC-026 v0.4 after the R3 rewrite. Read
`SPEC-026-r{1,2,3}-audit.md` first. Do NOT re-flag anything
already fixed.

Your lens is SECURITY: does v0.4 close the R3 HIGH/MEDIUM findings
without opening new holes?

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.4)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R4

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO. Skip anything
R1-R3 already covered.

1. **v0.4 §4.3 auth policy hardening.** Verify:
   - The 7-day migration blanket exemption is short enough that
     stolen legacy bearer tokens have bounded exploitation.
   - Operator-issued extensions require dual approval for >7 days.
     Can an insider single-handedly extend to 30 days? (7-day
     rule holds, but is the >7-day dual-approval rule
     enforceable in the admin API?)
   - What happens if the operator-issued exempt row is left in
     place forever (max_ttl = 30 days but re-issued monthly)?
     Note as MEDIUM if not covered.
2. **v0.4 §9.3 two-step verified email flow (§4.5).**
   - New email verification via delivery to new email. Attacker
     sets malware-controlled email, verifies it, waits 24h cooling
     window, and OWNS the channel. Does the OLD-email reject-link
     during the 24h window save honest users? If the honest user
     is asleep for 24h, they miss it. Is 24h the right window?
   - `notification_email_pending` overwrite behavior (§4.5 last
     bullet) — attacker can set/overwrite/set again to drain
     honest user's reject-link ability?
   - Rate limit on `set` is 1/7 days (§4.5 error `429
     email_change_rate_limit`) — combined with 24h reject
     window, honest user has 6 days after reject to notice
     something is wrong. That is defensible; note as INFO.
3. **v0.4 §4.1 rotate-on-duplicate `current_token_proof`.**
   - HMAC over `(provider_id, nonce, ts_utc)` using the CURRENT
     token as key. Is this replayable? Attacker who observes one
     valid re-register HMAC can... no, `nonce` and `ts_utc` are
     one-time. OK.
   - Does the coordinator require `ts_utc` freshness on this
     specific field? The `/register` body's `ts_utc` covers it,
     but is the HMAC over the SAME `ts_utc` or a separate one?
     Spec should be explicit.
4. **v0.4 §5.2 economic + additional criterion pairing.** Verify:
   - The "at least one economic + at least one additional" rule is
     unambiguous when a criterion counts as both (e.g. E2 wallet
     balance also matches criterion #3). The spec says "a second
     economic criterion counts here" for the additional slot,
     but that lets one satisfied criterion count twice.
5. **v0.4 §5.5 requalification 72h.** Any way to game demote/
   promote across the 72h?
6. **v0.4 §5.1 unbound emission replay at bind time.** The
   replay-through-cap job — is it atomic against concurrent
   emissions from a newly-just-bound-wallet? Race window.
7. **v0.4 §4.5 rate limit** on email `set` action is 1/7 days.
   Does this apply to `unset` too? An attacker who has
   compromised bearer+identity could `unset` (which per §9.3
   fails-closed above 500 USDC) then quickly `set` their own,
   effectively bypassing the rate limit if `unset` is not rate-
   limited.
8. **v0.4 §9.3 email delivery retry** cadence and pool. Is there
   a bound on how long the swap can be held in
   `pending_delivery_retry`? Attacker DoSes coordinator SMTP
   delivery to their address indefinitely?
9. **v0.4 §4.6 signed cancel URL replay.** The URL includes
   `expires_ts` and `swap_id`. Can an attacker intercept the URL
   (email account compromise) and reuse it? URLs are single-use
   (a cancelled swap can't be re-cancelled), so replay is
   idempotent. Note if the single-use enforcement is stated.

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
