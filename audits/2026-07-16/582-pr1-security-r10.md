# AUDIT ROUND 10 (closing) — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-9 findings FIXED. Round 9 was 0C/1H/2M — all in the round-9 session-enforcement
additions. Audit FULL branch vs origin/main (git diff origin/main...HEAD; diff at
audits/2026-07-16/582-pr1-r10.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-9 fixes below; report any REMAINING C/H/M. Changes this round are CONTAINED to
the ws/onboarding/pool session-revalidation code (no SQL migration / verify.go changes). Only
report defects with a concrete failure scenario.

## Round-9 fixes to verify
- Batched sweep: runTrustRevalidationSweep snapshots active sessions, collects distinct
  provider_ids, and makes ONE onboarding ProvidersWithoutActiveTrust(ids) call under a sweep-wide
  deadline min(trustRevalidationInterval=30s, cap=20s); evicts exactly the returned untrusted set
  via disconnectProviderForTrustRevocation. Fail-OPEN on DB error (log+skip, no mass evict).
  ProvidersWithoutActiveTrust: SELECT pid FROM unnest($1::text[]) pid WHERE NOT <shared active-trust
  predicate>; read-only as provider_onboarding.
- ProviderTrustActiveLocked: SET LOCAL lock_timeout='2s' before pg_advisory_xact_lock, caller uses
  a 3s bounded context; lock/DB timeout -> fail-open (registration proceeds, sweep backstops).
- Registration re-check centralized INSIDE registerProviderSession (guarded s.providerTrust != nil)
  so BOTH V1 (server.go ~1088) and V2 (~1557) paths get it once; inactive trust ->
  pool.RegisterRefusalHardwareTrustInactive -> both sites close CloseInvalidHello. nil store = no-op.
- Shared providerTrustActivePredicate builder used by both batched + locked queries (drift-proof).

## Preserved invariant (must hold)
provider_onboarding: read-only on trust; NO write/EXECUTE. Verifier batch SELECT + SQL migration
functions unchanged this round.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged. FIX-B residual
TOCTOU window is bounded by the <=30s sweep (acceptable bounded-staleness).

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
Most-severe first. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
