# AUDIT ROUND 4 — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-3 findings are FIXED across commits on branch `fix/582-onboarding-onramp`.
Audit the FULL branch vs `origin/main` (git diff origin/main...HEAD; full diff at
audits/2026-07-16/582-pr1-r4.diff), worktree /Users/augstar/macprovider-582-onboarding.
Tasks: (a) VERIFY the round-3 fixes below, (b) find any REMAINING C/H/M defect. The loop
is converging; be rigorous but do not invent speculative issues — only report defects you
can tie to a concrete failure scenario.

## Round-3 fixes to verify
- FOR SHARE restored on both job reads; definer has lock-only GRANT UPDATE(status) on
  hardware_verification_jobs (functions never UPDATE jobs) — serializes with verifier
  FOR UPDATE SKIP LOCKED. Also GRANT UPDATE(verified) on provider_hardware_profiles for revoke demotion.
- omitted trusted_hardware (nil) = no-op preserve; explicit '{}' = revoke-all. Presence-detecting
  UnmarshalYAML. Example + validation text updated.
- applyTrustDemotions: lock candidates FOR UPDATE (statement 1) then re-check fresh snapshot
  (statement 2) so it can't re-demote a just-promoted profile; demotions ALWAYS run even if
  applyTrustInventory errored (errors.Join).
- revoke_hardware_trust_approval atomically demotes the matching non-operator verified profile
  (hash-precise) in the same txn after expiring the root.
- single advisory-lock-first order in request + approve (deadlock removed).
- approve RAISEs hardware_trust_pending_expired (->410) when created_at < now()-7d; approve
  re-asserts decision_reason='missing_trusted_hardware_identity'.
- error map: only SQLSTATE P0001 classified by text; operational 08/53/57/40001 + store-unavailable
  ->503; 23505->409; unexpected/non-pq ->500. DSN parse errors redacted. Waiting-list adds
  per-row 'approvable' boolean.

## Preserved invariant (must still hold)
provider_onboarding: NO write on hardware_verification_trust/_pending/_grants, NO EXECUTE on
definer fns, NO SELECT on trust table. Definer's UPDATE grants are column-scoped (status/verified)
and used ONLY for row-locking/demotion inside the SECURITY DEFINER functions.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (verify.go, unchanged by this branch) — pre-existing, tracked separately.

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
Most-severe first. If a round-3 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
