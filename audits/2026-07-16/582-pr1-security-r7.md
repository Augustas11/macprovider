# AUDIT ROUND 7 — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-6 findings FIXED. Audit FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r7.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-6 fixes below; report any REMAINING C/H/M. This is the convergence round —
round 6 was down to regressions from the round-6 fixes themselves. Report ONLY defects with a
concrete failure scenario. Watch specifically for: NEW regressions introduced by these fixes,
and whether the root-cause admission-trust-join (below) is complete + correct.

## Round-6 fixes to verify
- ROOT-CAUSE race closer: admission consumer internal/autotune/evidence_pg.go LatestVerified now
  has a strictly-additive AND EXISTS on hardware_verification_trust matching the verifier tuple
  (provider_id, evidence hardware_identity_hash, chip_normalized, unified_memory_gb, unexpired vs
  the store's injected wall clock $4). So a stale provider_hardware_profiles.verified bit can NOT
  admit revoked/expired hardware. The hello gate (server.go ~1849) calls only LatestVerified.
  internal/stats/hardware/cache.go also reads verified=TRUE but feeds the CAPACITY map
  (poolsnapshot), not admission — intentionally left unchanged.
- approve_hardware_trust_approval signature REVERTED to (uuid,text); 7-day evidence limit HARDCODED
  in the definer fn (caller-unbypassable), = hardwareverify.MaxEvidenceAgeDays (7). All probes
  (startup smoke store_pg.go, deploy preflight) resolve 2-arg.
- approve active-root decision: if an ACTIVE root matches the exact tuple and is source='inventory'
  -> ride it (commit pending + grant, NO operator_api write); else UNCONDITIONAL upsert of an
  operator_api root for the job tuple. Guarantees an active matching root results (no false-success).
- deploy verifier preflight: NOINHERIT assertion dropped; column grants checked via
  has_column_privilege (status UPDATE on jobs; verified INSERT/UPDATE on profiles).
- verifier promoteJob uses pg_try_advisory_xact_lock(582026, hashtext(provider_id)) — skip
  promotion this pass if not acquired (no 40P01 deadlock). Batch SELECT unchanged.
- approve rejects insufficient promotion runway (requested_until < now+5min, or evidence within
  5min of the 7-day limit) -> 409.
- re-added GRANT SELECT ON hardware_verification_trust TO provider_onboarding (read-only, for the
  LatestVerified join; write/EXECUTE boundary preserved).

## Preserved invariant (must hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns. (SELECT on the
trust table is now intentionally granted for the admission join.) Definer UPDATE grants remain
column-scoped (status/verified) for locking/demotion only.

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
Most-severe first. If a round-6 fix is incomplete/wrong or introduced a regression, report it.
If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
