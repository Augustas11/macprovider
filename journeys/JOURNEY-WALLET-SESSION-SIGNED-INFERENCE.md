# JOURNEY-WALLET-SESSION-SIGNED-INFERENCE

Mapped SPECs: SPEC-040
Mapped authority domains: wallet-buyer-session, buyer-api-error-contract
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves that `mps_` inference, session-filtered model discovery,
and session self-management traffic are authenticated by both the session
bearer and the registered session key. Local automated evidence is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, gateway configuration, account id, session id, and redacted
  bearer/session-key fingerprints.
- Passing signed requests for `/v1/chat/completions`, `/v1/responses`,
  `/v1/messages`, `/v1/models`, self status, self usage, and self revoke,
  each with a client-supplied UUIDv4 request id.
- Exact signed-byte fixture hashes for the request-signature envelope.
- Rejections for missing/generated request id, invalid signature, stale
  timestamp, wrong route, changed raw body, changed `Accept`, changed semantic
  headers, signed session-id mismatch, disallowed model, and per-request cap
  excess.
- Proof that `/v1/models` accepts a valid signed session without budget
  consumption and filters every top-level and nested model/alias/catalog
  disclosure to the session allowlist.
- Proof signed metadata routes reject non-empty bodies and query strings, that
  session self-usage is summary-only, and that metadata rate/replay ceilings
  fail closed with machine-readable backoff for temporal limits and a
  non-retryable replay-capacity error for hard replay ceilings.
- Replay retention evidence showing delayed first-use/replay after pruning is
  rejected unless the replay row is retained for the active session lifetime
  plus settlement recovery window.
