# AUDIT ROUND 9 (closing) — #582 PR1 hardware-trust operator approval — architect lane

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
