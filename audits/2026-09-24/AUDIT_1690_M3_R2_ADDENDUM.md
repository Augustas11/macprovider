# #1690 M3 SPEC audit: round 2 addendum

**Scope change for round 2.** Audit the FULL combined M3 diff `git diff f244f9c1 400e9050 -- specs beta docs` (ignore `audits/`), not only the round-1 fix commit. The common brief still applies.

**Also check:**
- that each round-1 finding in `audits/2026-09-24/AUDIT_1690_M3_R1_FINDINGS_*.md` is actually resolved as claimed in `AUDIT_1690_M3_R1_RESOLUTION.md`;
- that the fixes introduced no new contradiction. The main new design is in SPEC-042-R004: the coordinator-derived runtime class from the hash-verified member format, a mismatch dropping the session from every pool, `pool_runtime_authorization` binding request_id/attempt/provider/route_snapshot_digest, digested `pool_generation` / `pool_operator_account_id`, and zero billable on a disputed external-runtime label.

Report only real defects at their true severity; do not re-report resolved items.
