# SPEC-017 IMPL Prompt Code-Mechanics Audit - Round 6

**Target:** `specs/BUILD_SPEC_017_IMPL_PROMPT.md`  
**Lens:** CODE-MECHANICS  
**Controlling contract:** `specs/SPEC-017-network-stats-api.md` v0.1.6 LOCKED  
**Required pattern check:** `phase4-coordinator/internal/explorer/handlers.go`

## Verdict

**READY:** 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW.

Round 6 verifies the round-5 CODE blocker is absorbed. The Step 1 AC-10
fixture now pre-seeds `p1` as `bucketed`, uses PostgreSQL-valid
`ON CONFLICT (provider_id) DO UPDATE SET mode = EXCLUDED.mode, updated_at =
now()`, asserts both the final `provider_visibility.mode = 'exact'` and the
matching provider audit row, and uses a distinct `p_rollback` provider for the
rollback subcase. That matches SPEC-017 §6.3 and AC-10.

No new code-mechanics defects were found in the IMPL prompt.

## Findings

None.

## Evidence Checked

- `BUILD_SPEC_017_IMPL_PROMPT.md` lines 157-194 now pin a mechanically valid
  AC-10 SQL fixture: explicit conflict target, commit-path state assertion,
  audit-row assertion, and rollback isolation by distinct provider.
- SPEC-017 §6.3 lines 1082-1089 pins the same `ON CONFLICT (provider_id)` state
  transition and same-transaction audit insert.
- SPEC-017 AC-1 through AC-21 lines 1763-1842 match the prompt's §2.4
  AC-to-step ownership matrix.
- `phase4-coordinator/go.mod` declares module
  `github.com/augstar/macprovider-coordinator`, matching the prompt's lint
  fixture guidance for compilable forbidden imports.
- `phase4-coordinator/internal/explorer/handlers.go` uses a flat
  `internal/explorer` handler package with local window parsing, bearer auth,
  and in-process rate limiting; the prompt's `internal/stats` flat handler
  package plus `store` and `rollup` subpackages does not fight that pattern.
- SPEC-005 v0.3 contains the AC-9 fixture tables named by the prompt:
  `ledger_request_credits`, `ledger_operator_credits`,
  `ledger_payout_ready`, and `ledger_reconciliation_runs`.
- SPEC-002 v1.4 contains `provider_tokens`, matching the prompt's
  implementation-time source-grant direction for authenticated provider IDs.

## Category Walk

- **A. Section number drift:** PASS. The prompt's SPEC-017 citations resolve to
  the intended locked sections: §3.7 partner-key format; §4.3 verbs; §5.1,
  §5.2, §5.3 endpoint shapes and cache headers; §5.4.x partner-key lifecycle;
  §5.6 rate limits; §5.7 CORS; §5.8 stale handling; §5.9 error envelope;
  §6.x visibility model; §7.x hosting/isolation; §8.5 changelog; §9.x rollup
  schemas/cadence/freshness/backfill; §10 ACs; §11 open-question deferrals.
- **B. Postgres grant shape correctness:** PASS. Role names, table names,
  grant kinds, and backing-sequence grants match SPEC §7.2. The prompt keeps
  `partner_keys_writer` default-off rather than widening the locked
  column-scoped grant. Per-role `*sql.DB` isolation is explicit.
- **C. Go package boundary correctness:** PASS. Request-path packages are
  limited to `internal/stats` and `internal/stats/store` using `stats_reader`.
  `internal/stats/rollup` is the only package allowed to import billing/session/
  pool read-only paths and is still denied `internal/explorer`, `internal/ws`,
  and non-allowlisted `internal/auth`.
- **D. Wire-contract correctness:** PASS. Partner-key length math is 32 random
  bytes -> 43 unpadded base64url chars plus `mpk_` = 47 chars. CORS preflight
  is exactly 204. Error codes stay within the §5.9 closed vocabulary. Status
  codes, cache directives, ETag/304, 405 `Allow`, and `X-Stats-Generated-At`
  directives align with the locked SPEC.
- **E. AC test-coverage mapping:** PASS. AC-1 through AC-21 are mapped in
  §2.4. AC-8 remains assigned to Step 4.B with the prompt honestly blocking
  production nginx config on the already-identified §5.6/AC-8 contract
  reconciliation instead of silently shipping a no-burst config. AC-10 is now
  mechanically valid and covered in Step 1.
- **F. Migration / IMPL-time decision drift:** PASS. OLTP source grants are
  implementation-authored against dependency line-3 versions at IMPL time.
  Backfill and hostname behavior implement both locked paths with cutover-time
  selection instead of code-time drift.
- **G. Test-shape correctness:** PASS. Step 1-4 tests are mechanically
  writable against the locked contract. The rollup fixture corpus is concrete,
  AC-7 has separate `down` and `degraded` fixtures, and smoke tests are scoped
  to a Pearl-equivalent nginx/staging surface.
- **H. Idiomatic Go correctness:** PASS. The prompt directs role-scoped
  `*sql.DB` pools, concrete recover/redaction middleware ordering, typed
  context key use for the bearer token, and no v0.1 `last_used_at` worker or
  channel because the writer role is skipped.
- **I. Naming hygiene:** PASS. Role names, table names, package paths, CLI
  names, error codes, and structured event names are consistent with SPEC-017
  and do not collide with the existing explorer `internal_bearer_accepted`
  event.

## Self-Verification

- [x] Walked every `§X.Y` citation against the SPEC.
- [x] Walked every AC-N citation against §10.
- [x] Walked every GRANT line.
- [x] Walked Categories A through I.
- [x] Severity per finding chosen against definitions.
- [x] Verdict recorded.

## 200-Word Handback Summary

Round 6 reaches the CODE lock target: 0 CRITICAL, 0 HIGH, 0 MEDIUM, 0 LOW. The only round-5 blocker, AC-10's provider-portal SQL fixture, is now closed. The IMPL prompt pre-seeds `p1` as `bucketed`, runs the toggle transaction as `provider_portal`, uses the PostgreSQL-required `ON CONFLICT (provider_id)` target, updates via `EXCLUDED.mode`, inserts the audit row in the same transaction, and asserts both final mode and exactly one provider audit row. The rollback case now uses `p_rollback`, so it can assert zero rows for that provider without colliding with the commit-path fixture.

I re-walked SPEC section references, all 21 AC references, grant shapes, BIGSERIAL sequence grants, role names, table names, package boundaries, wire-contract details, and test ownership. The prompt remains consistent with the existing `internal/explorer` handler pattern while keeping stats handlers isolated under `internal/stats`, with `store` and `rollup` subpackages. Partner-key format, CORS 204, closed error vocabulary, cache headers, 405 envelope, ETag/304 behavior, redaction coverage, and per-role `*sql.DB` isolation match the locked SPEC. Step 4.B continues to handle the known §5.6/AC-8 conflict by blocking production nginx config rather than silently choosing a divergent implementation path. No fix prompt is needed. Evidence supports READY for kickoff under the current prompt and locked SPEC as audited.
