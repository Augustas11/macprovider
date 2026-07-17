# AUDIT ROUND 2 — #582 PR1 hardware-trust operator approval — code lane

Round 1 found defects which have now been FIXED across two commits on branch
`fix/582-onboarding-onramp`. Audit the FULL branch vs `origin/main`
(git diff origin/main...HEAD; full diff at audits/2026-07-16/582-pr1-r2.diff),
worktree /Users/augstar/macprovider-582-onboarding. Your job: (a) VERIFY the round-1
fixes are correct and complete, and (b) find any NEW defects the fixes introduced.

## Round-1 fixes to verify
- Approval is now job-bound: request/approve take a job_id; SECURITY DEFINER fns
  derive the trust tuple from a status='waiting_trust' hardware_verification_jobs row
  (FOR SHARE lock), re-check job status at approve time (RAISE 'job no longer waiting_trust'),
  and re-derive/compare the tuple. No operator-supplied tuple.
- Trust provenance: stats-inventory-sync ON CONFLICT DO UPDATE scoped to source='inventory'
  (operator_api rows never converted/deleted). DELETE scoped source='inventory'.
- applyTrustDemotions now runs unconditionally every sync.
- Both new DB handles smoke-checked at startup (role-verified); handlers 503 on connectivity.
- Audited revoke path: revoke_hardware_trust_approval + POST /admin/hardware-trust/revoke;
  hardware_trust_grants.action in ('grant','revoke'); expires_at=now() inactivates the root.
- pending.cancelled_at + auto-cancel of stale expired pendings; open-uniqueness index
  predicate committed_at IS NULL AND cancelled_at IS NULL.
- strict JSON decode (DisallowUnknownFields + EOF); ListWaitingTrustJobs bounded (limit + after_id).
- hardware-specific error sentinels; grant provider_onboarding SELECT(chip, decision_reason).

## Preserved invariant (must still hold)
provider_onboarding must have NO write on hardware_verification_trust / _pending / _grants and
NO EXECUTE on the definer functions. All trust writes go through definer-owned SECURITY DEFINER fns.

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
Most-severe first. If a round-1 fix is INCOMPLETE or WRONG, report it as a finding at the
appropriate severity. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
