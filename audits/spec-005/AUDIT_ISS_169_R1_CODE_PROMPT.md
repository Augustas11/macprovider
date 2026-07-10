You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) for CODE-correctness concerns.

# Repository context

- This is `specs/SPEC-005-billing.md` in repo `Augustas11/macprovider`
  (branch `spec/005-v0-4-quarantine-resolution`).
- v0.4 adds the `ledger_quarantine_resolutions` table (§4.10), two
  POST endpoints (§11.6.1 / §11.6.2), an audit-log emit (§11.6.5),
  reader-side composition rules (§11.6.6), AC-Q040..AC-Q046 (§18).
- Companion code on `main` you may want to cite: `phase4-coordinator/internal/billing/endpoints.go`
  (existing /admin/ledger/* handlers), `phase4-coordinator/internal/audit/store.go`
  (existing audit_log writer), `phase4-coordinator/internal/billing/recovery.go`
  (existing quarantine writers — the populators we are now resolving).

# Audit scope (CODE lens)

You are NOT auditing security exposure (that's a parallel SECURITY
lens). You ARE auditing whether the SPEC text — read as an
implementer would — produces correct, finite, deterministic code:

- **Schema correctness.** Does §4.10's table shape capture every
  constraint the prose claims? Are CHECK constraints exhaustive for
  the columns named? Does the UNIQUE definition match the
  idempotency claim in §11.6.3?
- **Endpoint contract correctness.** Are the request/response shapes
  for §11.6.1 / §11.6.2 deterministic? Will two compliant
  implementations produce byte-identical responses given the same
  ledger state? Are all error paths (400/403/404/409/413/415/422)
  named with their triggering conditions? Are there reachable code
  paths the SPEC does not specify a response for?
- **Audit payload completeness.** §11.6.5 names 9 fields. Is each
  field's source unambiguous? Are types stable (no
  string-or-integer ambiguity)? Does the "same SQLite transaction"
  language match what `audit/store.go` Insert can plausibly support
  (note: audit's Insert is on a separate handle? same handle? check
  it)?
- **Reader-side widening (§11.6.6).** Do the SQL fragments in the
  filter table compile against the current schema? Are there any
  aggregation queries elsewhere in SPEC-005 (search the spec) that
  filter on `quarantined=0` or `quarantined=1` and were NOT updated
  in v0.4? List them.
- **Concurrency/race.** §11.6.7 says "single INSERT against the
  UNIQUE constraint" is the correct shape. Is the SPEC explicit
  about what error code surfaces when SQLite returns
  `SQLITE_CONSTRAINT_UNIQUE`? How does the handler distinguish that
  from other constraint failures (FK, CHECK)?
- **Cross-spec consistency.** Does v0.4 keep the v0.3.3 monotonic-
  quarantine invariant intact? Search the spec for any new clause
  that suggests UPDATEing `quarantined`.
- **AC coverage.** Are AC-Q040..AC-Q046 jointly sufficient to lock
  the v0.4 contract? Any normative §11.6.X clause without an AC
  pinning it?

# Severity vocabulary

- **CRITICAL** = SPEC defect that would corrupt the ledger / cause
  double-credit / cause silent money loss when implemented as
  written. Anything money-path-impactful.
- **HIGH** = SPEC defect that would force IMPL ambiguity / cause
  test failures / produce non-deterministic behavior; correct money
  outcome, broken contract.
- **MEDIUM** = clarity gap that risks IMPL drift but does not force
  a wrong outcome.
- **LOW** = wording, redundancy, minor inconsistency.

# Output

Plain text. For each finding:

```
[SEVERITY] <short title>

Location: <§ anchor or line range>
Concern: <what is wrong>
Evidence: <quote the offending text>
Fix: <one-sentence proposed change>
```

End with a tally line: `Tally: <C>/<H>/<M>/<L>`.

If no findings: `Tally: 0/0/0/0 ACCEPT`.

Do NOT propose new features. Do NOT speculate about future versions.
Audit the v0.4 text AS WRITTEN.
