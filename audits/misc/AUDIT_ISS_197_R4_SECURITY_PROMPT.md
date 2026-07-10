You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane, ROUND 4.

R3 returned 1 CRITICAL + 1 HIGH. R4 fixes:

1. (R3 CRITICAL) `request_log.model` is now sanitized via
   `sanitizeRequestLogText(b.model)` in
   `phase4-coordinator/internal/buyer/billing_recorder.go:159`.
   Regression test `TestRequestLogModelFieldSanitized` pins it.

2. (R3 HIGH) `/v1/pool/check?provider_id=` query value now passes
   through `sanitizeRequestLogText` before any structured log call
   in `phase4-coordinator/internal/buyer/server.go::handlePoolCheck`.

## Verify

- The model-field fix actually defeats valid-UTF-8 C1 (0xc2 0x9b)
  injection through `"model":"..."` paths.
- The provider_id fix — does any OTHER structured-log call along
  `/v1/pool/check`'s path still see the pre-sanitize value? Are
  there middleware loggers or access loggers that capture raw
  query strings?
- Are there OTHER buyer-controlled text fields that land in
  structured logs unsanitized? Specifically:
  - The 404 / unknown-model log line on the buyer path.
  - The Authorization bearer log lines (these should NEVER log raw
    bearer values, but if any C1-bearing buyer-supplied path leaks
    in...).
  - Provider-side: provider's `hello.provider_id`, `error.message`
    from upstream WS, `assigned_id`. These come from the provider
    side, not the buyer, but C1 from a malicious provider also
    qualifies.
- Defense-in-depth question: does the v1.5.1 SPEC text adequately
  describe the entire buyer→log surface as covered, or does the
  prose still imply only the two header fields are the concern?
- The state `unindexed` scope clarification (data-surface contract
  vs process placement) — does it now leave any path where an
  in-process money-path computation could silently produce wrong
  credits under state `unindexed`? Audit hot/recovery/admin
  reconcile one more time.

## Severity rubric

- **CRITICAL**: real sanitizer bypass or money-path bug remains.
- **HIGH**: a previously-flagged finding still open, OR a new
  exploit class introduced by R4.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
