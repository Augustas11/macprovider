# AUDIT ROUND 8 (closing) — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-7 findings FIXED. Audit FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r8.diff), worktree /Users/augstar/macprovider-582-onboarding.
Round 7 was 0 CRITICAL / 1 HIGH (session eviction) / a few MEDIUM, no regressions. Verify the
round-7 fixes below and report any REMAINING C/H/M. Only defects with a concrete failure scenario.

## Round-7 fixes to verify
- revoke handler now evicts the provider's ACTIVE ws session via the existing drain->MarkState->
  close path (disconnectProviderForTrustRevocation, mirrors handleAdminReject) after the DB revoke
  commits; best-effort no-op if not connected. Combined with the LatestVerified trust join, a
  revoked provider is evicted and cannot be re-admitted.
- approve rides an inventory root only if expires_at is NULL or > approval_time + 5min; else
  upserts operator_api. Rechecks chip_hardware_profiles EXISTS (409 hardware_trust_chip_profile_missing).
  Validates oldest evidence.benchmarks[].generated_at against the 7d-minus-5min runway (409).
- approve RETURNS out_source + out_effective_expires_at; handler returns effective source/expiry
  (+ operator_revocable flag) so a client revoke targets the right authority.
- deploy preflight asserts the full verifier write-column set (jobs: status/processed_at/
  decision_reason; profiles: the insert+update column set from migration 008) via has_column_privilege.
- startup smoke + deploy preflight now run the LatestVerified trust-join shape so a missing
  provider_onboarding SELECT-on-trust grant fails deploy.

## Preserved invariant (must hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns (SELECT on trust
table intentionally granted for the admission join). Definer write grants column-scoped only.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged.

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
Most-severe first. If a round-7 fix is incomplete/wrong or introduced a regression, report it.
If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
