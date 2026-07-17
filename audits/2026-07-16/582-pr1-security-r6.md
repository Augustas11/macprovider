# AUDIT ROUND 6 — #582 PR1 hardware-trust operator approval — security lane

Rounds 1-5 findings FIXED. Audit FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r6.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-5 fixes below; report any REMAINING C/H/M. The loop is at its tail (round 5
had 1 HIGH, now fixed). Only report defects with a concrete failure scenario — no speculation.

## Round-5 fixes to verify
- verifier promoteJob (verify.go) now takes pg_advisory_xact_lock(582026, hashtext(provider_id))
  — the SAME key as the approve/revoke SQL fns — before its trust re-check, and the re-check
  EXISTS compares t.expires_at > clock_timestamp() (not frozen now()). Serializes revoke-vs-promote:
  revoke-first -> verifier blocks then re-parks; verifier-first -> revoke waits then demotes.
  The profile-promotion trigger guard's trust-activity check also switched to clock_timestamp().
  Batch ProcessPending SELECT (ORDER BY id LIMIT SKIP LOCKED) UNCHANGED (carried residual).
- approve samples clock_timestamp() and runs deadline/requested_until/evidence-age checks AFTER
  the advisory lock + job FOR SHARE. revoke samples clock_timestamp() after its advisory lock.
- approve trust upsert ON CONFLICT DO UPDATE scoped WHERE source='operator_api' — never clobbers
  an inventory-owned root; approval is idempotent success if a row already exists.
- approve rejects jobs whose evidence generated_at is older than the verifier's maxEvidenceAge
  (7 days, exported as MaxEvidenceAgeDays; threaded via p_evidence_ttl_days) -> 409 resubmit-required.
- DSN handles built via pq.NewConnector + sql.OpenDB; malformed DSN returns a redacted error
  (config-handle name only), never the credential URL.
- deploy asserts verifier current_user/session_user/role + write grants and makes the initial
  verifier run FATAL when hardware-trust approval DSNs are set.
- down.sql DELETEs schema_migrations_spec017 version=18 in-tx (rollback re-applies 018).

## Preserved invariant (must hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns, NO SELECT on
trust table. Definer UPDATE grants column-scoped (status/verified) for locking/demotion only.

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
Most-severe first. If a round-5 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
