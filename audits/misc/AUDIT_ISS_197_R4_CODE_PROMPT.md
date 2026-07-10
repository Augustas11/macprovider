You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane, ROUND 4.

R3 returned 1 CRITICAL + 1 LOW. R4 fixes:

1. (R3 CRITICAL convergent with security) `request_log.model` was
   stored unsanitized. R4 wraps `b.model` with `sanitizeRequestLogText`
   in [phase4-coordinator/internal/buyer/billing_recorder.go:159] and
   adds regression test
   `TestRequestLogModelFieldSanitized` (sends JSON model containing
   valid UTF-8 for U+009B; asserts no C1 codepoint survives in
   request_log.model).

   Also (R3 security HIGH) `/v1/pool/check?provider_id=` was logged
   unsanitized. R4 sanitizes via `sanitizeRequestLogText`
   in `handlePoolCheck`.

2. (R3 LOW) `OpenStoreReadOnly` previously called `sqliteutil.WithPragmas`
   which sets `journal_mode(WAL)` — that's a metadata write on a fresh
   read-only open. R4 added `sqliteutil.ReadOnlyDSN` that opens with
   `mode=ro` and `_pragma=query_only(true)` only (no WAL/synchronous
   pragmas, no PRAGMA execs after open). `OpenStoreReadOnly` routes
   through it.

## Verify

- `sanitizeRequestLogText(b.model)` — does the sanitizer correctly
  strip C0/DEL/C1 codepoints from valid UTF-8 model strings? Are
  there any callers of `b.model` further down the path that still
  see the unsanitized version? (b.model is set once at recorder
  construction; verify that's the only mutation point.)
- The new `TestRequestLogModelFieldSanitized` skips assertion when
  no rows land. Is that the right behavior — should we instead
  require a 4xx response with NO row written? Audit whether C1 in
  model lands a request_log row in the current code path.
- `ReadOnlyDSN` — does `mode=ro` actually prevent the journal-mode
  metadata write? Confirm by running `--check` against a freshly-
  created legacy DB and checking that the WAL/SHM files are NOT
  created.
- Any other buyer-controlled text that lands in `request_log` /
  structured logs unsanitized? (Look beyond `provider_id` in
  `handlePoolCheck` for the wider class.)
- Full suite still green?

## Severity rubric

- **CRITICAL**: sanitizer bypass remains; or new regression.
- **HIGH**: an R3 finding still open.
- **MEDIUM**: SPEC↔impl divergence; missed MUST.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
