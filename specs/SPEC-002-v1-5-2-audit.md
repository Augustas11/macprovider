# SPEC-002 v1.5.2 / SPEC-005 v0.3.3 audit trail (issue #168)

Three-lane codex audit on the monotonic `attempt_n` column work.

## Scope

1. **SPEC-002 v1.5.2** — adds `attempt_n INTEGER NULL` to `request_log` with monotonic INSERT-time write-path semantics, per-column migration state machine (`legacy | populating | populated`), backfill subcommand.
2. **SPEC-005 v0.3.3** — promotes the row-mapping rule to prefer the persisted `attempt_n` exact match; retains v0.3.1 id-ASC derivation as back-compat fallback for legacy NULL rows. Closes §OQ-1.
3. **Coordinator IMPL** — column + schema migration + INSERT-time COUNT-then-INSERT in `requestlog.insert()`; read-side `COALESCE(rl.attempt_n, fallback_derivation)` in recovery.go + endpoints.go; backfill subcommand + `--check --format json` surface.

## Round dispositions

### R1 (3 lanes)
- CODE: 1 CRITICAL (`Store.Insert` race — multi-op through `*sql.DB` interleaves) + 1 MEDIUM (missing mixed-state regression test) + 1 LOW (external API break note).
- SECURITY: 2 HIGH (hotpath.go + recovery.go still implement v0.3.1 row-3+ quarantine; SPEC-005 internally inconsistent — multiple stale "row 3+ MUST quarantine" references).
- ARCHITECT: 1 CRITICAL (SPEC-005 stale "row 3+ MUST quarantine until SPEC-002 gains monotonic attempt_n" in §D10 + AC + oracle at lines 334, 1272, 1386, 1577-1578, 2378) + 1 HIGH (claim "legacy quarantines auto-resolve via §OQ-5 or deterministic re-derivation" contradicts ledger schema: `quarantined` is `0 → 1` immutable transition, §OQ-5 not yet defined) + 2 LOW (backfill live-safety SHOULD vs MAY; future umbrella subcommand).

### R2 fixes

**CRITICAL CODE: `Store.Insert` race fix.**
- `Store.Insert` now acquires a single `*sql.Conn` via `s.db.Conn(ctx)` and runs COUNT+INSERT through it. The pool cap blocks other writers while the conn is held. Hotpath callers via `InsertExec(ctx, conn, ...)` were already safe (BEGIN IMMEDIATE on held conn); only `Store.Insert` (called from `buyer/billing_recorder.go::record`) was vulnerable.
- New test `TestInsertConcurrentSameGroupProducesMonotonicAttemptN` spawns 16 goroutines inserting into the same group; asserts each receives a distinct `attempt_n ∈ [0, 15]`. Pre-fix would race; post-fix passes.

**CRITICAL ARCHITECT + HIGH SECURITY: SPEC-005 stale row-3+ text + IMPL still implements the old rule.**
- Rewrote 5+ stale references across SPEC-005 (§D10 line 334; v0.3.3 quarantine paragraph 746; AC-D10 line 1270; AC-D10 fixture 1383; OQ-1 1577; AC-D10 fixture detail 2378) — all now describe row 3+ as credited normally under both the persisted `attempt_n` path AND the byte-identical id-ASC fallback.
- `hotpath.go`: quarantine condition narrowed from `in.AttemptN > 1 || (in.AttemptN == 1 && reqRow.Retried == 0)` to just `in.AttemptN == 1 && reqRow.Retried == 0` (legitimate-retry-without-marker).
- `recovery.go`: same narrowing on the `ambiguousAttempt` flag (was `attemptN > 1 || (attemptN == 1 && retried == 0) || sameRequestCount > 2`); the unconditional `if attemptN > 1 { quarantine }` branch at line 252 removed entirely.
- Tests: `TestWriteHotPath_ThirdDerivedAttemptIsAlwaysQuarantined` → renamed `TestWriteHotPath_ThirdDerivedAttemptIsCreditedUnderMonotonicAttemptN` with inverted assertion. `TestRecoverLedger_QuarantinesExistingThirdAttempt` → `TestRecoverLedger_CreditsExistingThirdAttemptUnderMonotonicAttemptN` (also rewritten to seed via `WriteHotPath` so credits match the active rate card).

