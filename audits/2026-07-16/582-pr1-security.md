# AUDIT — #582 PR1 hardware-trust operator approval — SECURITY lane

You are a senior application-security + database-privilege reviewer. Audit ONLY the
change introduced by the HEAD commit on branch `fix/582-onboarding-onramp` in this
worktree (`/Users/augstar/macprovider-582-onboarding`). Full diff also at
`audits/2026-07-16/582-pr1.diff`. Read surrounding code for context; findings must be
about THIS diff.

## Security-critical context
`hardware_verification_trust` is the **trust root of the provider anti-fraud model**:
a matching row lets a provider's submitted hardware evidence be promoted to `verified`
and admitted to serve buyers (money path). The EXISTING deliberate boundary is that
the coordinator's `provider_onboarding` DB role can queue evidence and READ the trust
table but must NOT be able to write it — provider-submitted evidence must never
auto-create a trust root. This PR adds an operator approval path that writes trust
roots via SECURITY DEFINER functions owned by a new NOLOGIN `hardware_trust_definer`
role, with dual-control (requester ≠ approver) HTTP endpoints.

## Focus (SECURITY — verify the boundary is not weakened)
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
List findings as: `SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3
sentences (concrete exploit/failure scenario + fix). Most-severe first. If zero C/H/M,
say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly. Report only real defects.
