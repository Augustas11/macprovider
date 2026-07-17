# AUDIT ROUND 2 — #582 PR1 hardware-trust operator approval — security lane

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
1. **Privilege boundary:** Does migration 018 grant `provider_onboarding` (or PUBLIC,
   or any provider-reachable role) ANY write (INSERT/UPDATE/DELETE) on
   `hardware_verification_trust`, `hardware_trust_pending`, `hardware_trust_grants`,
   or EXECUTE on the definer functions? It must not. Verify REVOKEs are complete and
   that the SECURITY DEFINER functions have `SET search_path` pinned (search_path
   injection). Check function OWNER is the NOLOGIN definer, and the definer has no
   LOGIN and no excess grants (e.g. CREATE on schema public should be revoked).
2. **Dual-control integrity:** Can the same operator both request and approve? Is
   `approved_by <> requested_by` enforced in the DB (not just the handler)? Can the
   handler's operator-actor check be bypassed (e.g. empty/`requested_by` mismatch,
   header spoofing)? Is the approver authenticated with the same operator-token
   mechanism as the existing auth-policy endpoints?
3. **Trust-injection abuse:** Can an attacker who reaches the admin endpoints approve
   an ARBITRARY (provider_id, hardware_identity_hash) tuple that was never submitted
   as a `waiting_trust` job — i.e. mint a trust root for hardware that doesn't exist?
   Is the approved tuple constrained to an actual pending/waiting job, or free-form?
   (Design intent: operator approves a real parked job; assess whether free-form
   approval is a risk and whether it's acceptable given operator auth.)
4. **Durability vs. revocation:** operator_api rows now survive `stats-inventory-sync`.
   Is there any way to REVOKE an operator_api trust root once granted (or is it
   permanent with no removal path — a security concern)? Does `applyTrustDemotions`
   still function correctly for operator_api rows?
5. **Secrets/DSN handling:** the two new DSNs — logged anywhere? Exposed in errors?
6. **Audit trail:** are approvals logged with actor identity for forensics?

## Output
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences (scenario + fix).
Most-severe first. If a round-1 fix is INCOMPLETE or WRONG, report it as a finding at the
appropriate severity. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
