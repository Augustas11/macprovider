# SPEC-026 R5 — SECURITY audit lane

You are re-auditing SPEC-026 v0.5 after the R4 cleanup pass. Read
`SPEC-026-r{1,2,3,4}-audit.md` first. Do NOT re-flag anything
already fixed.

Your lens is SECURITY: attacker economics, key/token compromise
paths, replay, race conditions, PII.

## Files in scope

- `specs/SPEC-026-browserless-provider-onboarding.md` (v0.5)
- `beta/DECISION_CRITERIA.md` Entry 102

## What to check in R5

Rank findings CRITICAL / HIGH / MEDIUM / LOW / INFO.

1. **§9.3 three-path channel-authority transfer.** Verify:
   - Old-email approval: if the honest user's email account
     itself has been compromised (unrelated to Mac
     compromise), the attacker gets the approve link. Note
     residual risk.
   - Current-wallet EIP-712: does the currently-bound-wallet
     path allow malware with Mac control but no wallet control
     to bypass? No — attacker doesn't have the wallet private
     key. OK.
   - Dual-control operator: audit surface. Any single-insider
     path?
   - Fresh install "confirm transfers directly" exception:
     verified that the swap fail-closed rule protects.
2. **§4.5 `provider_email_change_requests` immutability.** If
   the requester can DELETE the pending row and start over,
   they can spam without hitting the rate limit. Verify the
   rate limit tracks BOTH the pending row insertions AND
   deletions.
3. **§4.3 admin-flow break-glass.** Cumulative renewal cap says
   30 days without break-glass. What's the break-glass cost?
   If it's just "new incident ID," a bad admin can create new
   incident IDs indefinitely. Note.
4. **§5.1 replay job race.** During `cap_replay_pending = TRUE`
   period, live emissions on the same provider_id still fire
   (§5.1 provisional emission rules). They lock the SAME
   aggregate row as the replay job. Verify the interleaving is
   correct: live emission going through the aggregate lock will
   see the replay-in-progress state. Any way the live emissions
   during replay bypass the per-wallet cap?
5. **§4.6 CSRF-token binding.** If the GET page's CSRF token is
   stored server-side and looked up on POST, what's the store
   TTL? If it's longer than the swap cooling window, an
   attacker who captured the GET could POST later.
6. **§9.3 fresh-install `confirm` direct transfer.** An attacker
   with bearer+identity access on a fresh Mac sets their email
   and confirms. Their email is now authoritative. They then
   wait for the user to bind a wallet, and the attacker owns
   the swap-cancellation channel. Note if the fresh-install
   window is bounded.
7. **PII: `provider_email_change_requests.new_email`.** Is this
   redacted in logs? INFO.
8. **§4.6 email-scanner GET fetch.** The GET now doesn't mutate
   state. Does it emit `wallet_swap_email_cancel_confirm_viewed`
   observability on every scan? Could log floods hit the alert
   pager.

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
