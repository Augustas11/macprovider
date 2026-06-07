# Mid-stream audit prompt — SPEC-002 v1.3.5 Phase 2E

Operator-paste prompt for Codex GPT-5 to perform an adversarial
**code / security / architecture review** of commit `c8aba39` on
branch `fix/spec-002-v1-3-5-coordinator`. Phase 2E is the FIFTH and
FINAL implementation phase, adding the `internal/audit/` SQLite
infrastructure + the `operator_model_swap` payload builder + F-1.5
invariant enforcement + the wiring that hooks Phase 2C's
`pool.SwapEventEmitter` callback.

This is money-path-adjacent code: the audit log is the operator-side
forensic record of warm-swap events. A forged or missing event
distorts billing/operator-reputation visibility. Codex's audit
discipline is the non-negotiable gate before the broader pre-merge
audit across all 5 phases.

Run via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~25-40 min.
This is a **read-only** review — Codex MUST NOT modify any file.

---

```
=== BEGIN PROMPT ===

You are performing an adversarial mid-stream review of commit
`c8aba39` on branch `fix/spec-002-v1-3-5-coordinator` in
/Users/augstar/macprovider-poc. This is Phase 2E of SPEC-002
v1.3.5 — the final implementation phase. It introduces the
`internal/audit/` SQLite store, the `operator_model_swap` payload
builder + F-1.5 invariant enforcement, the main.go wiring that
hooks Phase 2C's pool.SwapEventEmitter callback, and the retention
pruner.

This is a **read-only review**. You MUST NOT edit any file.

## Context

Branch state through `c8aba39`:
- de41380 (2A): Provider struct (coordinator)
- 11bf449 + 83540b1 + c739055 (2B + R2 + R3): v2 auth_request +
  retention lifecycle
- b43e7c8 + 9d4a423 + b76a608 (2C + R2 + R2V CLEAN): ApplyHeartbeat
  REPLACEMENT + SwapEventEmitter callback contract
- c9626af + 58defb0 (2D + audit CLEAN): /v1/status SPEC-010 echo
  (gateway)
- c8aba39 (2E): **THIS commit — internal/audit + emitter wiring**

Phase 2E ships:
- New package `internal/audit/` with Store (open/migrate/insert/
  prune/close + DB() accessor) and EmitSwap entry point.
- `swapPayload` struct matching the LOCKED §7.10.2 / SPEC-011 §3.6
  schema (8 REQUIRED + 1 OPTIONAL field, omits
  drain_inflight_count_estimate intentionally per R-7.10.4).
- `assertNoForbiddenSubstrings` enforces R-7.10.9 F-1.5 invariants
  by REJECTING the payload when "conv:" or "account_id" appears
  anywhere (not log+continue — reject and drop).
- `loadingWindowMillis` computes the R-7.10.6 wall-clock duration
  with a zero-LoadingStartedAt defensive branch.
- main.go wires the audit Store on the shared cfg.Storage.DBPath,
  threads the swap emitter via providerws.WithRegistryOptions(
  pool.WithSwapEmitter(swapEmitter)), and starts
  startAuditLogRetentionPruner.
- StorageConfig.AuditLogRetentionDays defaults to 90 with
  validation rejecting <= 0.

The coordinator threat model:
- Operator binaries: SEMI-trusted. A malicious binary controls all
  fields on the heartbeat that flows into pool.SwapEvent.
- Buyers (HTTP side): UNTRUSTED — but 2E touches no buyer surface.
- High-value asset: integrity of the audit_log table. Forged events
  pollute the forensic record; missing events hide real operator
  actions; F-1.5 violations leak sticky-derivation inputs.

## Required reading (in this order)

1. The commit via `git show c8aba39`. Read the FULL diff.

2. The BUILD prompt that produced the code:
   - `specs/BUILD_SPEC_002_v1_3_5_IMPL_PHASE_2E_PROMPT.md`
   (especially constraints 1-13 and the operator-notes section
   that flagged 4 likely drift points).

3. The locked spec (READ-ONLY, do not edit):
   - `specs/SPEC-002-coordinator.md` v1.3.5 §7.10 audit-log
     infrastructure (lines 2813-2956 — schema, payload, F-1.5,
     conditional emission, future event types).
   - `specs/SPEC-002-coordinator.md` v1.3.5 §11 AC-K.9 through
     AC-K.14 + AC-K.17.
   - `specs/SPEC-011-operator-pushed-warm-swap.md` v0.5 §3.6
     R-3.6.1 through R-3.6.6 (parent payload schema, F-1.5
     rationale, conditional-emission rationale).
   - `specs/SPEC-008-coordinator-trust.md` v0.3 §5.5 (the 5-state
     hash_verification_result enum — confirm the values Phase 2E
     emits are exactly the 5 LOCKED values).

4. The implementation files (each in full):
   - `phase4-coordinator/internal/audit/store.go`
   - `phase4-coordinator/internal/audit/store_test.go`
   - `phase4-coordinator/internal/audit/swap_event.go`
   - `phase4-coordinator/internal/audit/swap_event_test.go`
   - `phase4-coordinator/internal/config/config.go` (delta only)
   - `phase4-coordinator/internal/config/config_test.go` (delta)
   - `phase4-coordinator/cmd/coordinator/main.go` (delta)
   - `phase4-coordinator/internal/ws/server_test.go` (delta — the
     end-to-end test)

5. The upstream Phase 2C surface (READ-ONLY context):
   - `phase4-coordinator/internal/pool/provider.go:430-457`
     (SwapEvent + SwapEventEmitter type + mutex contract comment).
   - `phase4-coordinator/internal/pool/provider.go:518-553`
     (Phase 2C R2's swapCompleted gate + emitter call — confirms
     what triggers Phase 2E's writes).

6. The requestlog template (read for diff comparison):
   - `phase4-coordinator/internal/requestlog/store.go`

DO NOT inspect any file under `phase3-binary/.build/checkouts/`.

## Three review dimensions

### Dimension 1: CODE REVIEW

Focus areas — adversarial discipline appropriate for money-path-
adjacent code:

- **LOCKED payload schema (AC-K.10).** Read the `swapPayload`
  struct in swap_event.go. Verify:
    - All 8 REQUIRED JSON keys are present with EXACT spelling:
      `event`, `ts`, `provider_assigned_id`, `from_model_id`,
      `to_model_id`, `to_model_hash`, `loading_window_ms`,
      `hash_verification_result`. A typo in any key is CRITICAL.
    - The OPTIONAL `from_model_hash` uses `omitempty` so an
      empty string drops the key from the marshaled output.
    - No `drain_inflight_count_estimate` field — verified by both
      reading the struct AND running
      `TestBuildSwapPayloadTopLevelKeyAllowlist`.
    - The `event` field's constant string value is exactly
      `"operator_model_swap"`. A different value (e.g., a typo)
      makes downstream analysis tools miss the row entirely.
    - `loading_window_ms` is int64 (not float64, not int). Per
      SPEC-011 R-3.6.3 "integer milliseconds" is binding.
- **`ts_utc` format (AC-K.17).** R-7.10.2 says "MUST be RFC3339
  in UTC". Phase 2E uses `time.RFC3339Nano` (with fractional
  seconds). RFC3339Nano IS a superset of RFC3339 — every
  RFC3339Nano string parses as RFC3339. Verify:
    - `TestBuildSwapPayloadTSIsRFC3339UTC` parses the `ts` field
      via `time.Parse(time.RFC3339, ...)` and confirms success.
    - The `ts_utc` column in store.Insert also uses
      `ts.UTC().Format(time.RFC3339Nano)` — same format for
      consistency between row and payload.
    - The UTC timezone is enforced (`.UTC()` before Format).
  Flag if Phase 2E's RFC3339Nano choice could break AC-K.17's
  RFC3339 assertion test in a future audit — but for v1.3.5 this
  is fine because RFC3339Nano output is RFC3339-parseable.
- **F-1.5 invariants (AC-K.11).** R-7.10.9 requires runtime
  enforcement. Phase 2E implements via `assertNoForbiddenSubstrings`.
  Verify:
    - The forbidden list is exactly `"conv:"` and `"account_id"`.
      Case-sensitive (per the spec literal wording).
    - The function iterates bytes ONCE and checks each
      forbidden substring at each position. Linear in payload
      length. Verify no O(N²) pathological case (e.g., a
      regex that backtracks).
    - `EmitSwap` calls `assertNoForbiddenSubstrings` AFTER
      `buildSwapPayload` AND BEFORE `Insert`. Order matters: if
      the assertion runs before payload build, it has nothing
      to check; if it runs after insert, the violating row is
      already written.
    - The rejection path returns an error to the emitter closure
      in main.go. The closure logs WARN with the full payload
      preserved (via the `payload_json=%s` wrap in EmitSwap's
      error message — verify this is the actual behavior, not
      a comment that doesn't match the code).
    - `TestSwapEventPayloadEnforcesF15Invariants` covers the
      `conv:` case AND the `account_id` case AND asserts NO row
      was inserted (e.g., by querying COUNT(*) FROM audit_log).
- **R-7.10.8 best-effort write (AC-K.13).** The Phase 2C
  SwapEventEmitter signature is `func(SwapEvent)` (no error
  return) by design. Phase 2E's emitter closure in main.go MUST:
    - Catch any error from EmitSwap.
    - Log at WARN level with full payload context.
    - Return cleanly (no panic, no propagation).
  Verify:
    - The closure does NOT log at ERROR or FATAL (which could
      trigger alerting).
    - The closure does NOT call os.Exit, panic, or log.Fatal.
    - The WARN log includes ALL the SwapEvent fields needed for
      forensic recovery: provider_id, assigned_id,
      from_model_id, to_model_id, to_model_hash,
      loading_window_ms, hash_verification_result.
    - A test (`TestEmitterDoesNotPanicOnSQLiteFailure` —
      verify it exists OR is covered by the integration test
      `TestHeartbeatSwapEmitterWritesAuditLogRow` with a closed
      DB variant).
- **Mutex-held caller contract.** Phase 2C's emitter
  documentation (`provider.go:440-457`) says callers MUST NOT
  call back into Registry methods (deadlock risk) and MUST NOT
  block for long. Verify Phase 2E's EmitSwap:
    - Does NOT import pool's Registry (only the pool.SwapEvent
      type). A pool.Registry call from EmitSwap would deadlock.
    - The SQLite Insert is the single I/O operation. With the
      5-second busy_timeout, worst-case latency is 5s — flag if
      this could starve heartbeat processing on a busy DB.
- **`loading_window_ms` computation (AC-K.10 / R-7.10.6).** Verify:
    - `loadingWindowMillis` returns 0 when
      `event.LoadingStartedAt.IsZero()`. This branch is defensive
      — Phase 2C's gate requires priorLoadingState=true (which
      means LoadingStartedAt was stamped on a prior heartbeat),
      so in practice IsZero() should never be true. But verify
      the defensive branch doesn't silently emit 0 for a
      legitimate non-zero LoadingStartedAt.
    - The computation uses `event.CompletedAt.Sub(
      event.LoadingStartedAt).Milliseconds()` — correct units.
    - A NEGATIVE duration (CompletedAt < LoadingStartedAt) is
      possible if the coordinator clock skewed. The function
      returns a negative int64 silently. Is this a Phase 2E
      bug or an inherent limitation? Both timestamps are coordinator-
      clock (per R-7.10.6), so clock skew between them is zero —
      unless the system clock jumped backward. Flag if you'd
      prefer a max(0, duration) clamp.
- **SQLite schema (AC-K.17).** Verify the migration CREATE TABLE
  + 3 CREATE INDEX statements match §7.10.1 R-7.10.1 EXACTLY:
    - Table name `audit_log`.
    - Columns: `id` INTEGER PRIMARY KEY AUTOINCREMENT, `ts_utc`
      TEXT NOT NULL, `event_type` TEXT NOT NULL, `provider_id`
      TEXT (NULL-able — no NOT NULL), `payload_json` TEXT NOT
      NULL.
    - Indexes: `idx_audit_log_ts_utc` on `ts_utc`,
      `idx_audit_log_provider_id` on `provider_id`,
      `idx_audit_log_event_type` on `event_type`.
    - Each `IF NOT EXISTS` is idempotent — confirm.
- **`provider_id` NULL semantics.** Verify:
    - `Insert` with empty providerID stores SQL NULL (via
      sql.NullString) — NOT empty string.
    - The integration test queries the column and asserts NULL
      vs "".
    - `operator_model_swap` events always set providerID (Phase
      2C's SwapEvent.ProviderID is the operator-issued provider
      ID), so the NULL path is exercised only by future event
      types — but the storage layer must support it.
- **`PruneBefore` semantic (AC-K.14).** The Phase 2E pruner uses
  `julianday(ts_utc) < julianday(?)`. Verify:
    - The comparison is `<` (strict), matching the requestlog
      precedent.
    - julianday() converts both sides to a numeric Julian Date,
      so format drift (RFC3339 vs RFC3339Nano vs plain `Z` vs
      `+00:00`) doesn't break ordering.
    - `TestPruneBeforeRemovesOlderRows` exercises the boundary
      condition (rows exactly at the cutoff stay, rows older
      get pruned).
- **End-to-end integration (AC-K.9).** The test
  `TestHeartbeatSwapEmitterWritesAuditLogRow` covers the
  Phase 2C → Phase 2E pipeline. Verify:
    - The test registers a v2 auth provider (consistent with
      Phase 2B's lifecycle).
    - Sends heartbeat with loading=true + model_hash + ModelID="A".
    - Sends heartbeat with loading=false + new model_hash +
      ModelID="B".
    - Queries audit_log via eventually(), asserts EXACTLY ONE row
      with event_type="operator_model_swap".
    - Asserts the payload's `from_model_id`, `to_model_id`, and
      `loading_window_ms` are correct (the latter computed from
      the test's clock).
- **`go test -race -count=1 ./...` cleanliness.** Phase 2E uses
  SQLite from a test goroutine + the heartbeat goroutine. Verify
  no data races emerge under -race.

Findings format:
```
[code:N.M] [SEVERITY] <short title>
  File: <path>:<line>
  What: <description>
  Why: <impact>
  Fix: <remediation>
