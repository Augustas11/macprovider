You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane, ROUND 7.

R6 returned 1 HIGH on the encrypted-frame paths. R7 fix (same as code
lane prompt):

In `phase4-coordinator/internal/ws/relay.go`:
- `handleInferenceChunk` + `handleInferenceEnd` each get a
  `containsControlChar(envelope.RequestID)` reject AT THE TOP of the
  function, before any session/log/tier2-helper call.
- The encrypted branch in each function gets a SECOND
  `containsControlChar(requestID)` reject AFTER `DecodeAEADAAD` decodes
  the AAD, before `session.activeFor(...)` and before any log statement
  using the decoded id.

## Verify

- The two-layer guard (envelope + AAD) closes the R6 class fully.
  Trace every path:
  - Unencrypted plaintext: post-parse guard at `chunk.RequestID` /
    `end.RequestID` (R5).
  - Encrypted + session-known: top-of-function guard catches it.
  - Encrypted + AAD decode succeeds + session-unknown: AAD guard
    catches it.
  - Encrypted + AAD decode fails: top-of-function guard on
    envelope.RequestID protects the AAD-failure log.
  - Encrypted-required but unencrypted frame: top-of-function guard
    catches it before tier2.LogAEADDecryptFailed.
- Are there ANY other call sites of tier2 log helpers
  (LogAEADDecryptFailed, LogEncryptedLegSessionClosed) where a
  provider-controlled request_id reaches them without the guard?
  Sweep the entire repo, not just `relay.go`.
- Any other provider-controlled string that lands in close-frame
  reason strings sent to the buyer or other providers?
- Operational binding scope still holds — money-path unaffected.

## Severity rubric

- **CRITICAL**: real exploit class still reachable.
- **HIGH**: R6 finding not closed; or new exploit class.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
