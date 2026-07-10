You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), SECURITY lane, ROUND 3.

R2 returned 1 HIGH: stale "row 3+ remains quarantined until backfill"
references at SPEC-005 §8.2 (line 749), SPEC-002 v1.5.2 change-log
(lines 75-76), SPEC-005 §10.5 (line 850), and AC fixture detail
(line 2510).

R3 fixes all four:
- SPEC-005 §8.2 quarantine paragraph: now says "row 3+ in BOTH the
  persisted path AND the byte-identical id-ASC fallback is credited
  normally; only attempt_n=1 retried=0 remains".
- SPEC-002 v1.5.2 change-log: same correction.
- SPEC-005 §10.5: "Ambiguous attempt_n fallback quarantines rows" →
  "Ambiguous attempt_n=1 with retried=0 (legitimate retry without
  explicit marker) quarantines rows. (v0.3.3: row 3+ is no longer in
  this class — see §15.2.)"
- SPEC-005 AC-ATTEMPT-FALLBACK fixture detail (line 2510): two
  fixture variants (persisted attempt_n + NULL fallback) with the
  v0.3.3 row-3+ credit oracle.
- SPEC-005 change-log: added "Operators MUST NOT execute direct
  `UPDATE ledger_request_credits SET quarantined=0` SQL" — closes
  the side-channel resolution path the audit flagged.

## Verify

- Are there ANY remaining "row 3+ … quarantin" references anywhere
  in the SPEC corpus? (`rg "row 3.* quarantin" specs/`) Should be
  zero. (Historical references that are explicitly framed as
  resolved are OK.)
- Money-path correctness still preserved: the new contract credits
  row 3+ in both paths; the attempt_n=1 retried=0 class remains the
  only quarantine creation surface. Re-trace the WriteHotPath,
  RecoverLedger, and admin reconcile paths to confirm.
- Direct-SQL-unquarantine ban — does the SPEC text describe ALL the
  consequences (audit log bypass, credit_mismatch risk, missing
  provider_identity risk)? Or should it enumerate more cases?
- Backfill live-safety wording: is "measured the UPDATE wall-clock
  against your corpus" actionable enough for an operator? Specifically,
  does the SPEC say HOW to measure (e.g. `EXPLAIN QUERY PLAN`, a
  dry-run SELECT before the UPDATE)?
- Defense-in-depth: the writer-conn pin from `Store.Insert` race
  fix — does it interact with any other long-running UPDATE pattern
  in the codebase that could starve hot-path INSERTs? Scan billing/
  for transactions that hold the writer lock for non-trivial time.

## Severity rubric

- **CRITICAL**: real money-path regression or new attack class.
- **HIGH**: R2 finding still open.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
