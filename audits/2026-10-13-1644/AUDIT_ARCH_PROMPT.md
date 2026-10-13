Lane: ARCHITECTURE REVIEW. Read audits/2026-10-13-1644/AUDIT_COMMON.md first and follow it.

Focus:
- Is the §5A design coherent with the rest of SPEC-036 (FR-1..FR-18 stay
  intact) and SPEC-022 (R-7, R-15 retention, payout revalidation)?
- Package boundaries (ws cannot import buyer; computeintegrity shared types),
  wiring in cmd/coordinator, failure isolation (scoring failures must not block
  serving), kill switch semantics, defaults (ships on, no expiry dates).
- Statistical design: cold prior, learned band, greedy-only escalation while the
  sampled band is cold, failure confirmation by two scorer operators, recovery
  and hold semantics. Will honest cross-chip providers be failed? Will a
  substituted model be caught?
- Scalability to thousands of providers and hundreds of models: per-sweep cost,
  operator-key lookups, DB/rollup trigger cost, memory of windows and known
  sequences.
- SPEC text vs code drift (every MUST implemented, nothing implemented that the
  SPEC forbids), CONFORMANCE mappings accurate.
