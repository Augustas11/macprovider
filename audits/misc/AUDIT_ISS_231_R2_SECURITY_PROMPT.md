# Audit: ISS-231 R2 security lens — verify R1 fixes

R1 returned 0/1/2/1 (sec). R2 verifies on `0d96a03`.

## R1 sec findings to verify

- **HIGH**: collision-flood DoS via unbounded forensic SELECT.
  Fix: storage helper bounded at
  `ExplorerForensicMatchedAccountIDsCap+1=101` rows; handler caps
  the audit payload at the forensic cap. Both request-path scan
  AND audit row are now bounded.
- **MEDIUM**: hand-rolled JSON not C0-safe. Fix: `json.Marshal` on
  every audit/log payload (gateway + coordinator).
- **LOW**: typed-prefix collision with legacy IDs that literally
  start with `ext_`/`int_`. Documented as edge case (current ID
  shapes don't hit it).

## What I want (R2 security lens)

- Is the new 101-row bound a tight enough security invariant? Can
  an attacker repeat-call 100 distinct request_ids each carrying
  101 colliding account_ids and still inflate operator audit log
  volume?
- `json.Marshal` handles C0/Unicode correctly — confirm.
- Could the deprecation-WARN payload itself be attacker-poisonable
  via request_id substring injection now that we use
  `json.Marshal`? The path-segment IS attacker-influenced (X-
  Request-ID echo).
- Is the v0.5 deprecation window (90-day cutoff filed via #245)
  appropriately bounded?

End with `## Convergence X/X/X/X → DECISION`.
