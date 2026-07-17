# AUDIT ROUND 5 — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-4 findings FIXED. Audit the FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r5.diff), worktree /Users/augstar/macprovider-582-onboarding.
Tasks: verify the round-4 fixes below, and report any REMAINING C/H/M. Loop is converging —
only report defects with a concrete failure scenario; do not invent speculative issues.

## Round-4 fixes to verify
- RETURNS TABLE output columns renamed out_* (fixes SQLSTATE 42702 ambiguous provider_id);
  approve INTO now qualified hardware_trust_pending.provider_id.
- verify.go promoteJob re-checks the backing hardware_verification_trust root is active
  (expires_at IS NULL OR > now()) in-tx before promotion; re-parks as waiting_trust
  (missing_trusted_hardware_identity) if not. Batch ORDER BY/LIMIT/SKIP LOCKED UNCHANGED
  (carried residual). Closes revoke/demote/inventory-delete vs promotion races.
- YAML: nested KnownFields(true) strict decode (typo like expires_att errors); bare null
  trusted_hardware rejected (revoke-all requires explicit {}); omitted = no-op; {} = revoke-all.
- down.sql: \set ON_ERROR_STOP on + BEGIN/COMMIT; demotes operator_api-backed verified
  profiles before DELETE/DROP; IF EXISTS guards -> atomic + re-runnable.
- demotion runs on independent context budget (context.WithTimeout(WithoutCancel(parent),...)).
- request/approve re-sample clock_timestamp() AFTER lock waits for requested_until/7-day/expiry.
- error map: connectivity/context (DeadlineExceeded/Canceled/ErrConnDone/ErrBadConn/net.Error)
  -> 503; all other unknown -> 500 hardware_trust_internal_error. 23505 -> 409.
- deploy fails closed (exit 12) when hardware-trust DSNs set but stats-hardware-verifier.env absent.

## Preserved invariant (must still hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns, NO SELECT on
trust table. Definer UPDATE grants are column-scoped (status/verified) for locking/demotion only.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (verify.go ORDER BY id LIMIT ... SKIP LOCKED) — pre-existing,
unchanged by this branch, tracked separately.

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
Most-severe first. If a round-4 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
