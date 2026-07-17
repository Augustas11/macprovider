# AUDIT ROUND 4 — #582 PR1 hardware-trust operator approval — security lane

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
Most-severe first. If a round-3 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
