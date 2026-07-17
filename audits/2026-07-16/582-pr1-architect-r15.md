# AUDIT ROUND 15 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-14 FIXED. SECURITY + CODE lanes PASS 0/0/0 (frozen). Architect round-14 had ONE MEDIUM
(non-onboarding deploy installs 3-col sidecar against a pre-018 schema), now fixed with a universal
hard-gate. Audit FULL branch vs origin/main (git diff origin/main...HEAD; diff at
audits/2026-07-16/582-pr1-r15.diff), worktree /Users/augstar/macprovider-582-onboarding. Report any
REMAINING C/H/M. Only defects with a concrete failure scenario.

## Round-14 architect MEDIUM fix to verify
- New UNIVERSAL fail-closed gate in deploy-pearl-vps.sh (~1425-1593), OUTSIDE the onboarding-gated
  block so it runs on EVERY deploy path, positioned AFTER the round-14 onboarding auto-apply and
  BEFORE the (unconditional) sidecar binary install (~1994) + timer re-enable (~2973).
- Read-only psql probe: verifies hardware_verification_trust has the 'source' column AND the 3-col PK
  (provider_id, hardware_identity_hash, source) via information_schema.columns + pg_constraint conkey
  reconstruction. Absent shape -> abort exit 12 pointing to 'coordinator stats-migrate'.
- Applicability no-op unless the sidecar timer would actually be re-enabled (both inventory yaml +
  env present) AND STATS_TRUST_INVENTORY_DSN set (no trust reconciliation -> no 018 dependency).
- DSN: the sidecar's own STATS_TRUST_INVENTORY_DSN read as data via the shlex read_env_value parser
  (never sourced) and passed via root-only PGSERVICEFILE (no password in ps, no argv). No admin DSN needed.
- Onboarding path: round-14 auto-apply already applied 018, so the gate is a satisfied no-op there.
- Deploy-gate test asserts gate existence, non-onboarding placement, source+PK probe, PGSERVICEFILE
  (not argv), precedes install/re-enable, exit-12 abort.

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
