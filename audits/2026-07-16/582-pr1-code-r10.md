# AUDIT ROUND 10 (closing) — #582 PR1 hardware-trust operator approval — code lane

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
1. SQL correctness: the `request_/approve_hardware_trust_approval` plpgsql functions —
   transaction/locking correctness, ON CONFLICT targets, NULL handling of
   `requested_until`/`expires_at`, the partial-unique indexes (do they actually
   prevent duplicate open approvals and race double-inserts?), GET DIAGNOSTICS /
   ROW_COUNT logic, and whether the `.down.sql` cleanly reverses `.up.sql`.
2. The `stats-inventory-sync` DELETE-scoping change: does `source='inventory'` on
   the DELETE plus `source` in the upsert column list actually preserve operator_api
   rows AND still delete removed inventory rows? Any way an inventory row gets
   stranded or an operator_api row wrongly deleted?
3. Go: error handling, nil-guards on the new DB handles, resource cleanup (rows.Close,
   Close() on the new handles), context propagation, the new `ws`→`onboarding` import
   (confirm acyclic), JSON decode/validation in the handlers.
4. `ListWaitingTrustJobs` query correctness (the `#>> '{hardware,hardware_identity_hash}'`
   extraction, status filter, column grants sufficient).
5. Migration test/shape-assertion correctness and the `want`-list entry.
6. Any concurrency bug between request→approve and the verifier promoting the job.

## Output
`SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — title` + 1-3 sentences (scenario + fix).
Most-severe first. If zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