```

### Dimension 2: SECURITY REVIEW

Threat model: a malicious provider binary controls every byte of
heartbeats that flow into pool.SwapEvent. A compromised binary
could:
- Send crafted model_id / model_hash values designed to bypass
  F-1.5 (e.g., URL-encoded variants of "conv:" or "account_id").
- Force rapid swap-event emission to flood the audit_log and
  exhaust disk space.
- Send loading=true → loading=false on the same model_id (Phase
  2C R2 already gates this off — verify the gate holds in
  Phase 2E's integration test).
- Forge LoadingStartedAt indirectly (via heartbeat timing) to
  inflate or deflate loading_window_ms (Phase 2C stamps server-
  side, so this is bounded).

Focus areas:

- **F-1.5 evasion vectors.** The substring check is literal
  byte-match. Verify:
    - A model_id like `"my-conv%3Ax"` (URL-encoded `:`) does NOT
      trigger the gate — but DOES contain "conv" without the
      colon. Is "conv" without the colon a banned substring?
      Per R-3.6.5 the banned prefix is `"conv:"` specifically
      (with the colon). So the URL-encoded form bypasses by
      design. Flag only if the spec wants the broader ban.
    - A model_id with the colon at a string boundary (e.g.,
      `"conv:"` at the end of a string) is caught — the
      byte-loop doesn't require word boundaries.
    - Unicode that LOOKS like `c` (e.g., Cyrillic с) but isn't
      ASCII does NOT trigger. Per R-3.6.5 the substring is
      literal — Cyrillic-spoofed "сonv:" does not match. This
      is per spec; flag only if you'd recommend a broader
      Unicode-NFC normalize first.
    - The check runs AFTER json.Marshal escapes special bytes.
      An attacker who sends `"conv:"` (unicode escape for
      colon) gets json.Marshal output containing literal `conv:`
      bytes — the check catches this. Verify by reading the
      test or running it mentally.
- **DoS via audit_log floods.** A malicious operator could
  toggle warm-swap rapidly (loading:true → false on different
  model_ids back-and-forth). Each cycle writes a row. With
  no rate limit, disk fills. Phase 2E's pruner runs once per
  24h — could the disk fill in <24h? Worst case: heartbeat every
  5s × ~150-byte payload = ~2.6 MB/day. 90-day retention = ~230
  MB cap. Not a real DoS risk. Flag only if SPEC mandates a
  per-provider rate limit (it doesn't).
- **Disk-pressure interaction with R-7.10.8.** If the SQLite
  write fails due to disk-full, EmitSwap returns an error,
  the emitter closure logs WARN, heartbeat processing
  continues. Verify no path where disk-full causes a panic
  or unbounded retry loop.
- **PRAGMA settings.** `journal_mode=WAL` + `busy_timeout=5000`
  match the requestlog pattern. Verify the WAL file is on the
  same filesystem as the DB (it must be — same DBPath). No
  separate config for WAL location.

Findings format:
```
[sec:N.M] [SEVERITY] <short title>
  Asset: <what's at risk>
  Vector: <how a malicious provider binary exploits it>
  File: <path>:<line>
  Fix: <remediation>
