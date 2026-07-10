You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane.

## Scope

SPEC-002 v1.5.1 R-2 normative clarifications, doc-only, additive on top of v1.5.0
(merged via PR #224 on 2026-06-29).

The two clauses (in `specs/SPEC-002-coordinator.md`):

1. **`external_request_id` UUID-tolerance** — opaque sanitized text 1-128
   bytes, non-control chars; cross-service reconciliation MUST NOT assume
   UUIDv4 shape.

2. **Column-present / index-absent state semantics** — reconciliation
   tooling MUST introspect both `PRAGMA table_info` and `sqlite_master`;
   MUST surface "unindexed" state distinctly from "legacy".

## What to verify

Look for security implications of the new normative contract that the
v1.5.1 text either creates, fails to close, or makes worse than v1.5.0:

- **Log-injection / log-forgery surface**: the UUID-tolerance clause says
  the coordinator "MUST NOT echo the malformed payload to logs". Does any
  current log statement in `phase4-coordinator/internal/buyer/server.go`,
  `phase4-coordinator/internal/requestlog/store.go`, billing, or recovery
  log the raw header before sanitization? Does the v1.5.1 text adequately
  forbid future code from doing so, or is it advisory-only?

- **Confused-deputy via `external_request_id` shape**: by formalizing
  "opaque 1-128 byte text" the SPEC now allows IDs like
  `acct_other_account_id_here_123456` that could be misinterpreted by
  downstream tooling expecting UUIDv4. Is the v1.5.1 text sufficient to
  prevent an audit harness from naively casting `external_request_id` to
  `account_id` based on prefix matching?

- **Cross-account ID smuggling**: a buyer sending a crafted X-Request-ID
  designed to collide with another account's external_request_id was the
  driving #196/#211 fix. v1.5.1 reaffirms the composite key
  `(account_id, external_request_id)` is the reconciliation key — does
  it adequately re-state that `external_request_id` alone MUST NOT be
  used for any identity decision?

- **State (B) → fuzzy fallback risk**: if a tool ignores v1.5.1's
  introspection MUST and falls back to fuzzy match under state (B),
  does the audit miss a class of cross-account collisions that would
  have been caught by an exact composite-key join? Severity ladder it.

- **SPEC consistency with SPEC-006 v0.9.1 (UUIDv4-minting at gateway)**:
  v1.5.1 says gateway traffic gets UUIDv4 per R-G3 but direct buyer-port
  traffic MAY carry arbitrary text. Does this create a path for a
  malicious operator to bypass UUIDv4 by reaching the buyer port
  directly? What does the production deployment topology look like —
  is the buyer port publicly exposed, or only accessible via the
  gateway in production?

- **Sanitization defense-in-depth gaps**: 0x80-0x9f C1 range rejection
  was added to defeat CSI escape sequences (per memory
  `c1-control-chars-terminal-sanitizer-bypass`). Does the v1.5.1 text
  reference this and pin it as load-bearing, or merely incidental?

## Severity rubric

- **CRITICAL**: v1.5.1 normative text opens a security regression vs v1.5.0.
- **HIGH**: v1.5.1 fails to close a security hole that v1.5.0 / v1.4.2 R-2
  left ambiguous, and an audit harness following v1.5.1 verbatim would
  miss a real exploit class.
- **MEDIUM**: ambiguity that allows two reasonable implementations to
  diverge in security-relevant ways.
- **LOW / NIT**: hardening suggestions, additional cross-references.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Return a structured findings list with severity, file:line, evidence,
and recommended fix.
