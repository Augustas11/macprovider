You are auditing SPEC-005 v0.4 (issue #169 — manual quarantine
resolution admin surface) for SECURITY concerns.

# Repository context

- This is `specs/SPEC-005-billing.md` in repo `Augustas11/macprovider`
  (branch `spec/005-v0-4-quarantine-resolution`).
- v0.4 introduces two NEW money-path POST endpoints:
  - `POST /admin/ledger/quarantine/{request_credit_id}/force-credit`
  - `POST /admin/ledger/quarantine/{request_credit_id}/force-void`
- Both gated behind the existing `/admin/*` operator-key bearer.
- v0.4 adds a new `ledger_quarantine_resolutions` table and writes
  to the existing `audit_log` table.

# Audit scope (SECURITY lens)

- **Auth/authz.** Is the operator-key requirement complete? Any
  reachable bypass (e.g. CORS preflight, OPTIONS handling, gateway
  service-token confusion — see HIGH-1 history on PR #73)? Is
  empty-operator-key denied? Does §11.6 reuse the §11 envelope
  exactly?
- **Input validation.** §11.6.4 names UTF-8, ASCII control, C1
  control rejection, length cap. Are there other injection classes
  uncovered (e.g. surrogate pairs, BOMs, RTL override characters
  U+202E, zero-width joiners)? Is the path parameter
  `{request_credit_id}` validated before the DB lookup (SQL
  injection class on TEXT-as-int)?
- **Logging / audit poisoning.** The `reason` and `operator_id`
  strings land in the audit log payload. Could an attacker (with
  operator key — assume that's how they get here) inject
  shell/journal control sequences that affect downstream log
  consumers? Is `json.Marshal` enforced (memory: SPEC-007 v0.4 R1
  C0/C1 closure)?
- **Money-path correctness.** Could a malicious or coerced operator
  use these endpoints to silently pay a colluding provider? If yes,
  is the audit-log trail sufficient to detect after the fact? What
  is the blast-radius bound per single POST?
- **Race/TOCTOU.** §11.6.3 + §11.6.7 say "single INSERT" — is the
  SPEC explicit enough that an implementer cannot accidentally
  introduce a check-then-INSERT race?
- **DoS surface.** Is the rate limit explicit? Is there a body-size
  cap (§11.6.1 names 4 KiB)? Are repeated 409s rate-limited
  separately from 200s, or is there a hot-spam vector?
- **Information disclosure on errors.** Do 400 / 404 / 422 / 409
  responses leak information that helps an external attacker
  enumerate `request_credit_id` space? (The endpoint is operator-
  keyed, so this is lower stakes — but list it.)
- **Audit-log invariants.** Atomic write with the resolution INSERT
  is claimed in §11.6.5. Verify the SPEC names a single-transaction
  contract. If the audit table is on a different connection,
  atomicity is not free.
- **Settlement-window race.** §11.6.6 "Settlement timing" para says
  force-credited rows enter the NEXT window. What if a resolution
  POST commits AT THE EXACT MOMENT the settlement sweep is running?
  Is the SPEC clear on which side wins, or is there a race window
  where the row settles twice (once unresolved, once resolved)?
- **Immutable-resolution policy as security feature.** v0.4 makes
  resolutions immutable. Are there scenarios where this is a
  vulnerability (e.g. an operator under duress force-credits a
  malicious provider; no path to unwind)? Should v0.4 add an
  emergency-reversal path, or is the "audit + future SPEC bump"
  posture acceptable for a permissionless money-path?

# Severity

- **CRITICAL** = exploitable as written, money loss or auth bypass.
- **HIGH** = significant security gap requiring SPEC text fix.
- **MEDIUM** = hardening item the SPEC should explicitly name.
- **LOW** = wording that opens a class of mistakes for an inattentive
  implementer.

# Output format

Same as the CODE audit prompt:

```
[SEVERITY] <short title>

Location: <§ anchor>
Concern: <what is wrong>
Evidence: <quote>
Fix: <one-sentence>
```

End: `Tally: <C>/<H>/<M>/<L>` or `Tally: 0/0/0/0 ACCEPT`.

Do NOT propose features. Audit the v0.4 text AS WRITTEN.