```

### Dimension 3: ARCHITECTURE REVIEW

Focus areas:

- **Package boundary.** `internal/audit/` imports `pool` for
  SwapEvent + HashStatus types. This couples audit to pool's
  data model. Is that the right direction, or should SwapEvent
  live in audit (with pool emitting an interface)? Trade-off:
  current direction matches the v1.3.5 spec (SwapEvent is a
  pool-layer concept consumed by audit); reversal would force
  pool to know about audit which is worse coupling.
- **`startAuditLogRetentionPruner` reuses the existing
  `requestLogPruner` interface.** Per the BUILD prompt this was
  intentional. Verify the implementation uses the same
  interface (not a parallel `auditLogPruner`).
- **`shutdownCtx` capture by the emitter closure.** The closure
  captures `shutdownCtx`; if shutdown fires mid-Insert, the
  SQLite call returns a context-cancelled error which the
  closure logs WARN. This is correct R-7.10.8 behavior. Flag
  if you spot a path where shutdown leaks the emitter call.
- **`Insert(ctx, ts, eventType, providerID, payloadJSON)`
  generic signature.** Designed for R-7.10.11 future event
  types. Verify it doesn't expose internal SwapEvent details
  (it takes payloadJSON as a string, so the caller is
  responsible for marshaling). A future event type can use
  Insert directly without coupling.
- **Error wrapping discipline.** EmitSwap wraps errors with
  `payload_json=%s` for forensic recovery. Verify this doesn't
  leak unwanted bytes into structured logs (e.g., if the
  emitter closure uses Err(err) and the structured logger
  field-extracts, the payload bytes would land in a single
  string field — acceptable for forensic purposes).
- **Cross-codebase awareness.** Phase 2D edits phase5-gateway;
  Phase 2E edits phase4-coordinator. The branch crosses both
  codebases. Verify Phase 2E's commit message and the
  branch's overall PR description (when drafted) make this
  cross-codebase nature visible to reviewers.
- **The `DB()` accessor.** Phase 2E exposes Store.DB() — is
  this needed? requestlog.Store also exposes DB(); admission
  store reuses it. Phase 2E's caller doesn't currently use
  audit.Store.DB() — if no caller needs it, removing it
  reduces the API surface. Flag as MINOR if unused.
- **Test placement of `TestHeartbeatSwapEmitterWritesAuditLogRow`.**
  This is an end-to-end test that lives in `internal/ws/server_test.go`.
  An alternative would be `internal/audit/integration_test.go`.
  Trade-off: ws/ has the harness for the end-to-end pipeline;
  duplicating that in audit/ would be heavy. Current placement
  is correct.

Findings format:
```
[arch:N.M] [SEVERITY] <short title>
  What: <description>
  Trade-off: <gain vs loss>
  Suggestion: <concrete refactor>
