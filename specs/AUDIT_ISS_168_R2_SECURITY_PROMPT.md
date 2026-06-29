You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), SECURITY lane, ROUND 2.

R1 returned 2 HIGH:
1. hotpath.go + recovery.go still implemented v0.3.1 "row 3+ MUST
   quarantine" rule, contradicting SPEC-005 v0.3.3.
2. SPEC-005 internally inconsistent — multiple stale "row 3+ MUST
   quarantine" references in §D10, AC text, oracle text.

R2 fixes:

1. **hotpath.go**: quarantine condition narrowed from
   `in.AttemptN > 1 || (in.AttemptN == 1 && reqRow.Retried == 0)`
   to just `in.AttemptN == 1 && reqRow.Retried == 0`.
2. **recovery.go**: `ambiguousAttempt` flag narrowed similarly;
   `_ = sameRequestCount` since it's no longer a quarantine trigger;
   the unconditional `if attemptN > 1 { quarantine }` branch removed.
3. **SPEC-005**: rewrote stale references at 5+ locations to describe
   row 3+ as credited normally under both the persisted attempt_n
   path AND the byte-identical id-ASC fallback path.
4. **Cross-spec narrative**: change-log now says v0.3.3 closes the
   quarantine CREATION class for row 3+. Pre-existing quarantines
   from the v0.3.1 era remain immutable per ledger schema
   (`quarantined` is `0 → 1` monotonic). Resolution requires the
   §OQ-5 force-credit/force-void admin surface (issue #169).
5. **`Store.Insert` race closed** via held-conn pattern.

## Verify

- The narrowed quarantine rule correctly preserves the
  legitimate-retry-without-marker class (`attempt_n=1, retried=0`).
  Is this the right safety baseline? An attacker who replays a
  request without setting `retried=1` would still hit this class —
  preserved behavior.
- Are there any other code paths that historically quarantined on
  row-3+ that I missed? Sweep:
  - `quarantineExistingLedgerForRequestAttemptTx` calls
  - `insertQuarantineTx` calls
  - `quarantine_reason = 'ambiguous_attempt_n'` references
- Money-path discipline: does the new rule introduce any class of
  credits that DIDN'T exist under v0.3.1? Specifically: a buyer
  who sends 5+ retries to the same coordinator-internal request_id
  used to get rows 3, 4, 5 quarantined → 0 credits. Now they get
  credits for all 5. Is that the intended contract? It is — the
  monotonic attempt_n makes each attempt a separate, legitimate
  billable ledger row. The v0.3.1 quarantine was a safety net for
  the row-mapping ambiguity, not a deliberate anti-abuse measure.
- Pre-existing quarantine rows from v0.3.1 era — does the SPEC
  text adequately handle the case where the operator wants to
  resolve them but #169 hasn't shipped? "Operator action required"
  is honest but leaves the operator with no path. Is this an
  acceptable boundary or does it block #168 ship?
- The `Store.Insert` race fix — could a concurrent BACKFILL UPDATE
  during a daemon insert hit a lock contention? The hot-path
  INSERT pins the conn for COUNT+INSERT (fast). The backfill
  UPDATE pins it for the duration of the table scan. Both serialize
  cleanly under SetMaxOpenConns(1) but the live-safety window
  worsens — is the SPEC text honest about this?

## Severity rubric

- **CRITICAL**: real money-path regression OR a new attack class.
- **HIGH**: an R1 finding not actually closed.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
