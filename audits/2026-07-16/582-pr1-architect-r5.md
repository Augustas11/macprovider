# AUDIT ROUND 5 — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-4 findings FIXED. Audit the FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r5.diff), worktree /Users/augstar/macprovider-582-onboarding.
Tasks: verify the round-4 fixes below, and report any REMAINING C/H/M. Loop is converging —
only report defects with a concrete failure scenario; do not invent speculative issues.

## Round-4 fixes to verify
- RETURNS TABLE output columns renamed out_* (fixes SQLSTATE 42702 ambiguous provider_id);
  approve INTO now qualified hardware_trust_pending.provider_id.
- verify.go promoteJob re-checks the backing hardware_verification_trust root is active
  (expires_at IS NULL OR > now()) in-tx before promotion; re-parks as waiting_trust
  (missing_trusted_hardware_identity) if not. Batch ORDER BY/LIMIT/SKIP LOCKED UNCHANGED
  (carried residual). Closes revoke/demote/inventory-delete vs promotion races.
- YAML: nested KnownFields(true) strict decode (typo like expires_att errors); bare null
  trusted_hardware rejected (revoke-all requires explicit {}); omitted = no-op; {} = revoke-all.
- down.sql: \set ON_ERROR_STOP on + BEGIN/COMMIT; demotes operator_api-backed verified
  profiles before DELETE/DROP; IF EXISTS guards -> atomic + re-runnable.
- demotion runs on independent context budget (context.WithTimeout(WithoutCancel(parent),...)).
- request/approve re-sample clock_timestamp() AFTER lock waits for requested_until/7-day/expiry.
- error map: connectivity/context (DeadlineExceeded/Canceled/ErrConnDone/ErrBadConn/net.Error)
  -> 503; all other unknown -> 500 hardware_trust_internal_error. 23505 -> 409.
- deploy fails closed (exit 12) when hardware-trust DSNs set but stats-hardware-verifier.env absent.

## Preserved invariant (must still hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns, NO SELECT on
trust table. Definer UPDATE grants are column-scoped (status/verified) for locking/demotion only.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (verify.go ORDER BY id LIMIT ... SKIP LOCKED) — pre-existing,
unchanged by this branch, tracked separately.

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
Most-severe first. If a round-4 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
