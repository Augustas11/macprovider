# AUDIT ROUND 10 (closing) — #582 PR1 hardware-trust operator approval — architect lane

Rounds 1-9 findings FIXED. Round 9 was 0C/1H/2M — all in the round-9 session-enforcement
additions. Audit FULL branch vs origin/main (git diff origin/main...HEAD; diff at
audits/2026-07-16/582-pr1-r10.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-9 fixes below; report any REMAINING C/H/M. Changes this round are CONTAINED to
the ws/onboarding/pool session-revalidation code (no SQL migration / verify.go changes). Only
report defects with a concrete failure scenario.

## Round-9 fixes to verify
- Batched sweep: runTrustRevalidationSweep snapshots active sessions, collects distinct
  provider_ids, and makes ONE onboarding ProvidersWithoutActiveTrust(ids) call under a sweep-wide
  deadline min(trustRevalidationInterval=30s, cap=20s); evicts exactly the returned untrusted set
  via disconnectProviderForTrustRevocation. Fail-OPEN on DB error (log+skip, no mass evict).
  ProvidersWithoutActiveTrust: SELECT pid FROM unnest($1::text[]) pid WHERE NOT <shared active-trust
  predicate>; read-only as provider_onboarding.
- ProviderTrustActiveLocked: SET LOCAL lock_timeout='2s' before pg_advisory_xact_lock, caller uses
  a 3s bounded context; lock/DB timeout -> fail-open (registration proceeds, sweep backstops).
- Registration re-check centralized INSIDE registerProviderSession (guarded s.providerTrust != nil)
  so BOTH V1 (server.go ~1088) and V2 (~1557) paths get it once; inactive trust ->
  pool.RegisterRefusalHardwareTrustInactive -> both sites close CloseInvalidHello. nil store = no-op.
- Shared providerTrustActivePredicate builder used by both batched + locked queries (drift-proof).

## Preserved invariant (must hold)
provider_onboarding: read-only on trust; NO write/EXECUTE. Verifier batch SELECT + SQL migration
functions unchanged this round.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged. FIX-B residual
TOCTOU window is bounded by the <=30s sweep (acceptable bounded-staleness).

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
