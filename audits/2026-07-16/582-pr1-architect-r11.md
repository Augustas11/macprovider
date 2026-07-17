# AUDIT ROUND 11 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-10 findings FIXED. Round 10 was 0 CRITICAL; SECURITY lane PASSED 0/0/0 (frozen).
The architect lane had a HIGH at round 10 (inventory ride-along race). Audit FULL branch vs
origin/main (git diff origin/main...HEAD; diff at audits/2026-07-16/582-pr1-r11.diff), worktree
/Users/augstar/macprovider-582-onboarding. Verify the round-10 fix below; report any REMAINING
C/H/M. Only defects with a concrete failure scenario.

## Round-10 HIGH fix to verify (terminal structural change)
- hardware_verification_trust PRIMARY KEY changed to (provider_id, hardware_identity_hash, source),
  so operator-approval and inventory-sync own INDEPENDENT rows — no shared-row conflict.
- approve_hardware_trust_approval: ride-along REMOVED; it now UNCONDITIONALLY upserts the
  source='operator_api' row via ON CONFLICT (provider_id, hardware_identity_hash, source) DO UPDATE.
  Never reads/rides/clobbers an inventory row -> no race with stats-inventory-sync, no false-success.
  out_source always 'operator_api'. ALL job-side gates preserved (status/decision_reason/chip-profile/
  generated_at+benchmark staleness/runway/dual-control/7-day/advisory-lock/clock_timestamp).
- revoke targets the operator_api row; its in-tx demotion is source-agnostic (only demotes if NO
  active row of ANY source remains — an inventory root keeps the provider trusted after operator revoke).
- stats-inventory-sync applyTrustInventory ON CONFLICT -> 3-col; DELETE stays scoped source='inventory';
  removed the now-impossible operator_api-precedence-suppression warning.
- All trust-match predicates (verifier promote re-check + batch trust_matched, LatestVerified,
  ProvidersWithoutActiveTrust/ProviderTrustActiveLocked shared predicate, applyTrustDemotions) match
  'EXISTS any active row for the tuple' — NONE filter by source (audited). down.sql deletes operator_api
  rows then restores the 2-col PK, transactional.

## Preserved invariant (must hold)
provider_onboarding: read-only on trust; NO write/EXECUTE. Definer write grants column-scoped.
Verifier batch-ordering SELECT unchanged (carried residual).

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged. Live-PG smoke of
the SECURITY DEFINER request/approve/revoke round-trip is required out-of-band (no in-repo PG harness).

## Focus
1. **Dual authoritative source coherence:** inventory (YAML) and operator_api now both
   write `hardware_verification_trust`. What happens on conflict — same
   (provider_id, hardware_identity_hash) approved via API, then a DIFFERENT tuple
   appears in the YAML, or vice versa? Does the ON CONFLICT DO UPDATE let one source
   silently overwrite the other's `source` tag / expiry? Is there a defined precedence?
   Could a YAML sync flip an operator_api row back to inventory (losing durability) or
   an operator approval clobber an inventory row?
2. **Operational completeness:** the PR flags but does NOT add deploy preflight for the
   new roles/DSNs (`dist/deploy-pearl-vps.sh`, `dist/test/check_stats_inventory_deploy_test.sh`).
   Is anything missing that would cause a silent half-configured deploy (coordinator
   starts, endpoints 503, operators think approval works but it doesn't)? Is the
   nil-store 503 path clear and observable?
3. **Contract consistency:** do the new endpoints follow the same auth, error-envelope,
   and route-registration conventions as sibling admin endpoints? Is
   `GET /admin/hardware-trust/waiting` paginated/bounded (could it return unbounded rows)?
4. **Migration forward/back safety:** is 018 idempotent + re-runnable (matches the
   repo's idempotent-migration invariant)? Does adding the `source` column with a
   DEFAULT lock the table problematically at Pearl scale?
5. **Does this actually close the deadlock end-to-end?** Trace: operator calls approve →
   trust row written → verifier timer promotes job → autotune hello gate passes. Any
   gap where the approval still doesn't unblock admission (e.g. verifier only runs on a
   timer with latency, or the job needs a re-submit)?
6. **Scope creep / missing coverage:** anything half-done that should be in this PR vs
   correctly deferred to PR2 (CLI) / PR3 (Malibu)?

## Output
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences (scenario + fix).
Most-severe first. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
