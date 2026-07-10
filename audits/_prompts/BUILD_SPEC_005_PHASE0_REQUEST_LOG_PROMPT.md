# Build prompt — SPEC-002 FR-B9 request_log implementation (SPEC-005 Phase 0)

One-off session. Implements the `request_log` table and write hook in the
coordinator that SPEC-005 billing requires as its read-only data source.

The spec contract is **SPEC-002 v1.3.4 FR-B9** at
`specs/SPEC-002-coordinator.md` (line ~1095). Read FR-B9 and
AC-FR-B9-MULTI / AC-FR-B9-ERROR-CODE before writing anything.

Run in **Codex** or **Claude Code**, rooted at
`/Users/augstar/macprovider-poc`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session.

---

```
=== BEGIN PROMPT ===

Working directory: /Users/augstar/macprovider-poc

Read `specs/SPEC-002-coordinator.md` FR-B9 (search for "FR-B9") and
the two acceptance criteria AC-FR-B9-MULTI and AC-FR-B9-ERROR-CODE
before writing any code.

Implement the `request_log` SQLite table and write hook in the
coordinator. This is the only data source SPEC-005 billing reads;
get it right.

---

## Step 1 — New package: internal/requestlog/

Create `phase4-coordinator/internal/requestlog/store.go`.

The package opens its own `*sql.DB` connection to the same DB path
used by `internal/auth`. Use the same driver and WAL pattern as
`internal/auth/tokens.go` (`modernc.org/sqlite`, `PRAGMA journal_mode=WAL`).

### 1.1 Store type and constructor

```go
package requestlog

import (
    "context"
    "database/sql"
    "time"
    _ "modernc.org/sqlite"
)

type Store struct { db *sql.DB }

