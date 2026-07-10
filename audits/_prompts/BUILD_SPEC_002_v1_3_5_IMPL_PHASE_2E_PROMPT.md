# Implementation BUILD prompt — SPEC-002 v1.3.5 Phase 2E (audit-log infrastructure + operator_model_swap emitter)

Operator-paste prompt for Codex GPT-5 to land the **fifth and final**
implementation sub-phase of SPEC-002 v1.3.5. This phase closes the
acceptance-criteria matrix AC-K.9 through AC-K.14 + AC-K.17 by
adding a new `internal/audit/` SQLite store, the `operator_model_swap`
payload builder, the F-1.5 payload invariant enforcement, and the
wiring that hooks Phase 2C's `pool.SwapEventEmitter` callback to the
SQLite write.

**Scope: SQLite audit-log infrastructure + operator_model_swap
emitter.** No new endpoints, no /v1/status changes (Phase 2D already
shipped), no ApplyHeartbeat changes (Phase 2C is locked).

**One-line summary.** Create
`phase4-coordinator/internal/audit/{store.go,swap_event.go,*_test.go}`
implementing the §7.10.1 SQLite schema (table + 3 indexes), the
§7.10.2 `operator_model_swap` payload (8 REQUIRED + 2 OPTIONAL fields,
byte-for-byte from locked source), the R-7.10.9 F-1.5 invariant
enforcement (static grep + runtime substring assertion), the
R-7.10.8 best-effort write semantics (WARN-log on SQLite failure,
never block heartbeat). Add a `StorageConfig.AuditLogRetentionDays`
field (default 90) and a retention pruner mirroring the existing
request_log pruner. Wire the emitter in `cmd/coordinator/main.go`
via `providerws.WithRegistryOptions(pool.WithSwapEmitter(...))`. Add
a `loading_window_ms` computation from `SwapEvent.LoadingStartedAt`
to `SwapEvent.CompletedAt` per R-7.10.6. The LastLoadingState sticky
reset (R-7.1.6) is ALREADY handled by Phase 2C's per-heartbeat
LastLoadingState write at `provider.go:516`; Phase 2E does NOT
touch LastLoadingState.

**Locked-spec dependencies (DO NOT contradict).**
- SPEC-002 v1.3.5 §7.10.1 (SQLite schema, lines 2821-2845),
  §7.10.2 (`operator_model_swap` event LOCKED schema, lines 2847-2947),
  §11 AC-K.9 through AC-K.14 + AC-K.17.
- SPEC-011 v0.5 §3.6 R-3.6.1 through R-3.6.6 (payload schema +
  conditional emission rationale + F-1.5 invariants).
- SPEC-008 v0.3 §5.5 (the 5-state hash_verification_result enum).
- Phase 2C commits `b43e7c8` + `9d4a423` (the upstream
  `pool.SwapEvent` + `pool.SwapEventEmitter` types — read-only here).
- The existing `internal/requestlog/store.go` + the
  `startRequestLogRetentionPruner` in `cmd/coordinator/main.go` are
  the binding templates for the new audit store + pruner.

This is a **code-only** session. No spec edits. Verify with
`git diff specs/` — must be empty.

Run in **Codex CLI** via `omc ask codex` from session root
`/Users/augstar/macprovider-poc`. Expected wall-clock: ~120-180 min
(new package + SQLite migrations + payload schema + F-1.5
runtime/static checks + main.go wiring + integration test).

Branch: `fix/spec-002-v1-3-5-coordinator` (tip `58defb0`). Codex
MUST NOT create a new branch.

---

