You are auditing the SPEC-005 v0.4 IMPL (issue #169) for SECURITY
concerns.

# Repository context

- Branch `impl/spec-005-v0-4-force-void` in `Augustas11/macprovider`.
- Spec: `specs/SPEC-005-billing.md` v0.4 (locked).
- New money-path admin endpoint: `POST /admin/ledger/quarantine/{id}/force-void`.
- Files: `phase4-coordinator/internal/billing/quarantine.go`,
  `quarantine_test.go`, plus migrations/wiring in `store.go`,
  `endpoints.go`, `config.go`, `cmd/coordinator/main.go`.

# Audit scope (SECURITY lens)

- **Auth/authz.** Operator-key gating: any reachable bypass? CORS
  preflight, OPTIONS, gateway service-token confusion? Does the
  endpoint enforce the same posture as existing /admin/ledger/*?
- **Input validation completeness.** Trace `validateReason` and
  `validateOperatorID`. Any reject class named in SPEC §11.6.3
  missed? Are there codepoints / byte sequences that bypass the
  sanitizer (e.g., over-long UTF-8 encodings, surrogates,
  non-canonical forms)?
- **Audit-log poisoning.** Does the payload use `json.Marshal` (no
  hand-rolled JSON)? Can an attacker (with operator key) inject a
  control sequence that mangles downstream log consumers? Does
  `operator_id` flow through the sanitizer too (or just `reason`)?
- **Money-path correctness.** Force-void is supposed to produce NO
  money-out. Trace: does the resolution INSERT ever cause a
  downstream credit / payout to fire? Does the §11.6.5 reader
  narrowing actually keep force-voided rows OUT of the payable
  set?
- **Race/TOCTOU.** §11.6.2 says single INSERT against UNIQUE
  constraint. Does the IMPL ever pre-check
  ledger_quarantine_resolutions? Does the base-row precondition
  check have a TOCTOU window?
- **Information disclosure.** Distinct status codes (404 / 422 /
  409) leak whether a row exists / is quarantined / is resolved.
  This is operator-key-gated (acceptable per SPEC §11.6.6) but
  verify the 404 body for the disabled-flag case is byte-identical
  to the row-not-found 404 body — no leak of which case fired.
- **DoS.** Body cap (4 KiB) enforced via http.MaxBytesReader BEFORE
  full body read? Path parameter overflow handled? Rate-limit
  bucket shared with existing /admin/*?
- **Concurrency.** Concurrent POSTs against the same id — does the
  IMPL produce exactly one 200 + many 409? Does it deadlock at
  MaxOpenConns(1)?
- **Tx-rollback semantics on audit-INSERT failure.** Does the IMPL
  guarantee no orphan resolution row when audit-INSERT fails?
- **CHECK-constraint bypass.** v0.4 forbids force_credit via CHECK.
  Is there any code path that could attempt force_credit?
- **Operator-id self-assertion.** §11.6.4 caveat — does the IMPL
  emit `operator_attribution: "operator_key_self_asserted"`
  constant so forensic readers see the limitation?

# Severity

- **CRITICAL** = exploitable, money loss or auth bypass.
- **HIGH** = significant security gap.
- **MEDIUM** = hardening item.
- **LOW** = wording.

# Output

```
[SEVERITY] <short title>

Location: <file:line>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.
