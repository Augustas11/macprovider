You are auditing the SPEC-005 v0.4 IMPL (issue #169) from an
ARCHITECT lens.

# Repository context

- Branch `impl/spec-005-v0-4-force-void` in `Augustas11/macprovider`.
- Spec: `specs/SPEC-005-billing.md` v0.4 (locked).
- The IMPL adds one POST endpoint, a new SQLite table, validation
  helpers, and reader narrowing across §11.1/§11.2/§11.3.

# Audit scope (ARCHITECT lens)

- **Composition with existing endpoints.** Does the new
  `/admin/ledger/quarantine/{id}/force-void` route fit cleanly
  into the existing `serveHTTP` dispatch? Any conflicts with
  `/admin/ledger/summary` / `providers` / `reconcile`?
- **Composition with SPEC-007 explorer.** The explorer LEFT JOIN
  named in §11.6.5 is NOT included in this PR (SPEC-007 is owned
  by a separate spec). Is that OK to defer to a SPEC-007 patch
  PR, or does it cause v0.4 IMPL to ship with an inconsistent
  user surface?
- **Reload story.** §13.2 / §11.6.4 mandates a
  `billing_config_flag_changed` audit event on every actual flip
  of `billing.quarantine_resolution_force_void_enabled`. The IMPL
  does NOT yet emit this event (the handler is re-wired at
  startup; SIGHUP / HTTP-reload integration is not in this PR).
  Is this an acceptable v0.4 IMPL gap (operator must restart for
  the flag to take effect) or should the IMPL ship the flip-audit
  too?
- **Forward-compatibility with v0.5.** v0.5 adds force-credit +
  pre-payout hold + UNIQUE relaxation. Does the v0.4 IMPL choose
  data structures / function signatures that v0.5 can extend
  cleanly? Specifically:
  - The CHECK constraint must be ALTERed (SQLite drop + recreate).
  - The UNIQUE constraint must be relaxed.
  - The handler split (force-void only) needs to host force-credit.
  Will v0.5 IMPL be a clean addition or a rewrite?
- **MaxOpenConns(1) interaction.** The billing store shares a DB
  handle with requestlog (issue #21 ARCH-3 history). The new
  handler opens a BeginTx that holds the only conn. Does any
  reader path (admin/summary, providers, reconcile) become
  blocked while a force-void POST is in flight?
- **Test independence.** The new tests share a fixture and
  assume audit_log is created manually (production wires audit
  via a different path). Is this acceptable, or should the
  billing migrate ALSO ensure audit_log exists (defensive
  coupling)?
- **Operator UX.** v0.4 ships POST-by-id only — no list endpoint
  for open quarantines (deferred to v0.5 per the SPEC change-log).
  Is this acceptable for an operator about to force-void a
  handful of rows? Or does v0.4 IMPL need an interim discovery
  mechanism (e.g., the existing `/admin/ledger/summary`
  `quarantined_count` field is sufficient)?
- **Production launch gate item 10.** §11.5 says the operator
  MUST flip the flag deliberately. Does the IMPL surface a clean
  way to verify the flag state at startup (e.g., a log line)?

# Severity

- **CRITICAL** = fundamental design defect.
- **HIGH** = architectural gap compounding with v0.5.
- **MEDIUM** = scoping question.
- **LOW** = framing.

# Output

```
[SEVERITY] <short title>

Location: <file/symbol or topic>
Concern: <architectural question>
Evidence: <quote>
Fix: <one-sentence or "name as defer with rationale">
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.
