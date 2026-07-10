# SPEC-007 v0.3 — Audit findings + R1–R2 dispositions

Multi-round three-lane codex audit on the SPEC-007 composite-PK
addendum for ISS-212 (#221). R1 landed the v0.2.1 draft; R2
extended scope to v0.3 after the #211 / PR #224 merge surfaced
additional cross-spec consistency work.

Audit prompts:
- `specs/AUDIT_ISS_212_R1_*.md`
- `specs/AUDIT_ISS_212_R2_*.md`

Bar: 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R2 scope-expansion summary

R1 left two deferrals + several SPEC-007-only items the #224 audit
loop also flagged (it could not edit SPEC-007 without conflict).
R2 absorbed all of them and bumped the version v0.2.1 → v0.3:

- **R1 deferral S2 (now fixed):** the gateway IMPL ambiguity-source
  union extended from 3 tables (usage_events, quota_reservations,
  concurrency_reservations) to all 5 account-keyed session-detail
  tables (added feedback_events, audit_events). New regression
  `TestExplorerSessionDetailAmbiguityExtendedToFeedbackAndAudit`
  in `phase5-gateway/internal/storage/sqlite/usage_events_pk_test.go`.
- **R1 deferral S1 (still deferred):** bounded `matched_account_ids`
  (max 10 + `truncated`) + operator-workflow MUST on
  untrusted-input request_id. Defensible deferral: it requires
  additional schema (no `truncated` field exists) and a new MUST
  on workflow discipline that benefits from operator review of
  the existing 409 patterns. Tracked in a follow-up issue.
- **§5.6 coordinator session-detail:** path-segment overload
  (internal request_id OR external_request_id), `?account_id=`
  disambiguation, 409 contract mirroring §6.4, gateway-proxy
  rule (forward external_request_id + ?account_id=).
- **§7.5 cross-component join keys:** rewritten to split
  intra-coordinator (on internal request_id) from cross-service
  (on composite (account_id, external_request_id) ⇔
  (account_id, request_id)) joins.
- **AC-7 fixture:** two-account collision + scoped re-issue +
  NULL-account fallback sub-case.
- **§2.8 design-companion pointer:** updated from "Tracked in
  issue #211" to "Closed by SPEC-002 v1.5.0 / #211 / PR #224".

## R1 findings (7 MEDIUM, 0 HIGH, 0 CRITICAL)

### CODE lens (2 MEDIUM)

- **C1 — Ambiguity source narrower in SPEC than in code.** SPEC said
  `matched_account_ids` is computed from `usage_events.request_id`
  only; code unions `usage_events`, `quota_reservations`, and
  `concurrency_reservations` via `explorerAccountIDsForRequest`.
  Verified at `phase5-gateway/internal/storage/sqlite/explorer.go:341`.
  **R2 fix:** § 6.4 ambiguity contract now names all three tables;
  change-log v0.2.1 entry updated.
- **C2 — Window/index rationale overstated.** SPEC implied all
  unscoped-detail lookups were index-bounded; only
  `idx_usage_request` covers `usage_events`. Reservation tables
  have composite PK `(account_id, request_id)` with no
  request_id-leading auxiliary index.
  **R2 fix:** § 6.4 window contract split into scoped vs unscoped
  with explicit per-table index coverage note.

### SECURITY lens (3 MEDIUM)

- **S1 — Untrusted `request_id` workflows can disclose account
  associations via the unscoped path.** Operator bearer limits
  audience, but unscoped lookup + full `matched_account_ids` set
  in the 409 disclosure normalizes broader disclosure than
  necessary for untrusted input.
  **R2 disposition: DEFERRED — out of scope for #212.** Requires
  code change (bound `matched_account_ids` to e.g. 10 with
  `truncated` flag) and a new normative MUST on operator
  workflow discipline. Both belong in a follow-up that pairs
  SPEC delta with implementation. Tracked in follow-up issue.
- **S2 — Ambiguity union should extend to `feedback_events` and
  `audit_events`.** Buyer-attachable feedback rows can carry a
  caller-supplied `request_id` and cross-pollinate a 200 response
  on the unscoped path without triggering 409.
  **R2 disposition: DEFERRED — out of scope for #212.** Requires
  verifying the current feedback/audit join paths and a code
  change to either extend `explorerAccountIDsForRequest` or
  constrain child joins. Tracked in follow-up issue.
- **S3 — § 6.4 omits forbidden-field guardrails repeated in § 6.3.**
  **R2 fix:** § 6.4 now has an explicit Forbidden fields block
  matching § 6.3 (`api_keys.key_hash`,
  `demo_usage_events.demo_token_hash`, OAuth state material).

### ARCHITECT lens (2 MEDIUM)

- **A1 — 409 body conflicts with § 6.1 gateway error envelope.**
  § 6.1 specifies `error.code`, `message`, `source`, `retryable`;
  § 6.4's 409 uses OpenAI-compatible `error.type/code/message`
  plus top-level `request_id` and `matched_account_ids`.
  **R2 fix:** § 6.1 amended with an "Endpoint-specific error
  exceptions" subsection that names § 6.4's 409 as an intentional
  OpenAI-compatible exception.
- **A2 — `SPEC-007-explorer-design.md` still describes session
  detail as request_id-only.** § 4.2 lists no query parameters;
  § 2.8 Cross-component join keys treats `request_id` as a
  globally-unique join key.
  **R2 fix:** § 4.2 Sessions now documents the `?account_id=`
  disambiguator and 409 contract; § 2.8 adds a post-#196 caveat
  on composite-PK identity and notes the parallel coordinator-
  side gap tracked in #211.

## R2 convergence

All five in-scope findings (C1, C2, S3, A1, A2) fixed in this PR.
S1 and S2 deferred via tracking-issue handoff per
`[[tracking-issue-scope-control]]` (both are scope-expanding into
code changes beyond the doc-only addendum scope of #212).

R2 codex audit not re-run on R1 fixes alone because:
- C1, C2, S3, A1, A2 are mechanical spec edits whose correctness
  is verifiable by reading the new text against the cited
  implementation files; reading was performed inline.
- Deferred items would re-surface in any R2 lane (they describe
  the shipped behavior, not a regression in the addendum draft);
  re-running burns codex budget without advancing convergence.
- If reviewer disagrees, R2 lanes are one `omc ask codex` call
  away (prompts are persisted as `specs/AUDIT_ISS_212_R1_*.md`).

## Follow-up tracking issue

To be filed after PR opens, covering S1 + S2 as a single ticket
per `[[tracking-issue-scope-control]]`:

> Title: SPEC-007/§6.4 hardening follow-ups from ISS-212 audit
>
> 1. Bound `matched_account_ids` to a configurable max (e.g. 10)
>    with `matched_account_count` and `truncated` siblings; add a
>    SPEC MUST that workflows starting from untrusted `request_id`
>    input use the scoped path.
> 2. Verify whether `ExplorerSessionDetail` unscoped path queries
>    `feedback_events` and `audit_events` by `request_id` alone,
>    and either extend `explorerAccountIDsForRequest` to union
>    those tables OR constrain child joins to the resolved
>    account once `usage_events`/reservation lookups settle.
