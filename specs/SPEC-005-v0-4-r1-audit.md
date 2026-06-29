# SPEC-005 v0.4 — R1 three-lane codex audit findings

R1 fired against commit `032d31a` (v0.4 initial draft). Three lenses
(code / security / architect) per the locked convention (user memory
`feedback-three-lane-codex-audits`).

| Lens | Tally | Artifact |
|---|---|---|
| CODE | 0/5/3/0 | `.omc/artifacts/ask/codex-you-are-auditing-spec-005-v0-4-…-15-18-42-…md` |
| SECURITY | 0/1/2/2 | `.omc/artifacts/ask/codex-you-are-auditing-spec-005-v0-4-…-15-16-48-…md` |
| ARCHITECT | 0/2/4/1 | `.omc/artifacts/ask/codex-you-are-auditing-spec-005-v0-4-…-15-18-05-…md` |

Aggregate: 0 CRITICAL / 8 HIGH / 9 MEDIUM / 3 LOW.

## R1 → R2 fix plan

### Cluster 1 — Settlement / reconciliation / payout escape (A-H1, A-H2, A-M1, A-M4, C-H5, S-H1)

- **A-H1 / C-H5:** `delta_gross_credits` semantics under v0.4. Amend
  §10.3 + §11.3 to define `rows_force_resolved_in_range` as a
  mandatory field of `/admin/ledger/reconcile`, and to subtract
  force-credited deltas from the AC-H005 delta predicate. AC-H005
  remains the "ledger closes the books" gate — v0.4 just teaches
  it the new operator-write surface.
- **S-H1 / A-M1:** Settlement-sweep snapshot ordering. Add §11.6.6
  "Settlement-sweep snapshot ordering" subsection naming the
  `BEGIN IMMEDIATE` boundary around the sweep query + the
  payout-ready insert: any resolution that commits AFTER the
  sweep's read snapshot is observed by the NEXT sweep, never the
  current one.
- **A-H2:** Mistaken force-credit has no pre-payout escape, and
  SPEC-016 turns ready rows into real USDC transfers. Pre-payout
  hold (e.g., 24h delay between resolution and payout-ready
  eligibility) is the right shape but the change itself is
  substantial; **DEFERRED to v0.4.1 / v0.5** with a tracking
  issue. v0.4 PATCH: name the operator-runbook step "force-credit
  flushes to next §7 sweep AND to SPEC-016 USDC payout; operators
  with bulk-resolve workflows MUST pause the payout-runner per
  SPEC-016 ops runbook before issuing more than N resolutions in
  a single window." This is the "name as defer with rationale"
  fix the architect lens permits.
- **A-M4:** §17 failure modes. Add three rows: audit-write
  failure rollback, already_resolved conflict, settlement-timing
  race.

### Cluster 2 — Endpoint contract precision (C-H1, C-M1, C-H3)

- **C-H1:** 200 and 409 response shapes are NOT the same shape.
  200 is a top-level resolution row; 409 is the standard error
  envelope wrapping `existing_resolution`. Rewrite §11.6.1 last
  paragraph and §11.6.3 to make this explicit.
- **C-M1:** Add an exhaustive response-code table to §11.6.1:
  400 (path-not-integer, malformed JSON, non-object JSON,
  duplicate fields, unknown fields, path integer overflow), 401
  (no operator key), 403 (wrong operator key), 404 (no row), 405
  (non-POST), 409 (already_resolved), 413 (body>4KiB), 415 (CT
  not JSON), 422 (validation failure with code: empty_reason |
  not_quarantined | unsanitized_reason | invalid_utf8 |
  bad_operator_id | reason_too_long).
- **C-H3:** UNIQUE race vs 404/422 precondition. Clarify: the
  endpoint MUST check `request_credit_id` exists and has
  `quarantined=1` BEFORE the INSERT (those checks happen inside
  the SAME `BEGIN IMMEDIATE` transaction; they are NOT a TOCTOU
  pre-check on the resolution table itself). The forbidden
  pre-check is on `ledger_quarantine_resolutions`, not on
  `ledger_request_credits`. Only `SQLITE_CONSTRAINT_UNIQUE` on
  `idx_lqr_request_credit` (the UNIQUE clause) maps to HTTP 409
  `already_resolved`; FK / CHECK failures after validation are
  unreachable, but if they surface they produce HTTP 500
  `internal_error` (not silent corruption).

### Cluster 3 — Audit-log same-transaction (C-H2)

- **C-H2:** §11.6.5 says "same SQLite transaction as the
  resolution INSERT". The current `audit.Store.Insert` is on a
  separate `*sql.DB` handle (different connection pool path) so
  cannot share a transaction. Two options:
  1. Insert the audit row via the billing store's `*sql.Tx`
     directly (raw `INSERT INTO audit_log (...)` SQL, bypassing
     `audit.Store.Insert`).
  2. Relax atomicity to "best-effort with rollback compensation
     on audit failure".
- Choice: **option 1**. Amend §11.6.5 to say the audit row is
  INSERTed into the `audit_log` table through the SAME
  `*sql.Tx` opened by the resolution handler — NOT through
  `audit.Store.Insert`. The `audit_log` table is shared; only
  the insertion path differs. Retention sweep
  (`audit.Store.PruneBefore`) is unaffected.

