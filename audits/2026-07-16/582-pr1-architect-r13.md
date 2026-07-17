# AUDIT ROUND 13 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-12 FIXED. Round 12: SECURITY + CODE lanes PASS 0/0/0 (frozen, not re-run). Architect had
ONE MEDIUM (deploy PK-cutover ordering), now fixed. Audit FULL branch vs origin/main
(git diff origin/main...HEAD; diff at audits/2026-07-16/582-pr1-r13.diff), worktree
/Users/augstar/macprovider-582-onboarding. Verify the fix below; report any REMAINING C/H/M.

## Round-12 architect MEDIUM fix to verify
- dist/deploy-pearl-vps.sh now STOPS + DISABLES stats-inventory-sync.timer/.service (draining any
  in-flight run) BEFORE the onboarding hardware-trust migration preflight that applies 018 — so the
  old pre-#582 sidecar (2-col ON CONFLICT) can never reconcile against the migrated 3-col-PK schema.
  The sidecar was MOVED out of the later release-freeze loop (not duplicated). The rollback snapshot
  now records the sidecar inactive, so recovery won't restart the old binary against the new schema.
- dist/coordinator-deploy-recover.sh + both 018 migration headers document the rollback coupling:
  restoring the 2-col PK MUST be paired with restoring the OLD 2-col binary; never run the 3-col
  binary against a 2-col schema nor vice versa.
- dist/test/check_stats_inventory_deploy_test.sh asserts the quiesce anchor exists, the sidecar is
  disabled (not just stopped), and the quiesce line precedes the hardware_trust_request_preflight line.
- No Go/SQL logic change this round (migration function bodies unchanged; only header comments).

## Preserved invariant
provider_onboarding read-only on trust; per-source trust rows (round 11); definer privilege model;
verifier batch SELECT unchanged (carried residual).

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing. Live-PG smoke of the SECURITY
DEFINER request/approve/revoke round-trip required out-of-band (no in-repo PG harness).

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
