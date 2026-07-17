# AUDIT ROUND 9 (closing) — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-8 findings FIXED. Round 8 was 0C/1H (active-session trust enforcement) with architect
already PASS. Audit FULL branch vs origin/main (git diff origin/main...HEAD; diff at
audits/2026-07-16/582-pr1-r9.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-8 HIGH fix below; report any REMAINING C/H/M. Only defects with a concrete
failure scenario. The change this round is ADDITIVE (a periodic sweep + a registration re-check).

## Round-8 HIGH fix to verify
- FIX A: new internal/ws/trust_revalidation.go runTrustRevalidationLoop — a 30s ticker sweep
  (const trustRevalidationInterval; started at server.go ~562 alongside runSELivenessLoop, gated
  on s.providerTrust != nil, itself wired only under cfg.ProofOfWeights.RequireAutotuneHelloGate).
  Each tick iterates s.pool.Snapshot() active sessions, calls onboarding ProviderTrustActive
  (read-only EXISTS on hardware_verification_trust matching the admitted tuple, expires_at active),
  and evicts lapsed sessions via disconnectProviderForTrustRevocation (drain->MarkState->close).
  Fails OPEN on DB error (logs+skips, never mass-evicts).
- FIX B: registration-time re-check before registerProviderSession (server.go ~1557), guarded by
  s.providerTrust != nil: ProviderTrustActiveLocked opens a tx, takes
  pg_advisory_xact_lock(582026, hashtext(provider_id)) — the SAME lock revoke_hardware_trust_approval
  holds — then re-checks active trust with clock_timestamp(); refuses via the hello-gate close path
  (CloseInvalidHello) if lapsed. Fails open on DB error.
- Store: ProviderTrustActive (sweep) + ProviderTrustActiveLocked (registration), read-only as
  provider_onboarding; predicate mirrors LatestVerified's trust join but omits the evidence-age TTL
  (revalidation evicts only on revoked/expired trust root, not benchmark staleness).

## Preserved invariant (must hold)
provider_onboarding: read-only on trust; NO write/EXECUTE. Verifier batch SELECT unchanged.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged.
The FIX-B TOCTOU residual (in-process gap between lock-release and registerProviderSession) is
backstopped by FIX A's <=30s sweep — acceptable bounded-staleness; do not re-report as HIGH unless
you can show a concrete UNBOUNDED bypass.

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
