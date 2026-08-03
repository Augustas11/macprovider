# Audit: ISS-165 R4 security lens — verify R3 fixes

R3 returned 0/1/1/0 (sec). R4 verifies on `a8574cd`.

## R3 sec findings to verify

- **HIGH**: unbounded materialization. Fix: keyset chunking
  (256/chunk) + 20000 scan ceiling + PAGE on ceiling.
- **MEDIUM**: SPKI drain WARN missing §7.1 + §9 + severity/ts_utc.
  Fix: all four added.

## What I want (security lens)

- Adversarial inflation: can an attacker (operator-key compromise
  or data-path bug) make `total_scanned` > 20000 PER CYCLE in a
  way that masks money loss? At chunk size 256 + ceiling 20000,
  that's 78 chunks per cycle in the worst case — each chunk hits
  the DB. Query plan + index coverage adequate?
- Cursor injection: SQLite + mattn/go-sqlite3 — could a malicious
  `payout_id` or `attempt_seq` (e.g. negative, very large) break
  the cursor advance and cause skip-class denial of detection?
- Backlog ceiling-hit PAGE: is the operator-actionable signal
  sufficient, or does it need a separate event name? (The
  R3 fix shares the event with WARN-mode backlog and just
  changes the severity field.)
- Future-proof: `payout_spki_drain_skipped_unsupported_client`
  exists in code AND SPEC §7.1 AND §9 alert filter AND runbook §3.
  Is there a build-time/CI verification that all four stay in
  sync, or is drift still possible?

Find security defects. Severity + Convergence line.
