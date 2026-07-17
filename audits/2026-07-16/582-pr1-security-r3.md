# AUDIT ROUND 3 — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-2 findings are now FIXED across commits on branch `fix/582-onboarding-onramp`.
Audit the FULL branch vs `origin/main` (git diff origin/main...HEAD; full diff at
audits/2026-07-16/582-pr1-r3.diff), worktree /Users/augstar/macprovider-582-onboarding.
Tasks: (a) VERIFY the round-2 fixes below are correct/complete, (b) find NEW defects.

## Round-2 fixes to verify
- FOR SHARE removed from job-table reads (definer has only column SELECT); job reads are
  plain SELECT; convergence via advisory lock + idempotent ON CONFLICT insert + verifier.
  (FOR UPDATE on hardware_trust_pending remains — definer OWNS that table, which is correct.)
- applyTrustDemotions demotes all verified profiles with source <> 'operator' lacking active
  trust (covers cli_hello + app_register); runs UNCONDITIONALLY every sync (empty YAML revokes
  last inventory root).
- request_hardware_trust_approval RAISEs unless job.decision_reason='missing_trusted_hardware_identity'.
- stale-pending auto-cancel spans (provider,hardware_identity_hash)+(provider,incident_id)+job_id,
  and a 7-day deadline cancels abandoned no-expiry pendings; open-uniqueness index predicate
  committed_at IS NULL AND cancelled_at IS NULL.
- down.sql DELETEs operator_api roots before dropping source column; revokes only chip (keeps 015 decision_reason).
- HTTP error map: validation 400/422, conflict 409 (incl 23505 unique_violation), operational
  SQLSTATE (08/53/57/40001)+store-unavailable 503, unexpected 500; waiting-list uses same mapper.
- applyTrustInventory logs when operator_api precedence suppresses a conflicting YAML entry.
- deploy: hardware_trust DSN require_env_value + preflights in dist/deploy-pearl-vps.sh; new
  dist/hardware-trust-roles-bootstrap.sql; dist/test/check_stats_inventory_deploy_test.sh assertions.
- smoke verifies approver EXECUTE on revoke; provider_onboarding trust-table SELECT grant REMOVED.

## Preserved invariant (must still hold)
provider_onboarding: NO write on hardware_verification_trust/_pending/_grants, NO EXECUTE on
definer fns, and now NO SELECT on the trust table. All trust writes via definer SECURITY DEFINER fns.

## Known carried residual (do NOT re-report as new)
Verifier batch-ordering fairness (internal/stats/hardwareverify/verify.go) is pre-existing
(verify.go unchanged by this branch) and not worsened; tracked separately. NOTE(#582) comment
is on the approve handler.

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
Most-severe first. If a round-2 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
