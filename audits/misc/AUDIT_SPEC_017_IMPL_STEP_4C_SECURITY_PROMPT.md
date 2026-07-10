# AUDIT_SPEC_017_IMPL_STEP_4C — Security lane

Operator-paste prompt to audit the **Step 4.C IMPL diff** under
PR `Augustas11/macprovider#173` from the security (label-
leak / disclosure-gate / metric-cardinality) lens.

Severity: **CRITICAL / HIGH / MEDIUM / LOW / INFO**. Lock target:
0 CRITICAL + 0 HIGH + 0 MEDIUM.

Each round writes
`specs/SPEC-017-IMPL-STEP_4C-security-rM-audit.md`.

---

```
=== BEGIN PROMPT ===

You are auditing the Step 4.C IMPL diff for SPEC-017 at branch
`impl/spec-017-step-1` (PR #173) from the SECURITY (label-leak /
disclosure-gate / metric-cardinality) lens.

Step 4.C scope: see ARCH-lane prompt.

Output: specs/SPEC-017-IMPL-STEP_4C-security-rM-audit.md.

Severity model:
- CRITICAL — Prometheus metric label carries raw token, 43-char
  body, `token_hash`, untrusted Origin string, or partner_keys.
  label_text (label_text is operator-supplied but treated as
  operator-permitted prefix-permitted only; using it as a
  metric label is a high-cardinality + information-disclosure
  risk); operator-runbook recipe shows a real-looking `mpk_*`
  string; the §6.6.2 sign-off template is absent OR present
  but signed-off without SPEC-014 v0.9 actually deployed (this
  is a process audit, not a code audit, but lives in the
  SECURITY lane because the disclosure obligation is the
  privacy boundary).
- HIGH — `stats_handler_panic` event omits redaction so a
  stack trace could include Authorization-bearing url fields;
  `stats_partner_key_issued` event includes a substring of the
  raw token; metric scrape endpoint reachable without auth.
- MEDIUM — partial label hygiene (one metric's labels are
  fine, another's is borderline); runbook entry shows a
  command with `<token>` but the example syntax could lure
  an operator to paste the real token.
- LOW — polish / quality / non-blocking.
- INFO — positive observations.

Required reading (same as ARCH/CODE lanes).

Audit categories (sweep ALL — empty findings still record
evidence):

A. **Metric-label leak sweep** — for each labeled metric,
   enumerate every label and reason about every value that
   could appear there. Raw token, body, `token_hash`, prefix,
   `label` column from `partner_keys`, Authorization fragments,
   Origin fragments — none MUST appear. Only `partner_keys.id`
   (INTEGER), endpoint name, tier, status code, component
   name, axis name are permitted.

B. **Event field redaction** — every structured event emits
   only operator-permitted fields. Cross-reference SPEC §7.4
   redaction directive.

C. **Operator-runbook redaction defaults** — every `coordinator
   partner-keys issue` example in OPS.md uses
   `mpk_REDACTED_RAW_TOKEN` or equivalent placeholder. NO real-
   looking `mpk_<base64url>` strings.

D. **§6.6.2 sign-off template** — present in OPS.md verbatim,
   matches the BUILD §2 v11 ARCH r10 H1 paragraph. The Step
   4.C convergence file MUST state whether the live SPEC-014
   v0.9 disclosure is in production OR remains an operator-
   side cutover prerequisite.

E. **AC-20 CI assertion strength** — the test MUST be the SQL
   count, NOT a Go-level introspection of the CLI surface
   (because future code paths could bypass the CLI and write
   directly).

F. **Metric scrape endpoint posture** — if Step 4.C wires a
   `/metrics` endpoint, it MUST be on a bind-loopback or
   bearer-auth-gated surface. NEVER public.

G. **Cross-step disclosure surface** — Step 4.C MUST NOT
   change Step 3 redaction surfaces (the existing middleware
   IS the redaction surface — Step 4.C composes against it,
   not replaces).

H. **AC-15 (Step 4.C share)** — Prometheus metric labels
   scanned under test load show NO raw token, body,
   `token_hash`, prefix-derived secret, or Authorization-
   derived value.

Validation steps (same as ARCH/CODE lanes).

Output structure (one document per round, fresh file).

Lock target is 0 CRITICAL + 0 HIGH + 0 MEDIUM.

=== END PROMPT ===
```
