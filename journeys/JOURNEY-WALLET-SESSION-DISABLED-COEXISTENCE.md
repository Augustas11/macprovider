# JOURNEY-WALLET-SESSION-DISABLED-COEXISTENCE

Mapped SPECs: SPEC-040, SPEC-006
Mapped authority domains: wallet-buyer-session, buyer-api-error-contract
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves disabled wallet-session runtime behavior preserves existing
API-key, demo, quota, and settlement behavior while allowing additive schema
migrations. Local automated evidence is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, fresh database startup, upgraded database startup, and
  wallet-session enabled/disabled configuration snapshots.
- Idempotent schema migration evidence showing additive wallet tables are safe
  while disabled.
- Proof disabled mode mounts no wallet-session routes, does not require
  wallet-session secrets, and never accepts `mps_` session bearers.
- API-key, demo, `/v1/models`, inference, quota reservation, settlement, and
  existing auth smoke evidence before and after disabled startup.
- Disable-after-use evidence showing existing sessions are not accepted while
  disabled and API-key behavior remains unchanged.
- Old-binary rollback evidence showing fail-closed startup against the
  post-migration database, successful startup after restoring the pre-deploy
  database snapshot when zero post-snapshot rows exist, and maintenance/drain
  plus full post-snapshot gateway-effect reconciliation before old-binary
  service when traffic occurred after the snapshot.