func OpenStore(dbPath string) (*Store, error)
func (s *Store) Close() error
```

`OpenStore` must:
1. Open the DB with `modernc.org/sqlite`
2. Set `PRAGMA journal_mode=WAL`
3. Set `PRAGMA busy_timeout=5000` (5 s; prevents write-lock races with
   the auth store on the same file)
4. Call `migrate(ctx)`
5. Return the store

### 1.2 Migration

```go
func (s *Store) migrate(ctx context.Context) error
```

Creates the table and both required indexes if they do not exist:

```sql
CREATE TABLE IF NOT EXISTS request_log (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_utc              TEXT    NOT NULL,
    request_id          TEXT    NOT NULL,
    model               TEXT    NOT NULL,
    provider_assigned_id TEXT   NULL,
    prompt_tokens       INTEGER NULL,
    completion_tokens   INTEGER NULL,
    total_tokens        INTEGER NULL,
    latency_ms          REAL    NOT NULL,
    routing_ms          REAL    NOT NULL,
    status              INTEGER NOT NULL,
    stream              INTEGER NOT NULL,
    buyer_ip            TEXT    NOT NULL DEFAULT '',
    error               TEXT    NULL,
    error_code          TEXT    NULL,
    pref_header         TEXT    NULL,
    provider_header     TEXT    NULL,
    retried             INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_request_log_ts_utc
    ON request_log(ts_utc);
CREATE INDEX IF NOT EXISTS idx_request_log_request_id_id
    ON request_log(request_id, id);
```

`total_tokens` is computed as `prompt_tokens + completion_tokens` when
both are non-NULL; otherwise NULL. The INSERT method (below) handles
this — do not encode it as a generated column.

Migration must also handle existing deployments that have the table
WITHOUT the indexes. Use `CREATE INDEX IF NOT EXISTS` — no ALTER TABLE
needed for indexes.

### 1.3 Row type

```go
type Row struct {
    TSUtc              time.Time
    RequestID          string
    Model              string
    ProviderAssignedID string  // empty string = NULL stored
    PromptTokens       *int64  // nil = NULL
    CompletionTokens   *int64  // nil = NULL
    LatencyMs          float64
    RoutingMs          float64
    Status             int
    Stream             bool
    BuyerIP            string
    Error              string  // empty = NULL stored
    ErrorCode          string  // empty = NULL stored
    PrefHeader         string  // empty = NULL stored
    ProviderHeader     string  // empty = NULL stored
    Retried            int
}
```

Pointer types for `PromptTokens` / `CompletionTokens` because they are
genuinely nullable (failed requests have no token counts).

### 1.4 Insert method

```go
func (s *Store) Insert(ctx context.Context, row Row) error
```

- Computes `total_tokens` as `*row.PromptTokens + *row.CompletionTokens`
  when both are non-nil; passes NULL otherwise.
- Stores empty strings for `ProviderAssignedID`, `Error`, `ErrorCode`,
  `PrefHeader`, `ProviderHeader` as SQL NULL (use `sql.NullString`).
- Never returns an error that would propagate to the buyer — the caller
  MUST log the error and continue. (`Insert` itself returns the error;
  the caller decides whether to log or swallow.)
- Does NOT open a transaction — single INSERT only.

---

## Step 2 — Wire into main.go

File: `phase4-coordinator/cmd/coordinator/main.go`

After `auth.OpenStore` succeeds, open the request log store:

```go
reqLogStore, err := requestlog.OpenStore(cfg.Storage.DBPath)
if err != nil {
    fmt.Fprintf(os.Stderr, "requestlog: %v\n", err)
    os.Exit(1)
}
defer reqLogStore.Close()
```

Add import for `requestlog` package.

Pass the store to `buyer.NewServer` via a new option (Step 3 below):

```go
buyer.WithRequestLog(reqLogStore),
```

---

## Step 3 — Add option and field to buyer.Server

File: `phase4-coordinator/internal/buyer/server.go`

Add field to `Server` struct:

```go
reqLog *requestlog.Store  // nil = logging disabled (test default)
```

Add functional option:

```go
func WithRequestLog(s *requestlog.Store) Option {
    return func(srv *Server) { srv.reqLog = s }
}
```

`reqLog` being nil is valid — the write hook below MUST guard with
`if s.reqLog == nil { return }`. This keeps all existing tests green
without change.

---

## Step 4 — Write hook in handleChatCompletions

File: `phase4-coordinator/internal/buyer/server.go`

`handleChatCompletions` has two main paths (streaming + non-streaming)
each with a retry loop. The hook writes one row per provider attempt,
not one row per request.

### 4.1 Declare a row builder at function entry

After `startedAt := s.now()` (already present), declare:

```go
routingDone := s.now()   // will be set after selectProvider returns
logRow := func(
    providerAssignedID string,
    status int,
    promptTok, completionTok *int64,
    errMsg, errCode string,
    retried int,
) {
    if s.reqLog == nil {
        return
    }
    row := requestlog.Row{
        TSUtc:              startedAt,
        RequestID:          originalRequestID,
        Model:              req.Model,
        ProviderAssignedID: providerAssignedID,
        PromptTokens:       promptTok,
        CompletionTokens:   completionTok,
        LatencyMs:          float64(time.Since(startedAt).Milliseconds()),
        RoutingMs:          float64(routingDone.Sub(startedAt).Milliseconds()),
        Status:             status,
        Stream:             req.Stream,
        BuyerIP:            r.RemoteAddr,
        Error:              errMsg,
        ErrorCode:          errCode,
        PrefHeader:         r.Header.Get("X-MacProvider-Pref"),
        ProviderHeader:     r.Header.Get("X-MacProvider-Provider"),
        Retried:            retried,
    }
    if err := s.reqLog.Insert(r.Context(), row); err != nil {
        s.log.Warn().Err(err).Str("request_id", originalRequestID).
            Msg("request_log insert failed")
    }
}
```

Set `routingDone = s.now()` immediately after `selectProvider` returns
successfully (it's already tracked for latency; you are simply capturing
the same timestamp into the closure).

### 4.2 Call logRow at each provider-attempt outcome

There are four distinct outcomes to instrument. In EACH case, call
`logRow` with the correct arguments BEFORE any `return` or `continue`.

**503 — no provider available** (before the retry loop, after
`selectProvider` returns an error):
```go
logRow("", http.StatusServiceUnavailable, nil, nil,
    routeErr.Error(), "", 0)
```

**Success — non-streaming** (after the provider HTTP/WS call succeeds
and `status == 200`). Extract token counts from the response usage if
present; pass nil pointers if not:
```go
logRow(provider.AssignedID, http.StatusOK,
    promptTokPtr, completionTokPtr, "", "", explicitRetries)
```

**Success — streaming** (after streaming completes and the final usage
chunk has been forwarded). Same pattern as non-streaming success.

**Provider failure / failover** (any path that logs a provider failure
and either retries or returns a non-200 status to the buyer). Use the
actual HTTP status written to the buyer, extract `ErrorCode` from the
SPEC-001 `inference_response_end.status` field when it is non-empty,
otherwise pass empty string:
```go
logRow(provider.AssignedID, httpStatus,
    nil, nil, errMsg, spec001ErrorCode, explicitRetries)
```

`spec001ErrorCode` is the value of `inference_response_end.status` when
the provider returned a SPEC-001 error response
(`error_model_not_loaded`, `error_context_exceeded`,
`error_queue_full`, `error_internal`). It is already parsed somewhere
in the relay path — look for where the provider's `status` field is
checked. If the relay result does not surface it, pass empty string and
add a TODO comment; do not fabricate the value.

Do NOT refactor the retry loop. Add the `logRow` calls as minimal
additions at the natural exit/continue points.

---

## Step 5 — Tests

File: `phase4-coordinator/internal/requestlog/store_test.go`

### 5.1 Basic round-trip

`TestRequestLogInsertAndRead`: insert a row with all fields set, query
it back by `request_id`, assert every column matches.

### 5.2 AC-FR-B9-MULTI — multi-attempt rows

`TestRequestLogMultiAttemptRows` (exact name required by spec AC):

Insert two rows with the same `request_id` but different
`provider_assigned_id` values (simulating two retry attempts). Query
by `request_id ORDER BY id ASC`. Assert:
- Exactly 2 rows returned
- Both have the same `request_id`
- `id` values are distinct and increasing
- `provider_assigned_id` differs between rows
- No uniqueness error was returned on insert

### 5.3 AC-FR-B9-ERROR-CODE — error code propagation

`TestRequestLogErrorCodePopulation` (exact name required by spec AC):

Insert one row with `ErrorCode = "error_model_not_loaded"` and
`PromptTokens = nil`, `CompletionTokens = nil`. Insert one row with
`ErrorCode = ""` (success path). Query both. Assert:
- First row has `error_code = "error_model_not_loaded"` in the DB
- Second row has `error_code IS NULL` in the DB (empty string stored
  as NULL)
- `prompt_tokens IS NULL` for both rows (nil pointer → NULL)

### 5.4 Nil-log guard (buyer server option test)

In `phase4-coordinator/internal/buyer/server_test.go`, add
`TestRequestLogNilGuard`: construct a `buyer.Server` without
`WithRequestLog`, send a mock request through `handleChatCompletions`
using the existing test infrastructure. Assert no panic and the
handler completes normally. This proves `reqLog == nil` is safe.

---

## Step 6 — Run all tests

```bash
cd phase4-coordinator && \
  GOCACHE=/private/tmp/macprovider-go-build-cache \
  go test ./... 2>&1 | tail -40
```

All tests must pass, including existing ones. Fix any failures before
committing.

---

## Step 7 — Commit

```bash
git add \
  phase4-coordinator/internal/requestlog/ \
  phase4-coordinator/internal/buyer/server.go \
  phase4-coordinator/internal/buyer/server_test.go \
  phase4-coordinator/cmd/coordinator/main.go

git commit -m "$(cat <<'EOF'
feat(coordinator): FR-B9 request_log — table, indexes, write hook, tests

Implements SPEC-002 v1.3.4 FR-B9 as the read-only data source for
SPEC-005 billing. New internal/requestlog package; one row per provider
attempt; AC-FR-B9-MULTI and AC-FR-B9-ERROR-CODE passing.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

=== END PROMPT ===
```
