# AUDIT ROUND 16 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-15 FIXED. SECURITY + CODE lanes PASS 0/0/0 (frozen). Architect round-15 had ONE narrow
MEDIUM (deploy gate fail-open on env parse error), now fixed. Audit FULL branch vs origin/main
(git diff origin/main...HEAD; diff at audits/2026-07-16/582-pr1-r16.diff), worktree
/Users/augstar/macprovider-582-onboarding. Report any REMAINING C/H/M. Only defects with a concrete
failure scenario. NOTE: the last 3 rounds' findings have been progressively narrower deploy-script
edges in NEW gate code; if the fail-closed handling below is correct, this branch is done.

## Round-15 architect MEDIUM fix to verify
- The universal 018 schema gate previously collapsed read_env_value exit 1 (clean-absent) and exit 2
  (parse/malformed error) into one no-op path (fail-open). Now the gate captures the exit code
  (trust_dsn=... || trust_dsn_rc=$?) and ABORTS exit 12 on any nonzero EXCEPT 1; only exit 1
  (clean-absent) or an explicitly-empty value takes the no-op. read_env_value contract: exit 0
  found/value, exit 1 key-absent, exit 2 parse error. Happy path + clean-absent unchanged.
- Other env consumers audited: onboarding preflight (require_env_value) already aborts exit 12 on any
  nonzero; step-9 sidecar re-enable reads NO env (file-presence only) and is protected by this
  now-fail-closed gate running first. Single fail-open site, now closed.
- Test asserts exit-2 (malformed, DSN hidden below a no-= line) vs exit-1 (comment-only, absent) are
  distinguished, and the gate branches fail-closed with the abort message.

## Preserved invariant
provider_onboarding read-only on trust; per-source trust rows; definer privilege model; verifier
batch SELECT unchanged (carried residual).

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT). Live-PG smoke of the SECURITY DEFINER
round-trip required out-of-band.

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
`SEVERITY — file:line — title` + 1-3 sentences. Most-severe first. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
