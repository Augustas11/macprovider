# AUDIT ROUND 12 (closing) — #582 PR1 hardware-trust operator approval — code lane

Rounds 1-11 findings FIXED. Round 11: 0 CRITICAL / 0 HIGH on all lanes (SECURITY PASSED 0/0/0
at round 10 and is frozen/not re-run). The code lane had ONE MEDIUM at round 11, now fixed.
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
