# AUDIT ROUND 6 — #582 PR1 hardware-trust operator approval — code lane

Rounds 1-5 findings FIXED. Audit FULL branch vs origin/main (git diff origin/main...HEAD;
diff at audits/2026-07-16/582-pr1-r6.diff), worktree /Users/augstar/macprovider-582-onboarding.
Verify the round-5 fixes below; report any REMAINING C/H/M. The loop is at its tail (round 5
had 1 HIGH, now fixed). Only report defects with a concrete failure scenario — no speculation.

## Round-5 fixes to verify
- verifier promoteJob (verify.go) now takes pg_advisory_xact_lock(582026, hashtext(provider_id))
  — the SAME key as the approve/revoke SQL fns — before its trust re-check, and the re-check
  EXISTS compares t.expires_at > clock_timestamp() (not frozen now()). Serializes revoke-vs-promote:
  revoke-first -> verifier blocks then re-parks; verifier-first -> revoke waits then demotes.
  The profile-promotion trigger guard's trust-activity check also switched to clock_timestamp().
  Batch ProcessPending SELECT (ORDER BY id LIMIT SKIP LOCKED) UNCHANGED (carried residual).
- approve samples clock_timestamp() and runs deadline/requested_until/evidence-age checks AFTER
  the advisory lock + job FOR SHARE. revoke samples clock_timestamp() after its advisory lock.
- approve trust upsert ON CONFLICT DO UPDATE scoped WHERE source='operator_api' — never clobbers
  an inventory-owned root; approval is idempotent success if a row already exists.
- approve rejects jobs whose evidence generated_at is older than the verifier's maxEvidenceAge
  (7 days, exported as MaxEvidenceAgeDays; threaded via p_evidence_ttl_days) -> 409 resubmit-required.
- DSN handles built via pq.NewConnector + sql.OpenDB; malformed DSN returns a redacted error
  (config-handle name only), never the credential URL.
- deploy asserts verifier current_user/session_user/role + write grants and makes the initial
  verifier run FATAL when hardware-trust approval DSNs are set.
- down.sql DELETEs schema_migrations_spec017 version=18 in-tx (rollback re-applies 018).

## Preserved invariant (must hold)
provider_onboarding: NO write on trust/pending/grants, NO EXECUTE on definer fns, NO SELECT on
trust table. Definer UPDATE grants column-scoped (status/verified) for locking/demotion only.

## Known carried residual (do NOT re-report)
Verifier batch-ordering fairness (ProcessPending SELECT) — pre-existing, unchanged.

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
Most-severe first. If a round-5 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
