# AUDIT — #582 PR1 hardware-trust operator approval — CODE lane

You are a senior Go/PostgreSQL code reviewer. Audit ONLY the change introduced by
the HEAD commit on branch `fix/582-onboarding-onramp` in this worktree
(`/Users/augstar/macprovider-582-onboarding`). The full diff is also at
`audits/2026-07-16/582-pr1.diff`. Read the surrounding code as needed for context,
but findings must be about THIS diff.

## What the change does
Adds a durable operator approval path for provider hardware-trust. A
hardware-verification job parked in `hardware_verification_jobs.status='waiting_trust'`
can now be approved via dual-control HTTP endpoints, which insert an
`source='operator_api'` row into `hardware_verification_trust` through SECURITY
DEFINER functions. `stats-inventory-sync` was changed so its trust-table DELETE is
scoped to `source='inventory'` (operator_api rows survive). New DB roles, DSNs,
store methods, and admin endpoints mirror the existing `provider_auth_policy`
dual-control pattern.

Key files: `internal/stats/migrations/018_hardware_trust_operator_approval.{up,down}.sql`,
`cmd/stats-inventory-sync/main.go`, `internal/onboarding/store_pg.go`,
`internal/config/config.go`, `internal/ws/admin_hardware_trust.go`,
`internal/ws/server.go`, `cmd/coordinator/main.go`.

## Focus (CODE correctness — not security policy, that's a separate lane)
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
List findings as: `SEVERITY (CRITICAL|HIGH|MEDIUM|LOW|INFO) — file:line — one-line title`
followed by 1-3 sentences: the concrete failure scenario and the fix. Rank most-severe
first. If you find zero C/H/M, say `PASS — 0 CRITICAL / 0 HIGH / 0 MEDIUM` explicitly.
Do not restate the design; only report defects.
