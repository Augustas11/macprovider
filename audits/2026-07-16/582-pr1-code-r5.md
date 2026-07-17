# AUDIT ROUND 5 — #582 PR1 hardware-trust operator approval — code lane

Rounds 1-4 findings FIXED. Audit the FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r5.diff), worktree /Users/augstar/macprovider-582-onboarding.
Tasks: verify the round-4 fixes below, and report any REMAINING C/H/M. Loop is converging —
only report defects with a concrete failure scenario; do not invent speculative issues.

## Round-4 fixes to verify
- RETURNS TABLE output columns renamed out_* (fixes SQLSTATE 42702 ambiguous provider_id);
  approve INTO now qualified hardware_trust_pending.provider_id.
- verify.go promoteJob re-checks the backing hardware_verification_trust root is active
  (expires_at IS NULL OR > now()) in-tx before promotion; re-parks as waiting_trust
  (missing_trusted_hardware_identity) if not. Batch ORDER BY/LIMIT/SKIP LOCKED UNCHANGED
  (carried residual). Closes revoke/demote/inventory-delete vs promotion races.
- YAML: nested KnownFields(true) strict decode (typo like expires_att errors); bare null
  trusted_hardware rejected (revoke-all requires explicit {}); omitted = no-op; {} = revoke-all.
- down.sql: \set ON_ERROR_STOP on + BEGIN/COMMIT; demotes operator_api-backed verified
  profiles before DELETE/DROP; IF EXISTS guards -> atomic + re-runnable.
- demotion runs on independent context budget (context.WithTimeout(WithoutCancel(parent),...)).
- request/approve re-sample clock_timestamp() AFTER lock waits for requested_until/7-day/expiry.
- error map: connectivity/context (DeadlineExceeded/Canceled/ErrConnDone/ErrBadConn/net.Error)
  -> 503; all other unknown -> 500 hardware_trust_internal_error. 23505 -> 409.
- deploy fails closed (exit 12) when hardware-trust DSNs set but stats-hardware-verifier.env absent.

## Preserved invariant (must still hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns, NO SELECT on
trust table. Definer UPDATE grants are column-scoped (status/verified) for locking/demotion only.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (verify.go ORDER BY id LIMIT ... SKIP LOCKED) — pre-existing,
unchanged by this branch, tracked separately.

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
Most-severe first. If a round-4 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
