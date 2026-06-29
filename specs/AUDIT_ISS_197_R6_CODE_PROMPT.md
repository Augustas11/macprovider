You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), CODE lane, ROUND 6.

R5 returned 1 MEDIUM (other provider-frame parsers bypass control-char
check). R6 fixes:

1. Extracted `containsControlChar(s string) bool` in
   `phase4-coordinator/internal/ws/messages.go`. Applied at:
   - `ParseHello`: `model_hash`, `endpoint_url` (also from `parseAuthInitial`).
   - `parseAuthInitial`: `model_hash`, `endpoint_url`.
   - `ParseStateUpdate`: `reason`, `since`.
   - `ParseHeartbeat`: `model_hash`.
   - `ParsePreflightAck`: `request_id`.
   - `ParseNak`: `in_reply_to`, `error.code`, `error.message`.
   - `handleInferenceChunk` / `handleInferenceEnd` in `relay.go`:
     `chunk.RequestID` / `end.RequestID` reject before structured log.
   - `server.go::handleMessage` unknown-envelope-type log site:
     redact to `"[redacted_control_chars]"` if control chars present.

## Verify

- Are there any remaining provider-controlled strings that reach
  structured logs without the control-char check? Particularly:
  - `ParseDrainStatus` — its `reason` field.
  - tier2 / receipts JSON.
  - admission / auth log paths.
- Does the inference chunk/end fix break any legitimate flow? The
  request_id is internally minted as a UUID in non-malicious flow,
  so rejecting C1/CSI should be safe.
- Full suite still green?

## Severity rubric

- **CRITICAL**: regression.
- **HIGH**: R5 finding still open.
- **MEDIUM**: SPEC↔impl divergence; missed MUST.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
