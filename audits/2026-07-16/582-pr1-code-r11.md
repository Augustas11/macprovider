# AUDIT ROUND 11 (closing) — #582 PR1 hardware-trust operator approval — code lane

Rounds 1-10 findings FIXED. Round 10 was 0 CRITICAL; SECURITY lane PASSED 0/0/0 (frozen).
The code lane had a HIGH at round 10 (inventory ride-along race). Audit FULL branch vs
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
1. SQL correctness: the `request_/approve_hardware_trust_approval` plpgsql functions —
   transaction/locking correctness, ON CONFLICT targets, NULL handling of
   `requested_until`/`expires_at`, the partial-unique indexes (do they actually
   prevent duplicate open approvals and race double-inserts?), GET DIAGNOSTICS /
   ROW_COUNT logic, and whether the `.down.sql` cleanly reverses `.up.sql`.
2. The `stats-inventory-sync` DELETE-scoping change: does `source='inventory'` on
   the DELETE plus `source` in the upsert column list actually preserve operator_api
   rows AND still delete removed inventory rows? Any way an inventory row gets
   stranded or an operator_api row wrongly deleted?
3. Go: error handling, nil-guards on the new DB handles, resource cleanup (rows.Close,
   Close() on the new handles), context propagation, the new `ws`→`onboarding` import
   (confirm acyclic), JSON decode/validation in the handlers.
4. `ListWaitingTrustJobs` query correctness (the `#>> '{hardware,hardware_identity_hash}'`
   extraction, status filter, column grants sufficient).
5. Migration test/shape-assertion correctness and the `want`-list entry.
6. Any concurrency bug between request→approve and the verifier promoting the job.

## Output
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences (scenario + fix).
Most-severe first. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
