You are reviewing branch `spec/iss-197-v1-4-3-clarifications` of the macprovider repo
(working tree `/Users/augstar/macprovider-iss197`), SECURITY lane, ROUND 6.

R5 returned 1 HIGH (provider-controlled WS strings bypass control-char
check beyond the narrow required-hello-string path). R6 fixes:

Shared helper `containsControlChar(s string) bool` extracted in
`phase4-coordinator/internal/ws/messages.go` and applied at every
provider-controlled string that flows to structured logs or close-
frame reason strings:
- Hello: model_hash, endpoint_url.
- AuthRequest (initial): model_hash, endpoint_url.
- StateUpdate: reason, since.
- Heartbeat: model_hash.
- PreflightAck: request_id.
- Nak: in_reply_to, error.code, error.message.
- Inference response chunk/end: request_id (in `relay.go` before the
  unknown-request_id log call).
- Unknown envelope `type`: redacted to a literal sentinel before
  logging in `server.go::handleMessage`.

## Verify

- Are there OTHER provider-controlled values that reach structured
  logs unsanitized? Sweep:
  - `ParseDrainStatus.reason` (logged in handleDrainStatus).
  - Any tier2 receipt fields that the coordinator logs.
  - Any provider HTTP path values reaching access logs (provider
    HTTP is on a different boundary, but verify).
- Are there gateway-side surfaces that also need this hardening?
  (Out of scope for #197 — gateway has its own UUIDv4 minting for
  X-Request-ID per SPEC-006 R-G3 — but flag for follow-up if found.)
- Does any close-frame reason string we send to the provider (or to
  the buyer) include control characters via provider-or-buyer
  controlled values?
- The redact-vs-reject choice on the unknown-envelope path: is
  "redact to sentinel and log" the right discipline, or should we
  reject the whole message earlier (return without any log line)?
- Money-path scope re-verify under state `unindexed`.

## Severity rubric

- **CRITICAL**: real exploit class still reachable.
- **HIGH**: R5 finding not closed; or new exploit class.
- **MEDIUM**: hardening that should land but didn't.
- **LOW / NIT**: defensive suggestions.

Bar for convergence: 0 CRITICAL / 0 HIGH / 0 MEDIUM.
