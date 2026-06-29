You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane, ROUND 2.

R1 returned 1 HIGH: raw C1 bytes bypassed `sanitizeExternalRequestID`
via rune iteration that decoded 0x80-0x9f to `utf8.RuneError`. The fix
in R2:

- `phase4-coordinator/internal/buyer/server.go`: byte-level sanitizer
  `sanitizeOpaqueHeader` rejects invalid UTF-8 and iterates the C0/DEL/C1
  reject set byte-by-byte before any rune decode. Both
  `sanitizeExternalRequestID` and `sanitizeAccountID` route through it.
- Regression tests added for 0x80, 0x9b, 0x9f, invalid UTF-8 leads.

## Verify

- The byte-level loop closes the CSI / terminal-control class fully:
  - 0x9b standalone — rejected?
  - Percent-encoded `%9b` if the buyer/gateway middleware ever decodes
    before passing to the sanitizer — does any layer between transport
    and `sanitizeExternalRequestID` percent-decode?
  - Overlong UTF-8 encoding of C1 (e.g. `0xc2 0x9b`) — this is VALID
    UTF-8 and decodes to U+009B. Is `0xc2 0x9b` byte-level-passed by
    the byte loop (since neither byte alone is in C1 range)? If yes,
    is this acceptable? The C1 codepoint U+009B is what we want to
    reject; overlong UTF-8 encoding of it would slip past byte-wise
    rejection but rune iteration would catch it.
- Does the v1.5.1 SPEC text mandate rejection at both byte-level AND
  codepoint-level, or only byte-level? If only byte-level, the
  overlong-UTF-8 C1 codepoints slip through. Recommend the SPEC
  require BOTH layers.
- Are there other coordinator paths that accept buyer-controlled text
  into structured logs WITHOUT going through `sanitizeOpaqueHeader`?
  Look for: `X-MacProvider-Pref`, `X-MacProvider-Provider`,
  `Authorization` bearer, model name, prompt content.
- State `unindexed` operational binding: does v1.5.1 close the
  silent-fuzzy-match fallback class? Is there a way for an audit
  harness to read the `migration_state` JSON and ignore it?
- The new `coordinator migrate-indexes --check` reads the DB without
  mutating — is there any path where `--check` could be invoked with
  a malicious config file (path traversal, symlink) that escalates?
  The `--config` flag is operator-supplied; reasonable to trust, but
  worth flagging if a privilege boundary changed.
- Cross-reference SPEC-005 v0.3.1 reconciliation contract: does the
  v1.5.1 normative MUST on state `unindexed` propagate to the
  reconciliation tooling in `phase4-coordinator/internal/billing/recovery.go`
  or wherever the schema-check happens?

## Severity rubric

- **CRITICAL**: a remaining bypass in the sanitizer or a new
  vulnerability introduced by the v1.5.1 surface.
- **HIGH**: a HIGH that v1.5.1 claims to close but doesn't (e.g.
  overlong-UTF-8 C1 bypass).
- **MEDIUM**: hardening that v1.5.1 should adopt but didn't (e.g.
  rejecting at both byte and codepoint level).
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.

Return a structured findings list with severity, file:line, evidence,
and recommended fix.
