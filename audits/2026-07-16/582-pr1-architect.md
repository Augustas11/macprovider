# AUDIT — #582 PR1 hardware-trust operator approval — ARCHITECT lane

You are a staff engineer reviewing architecture/operability. Audit ONLY the change
introduced by the HEAD commit on branch `fix/582-onboarding-onramp` in this worktree
(`/Users/augstar/macprovider-582-onboarding`). Full diff also at
`audits/2026-07-16/582-pr1.diff`. Findings about THIS diff.

## Context
This is PR1 of issue #582 (provider onboarding deadlocks). It adds a durable operator
approval path for hardware-trust so a `waiting_trust` job can be promoted via HTTP
instead of hand-editing `stats-hardware-inventory.yaml` + waiting on systemd timers.
It mirrors the `provider_auth_policy` dual-control SECURITY DEFINER pattern. The change
introduces a SECOND authoritative source for the trust table (`source='inventory'` from
the YAML sync vs `source='operator_api'` from the endpoint).

## Focus (ARCHITECTURE / OPERABILITY / CONSISTENCY)
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
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences
(scenario + fix). Most-severe first. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly. Real defects only; don't restate design.
