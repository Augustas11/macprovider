# AUDIT ROUND 8 (closing) — #582 PR1 hardware-trust operator approval — code lane

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
Most-severe first. If a round-7 fix is incomplete/wrong or introduced a regression, report it.
If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
