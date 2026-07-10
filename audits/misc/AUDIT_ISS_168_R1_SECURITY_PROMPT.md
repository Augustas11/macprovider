You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), SECURITY lane, ROUND 1.

## Scope

SPEC-002 v1.5.2 + SPEC-005 v0.3.3 + IMPL — monotonic `attempt_n` column at
write time, backfill subcommand for legacy rows.

## What landed

(See code lane prompt for full surface — `request_log.attempt_n` column,
INSERT-time COUNT-then-INSERT derivation, BackfillAttemptN UPDATE via
ROW_NUMBER() window function, new `coordinator backfill-attempt-n
[--check]` subcommand.)

## Verify

- **Money-path correctness**: the v0.3.1 quarantine rule "row 3+ MUST
  be quarantined until SPEC-002 gains monotonic attempt_n" was a
  load-bearing safety net. With v1.5.2 persisting attempt_n, row 3+
  receives `attempt_n=2,3,...` and is credited normally. Is this a
  safety regression in any scenario the v0.3.1 rule was actually
  catching? Specifically — was the v0.3.1 quarantine catching ANY
  legitimate-attack class (e.g. duplicate INSERT by a misbehaving
  retry path) that v1.5.2 now silently credits?
- **Persistence channel for the SPEC-002 v1.5.0 internal-request_id
  collision class**: a UUID v4 collision across accounts would
  produce attempt_n=0 in each (different) account group. The
  account-IS clustering preserves that. Verify the v1.5.2 INSERT-time
  COUNT respects the same IS-clustering as the v1.5.0 read-time
  derivation (both clause: `account_id IS ?`).
- **Backfill non-malicious-state preservation**: the ROW_NUMBER()
  window function is computed over ALL rows including any v1.5.2-
  written rows. Verify a partial backfill (interrupted mid-run)
  doesn't leave the DB in an inconsistent state — e.g. if rows 0, 2
  are backfilled but row 1 is missed (impossible under the
  WHERE attempt_n IS NULL filter, but worth tracing).
- **Race during ALTER TABLE rollout**: between daemon startup
  (column added) and `backfill-attempt-n` running (column populated),
  new writes correctly populate attempt_n while old rows have NULL.
  The read-side COALESCE handles this. But what about an out-of-
  process tool that reads request_log directly without using the
  COALESCE? Does the SPEC adequately document the read-side discipline
  for external tools (similar to the v1.5.1 reconciliation tooling
  binding)?
- **Operator-induced state issues**: an operator who runs
  `backfill-attempt-n` on a partially-rolled-out fleet (some nodes
  v1.5.2, some v1.5.1) could create a confused state if the daemon
  is also writing. Is the SPEC text clear that backfill SHOULD run
  while the daemon is up (the single-writer cap serializes), or that
  it MUST be run during a maintenance window?
- **Money-path attribution**: the v1.5.2 attempt_n is used by SPEC-005
  ledger row keys `(request_id, attempt_n, provider_id)`. Persisting
  a value at write time means it's stable across reconciliation runs.
  Does this close any prior race where the read-time derivation could
  give different values on different reconciliation passes (and thus
  different ledger keys)?
- **CLI surface**: `coordinator backfill-attempt-n --check --format
  json` — does it leak any sensitive info beyond null/total counts?
  Should it gate on operator_key for the non-check path?

## Severity rubric

- **CRITICAL**: real money-path regression or new attack class.
- **HIGH**: SPEC contract gap that lets two implementations diverge
  in a money-path-observable way.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
