# AUDIT ROUND 2 — #582 PR1 hardware-trust operator approval — architect lane

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
Most-severe first. If a round-1 fix is INCOMPLETE or WRONG, report it as a finding at the
appropriate severity. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