```
=== BEGIN PROMPT ===

You are implementing Phase 2E of SPEC-002 v1.3.5 in the Go
coordinator at /Users/augstar/macprovider-poc/phase4-coordinator/.
This is the final implementation phase. Phase 2C
(b43e7c8 + 9d4a423) already shipped the
`pool.SwapEvent`/`pool.SwapEventEmitter` types and the gate that
calls the emitter when a swap completes. Phase 2E's job is to
register a non-nil emitter that writes to SQLite.

You will edit/create the following files (and ONLY these):

  phase4-coordinator/internal/audit/store.go             (NEW)
  phase4-coordinator/internal/audit/store_test.go        (NEW)
  phase4-coordinator/internal/audit/swap_event.go        (NEW)
  phase4-coordinator/internal/audit/swap_event_test.go   (NEW)
  phase4-coordinator/internal/config/config.go           (extend)
  phase4-coordinator/internal/config/config_test.go      (extend — light)
  phase4-coordinator/cmd/coordinator/main.go             (extend — wiring)
  phase4-coordinator/internal/ws/server_test.go          (extend — 1 E2E test)

You will NOT edit any file under `specs/`, `beta/`,
`phase3-binary/`, `phase5-gateway/`, any Phase 2A-2D file outside
the surfaces named below, or any other file in
`phase4-coordinator/`. Verify the edit set with:

  git diff --name-only HEAD \
    | grep -vE '^phase4-coordinator/(internal/audit/(store|store_test|swap_event|swap_event_test)\.go|internal/config/config(_test)?\.go|cmd/coordinator/main\.go|internal/ws/server_test\.go)$' \
    | wc -l

The output MUST be `0`.

## Critical constraints

**1. The `operator_model_swap` payload schema is LOCKED byte-for-
byte per SPEC-011 v0.5 §3.6 / SPEC-002 v1.3.5 §7.10.2.** Field names,
types, units, and presence are normative. The 8 REQUIRED fields
(MUST be present on every emission):

| JSON key | Type | Source |
|---|---|---|
| `event` | string, constant `"operator_model_swap"` | hardcoded |
| `ts` | RFC3339 UTC timestamp (with `Z` suffix or `+00:00`) | `event.CompletedAt.UTC().Format(time.RFC3339)` |
| `provider_assigned_id` | string | `event.AssignedID` |
| `from_model_id` | string | `event.FromModelID` |
| `to_model_id` | string | `event.ToModelID` |
| `to_model_hash` | string, raw 64-char lowercase hex | `event.ToModelHash` |
| `loading_window_ms` | int64 milliseconds | computed (see constraint 3) |
| `hash_verification_result` | string, one of 5 SPEC-008 §5.5 enum values | `string(event.HashVerificationResult)` |

The 2 OPTIONAL fields:

| JSON key | Type | Rule |
|---|---|---|
| `from_model_hash` | string OR empty string | emit when `event.FromModelHash != ""`; OMIT entirely when empty (NOT `null`, NOT `""`) |
| `drain_inflight_count_estimate` | int64 OR omitted | OMIT in v1.3.5 (Phase 2C's SwapEvent doesn't carry it; Phase 2E does not add it). Document the omission in a code comment citing SPEC-002 v1.3.5 R-7.10.4 ("MAY be omitted; observability-only"). |

NO other top-level keys are part of the v1.3.5 contract — future
event types or extensions are out of scope per §7.10.3 R-7.10.11.
A regression test MUST assert the marshaled payload's top-level
key set against the locked allowlist.

**2. SQLite schema is LOCKED per §7.10.1 R-7.10.1.** Migration:

    CREATE TABLE IF NOT EXISTS audit_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_utc TEXT NOT NULL,
        event_type TEXT NOT NULL,
        provider_id TEXT,
        payload_json TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_audit_log_ts_utc ON audit_log(ts_utc);
    CREATE INDEX IF NOT EXISTS idx_audit_log_provider_id ON audit_log(provider_id);
    CREATE INDEX IF NOT EXISTS idx_audit_log_event_type ON audit_log(event_type);

Column names, types, indexes, and order are normative per §7.10.1.
`provider_id` is NULL-able to support future event types that
aren't provider-scoped. For `operator_model_swap`, write the
operator-issued `provider_id` (`event.ProviderID`), NOT the
per-session `assigned_id` (which goes inside the payload as
`provider_assigned_id` per R-7.10.5).

**3. `loading_window_ms` computation per R-7.10.6.** Wall-clock
duration in integer milliseconds from `event.LoadingStartedAt` to
`event.CompletedAt`. Both are coordinator-clock timestamps stamped
by Phase 2C's ApplyHeartbeat. Implementation:

    func loadingWindowMillis(event pool.SwapEvent) int64 {
        if event.LoadingStartedAt.IsZero() {
            return 0
        }
        return event.CompletedAt.Sub(event.LoadingStartedAt).Milliseconds()
    }

The zero-LoadingStartedAt branch is defensive — it shouldn't happen
in practice because Phase 2C's gate requires `priorLoadingState ==
true`, which means LoadingStartedAt was stamped on a prior
heartbeat. Defensive: emit 0 and log at WARN (do NOT skip the
event — the spec mandates the field).

**4. F-1.5 payload invariants per R-7.10.9.** The payload MUST NOT
contain any of:
  - the literal substring `"conv:"` (case-sensitive)
  - the literal substring `"account_id"` (case-sensitive)
  - sticky session identifiers (in v1.3.5 there are no such inputs
    on SwapEvent, but enforce the rule defensively)
  - buyer prompt text (none on SwapEvent — defensive)

Enforcement is twofold:
  a. **Static guard:** the payload builder ONLY reads fields from
     `pool.SwapEvent`. No other inputs are wired through. A code
     comment at the builder explicitly cites R-7.10.9 + R-3.6.5.
  b. **Runtime regression test:** the test builds a SwapEvent
     containing the forbidden substrings IN ALL TEXTUAL FIELDS
     (`FromModelID = "mlx-community/conv:bad"`,
     `ToModelID = "account_id/x"`, etc.), serializes the payload,
     and asserts the marshaled JSON does NOT contain the forbidden
     substrings ANYWHERE. (A model_id that legitimately contains
     "conv:" would fail this test — but that's intentional because
     no real model_id contains the prefix; if it ever does, the
     spec's invariant prevails over the data.) The test name is
     `TestSwapEventPayloadEnforcesF15Invariants`.

  Actually — wait. The model_id field IS user-controlled. A
  malicious operator could set `--supported-models conv:evil` on
  the binary. The F-1.5 invariant means the coordinator MUST NOT
  emit such input verbatim in the payload. So the runtime
  enforcement is REJECTION at payload build time, not just
  assertion in tests. Implement as:

      func (s *Store) emitSwap(ctx context.Context, event pool.SwapEvent) error {
          payload, err := buildSwapPayload(event)
          if err != nil {
              return err
          }
          if err := assertNoForbiddenSubstrings(payload); err != nil {
              // F-1.5 violation in the payload — drop the event,
              // log at WARN with the full payload available in
              // process logs only. NEVER write the row.
              return err
          }
          return s.Insert(ctx, ...)
      }

  Forbidden-substring list:
      "conv:" (any case-sensitive occurrence)
      "account_id" (any case-sensitive occurrence)

  Implement `assertNoForbiddenSubstrings` as a tight function that
  iterates the bytes once. Cite R-7.10.9 + R-3.6.5 in the comment.

**5. R-7.10.8 best-effort write semantics.** A SQLite Insert error
MUST NOT propagate up to the Phase 2C emitter caller. The emitter
closure wired in main.go MUST capture the error, log at WARN level
with the full payload available in the log context (so operators
can recover via process logs), and return. The Phase 2C emitter
is `func(SwapEvent)` (no error return) — this is by design.
Implementation:

    swapEmitter := func(event pool.SwapEvent) {
        if err := auditStore.EmitSwap(ctx, event); err != nil {
            logger.Warn().
                Err(err).
                Str("provider_id", event.ProviderID).
                Str("assigned_id", event.AssignedID).
                Str("from_model_id", event.FromModelID).
                Str("to_model_id", event.ToModelID).
                Str("to_model_hash", event.ToModelHash).
                Int64("loading_window_ms", loadingWindowMillis(event)).
                Str("hash_verification_result", string(event.HashVerificationResult)).
                Msg("operator_model_swap audit write failed")
        }
    }

  Test `TestEmitterDoesNotPanicOnSQLiteFailure` simulates a closed
  DB and confirms the emitter returns cleanly.

**6. The Phase 2C ApplyHeartbeat caller invokes the emitter UNDER
THE REGISTRY MUTEX.** Phase 2C's `pool.SwapEventEmitter`
documentation (see `provider.go:440-457`) says emitters MUST NOT
call back into Registry methods (deadlock risk) and MUST NOT block
for long. The Phase 2E emitter:
  - Calls `auditStore.EmitSwap(ctx, event)` — a SQLite Insert.
  - Does NOT call back into pool/Registry (no symmetric write).
  - SQLite Insert is typically <1ms; if the DB is busy and the
    5-second busy_timeout fires, the heartbeat handler stalls for
    up to 5 seconds. This is acceptable per the locked
    requestlog/store.go pattern and per R-7.10.8 (best-effort).
  - Document the mutex-held caller assumption in the
    `audit.Store.EmitSwap` doc comment.

**7. R-7.10.10 conditional emission is upstream-enforced.** Phase
2C's `swapCompleted` gate (`provider.go:531-541`) already gates on
`priorLoadingState && hb.LoadingPresent && !hb.Loading &&
modelIDChanged`. Phase 2E does NOT add any further conditional
logic to the emitter — it writes whatever the upstream gate
emits. R-7.10.10's WS-drop case is naturally handled: a new
session starts with priorLoadingState=false, so the gate doesn't
fire.

**8. R-7.10.11 future extensibility.** The `audit.Store` API
exposes a generic `Insert(ctx, ts, eventType, providerID,
payloadJSON)` for future event types. v1.3.5 ships only
`operator_model_swap`. Tests verify the generic Insert works for
arbitrary event_type strings.

**9. Retention pruner per R-7.10.2 / AC-K.14.** Add to
`StorageConfig`:

    AuditLogRetentionDays int `yaml:"audit_log_retention_days"`

with default `90` in `Default()`. Validation: must be > 0. Add a
`startAuditLogRetentionPruner` to `cmd/coordinator/main.go` that
mirrors `startRequestLogRetentionPruner` exactly. The audit
`Store` satisfies the existing `requestLogPruner` interface (via
its `PruneBefore(ctx, cutoff) (int64, error)` method) — REUSE
that interface, do NOT define a parallel `auditLogPruner`
interface.

**10. main.go wiring sequence.** Insert the new code AFTER the
existing `requestlog.OpenStore` block (around `main.go:52-57`) and
BEFORE `admissionStore` opens. The audit store uses the same
`cfg.Storage.DBPath` (single SQLite file holds all coordinator
tables — see requestlog precedent). The Pruner starts AFTER
`startRequestLogRetentionPruner`. The emitter closure is built
right before `wsServer := providerws.NewServer(...)` and threaded
via:

    wsOpts = append(wsOpts, providerws.WithRegistryOptions(
        pool.WithSwapEmitter(swapEmitter),
    ))

`providerws.WithRegistryOptions` was added in Phase 2C exactly for
this case.

**11. The shutdownCtx is the audit emitter's context.** The
emitter closure captures `shutdownCtx` (declared at `main.go:108`)
so audit writes get cancelled during shutdown. Wait — that's
DIFFERENT from the requestlog use case. Look at how requestlog
writes are scoped (per-request, with a request-scoped context)
versus how audit writes happen (inside ApplyHeartbeat, which has
no caller-supplied context). For audit, use shutdownCtx as the
capture; if shutdown fires mid-write, the SQLite Insert returns a
context-cancelled error, which the emitter logs at WARN and
ignores. This is the spec-correct best-effort behavior.

**12. `gofmt -l ./internal/...` clean. `go vet ./...` clean.
`go test -race -count=1 ./...` clean for the WHOLE coordinator
module — this is the final phase, the whole suite must be green.**

**13. No spec/handoff/DECISION_CRITERIA/BUILD/AUDIT prompt
edits.** Verify with `git diff specs/ beta/ phase3-binary/
phase5-gateway/` — empty.

## Required reading (in this order)

1. `specs/SPEC-002-coordinator.md` lines 2813-2956 (§7.10
   audit-log infrastructure, LOCKED).
2. `specs/SPEC-002-coordinator.md` lines 3675-3765 (AC-K.9
   through AC-K.14, AC-K.17 — these are the test oracles).
3. `specs/SPEC-011-operator-pushed-warm-swap.md` §3.6 R-3.6.1
   through R-3.6.6 (the parent payload schema + rationale).
4. `phase4-coordinator/internal/requestlog/store.go` (the
   template for the new audit Store — open/migrate/insert/prune
   pattern).
5. `phase4-coordinator/internal/pool/provider.go:430-457` (the
   SwapEvent + SwapEventEmitter types — the Phase 2C contract).
6. `phase4-coordinator/internal/pool/provider.go:518-553` (Phase
   2C R2's swapCompleted gate + emitter call — confirms what
   triggers the emit).
7. `phase4-coordinator/cmd/coordinator/main.go:50-180` (existing
   wiring + pruner template).
8. `phase4-coordinator/internal/config/config.go:155-170`
   (StorageConfig — the field add site).

## Required edits — exact shape

### `internal/audit/store.go`

Mirror `internal/requestlog/store.go` structure:

  - package: `audit`
  - imports: `context, database/sql, errors, fmt, os, path/filepath, time, sqliteutil, _ "modernc.org/sqlite"`
  - type `Store struct { db *sql.DB }`
  - `func OpenStore(dbPath string) (*Store, error)` — opens SQLite
    (WAL + busy_timeout 5000), runs migrate(), returns Store.
  - `func (s *Store) Close() error` — closes DB.
  - `func (s *Store) DB() *sql.DB` — accessor.
  - `func (s *Store) migrate(ctx context.Context) error` — runs
    the LOCKED CREATE TABLE + 3 indexes.
  - `func (s *Store) Insert(ctx context.Context, ts time.Time,
    eventType, providerID, payloadJSON string) error` —
    parameterized INSERT into audit_log. providerID empty string
    becomes SQL NULL.
  - `func (s *Store) PruneBefore(ctx context.Context, cutoff
    time.Time) (int64, error)` — DELETE WHERE ts_utc < cutoff;
    returns rows affected.
  - `func (s *Store) EmitSwap(ctx context.Context, event
    pool.SwapEvent) error` — builds payload via
    `buildSwapPayload`, enforces F-1.5 via
    `assertNoForbiddenSubstrings`, calls Insert with eventType =
    `"operator_model_swap"` + providerID = event.ProviderID + ts
    = event.CompletedAt.UTC().
  - The pool package is imported as
    `github.com/augstar/macprovider-coordinator/internal/pool`.

### `internal/audit/swap_event.go`

  - package: `audit`
  - imports: `bytes, encoding/json, fmt, strings, time, pool`
  - `func buildSwapPayload(event pool.SwapEvent) ([]byte, error)` —
    builds a `map[string]any` or a dedicated struct with the 8
    REQUIRED fields, conditionally adds `from_model_hash` when
    non-empty, MARSHALS to JSON via json.Marshal, returns the
    bytes. Key order is whatever Go's encoding/json produces
    (sorted alphabetically by map key for `map[string]any`,
    declaration order for struct). The locked SPEC doesn't
    mandate key order; the v1.3.5 example payload has a specific
    order but only field NAMES are LOCKED.

    Use a struct (not map) for deterministic order and Go-idiomatic
    style:

        type swapPayload struct {
            Event                       string `json:"event"`
            TS                          string `json:"ts"`
            ProviderAssignedID          string `json:"provider_assigned_id"`
            FromModelID                 string `json:"from_model_id"`
            FromModelHash               string `json:"from_model_hash,omitempty"`
            ToModelID                   string `json:"to_model_id"`
            ToModelHash                 string `json:"to_model_hash"`
            LoadingWindowMs             int64  `json:"loading_window_ms"`
            HashVerificationResult      string `json:"hash_verification_result"`
            // SPEC-002 v1.3.5 R-7.10.4 — drain_inflight_count_estimate
            // is OPTIONAL and MAY be omitted; observability-only. v1.3.5
            // ships without it because Phase 2C's SwapEvent doesn't
            // carry the inflight count, and adding it would require
            // a Phase 2C reach-back. Tracked as a follow-up if
            // operators want it.
        }

    `from_model_hash,omitempty` means an empty string drops the
    key from the marshaled output — matches the R-7.10.4 OPTIONAL
    rule.

  - `func loadingWindowMillis(event pool.SwapEvent) int64` — per
    constraint 3 above.

  - `func assertNoForbiddenSubstrings(payload []byte) error` —
    per constraint 4 above. Forbidden list as a small package-
    private slice of byte slices.

### `internal/audit/store_test.go`

  - `TestOpenStoreCreatesAuditLogSchema` — open store, query
    sqlite_master for table + 3 indexes, assert all 4 names
    present.
  - `TestInsertAndReadBack` — Insert with a specific timestamp +
    event_type + provider_id + payload, query SELECT, assert all
    fields round-trip.
  - `TestInsertWithEmptyProviderIDStoresNull` — Insert with
    providerID="", query SELECT provider_id, assert NULL not "".
    (Use `sql.NullString` to detect.)
  - `TestPruneBeforeRemovesOlderRows` — Insert 3 rows with
    timestamps -2, -1, +0 days. PruneBefore(now - 1 day +
    epsilon). Assert 2 rows deleted (the -2 and the -1, since
    cutoff is strict <). Adjust the test to assert against the
    actual <= vs < semantic — pick one and document; the
    requestlog pruner uses `<` per its existing code.

### `internal/audit/swap_event_test.go`

  - `TestBuildSwapPayloadIncludes8RequiredKeys` — build payload
    with all fields set (FromModelHash present), unmarshal to
    map[string]any, assert the 8 REQUIRED keys are present with
    correct types. Assert the OPTIONAL from_model_hash IS present
    (because it's non-empty). Assert NO `drain_inflight_count_estimate`
    key.
  - `TestBuildSwapPayloadOmitsEmptyFromModelHash` — build payload
    with FromModelHash="", unmarshal to map[string]any, assert
    `from_model_hash` key is ABSENT.
  - `TestBuildSwapPayloadTopLevelKeyAllowlist` — build a payload,
    unmarshal to map[string]any, assert the key set is a SUBSET
    of the v1.3.5 contract: `{"event", "ts", "provider_assigned_id",
    "from_model_id", "from_model_hash", "to_model_id", "to_model_hash",
    "loading_window_ms", "hash_verification_result"}`. Any
    out-of-set key fails — guards against future v1.3.5 schema
    drift.
  - `TestBuildSwapPayloadTSIsRFC3339UTC` — build payload, parse
    `ts` with time.Parse(time.RFC3339, ...) and assert success.
    Assert the parsed time is in UTC.
  - `TestSwapEventPayloadEnforcesF15Invariants` — build SwapEvent
    with `FromModelID="mlx/conv:evil"`, ToModelID containing
    `account_id`, etc. Call `EmitSwap` against an open Store;
    assert it returns a non-nil error (the F-1.5 guard rejected
    the payload). Assert NO row was inserted (count returns 0).
  - `TestLoadingWindowMillisZeroLoadingStartedAt` — call with a
    SwapEvent that has zero LoadingStartedAt; assert returns 0.
  - `TestLoadingWindowMillisComputesCorrectDuration` — call with
    LoadingStartedAt = t0, CompletedAt = t0 + 18243ms; assert
    returns 18243.

### `internal/config/config.go`

Extend `StorageConfig` (line ~155) with the new field BETWEEN
existing fields, preserving the YAML field order discipline:

    type StorageConfig struct {
        DBPath                  string `yaml:"db_path"`
        SnapshotIntervalS       int    `yaml:"snapshot_interval_s"`
        RequestLogRetentionDays int    `yaml:"request_log_retention_days"`
        // SPEC-002 v1.3.5 §7.10.1 R-7.10.2 — retention for the
        // operator_model_swap audit_log table (and any future
        // audit event types). Default 90 days mirrors
        // request_log_retention_days.
        AuditLogRetentionDays int `yaml:"audit_log_retention_days"`
    }

In `Default()` (line ~305) add:

    AuditLogRetentionDays: 90,

Add validation in `Validate()` (line ~584):

    if c.Storage.AuditLogRetentionDays <= 0 {
        return fmt.Errorf("storage.audit_log_retention_days must be > 0")
    }

### `internal/config/config_test.go`

Extend the default-config test to assert
`cfg.Storage.AuditLogRetentionDays == 90`. Add a validation test
that asserts `audit_log_retention_days = 0` returns the expected
error substring.

### `cmd/coordinator/main.go`

After the existing `reqLogStore` open block (line 52-57), add:

    auditStore, err := audit.OpenStore(cfg.Storage.DBPath)
    if err != nil {
        fmt.Fprintf(os.Stderr, "audit log storage: %v\n", err)
        os.Exit(1)
    }
    defer auditStore.Close()

After `startRequestLogRetentionPruner(...)` (line 134), add:

    startAuditLogRetentionPruner(shutdownCtx, auditStore, cfg.Storage.AuditLogRetentionDays, logger)

Implement `startAuditLogRetentionPruner` at the end of the file,
mirroring `startRequestLogRetentionPruner` line-for-line with
"request_log" → "audit_log" in log messages. The audit Store
satisfies the existing `requestLogPruner` interface (it has the
`PruneBefore(ctx, cutoff) (int64, error)` method) — REUSE that
interface; do NOT define a parallel `auditLogPruner` interface.

Before `wsServer := providerws.NewServer(...)`, add the emitter
closure and thread it into wsOpts:

    swapEmitter := func(event pool.SwapEvent) {
        if err := auditStore.EmitSwap(shutdownCtx, event); err != nil {
            logger.Warn().
                Err(err).
                Str("provider_id", event.ProviderID).
                Str("assigned_id", event.AssignedID).
                Str("from_model_id", event.FromModelID).
                Str("to_model_id", event.ToModelID).
                Str("to_model_hash", event.ToModelHash).
                Int64("loading_window_ms", event.CompletedAt.Sub(event.LoadingStartedAt).Milliseconds()).
                Str("hash_verification_result", string(event.HashVerificationResult)).
                Msg("operator_model_swap audit write failed")
        }
    }
    wsOpts = append(wsOpts, providerws.WithRegistryOptions(
        pool.WithSwapEmitter(swapEmitter),
    ))

The `pool` import is already in main.go's import block (or add it
if absent). The `audit` import will be new — add it.

### `internal/ws/server_test.go` (1 new end-to-end test)

Add `TestHeartbeatSwapEmitterWritesAuditLogRow`:
  - Open a temp `audit.Store` (in a test-scoped DB path).
  - Construct a Server with a custom emitter via
    `providerws.WithRegistryOptions(pool.WithSwapEmitter(...))`
    that calls `auditStore.EmitSwap`.
  - Register a provider via the v2 auth path.
  - Send heartbeat with loading=true + model_hash + ModelID="A".
  - Send heartbeat with loading=false + new model_hash + ModelID="B".
  - Assert via `eventually` that the audit_log table contains
    exactly 1 row with event_type="operator_model_swap" and
    correct payload fields.

## Done criteria

1. `go build ./...` exits 0.
2. `go vet ./...` exits 0 with no output.
3. `gofmt -l ./internal/ ./cmd/` produces empty output.
4. `go test -race -count=1 ./...` passes for the WHOLE coordinator
   module (all packages, including the new audit package).
5. `git diff --name-only HEAD` lists exactly the 8 files in the
   edit budget.
6. `git diff specs/ beta/ phase3-binary/ phase5-gateway/` — empty.

## Out of scope (do NOT do in this phase)

- Adding `drain_inflight_count_estimate` to SwapEvent or the
  payload (deferred — would require Phase 2C reach-back).
- Adding new event types beyond `operator_model_swap`.
- Resetting `Provider.LastLoadingState` from the emitter
  (already handled by Phase 2C's per-heartbeat write).
- Changing the SQLite DB file path; reuse cfg.Storage.DBPath.
- Adding metrics, traces, or new log levels beyond WARN-on-fail.
- Editing the Phase 2C `pool.SwapEvent` struct or `pool.SwapEventEmitter`
  signature.
- Adding a new admin endpoint to query audit rows (defer to a
  future phase).
- Touching auth_attempts.go, the v2 auth handshake, ApplyHeartbeat,
  parser, or /v1/status path.

## Self-check before reporting done

Run, in order, from /Users/augstar/macprovider-poc/phase4-coordinator,
and paste each output back:

    go build ./...
    go vet ./...
    gofmt -l ./internal/ ./cmd/
    go test -race -count=1 -v -run TestOpenStoreCreatesAuditLogSchema ./internal/audit/... | tail -10
    go test -race -count=1 -v -run TestBuildSwapPayload ./internal/audit/... | tail -30
    go test -race -count=1 -v -run TestSwapEventPayloadEnforcesF15Invariants ./internal/audit/... | tail -10
    go test -race -count=1 -v -run TestHeartbeatSwapEmitter ./internal/ws/... | tail -20
    go test -race -count=1 ./internal/audit/... ./internal/ws/... ./internal/pool/... ./internal/config/...
    go test -race -count=1 ./...
    cd /Users/augstar/macprovider-poc
    git diff --name-only HEAD
    git diff specs/ beta/ phase3-binary/ phase5-gateway/

The last `git diff` MUST produce empty output. If any earlier
command fails, do NOT report done.

=== END PROMPT ===
```

