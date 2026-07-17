# AUDIT ROUND 6 — #582 PR1 hardware-trust operator approval — architect lane

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
Most-severe first. If a round-5 fix is incomplete/wrong, report it. If zero C/H/M, say
`PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
