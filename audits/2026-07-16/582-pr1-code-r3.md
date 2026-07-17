# AUDIT ROUND 3 — #582 PR1 hardware-trust operator approval — code lane

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
Most-severe first. If a round-2 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
