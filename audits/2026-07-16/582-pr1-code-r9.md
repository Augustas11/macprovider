# AUDIT ROUND 9 (closing) — #582 PR1 hardware-trust operator approval — code lane

Rounds 1-8 findings FIXED. Round 8 was 0C/1H (active-session trust enforcement) with architect
already PASS. Audit FULL branch vs origin/main (git diff origin/main...HEAD; diff at
audits/2026-07-16/582-pr1-r9.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-8 HIGH fix below; report any REMAINING C/H/M. Only defects with a concrete
failure scenario. The change this round is ADDITIVE (a periodic sweep + a registration re-check).

## Round-8 HIGH fix to verify
- FIX A: new internal/ws/trust_revalidation.go runTrustRevalidationLoop — a 30s ticker sweep
  (const trustRevalidationInterval; started at server.go ~562 alongside runSELivenessLoop, gated
  on s.providerTrust != nil, itself wired only under cfg.ProofOfWeights.RequireAutotuneHelloGate).
  Each tick iterates s.pool.Snapshot() active sessions, calls onboarding ProviderTrustActive
  (read-only EXISTS on hardware_verification_trust matching the admitted tuple, expires_at active),
  and evicts lapsed sessions via disconnectProviderForTrustRevocation (drain->MarkState->close).
  Fails OPEN on DB error (logs+skips, never mass-evicts).
- FIX B: registration-time re-check before registerProviderSession (server.go ~1557), guarded by
  s.providerTrust != nil: ProviderTrustActiveLocked opens a tx, takes
  pg_advisory_xact_lock(582026, hashtext(provider_id)) — the SAME lock revoke_hardware_trust_approval
  holds — then re-checks active trust with clock_timestamp(); refuses via the hello-gate close path
  (CloseInvalidHello) if lapsed. Fails open on DB error.
- Store: ProviderTrustActive (sweep) + ProviderTrustActiveLocked (registration), read-only as
  provider_onboarding; predicate mirrors LatestVerified's trust join but omits the evidence-age TTL
  (revalidation evicts only on revoked/expired trust root, not benchmark staleness).

## Preserved invariant (must hold)
provider_onboarding: read-only on trust; NO write/EXECUTE. Verifier batch SELECT unchanged.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged.
The FIX-B TOCTOU residual (in-process gap between lock-release and registerProviderSession) is
backstopped by FIX A's <=30s sweep — acceptable bounded-staleness; do not re-report as HIGH unless
you can show a concrete UNBOUNDED bypass.

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
