You are reviewing branch `spec/iss-168-monotonic-attempt-n` of the macprovider
repo (working tree `/Users/augstar/macprovider-iss168`), SECURITY lane, ROUND 4.

R3 returned 1 MEDIUM (backfill preflight not operator-actionable) + 2 LOW
(quarantine reason strings; existing long-tx patterns).

R4 fixes:

1. **MEDIUM**: added `coordinator backfill-attempt-n --dry-run`. The
   `--dry-run` path runs the same UPDATE inside a transaction and
   ROLLBACKs, capturing the rows-that-would-be-updated count plus
   wall-clock elapsed time on the operator's actual production
   corpus. Mutually exclusive with `--check`. The CLI emits a
   WARNING if elapsed exceeds 4s (75% of the 6s hot-path INSERT
   budget). SPEC-002 v1.5.2 backfill live-safety paragraph
   rewritten: operators MUST use `--dry-run` to measure before
   committing to a live backfill; warning means use a maintenance
   window; clean dry-run authorizes a live run.
2. **LOW (reason strings)**: SPEC-005 v0.3.3 direct-SQL ban now
   lists the actual coordinator quarantine reason strings:
   `ambiguous_attempt_n`, `missing_request_log`,
   `missing_provider_identity`, `missing_config_snapshot`,
   `invalid_usage_tokens`, `reconciliation_mismatch`,
   `operator_split_mismatch`. Notes that only the first is a
   candidate for unquarantine — others reflect real invariant
   violations.
3. **LOW (long-tx patterns)**: not addressed in code — existing
   `RecoverLedger` and settlement transactions are part of the
   existing operational reality, not new in #168. The backfill
   live-safety wording acknowledges this implicitly via the
   measurement discipline.

## Verify

- `--dry-run` actually measures wall-clock on the real UPDATE
  (full BEGIN IMMEDIATE → UPDATE → ROLLBACK), not just a fast no-op.
- The 4s WARNING threshold is reasonable for the 6s hot-path INSERT
  budget (75% margin).
- The reason-string list is accurate — `rg -n
  "quarantine_reason.*=" phase4-coordinator/` to verify.
- Is there ANY new attack class introduced by the `--dry-run`
  surface? E.g. could an operator running `--dry-run` repeatedly
  starve hot-path writes via repeated writer-lock acquisitions?
  (The dry-run is operator-authenticated via config, not buyer-
  reachable, so DOS via this surface requires operator collusion.)
- Money-path correctness re-verify on the full hotpath →
  recovery → admin reconcile chain.

## Severity rubric

- **CRITICAL**: real money-path regression or new attack class.
- **HIGH**: R3 finding still open.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
