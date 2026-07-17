# AUDIT ROUND 7 — #582 PR1 hardware-trust operator approval — code lane

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
1. SQL correctness: the `request_/approve_hardware_trust_approval` plpgsql functions —
   transaction/locking correctness, ON CONFLICT targets, NULL handling of
   `requested_until`/`expires_at`, the partial-unique indexes (do they actually
   prevent duplicate open approvals and race double-inserts?), GET DIAGNOSTICS /
   ROW_COUNT logic, and whether the `.down.sql` cleanly reverses `.up.sql`.
2. The `stats-inventory-sync` DELETE-scoping change: does `source='inventory'` on
   the DELETE plus `source` in the upsert column list actually preserve operator_api
   rows AND still delete removed inventory rows? Any way an inventory row gets
   stranded or an operator_api row wrongly deleted?
3. Go: error handling, nil-guards on the new DB handles, resource cleanup (rows.Close,
   Close() on the new handles), context propagation, the new `ws`→`onboarding` import
   (confirm acyclic), JSON decode/validation in the handlers.
4. `ListWaitingTrustJobs` query correctness (the `#>> '{hardware,hardware_identity_hash}'`
   extraction, status filter, column grants sufficient).
5. Migration test/shape-assertion correctness and the `want`-list entry.
6. Any concurrency bug between request→approve and the verifier promoting the job.

## Output
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences (scenario + fix).
Most-severe first. If a round-6 fix is incomplete/wrong or introduced a regression, report it.
If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