```

## Severity scale

- **CRITICAL** — must be fixed before pre-merge audit / merge.
  Breaks the LOCKED payload schema (any of 8 REQUIRED fields
  missing or wrong type/name), violates F-1.5 silently, allows
  the emitter to propagate errors into ApplyHeartbeat
  (deadlock/crash), or breaks AC-K acceptance criterion.
- **MAJOR** — should be fixed before merge. Real bug, real
  impact.
- **MINOR** — would improve the code; does not block.

## Output format

```
# SPEC-002 v1.3.5 Phase 2E mid-stream audit — Codex GPT-5

## Verdict

<one-line: PROCEED-TO-PRE-MERGE-AUDIT | FIX-THEN-PROCEED | BLOCK>

## Counts

| Dimension | CRITICAL | MAJOR | MINOR |
|---|---:|---:|---:|
| Code         | <N> | <N> | <N> |
| Security     | <N> | <N> | <N> |
| Architecture | <N> | <N> | <N> |
| **Total**    | <N> | <N> | <N> |

## Findings

### Code review
[code:1.1] [SEVERITY] ...

### Security review
[sec:1.1] [SEVERITY] ...

### Architecture review
[arch:1.1] [SEVERITY] ...

## AC traceability

| AC | Where satisfied | Test name |
|---|---|---|
| AC-K.9 (exactly-once emission, full closure) | <file:line> | <test> |
| AC-K.10 (payload schema 8 REQUIRED + 2 OPTIONAL) | <file:line> | <test> |
| AC-K.11 (F-1.5 invariants enforced at runtime) | <file:line> | <test> |
| AC-K.13 (audit write failure tolerance) | <file:line> | <test> |
| AC-K.14 (retention pruning) | <file:line> | <test> |
| AC-K.17 (table schema + ts_utc RFC3339 UTC) | <file:line> | <test> |

