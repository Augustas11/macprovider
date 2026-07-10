# Audit: ISS-231 R4 security lens — verify R3 closures

R3 sec returned 0/0/1/0. R4 verifies on `98309b5`.

## R3 sec finding to verify

- **MEDIUM**: ambiguity probe full-scanned quota_reservations +
  concurrency_reservations branches. Fix: added partial indexes,
  bumped schema version.

Expect 0/0/0/N. Verify:

- EXPLAIN QUERY PLAN reports SEARCH USING INDEX on both branches
  AND on the other three (usage_events, feedback_events,
  audit_events).
- No remaining unbounded scan in the request path.
- Forensic SELECT also benefits from the new indexes (uses the
  same query shape).

End with `## Convergence X/X/X/X → DECISION`.
