# Audit prompt — ISS-196 R1 SECURITY lane

## What's under review

`fix/iss-196-account-scoped-pk` against `origin/main` (HEAD `ad76194`).
Changes the gateway's `usage_events` table PRIMARY KEY from
`(request_id)` to `(account_id, request_id)` to close the [issue #196](https://github.com/Augustas11/macprovider/issues/196)
cross-account collision attack.

## The attack we're closing

A buyer controlling two accounts (A, B) supplies the SAME UUIDv4
`X-Request-ID` from both. Pre-fix:

1. Account A fires a streaming chat completion. Settles cleanly.
2. Account B fires same prompt + same X-Request-ID. Gateway forwards,
   streams response back to buyer, attempts to settle. SQLite
   `INSERT INTO usage_events` fails on global PK collision (request_id
   already used by A). Account B gets the inference output without
   being debited.

Post-fix: PK is `(account_id, request_id)` so B's settlement INSERT
succeeds on the composite key, B is debited, and the audit trail has
both rows.

## Audit lens — SECURITY

You are a security reviewer pretending to be the attacker. Limit
findings to the diff. Severity bar:

- **CRITICAL** — a working exploit path that survives this fix.
- **HIGH** — a different abuse surface (DoS, audit-trail poisoning,
  reservation leak) opened or unblocked by the schema/runtime change.
- **MEDIUM** — defense-in-depth gap that compounds another bug.
- **LOW** — won't file.

## Concrete things to attack

1. **The original exploit, residual paths.** Confirm cross-account
   collision IS now closed end-to-end. Both `settleAfterCommit` /
   `SettleReservation` (plain `INSERT`) and the `EnsureUsageEvent`
   fallback (INSERT OR IGNORE + verify) — does either path still
   silently swallow a cross-account collision?
2. **The migration window.** During the table rebuild, a concurrent
   in-flight inference settle could write to the OLD `usage_events`
   table after we've already started `INSERT INTO ... SELECT`. Is
   that handled? (Hint: the gateway is single-process; check if
   anything else can write during Migrate.)
3. **`demo_usage_events` parallel surface.** That table still has
   `request_id PRIMARY KEY` (global). Is it also exploitable for a
   buyer running through demo tokens? If so, file as a separate
   issue (don't expand scope of this PR), but note it.
4. **`audit_events.request_id`.** Has `request_id TEXT NOT NULL` with
   no uniqueness constraint, only an index. Cross-account collision
   here doesn't matter for billing, but does it confuse explorer or
   reconciliation queries?
5. **`signup_events` / `quota_reservations` / `concurrency_reservations`.**
   Quota and concurrency reservations are already
   `PRIMARY KEY (account_id, request_id)` — the right shape. Confirm
   the PR doesn't accidentally regress them.
6. **Buyer-supplied X-Request-ID still admitted.** The fix doesn't
   block buyer-controlled UUIDs (intentional, to preserve buyer
   correlation). Confirm there's no new path where a malicious
   X-Request-ID can corrupt indexes, fool the explorer's
   per-account-last-request lookup, or DoS the gateway.
7. **`EnsureUsageEvent` payload-verify behavior after fix.** The
   cross-account branch can no longer occur. Same-account payload
   drift still triggers `ErrUsageEventConflict`. Is there a scenario
   where same-account RETRY with legitimately-different tokens
   (e.g., upstream provider corrected its usage block on retry)
   gets falsely rejected and causes a refund the buyer didn't
   deserve?
8. **Rollback / downgrade.** If a future deploy reverts to the old
   binary, can the composite-PK DB still serve reads? Writes? Any
   data-loss risk on downgrade?

## Output format

```
SEVERITY: <CRITICAL|HIGH|MEDIUM>
TITLE: <short>
FILE: <path>:<line>  (or "behavioral" if not file-bound)
EXPLOIT: <step-by-step trigger or attack scenario>
SUGGESTED FIX: <one-line>
```

If 0 findings, output exactly: `0 CRITICAL / 0 HIGH / 0 MEDIUM`.

## R2 update — what changed since R1
- Rebased onto current main (ad76194 includes #193).
- ExplorerSessionDetail now account-scoped with ambiguity detection (addresses R1 HIGH).
- Schema version gate added (addresses R1 HIGH rollback).
- #210 filed for demo_usage_events parallel surface (out of scope for this PR).

Re-audit against the same bar.

## R3 update — what changed since R2
- A5 (ambiguity check usage-only): probe now spans usage_events + quota_reservations + concurrency_reservations via UNION DISTINCT.
- A2 (rollback safety): deploy script now snapshots gateway.db pre-restart; restore path documented.
- #210 (demo_usage_events) tracked separately.

Re-audit on the same bar.