**HIGH ARCHITECT: legacy-quarantine resolution claim.**
- Rewrote the change-log narrative: pre-existing quarantine rows from the v0.3.1 era remain immutable per ledger schema; v0.3.3 closes the **CREATION** class for row 3+ but does NOT introduce an unquarantine flow. Resolution of pre-existing quarantines requires the §OQ-5 admin surface (issue #169). Honest about the scope boundary.

**MEDIUM CODE: mixed-state regression test.**
- `TestBackfillAttemptNHandlesMixedRolloutState`: insert 3 rows (all populated), null out only rows 1+2, run backfill, assert sequence is `[0, 1, 2]` (row 0's persisted value preserved). Proves the ROW_NUMBER OVER PARTITION computes ordinals over ALL rows including the v1.5.2-written one, and the UPDATE filter `attempt_n IS NULL` leaves the populated row untouched.

**LOW ARCHITECT: backfill live-safety SHOULD vs MAY.**
- SPEC-002 change-log now says: SHOULD run during a maintenance window; MAY run live but operators MUST accept that the backfill UPDATE will hold the writer lock and potentially trigger 6s INSERT timeouts → buyer-visible 503s. Small corpora (single-digit-thousand legacy rows) MAY skip the window since backfill completes in tens of ms.

**LOW CODE: external API break note** — acceptable, `InsertExec` is internal-only.

**LOW ARCHITECT: future umbrella subcommand** — out of scope for #168, deferred.

### R2 audit returned
- CODE: 0 C/H/M, 1 LOW (dead `same_request_count` subquery + scan + placeholder).
- SECURITY: 1 HIGH (4 stale "row 3+ remains quarantined" references at SPEC-005 §8.2 + §10.5 + AC-ATTEMPT-FALLBACK fixture + SPEC-002 v1.5.2 change-log lines 75-76).
- ARCHITECT: 1 CRITICAL (same convergent stale text on SPEC-005 §8.2 + SPEC-002 lines 75-76) + 2 LOW (SPEC-007 design `[GAP]`; "tens of ms" empirical wording).

### R3 fixes
- Removed dead `same_request_count` subquery + scan target + placeholder in `recovery.go`.
- Rewrote ALL 4 stale references: SPEC-005 §8.2 quarantine paragraph, §10.5 "ambiguous attempt_n fallback", AC-ATTEMPT-FALLBACK fixture detail, SPEC-002 v1.5.2 change-log row-3+ wording. All now say row 3+ is credited in BOTH paths; only `attempt_n=1 retried=0` quarantined.
- SPEC-007 design notes `[GAP]` for stored `attempt_n` → `[GAP-CLOSED]` pointing at SPEC-002 v1.5.2 / #168 (both §2.3 and §3.4).
- SPEC-002 "tens of ms" empirical claim → operator-discretion-based wording.
- SPEC-005 direct-SQL-unquarantine ban added explicitly (with audit-log + invariant + cross-quarantine-class risks enumerated).

### R3 audit returned
- CODE: 0 C/H/M, 3 LOW (gofmt store.go, stale test comment, InsertExec docs).
- SECURITY: 1 MEDIUM (backfill preflight not operator-actionable — can't measure wall-clock before live commit) + 2 LOW (wrong quarantine reason strings; existing long-tx patterns).
- ARCHITECT: 1 CRITICAL (SPEC-002 `legacy` state still applied "v0.3.1 quarantine rules unchanged" — contradicts v0.3.3 row-3+ credit) + 1 HIGH (line 1703 v1.5.0 AttemptN paragraph still said "derive from COUNT" without v1.5.2 column-first read) + 1 LOW (SPEC-007 §3.4 second stale `[GAP]`).

### R4 fixes
- **CRITICAL** (architect): SPEC-002 `legacy` state text rewritten to apply v0.3.3 fallback rules (row 3+ credited normally; only `attempt_n=1 retried=0` quarantined).
- **HIGH** (architect): SPEC-002 line 1703 paragraph renamed "AttemptN read-side discipline (v1.5.2; supersedes v1.5.0 derivation rule)" and rewritten: read persisted `attempt_n` when non-NULL, fall back to v1.5.0 COUNT only when NULL, final sentence pins the row-3+ contract explicitly.
- **MEDIUM** (security): added `coordinator backfill-attempt-n --dry-run` — runs the same UPDATE inside BEGIN IMMEDIATE + ROLLBACK, captures wall-clock + rows-affected, emits a WARNING if elapsed > 4s (75% of 6s hot-path INSERT budget). Mutually exclusive with `--check`. SPEC-002 backfill live-safety paragraph rewritten to mandate `--dry-run` as operator preflight discipline.
- **LOW** (security reason strings): SPEC-005 direct-SQL ban now lists the actual quarantine reason strings.
- **LOW** (architect SPEC-007): §3.4 `[GAP]` → `[GAP-CLOSED]`.
- **LOW** (code): gofmt on store.go; updated stale `same_request_count` reference in billing test comment.

### R4 audit returned
- ARCHITECT: 0 C/H/M — **converged**.
- SECURITY: 0 C/H/M + 1 LOW (missing `conflicting_settlement_id` from the reason-string list).

### R5 NOT REQUIRED — Converged.

All three lanes at **0 CRITICAL / 0 HIGH / 0 MEDIUM**:
- CODE lane: R3 0 C/H/M (3 LOW cleanup done in R4).
- SECURITY lane: R4 0 C/H/M (final LOW — `conflicting_settlement_id` added — fixed inline before commit).
- ARCHITECT lane: R4 0 C/H/M.

Loop closed.

