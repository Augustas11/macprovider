# AUDIT ROUND 17 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-16 FIXED. SECURITY + CODE lanes PASS 0/0/0 (frozen). Architect has spent rounds 13-16 on
deploy-script edges in the NEW deploy-safety gate; round-16's MEDIUM (clean-absent DSN with
trusted_hardware present) is now fixed. Audit FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r17.diff), worktree /Users/augstar/macprovider-582-onboarding.
Report any REMAINING C/H/M with a concrete failure scenario.

IMPORTANT SCOPING NOTE: this PR ADDS deploy-safety machinery (quiesce ordering + universal 018
schema gate) that did NOT exist before. Pre-existing deploy behaviors unrelated to the migration-018
PK change (e.g. general sidecar misconfig that predates this branch and is unchanged by it) are NOT
in scope — flag them only if THIS branch introduced or worsened them. The verifier batch-ordering
SELECT is a documented pre-existing residual.

## Round-16 architect MEDIUM fix to verify
- The gate now keys applicability on the trust-reconciliation TRIGGER — presence of a top-level
  'trusted_hardware:' key in the inventory YAML (present incl. explicit {} = revoke-all, still
  requires DSN+018; omitted = no reconciliation = no-op) — detected via PyYAML on the VPS, mirroring
  the sidecar UnmarshalYAML omitted-vs-{} contract. Fail-CLOSED fallback: any PyYAML import/parse
  error / non-mapping / exception resolves to 'present' (only a cleanly-parsed mapping provably
  lacking the key no-ops).
- When trusted_hardware PRESENT, any incompleteness aborts exit 12: DSN parse error (r16),
  DSN clean-absent/empty (NEW — closes r16 MEDIUM), or pre-018 schema (r15). DSN present + 018 -> proceed.
- Test: omitted -> exit 0 no-op; present + no DSN -> exit 12; present + DSN + 018-present -> exit 0 proceed.

## Preserved invariant
provider_onboarding read-only on trust; per-source trust rows; definer privilege model; verifier
batch SELECT unchanged (carried residual).

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
`SEVERITY — file:line — title` + 1-3 sentences. Most-severe first. For any finding, state whether
it is NEW-to-this-branch or PRE-EXISTING/unrelated to the migration-018 change. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
