# AUDIT ROUND 3 — #582 PR1 hardware-trust operator approval — architect lane

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
Most-severe first. If a round-2 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
