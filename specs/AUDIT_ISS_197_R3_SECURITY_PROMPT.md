You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane, ROUND 3.

R2 returned 2 MEDIUM. R3 fixes:

1. (R2 MEDIUM #1) Other persisted text fields (`error`, `pref_header`,
   `provider_header`, `model`) used the weaker `sanitizeRequestLogText`
   which stripped C0/DEL via rune iteration but missed raw C1 bytes
   (decoded as `utf8.RuneError`) and didn't validate UTF-8. R3
   strengthened `sanitizeRequestLogText`:
   - reject invalid UTF-8 outright (return "");
   - after the UTF-8 gate, strip C0/DEL/C1 codepoints (0x00-0x1f,
     0x7f, 0x80-0x9f) via the existing rune map. The UTF-8 gate makes
     rune iteration safe for the strip step — raw C1 bytes can't
     survive as `utf8.RuneError` because the input was rejected first.
   The strip-vs-reject distinction is intentional: opaque headers
   (X-Request-ID, X-MacProvider-Account) reject the whole value;
   multi-character text fields (error messages, model names) strip
   the bad codepoints and keep the rest.

2. (R2 MEDIUM #2) The "MUST fail closed on `unindexed`" scope was
   ambiguous. R3 sharpened it to **out-of-process reconciliation
   tooling only** — not coordinator's in-process `RecoverLedger` /
   admin reconcile / hot-path AttemptN, which use SQLite `IS`
   clustering and are correct under unindexed. SPEC-005 v0.3.2
   pins the dependency.

## Verify

- Does the strengthened `sanitizeRequestLogText` actually close the
  C1 bypass for `error` / `pref_header` / `provider_header` / `model`?
  Try:
  - `error` containing raw `0x9b` — should be rejected at UTF-8 gate.
  - `model` JSON value `""` (which is valid UTF-8 for U+009B)
    — does the rune-map strip catch this?
  - `pref_header` / `provider_header` with raw C1 bytes from the HTTP
    request — does the call path persist them via
    `sanitizeRequestLogText` or some other untreated path?
- Are there any OTHER buyer-controlled text fields that land in
  `request_log` or structured logs without going through
  `sanitizeOpaqueHeader` or `sanitizeRequestLogText`? Look for
  prompt/message content if it lands in logs, finish_reason,
  provider id, model name from the upstream response, etc.
- The new SPEC scope clarification — does it preserve safety? An
  attacker can no longer force-close in-process recovery via raw
  control bytes (those are pre-sanitized) but a state-`unindexed`
  daemon still serves traffic. Is there ANY in-process money-path
  computation that would silently produce wrong credits under
  state `unindexed`? (I think no — the IS-clustering only affects
  AttemptN derivation, which doesn't depend on the partial-NULL
  composite index for correctness — but verify.)
- `OpenStoreReadOnly` uses `PRAGMA query_only=ON`. Is there any
  escape from query_only (e.g. via attach, savepoint, vacuum)? In
  particular, does any `sqliteutil.WithPragmas` setting bypass it?

## Severity rubric

- **CRITICAL**: new bypass introduced by R3 OR an R2 finding still
  open.
- **HIGH**: real exploit class still reachable through a path R3
  didn't address.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