### Cluster 4 — Reader SQL precision (C-H4, C-M2)

- **C-H4:** §11.6.6 filter table mixes prose and SQL; alias names
  drift from §4.10 column names (`resolution_operator_id` vs
  `operator_id`, `resolution_at_utc` vs `created_at_utc`). Fix:
  rewrite filter table with concrete `LEFT JOIN` SQL fragments
  and require aliases such as `r.operator_id AS resolution_operator_id`,
  `r.created_at_utc AS resolution_at_utc` so the alias names
  surface as field names in admin/SPEC-007 responses.
- **C-M2:** Schema CHECKs in §4.10 only enforce length, not
  charset/control rules from §11.6.4. Mark the §11.6.4 checks
  as ENDPOINT-LAYER ONLY explicitly (not schema-layer); add a
  note in §4.10 cross-referencing.

### Cluster 5 — Sanitization / threat-model (S-M1, S-M2, S-L1, S-L2)

- **S-M2:** Expand §11.6.4 reject classes to include Unicode
  bidi/format/zero-width: U+200B (ZWSP), U+200C (ZWNJ), U+200D
  (ZWJ), U+200E (LRM), U+200F (RLM), U+202A..U+202E (LRE / RLE /
  PDF / LRO / RLO), U+2066..U+2069 (LRI / RLI / FSI / PDI),
  U+FEFF (BOM). These are display-mangling characters that the
  audit-log viewer or terminal-paste workflow could be tricked
  by.
- **S-M1:** Add a one-paragraph clarification to §11.6.5: the
  `operator_id` field is free-form client input and the audit
  trail therefore proves operator-KEY use, not human identity.
  Bind-to-authenticated-principal is deferred until the
  operator-key surface gains per-human attribution (out of v0.4
  scope).
- **S-L1:** ID enumeration via distinct 404/422/409. Accept under
  operator-key threat model; add one-line note in §11.6.7
  threat-model paragraph: "the endpoint is operator-key-gated;
  distinct status codes for not_found / not_quarantined /
  already_resolved are intentional for operator UX and accepted
  under the threat model."
- **S-L2:** Rate-limit accounting. Add to §11.6.7: "every
  response code path (200, 4xx, 5xx) consumes the same `/admin/*`
  rate-limit budget — failure responses do NOT bypass the bucket."

### Cluster 6 — Architecture / launch-gate (A-M2, A-M3, A-L1)

- **A-M2 DEFERRED:** `GET /admin/ledger/quarantine?status=open`
  list endpoint. v0.4 ships POST-by-id resolution only.
  Operators discover quarantined rows via the existing
  SPEC-007 explorer (read-only) or via the §11.1 summary
  `quarantined_count`. A first-class list endpoint is real
  operator UX but is a separate v0.5 surface; tracking issue
  to be filed if v0.4 ships and the absence becomes load-bearing.
- **A-M3:** Production launch gate. Add a new item to the
  §11.5-era "production launch gate" list: "force-credit /
  force-void operator runbook MUST be reviewed before enabling
  the §11.6 endpoints in production; payout-runner pause / resume
  procedure (SPEC-016 ops) MUST be tested in staging before bulk
  resolutions."
- **A-L1:** Schema-versioning rationale. Add one sentence to
  §4.10 explaining why a separate resolution table (not a
  `resolution_kind` column on `ledger_request_credits`): the
  base row's monotonic-quarantine invariant must stay intact;
  v0.5+ may reconsider; v0.4 reserves the simpler shape.

### Cluster 7 — AC coverage (C-M3)

- **C-M3:** Add ACs:
  - **AC-Q047** — same-tx audit atomicity: assert a fault during
    audit-log INSERT rolls back the resolution INSERT (no row in
    either table).
  - **AC-Q048** — 405 on GET / DELETE / PATCH against
    `/admin/ledger/quarantine/{id}/force-credit`.
  - **AC-Q049** — concurrent insertion: 64-thread test against
    the same `request_credit_id` produces exactly one 200 and
    63 × 409; only one `audit_log` row.
  - **AC-Q050** — SPEC-007 explorer alias columns surface
    correctly when LEFT JOIN matches.
  - **AC-Q051** — `/admin/ledger/reconcile` includes
    `rows_force_resolved_in_range`; AC-H005 delta computed over
    the adjusted set.
  - **AC-Q052** — existing weekly payout-ready row + late
    force-credit: assert the force-credit waits for the NEXT
    settlement tick and never modifies the existing payout-ready
    row.

## Deferred (with rationale)

Two findings from the R1 ARCH lens are explicitly named as v0.5
or later, with rationale recorded inline in the SPEC:

1. **A-H2 — pre-payout hold for mistaken force-credit.** Tracked
   as a separate follow-up issue. v0.4 PATCH: name the
   payout-runner pause runbook step in §11.6 + launch-gate item.
2. **A-M2 — first-class open-quarantine list endpoint.** Tracked
   as a separate follow-up issue. v0.4 PATCH: §11.6 explicitly
   names this as a v0.5 surface.

Followup issues will be filed with the v0.4 PR.

## Convergence target

R2 fires the same three lenses against the v0.4 draft AFTER these
fixes land. Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three
lenses. LOWs may be absorbed in the same fix-pass.
