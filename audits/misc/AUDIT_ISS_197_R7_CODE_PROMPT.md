You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane, ROUND 7.

R6 returned 1 HIGH (encrypted-frame `envelope.RequestID` / `aad.RequestID`
were logged in `handleInferenceChunk` / `handleInferenceEnd` BEFORE the
post-parse `containsControlChar` check fired, via tier2 log helpers and
direct structured log calls). R7 fix:

In `phase4-coordinator/internal/ws/relay.go`:
- `handleInferenceChunk`: added `containsControlChar(envelope.RequestID)`
  reject at the TOP of the function, immediately after the
  `json.Unmarshal` returns successfully and before any other log call.
- `handleInferenceChunk` encrypted-branch: added a SECOND
  `containsControlChar(requestID)` reject AFTER `DecodeAEADAAD` returns
  but BEFORE `session.activeFor(requestID)` / any log statement using
  the AAD-decoded id.
- `handleInferenceEnd`: same TWO guards (top-of-function on envelope,
  post-AAD on requestID).

The plaintext-branch post-parse `containsControlChar(chunk.RequestID)` /
`containsControlChar(end.RequestID)` guards from R5 remain in place.

## Verify

- Are the new top-of-function guards in the correct position — BEFORE
  `s.sessionFor(...)` and BEFORE any tier2.Log* helper invocation?
- The AAD-decoded `requestID` (after `DecodeAEADAAD`) — is the guard
  positioned before BOTH `s.closeProviderForTier2AEADFailure` AND
  `session.activeFor(requestID)`?
- Could a provider craft a payload that triggers the
  `closeProviderForTier2AEADFailure` log path BEFORE either guard
  (e.g. by failing `DecodeAEADAAD` but leaving `envelope.RequestID`
  with control chars)? Trace each branch.
- Are there OTHER tier2 log helpers (`LogAEADDecryptFailed`,
  `LogEncryptedLegSessionClosed`, etc.) called from elsewhere in
  the codebase with provider-controlled request_id values that
  bypass the new guards?
- Full coordinator test suite still green?

## Severity rubric

- **CRITICAL**: regression OR new bypass introduced.
- **HIGH**: R6 finding still open in the encrypted-frame paths.
- **MEDIUM**: SPEC↔impl divergence; missed MUST.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
