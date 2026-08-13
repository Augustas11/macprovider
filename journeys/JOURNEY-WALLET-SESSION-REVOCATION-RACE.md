# JOURNEY-WALLET-SESSION-REVOCATION-RACE

Mapped SPECs: SPEC-040
Mapped authority domains: wallet-buyer-session
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves revocation and expiry serialize with wallet-session
admission. Local automated evidence is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, session id, expiry, account id, and database identity.
- A request admitted and dispatch-fenced before revocation that may complete
  under existing reservations.
- A revocation transaction racing with still-`claimed` records and new
  admission attempts.
- Proof that after revocation commits, later admission fails before dispatch,
  still-`claimed` records cannot move to `dispatch_armed`, and their
  account/session reservations are refunded or held without coordinator
  dispatch.
- Expiry case proving stale sessions and stale claimed replay records do not
  dispatch.
