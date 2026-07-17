# AUDIT ROUND 12 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-11 findings FIXED. Round 11: 0 CRITICAL / 0 HIGH on all lanes (SECURITY PASSED 0/0/0
at round 10 and is frozen/not re-run). The architect lane had ONE MEDIUM at round 11, now fixed.
Audit FULL branch vs origin/main (git diff origin/main...HEAD; diff at
audits/2026-07-16/582-pr1-r12.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-11 MEDIUM fixes below; report any REMAINING C/H/M. Only defects with a concrete
failure scenario.

## Round-11 MEDIUM fixes to verify
- revoke_hardware_trust_approval RETURNS an added out_now_untrusted BOOLEAN = NOT EXISTS(any active
  trust root of ANY source for the tuple, post-revoke). Threaded through store + HardwareTrustAdminStore
  + handler. The revoke HANDLER now calls disconnectProviderForTrustRevocation ONLY when now_untrusted
  is true; if an inventory root still vouches, the operator grant is revoked but the session stays up.
- config validateProofOfWeights: when require_autotune_hello_gate is true, require
  autotune_evidence_ttl_days >= hardwareverify.MaxEvidenceAgeDays (7) so evidence the verifier can
  approve/promote isn't excluded by a narrower hello-gate admission window (false-success). config
  imports hardwareverify directly (no import cycle) for the authoritative constant.

## Preserved invariant (must hold)
provider_onboarding: read-only on trust; NO write/EXECUTE. Definer write grants column-scoped.
Verifier batch-ordering SELECT unchanged (carried residual). Per-source trust rows (round 11).

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged. Live-PG smoke of
the SECURITY DEFINER request/approve/revoke round-trip required out-of-band (no in-repo PG harness).

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
Most-severe first. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
