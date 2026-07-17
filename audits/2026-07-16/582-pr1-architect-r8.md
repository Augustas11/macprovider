# AUDIT ROUND 8 (closing) — #582 PR1 hardware-trust operator approval — architect lane

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
Most-severe first. If a round-7 fix is incomplete/wrong or introduced a regression, report it.
If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
