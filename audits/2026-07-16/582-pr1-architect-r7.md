# AUDIT ROUND 7 — #582 PR1 hardware-trust operator approval — architect lane

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
1. **Dual authoritative source coherence:** inventory (YAML) and operator_api now both
   write `hardware_verification_trust`. What happens on conflict — same
   (provider_id, hardware_identity_hash) approved via API, then a DIFFERENT tuple
   appears in the YAML, or vice versa? Does the ON CONFLICT DO UPDATE let one source
   silently overwrite the other's `source` tag / expiry? Is there a defined precedence?
   Could a YAML sync flip an operator_api row back to inventory (losing durability) or
   an operator approval clobber an inventory row?
2. **Operational completeness:** the PR flags but does NOT add deploy preflight for the
   new roles/DSNs (`dist/deploy-pearl-vps.sh`, `dist/test/check_stats_inventory_deploy_test.sh`).
   Is anything missing that would cause a silent half-configured deploy (coordinator
   starts, endpoints 503, operators think approval works but it doesn't)? Is the
   nil-store 503 path clear and observable?
3. **Contract consistency:** do the new endpoints follow the same auth, error-envelope,
   and route-registration conventions as sibling admin endpoints? Is
   `GET /admin/hardware-trust/waiting` paginated/bounded (could it return unbounded rows)?
4. **Migration forward/back safety:** is 018 idempotent + re-runnable (matches the
   repo's idempotent-migration invariant)? Does adding the `source` column with a
   DEFAULT lock the table problematically at Pearl scale?
5. **Does this actually close the deadlock end-to-end?** Trace: operator calls approve →
   trust row written → verifier timer promotes job → autotune hello gate passes. Any
   gap where the approval still doesn't unblock admission (e.g. verifier only runs on a
   timer with latency, or the job needs a re-submit)?
6. **Scope creep / missing coverage:** anything half-done that should be in this PR vs
   correctly deferred to PR2 (CLI) / PR3 (Malibu)?

## Output
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences (scenario + fix).
Most-severe first. If a round-6 fix is incomplete/wrong or introduced a regression, report it.
If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
