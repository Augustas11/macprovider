# JOURNEY-WALLET-SESSION-STATUS-USAGE-IDOR

Mapped SPECs: SPEC-040
Mapped authority domains: wallet-buyer-session
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves wallet-session management APIs expose buyer-safe data only
to the owning account or the matching session itself. Local automated evidence
is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, two isolated accounts, at least two sessions, and redacted
  wallet/session fingerprints.
- Account-owner list/status/usage/revoke success for same-account sessions.
- Signed session self status/usage/revoke success for the matching session.
- Cross-account and cross-session IDOR attempts rejected with safe SPEC-006
  errors.
- Account-key pagination, bounded usage-detail ranges, session self-usage
  summary-only behavior, opaque/type-scoped IDs, read-store use for GET
  handlers, session-filtered `/v1/models` nested disclosure pruning, and
  CORS `Vary` preservation evidence.
- OPTIONS preflight evidence for mounted wallet-session-capable routes showing
  `X-MacProvider-Session-Timestamp` and `X-MacProvider-Session-Signature` are
  allowed request headers.
- Response samples proving no raw bearer, bearer hash, raw prompt, raw output,
  raw wallet key, signature, or unrelated account session is exposed.
