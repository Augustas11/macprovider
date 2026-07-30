You are auditing the SPEC-005 v0.4 IMPL (issue #169 — manual
quarantine VOID admin surface) for CODE-correctness concerns.

# Repository context

- Branch `impl/spec-005-v0-4-force-void` in `Augustas11/macprovider`.
- Spec contract: `specs/SPEC-005-billing.md` v0.4 (locked on `main`,
  landed in PR #252).
- IMPL files added/touched in this PR:
  - `phase4-coordinator/internal/billing/quarantine.go` (NEW —
    handler + validation)
  - `phase4-coordinator/internal/billing/quarantine_test.go` (NEW —
    acceptance tests)
  - `phase4-coordinator/internal/billing/store.go` (MIG-005-010
    table)
  - `phase4-coordinator/internal/billing/endpoints.go` (route
    dispatch + handler struct + §11.1/§11.2/§11.3 reader narrowing)
  - `phase4-coordinator/internal/config/config.go` (BillingConfig)
  - `phase4-coordinator/cmd/coordinator/main.go` (wire-up)

# Audit scope (CODE lens)

Verify the IMPL faithfully implements SPEC-005 v0.4. Specifically:

- **Schema (MIG-005-010).** Does the new CREATE TABLE statement
  match SPEC §4.10 exactly? CHECK constraints; UNIQUE; index
  surface (must NOT have a separate idx_lqr_request_credit per
  the SPEC).
- **Handler request flow.** Does `forceVoidHandler` follow the
  §11.6.1 / §11.6.1.1 / §11.6.2 contract? Trace each branch:
  method, auth, route-flag, content-type, body cap, JSON parse,
  validation, BEGIN IMMEDIATE, base-row preconditions, INSERT,
  audit INSERT, COMMIT, response. Are there reachable code paths
  the SPEC does not specify a response for?
- **Audit-log atomicity (§11.6.4).** Verify the audit_log INSERT
  is on the SAME `*sql.Tx` as the resolution INSERT. Verify
  `audit.Store.Insert` is NOT used. Verify rollback semantics on
  audit-INSERT failure.
- **Reader narrowing.** Trace the `/admin/ledger/summary` and
  `/admin/ledger/providers` query changes. Do they match §11.6.5
  `OPEN_PREDICATE`? Are the SQL queries syntactically correct?
- **Reconcile widening.** Does `/admin/ledger/reconcile` now emit
  `rows_force_resolved_in_range` AND narrow `rows_quarantined` to
  OPEN_PREDICATE? Trace the SQL.
- **UNIQUE race handling.** §11.6.2 forbids check-then-INSERT. Does
  `forceVoidHandler` rely solely on the UNIQUE constraint for race
  protection? Verify that `respondAlreadyResolved` does NOT hit a
  deadlock at MaxOpenConns(1) (tx must be released before re-read).
- **isRejectedCodepoint coverage.** Does the function reject every
  codepoint named in SPEC §11.6.3? The DICP set is large — list
  any Unicode 16.0 DICP=Yes codepoint MISSING from the function.
- **Validation order.** Does the handler validate BEFORE the
  resolution INSERT (not after)? Are CHECK constraint failures
  unreachable as the spec requires?
- **Config wiring.** Is `cfg.Billing.QuarantineResolutionForceVoidEnabled`
  threaded correctly into the handler? Reload story acknowledged?
- **AC coverage.** Verify the ACs in `quarantine_test.go` actually
  pin the §11.6 contract. Any AC missing? Any test that passes
  vacuously?
- **Composition with existing tests.** Did the changes break any
  existing test (e.g. the §11.1 summary query)?

# Severity

- **CRITICAL** = IMPL defect that would corrupt the ledger or cause
  silent money loss.
- **HIGH** = IMPL defect violating §11.6 contract / reachable
  incorrect response.
- **MEDIUM** = clarity gap, missing test, unspecified branch.
- **LOW** = style, comment, redundancy.

# Output

```
[SEVERITY] <short title>

Location: <file:line or symbol>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Audit the IMPL AS WRITTEN against the LOCKED v0.4 SPEC.