## Build / vet / race / suite evidence

Paste outputs from:
  cd /Users/augstar/macprovider-poc/phase4-coordinator
  go build ./...
  go vet ./...
  gofmt -l ./internal/ ./cmd/
  go test -race -count=1 ./internal/audit/...
  go test -race -count=1 ./...

## Cross-cutting observations

<patterns spanning findings>
```

## Discipline

- LOCKED payload schema violations are CRITICAL (any of the 8
  REQUIRED keys missing or misspelled or wrong type).
- F-1.5 silent failures (no rejection, no test) are CRITICAL.
- R-7.10.8 propagation-to-heartbeat-handler errors are CRITICAL
  (would crash the WS loop).
- Cite file:line + binding spec rule for every finding.
- Zero findings is a valid result.

You may run shell commands (git, grep, go build/vet/test
-race). You MUST NOT modify any file.

You may take up to 40 minutes wall-clock.

=== END PROMPT ===
```

---

## Operator notes

- This audit is the last gate before the broader full pre-merge
  audit across all 5 phases. Phase 2E surface is the largest
  single-phase surface (4 new files + main.go wiring + config).
- Expected outcome: likely a MINOR or two on edge cases (e.g.,
  negative loading_window_ms clamp, unused DB() accessor). I'd be
  surprised by a CRITICAL given the F-1.5 enforcement was
  explicit in the BUILD prompt and the integration test
  exercises the full pipeline.
- If CRITICAL/MAJOR, R2 inline (small surface) then R2V; if
  CLOSED-CLEAN or MINOR-only, proceed to the broader pre-merge
  audit (the one modeled after PR #5's
  AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md).

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7).