---

## Operator notes (out-of-band)

- 2E is the largest single phase by responsibility count but the
  surface is well-isolated in the new `internal/audit/` package.
  The integration with Phase 2C is one line (the emitter closure
  passed via `pool.WithSwapEmitter`).
- Areas where I expect Codex to drift:
  - **JSON key ordering.** The struct shape forces declaration
    order; the locked spec example has a specific order
    (`event, ts, provider_assigned_id, from_model_id, to_model_id,
    from_model_hash, to_model_hash, loading_window_ms,
    hash_verification_result, drain_inflight_count_estimate`).
    The struct above puts `from_model_hash` BETWEEN `from_model_id`
    and `to_model_id` to match the locked example. Verify Codex
    matches this order — but the spec says key order isn't
    binding, only key NAMES are. Note in the audit if Codex
    chose a different but equivalent order.
  - **F-1.5 rejection vs assertion.** The runtime check is a
    REJECT (return error, no insert) — not a "log and continue".
    Codex may try to "log warn and write anyway". Audit catches
    this.
  - **R-7.10.8 vs F-1.5.** R-7.10.8 says "audit write failure
    MUST NOT block heartbeat processing". F-1.5 rejection IS an
    audit-write-failure path — it's logged at WARN and dropped
    (best-effort), exactly like a SQLite failure. The emitter
    sees both as "EmitSwap returned an error; log and continue".
  - **Pruner cutoff sign.** Easy to flip the comparison operator
    in `PruneBefore`. The requestlog precedent is `<`; copy it
    verbatim.
- After 2E lands, dispatch the Phase 2E mid-stream Codex audit
  (largest surface, money-path adjacent — non-negotiable gate).
- After 2E audit clears, the FULL PRE-MERGE AUDIT across all 5
  phases (model after PR #5's
  `specs/AUDIT_SPEC_001_v1_3_IMPL_PR5_PROMPT.md`) is the final
  gate before squash-merge to main.

🤖 Generated with [Claude Code](https://claude.com/claude-code) (Opus
4.7) for the SPEC-002 v1.3.5 Phase 2 implementation.
