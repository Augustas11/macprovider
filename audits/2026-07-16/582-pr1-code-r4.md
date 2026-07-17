# AUDIT ROUND 4 — #582 PR1 hardware-trust operator approval — code lane

Rounds 1-3 findings are FIXED across commits on branch `fix/582-onboarding-onramp`.
Audit the FULL branch vs `origin/main` (git diff origin/main...HEAD; full diff at
audits/2026-07-16/582-pr1-r4.diff), worktree /Users/augstar/macprovider-582-onboarding.
Tasks: (a) VERIFY the round-3 fixes below, (b) find any REMAINING C/H/M defect. The loop
is converging; be rigorous but do not invent speculative issues — only report defects you
can tie to a concrete failure scenario.

## Round-3 fixes to verify
- FOR SHARE restored on both job reads; definer has lock-only GRANT UPDATE(status) on
  hardware_verification_jobs (functions never UPDATE jobs) — serializes with verifier
  FOR UPDATE SKIP LOCKED. Also GRANT UPDATE(verified) on provider_hardware_profiles for revoke demotion.
- omitted trusted_hardware (nil) = no-op preserve; explicit '{}' = revoke-all. Presence-detecting
  UnmarshalYAML. Example + validation text updated.
- applyTrustDemotions: lock candidates FOR UPDATE (statement 1) then re-check fresh snapshot
  (statement 2) so it can't re-demote a just-promoted profile; demotions ALWAYS run even if
  applyTrustInventory errored (errors.Join).
- revoke_hardware_trust_approval atomically demotes the matching non-operator verified profile
  (hash-precise) in the same txn after expiring the root.
- single advisory-lock-first order in request + approve (deadlock removed).
- approve RAISEs hardware_trust_pending_expired (->410) when created_at < now()-7d; approve
  re-asserts decision_reason='missing_trusted_hardware_identity'.
- error map: only SQLSTATE P0001 classified by text; operational 08/53/57/40001 + store-unavailable
  ->503; 23505->409; unexpected/non-pq ->500. DSN parse errors redacted. Waiting-list adds
  per-row 'approvable' boolean.

## Preserved invariant (must still hold)
provider_onboarding: NO write on hardware_verification_trust/_pending/_grants, NO EXECUTE on
definer fns, NO SELECT on trust table. Definer's UPDATE grants are column-scoped (status/verified)
and used ONLY for row-locking/demotion inside the SECURITY DEFINER functions.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (verify.go, unchanged by this branch) — pre-existing, tracked separately.

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
Most-severe first. If a round-3 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
