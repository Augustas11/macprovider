# JOURNEY-WALLET-SESSION-CONCURRENT-CAP-ENFORCEMENT

Mapped SPECs: SPEC-040
Mapped authority domains: wallet-buyer-session, billing-settlement-formula
Issue: https://github.com/Augustas11/macprovider/issues/930
Status: local automated evidence captured; production evidence pending

## Purpose

This journey proves that wallet-session total caps cannot be overspent by
parallel requests. Local automated evidence is captured in
`journeys/evidence/JOURNEY-WALLET-SESSION-LOCAL-VALIDATION-2026-08-13.md`.

## Required capture

- Candidate commit, database identity, session cap, per-request cap, and
  concurrency setup.
- Parallel signed inference attempts whose combined reservation demand exceeds
  the session cap.
- Durable rows showing atomic replay/account-reservation/session-reservation
  admission for accepted requests and no reservation rows for rejected ones.
- Final settled plus pending reservation totals proving the cap was never
  exceeded.
- Rejection codes for cap exhaustion and duplicate/replay conflicts.
