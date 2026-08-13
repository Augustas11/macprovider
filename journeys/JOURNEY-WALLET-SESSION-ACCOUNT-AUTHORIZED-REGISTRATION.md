# JOURNEY-WALLET-SESSION-ACCOUNT-AUTHORIZED-REGISTRATION

Mapped SPECs: SPEC-040
Mapped authority domains: wallet-buyer-session
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves that wallet-session creation is authorized by an existing
gateway account before a wallet can spend that account's quota. Local automated
evidence is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, gateway configuration, wallet-session enabled posture, and
  isolated database identity.
- Authenticated `mp_` account principal used for challenge creation.
- Challenge fields bound to account, wallet fingerprint, caps, expiry, model
  allowlist, audience, nonce hash, and session public key.
- Successful Ed25519 proof registration and single returned `mps_` bearer
  redacted to a stable hash.
- Rejections for wallet-only registration, mismatched body account id,
  inactive account, expired challenge, consumed challenge, unsupported
  algorithm, invalid signature, invalid caps/expiry/allowlist, duplicate JSON
  fields, and non-canonical base64url.
- Parallel redemption attempt proving exactly one session is created.
- Parallel unique-challenge redemption at the account and wallet active-session
  caps proving the cap is not exceeded.
- Bearer hash key id, wallet fingerprint key version, no-store/Vary response
  headers, and redacted audit/log samples proving no raw bearer, raw public
  key, signature, prompt, or output leaks.
