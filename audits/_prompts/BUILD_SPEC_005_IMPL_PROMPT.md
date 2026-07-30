# Build prompt — SPEC-005 billing implementation (Phase 1)

Implements the full provider-credit ledger, settlement, reconciliation,
and four admin endpoints defined in `specs/SPEC-005-billing.md` v0.3.

**Prerequisite:** Phase 0 (`internal/requestlog/`) is built and committed.
The `requestlog.Store` has `BeginTx`, `InsertTx`, and a `DB() *sql.DB`
method (add it if missing — one line).

Read `specs/SPEC-005-billing.md` §§ 1–13 before writing any code.
The locked decisions in § 2 are read-only. Do not relitigate D1–D12.

Run in **Codex** or **Claude Code**, rooted at
`/Users/augstar/macprovider-poc`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh session.

---

```
=== BEGIN PROMPT ===

Working directory: /Users/augstar/macprovider-poc

Read specs/SPEC-005-billing.md in full before writing code.
Pay special attention to:
  § 2   locked decisions D1–D12 (read-only; do not change)
  § 4   table schemas and migration ordering MIG-005-001 to MIG-005-009
  § 5   integer arithmetic and round-half-to-even rule
  § 6   D8 credit matrix (11 request states, §§ 6.1–6.11)
  § 7   settlement cadence, threshold, idempotency
  § 10  ACID transaction contract and recovery algorithm
  § 11  four JSON endpoint contracts with example payloads
  § 13  coordinator.yaml config keys

---

## PART A — Shared DB connection

### A.1 Expose DB from requestlog.Store

File: `phase4-coordinator/internal/requestlog/store.go`

Add one method if it does not already exist:

```go
func (s *Store) DB() *sql.DB { return s.db }
```

This allows billing to share the same SQLite connection for ACID
transactions that span request_log + ledger tables (D9 requirement).

---

## PART B — Config additions

### B.1 New config structs

File: `phase4-coordinator/internal/config/config.go`

Add the following structs and wire them into the root `Config` struct.
Follow the existing pattern (YAML tags, setDefaults, validate).

```go
type RateCardEntry struct {
    PromptCreditsPerMtok     int64 `yaml:"prompt_credits_per_mtok"`
    CompletionCreditsPerMtok int64 `yaml:"completion_credits_per_mtok"`
}

type RewardsConfig struct {
    GlobalMultiplier float64                  `yaml:"global_multiplier"`
    ProviderShare    float64                  `yaml:"provider_share"`
    RateCard         map[string]RateCardEntry `yaml:"rate_card"`
}

type SettlementConfig struct {
    CadenceDays                  int  `yaml:"cadence_days"`
    MinPayoutCredits             int64 `yaml:"min_payout_credits"`
    StartupReconcileWindowHours  int  `yaml:"startup_reconcile_window_hours"`
    NightlyReconcileWindowDays   int  `yaml:"nightly_reconcile_window_days"`
    RecoveryGraceSeconds         int  `yaml:"recovery_grace_seconds"`
    JobEnabled                   bool `yaml:"job_enabled"`
}

type EndpointsConfig struct {
    ProviderEarningsRateLimitPerMinute int `yaml:"provider_earnings_rate_limit_per_minute"`
}
```

Wire into root `Config`:
```go
Rewards    RewardsConfig    `yaml:"rewards"`
Settlement SettlementConfig `yaml:"settlement"`
Endpoints  EndpointsConfig  `yaml:"endpoints"`
```

Defaults in `setDefaults()`:
```
GlobalMultiplier                 = 1.0
ProviderShare                    = 0.90
RateCard["default"].Prompt       = 500000
RateCard["default"].Completion   = 1000000
CadenceDays                      = 7
MinPayoutCredits                 = 500000
StartupReconcileWindowHours      = 24
NightlyReconcileWindowDays       = 7
RecoveryGraceSeconds             = 30
JobEnabled                       = true
ProviderEarningsRateLimitPerMin  = 60
```

Validation:
- `ProviderShare` must be in [0.0, 1.0]
- `GlobalMultiplier` must be > 0
- `CadenceDays` must be > 0
- `MinPayoutCredits` must be >= 0
- `RateCard` must contain a "default" entry
- Each rate card entry: both fields must be >= 0

### B.2 Update coordinator.yaml.example

Add the SPEC-005 section to `phase4-coordinator/coordinator.yaml.example`:

```yaml
rewards:
  global_multiplier: 1.0
  provider_share: 0.90
  rate_card:
    default:
      prompt_credits_per_mtok: 500000
      completion_credits_per_mtok: 1000000
    "mlx-community/Qwen2.5-7B-Instruct-4bit":
      prompt_credits_per_mtok: 1000000
      completion_credits_per_mtok: 2000000
    "mlx-community/Llama-3.2-3B-Instruct-4bit":
      prompt_credits_per_mtok: 500000
      completion_credits_per_mtok: 1000000

settlement:
  cadence_days: 7
  min_payout_credits: 500000
  startup_reconcile_window_hours: 24
  nightly_reconcile_window_days: 7
  recovery_grace_seconds: 30
  job_enabled: true

endpoints:
  provider_earnings_rate_limit_per_minute: 60
```

---

## PART C — Billing package

Create `phase4-coordinator/internal/billing/` with the files below.
Use `modernc.org/sqlite` (already a dependency). No new modules.

### C.1 store.go — SQLite migration and base store

```go
package billing

type Store struct {
    db *sql.DB  // shared with requestlog.Store
}

func NewStore(db *sql.DB) (*Store, error)
```

`NewStore` runs `migrate(ctx)` and returns the store.

Migration implements MIG-005-001 through MIG-005-009 exactly as
specified in SPEC-005 § 4.9. Create each table with `CREATE TABLE IF
NOT EXISTS` using the exact schema from §§ 4.3–4.8 (column names,
types, CHECK constraints, UNIQUE constraints, and all named indexes).

Key constraints to encode faithfully:
- `ledger_request_credits`: `UNIQUE(request_id, attempt_n, provider_id)`
- `ledger_payout_ready`: `UNIQUE(provider_id, window_start_utc, window_end_utc)`
  and `UNIQUE(idempotency_key)`
- `ledger_provider_identity_snapshots`: `UNIQUE(request_id, attempt_n,
  provider_assigned_id)`
- `ledger_reconciliation_runs.run_type` CHECK includes `'spec_007_claim'`
  (MIG-005-008 is already folded into the initial CREATE)
- `ledger_reconciliation_runs.buyer_equivalent_credits` is the canonical
  column; `buyer_debit_credits` is NOT created (MIG-005-009: skip
  deprecated column entirely for new deployments)

MIG-005-007: after all tables are created, verify request_log has the
required columns (`id`, `ts_utc`, `request_id`, `model`,
`provider_assigned_id`, `prompt_tokens`, `completion_tokens`,
`error_code`, `retried`) via `PRAGMA table_info(request_log)`. Fail
migration if any are missing. Do NOT alter request_log.

### C.2 formula.go — pure arithmetic (no DB, fully testable)

```go
package billing

// BilledRow is the result of computing credits for one request attempt.
type BilledRow struct {
    GrossCredits    int64
    ProviderCredits int64
    OperatorCredits int64
    UsageSource     string // 'provider_reported'|'byte_estimated'|'null_error'
    FaultFlag       string // 'none'|'breaker_qualifying'|'null_usage_error'
    PromptTokens          *int64
    CompletionTokens      *int64
    EstimatedCompTokens   *int64
    PromptRatePerMtok     int64
    CompletionRatePerMtok int64
    GlobalMultiplierPPM   int64
    ProviderShareBps      int64
}

// RateFor returns the rate card entry for model, falling back to "default".
func RateFor(rateCard map[string]RateCardEntry, model string) RateCardEntry

// ParseMultiplierPPM converts float64 global_multiplier to integer PPM.
// 1.0 → 1_000_000; 0.5 → 500_000.
func ParseMultiplierPPM(v float64) int64

// ParseShareBps converts float64 provider_share to basis points.
// 0.90 → 9000.
func ParseShareBps(v float64) int64

// RoundHalfEven implements round-half-to-even (banker's rounding).
// result = round_half_even(numerator, denominator)
func RoundHalfEven(numerator, denominator int64) int64

// ComputeCredits applies § 5.3 and § 6 to one request-log row.
// Inputs: token counts (nil = NULL), usage source, fault flag, rate card.
// Returns BilledRow with all credit fields populated.
// Fault and null-error overrides zero ALL credits before formula.
func ComputeCredits(
    promptTokens, completionTokens *int64,
    estimatedCompletionTokens *int64,
    usageSource string,
    faultFlag string,
    rateEntry RateCardEntry,
    multiplierPPM int64,
    providerShareBps int64,
) BilledRow
```

`ComputeCredits` must handle all 11 cases from § 6:
- 503 provider-not-reached: caller should not call ComputeCredits at
  all (§ 6.2 writes zero rows). Document this in a comment.
- null_error (`error_code` in SPEC-001 set): zero all credits, set
  `usage_source='null_error'`, `fault_flag='null_usage_error'` unless
  `faultFlag='breaker_qualifying'` which takes precedence.
- breaker_qualifying fault (§ 6.11): zero all credits, set
  `fault_flag='breaker_qualifying'`.
- byte_estimated (§ 6.8): use estimatedCompletionTokens instead of
  completionTokens for effective completion.
- All other cases: full § 5.3 formula.

### C.3 hotpath.go — ACID hot-path write

```go
package billing

// HotPathInput carries all data needed to write the billing triple
// (ledger_request_credits + ledger_operator_credits +
//  ledger_provider_identity_snapshots) in the same transaction as
//  request_log.
type HotPathInput struct {
    // From request_log row
    RequestID          string
    AttemptN           int
    ProviderAssignedID string // empty → provider-not-reached, skip all writes
    ProviderID         string // stable ID from pool entry
    Model              string
    Status             int
    Stream             bool
    TSUtc              time.Time
    PromptTokens       *int64
    CompletionTokens   *int64
    EstimatedCompTokens *int64
    ErrorCode          string  // SPEC-001 error enum, empty if none
    FaultFlag          string  // 'none'|'breaker_qualifying'

    // From current config snapshot
    ConfigSnapshotID int64
    RateEntry        RateCardEntry
    MultiplierPPM    int64
    ProviderShareBps int64
}

// WriteHotPath writes request_log + all ledger rows in a single
// BEGIN IMMEDIATE ... COMMIT transaction on the shared DB.
// If ProviderAssignedID is empty (503 path), only request_log is written.
// Returns the auto-increment ID of the inserted request_log row.
func (s *Store) WriteHotPath(
    ctx context.Context,
    reqLogStore *requestlog.Store,
    reqRow requestlog.Row,
    billing HotPathInput,
) (int64, error)
```

Implementation:
1. `tx, err := s.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelSerializable})`
   — use the shared DB (PART A) so all writes are in one transaction.
   The spec requires `BEGIN IMMEDIATE`; map to `sql.LevelSerializable`
   or execute `BEGIN IMMEDIATE` directly via `db.ExecContext` before
   using the tx. Use direct `BEGIN IMMEDIATE` to match spec exactly:
   ```go
   tx, _ := s.db.BeginTx(ctx, nil)
   s.db.ExecContext(ctx, "SAVEPOINT billing_hot_path")
   // actually: start with explicit PRAGMA-free BEGIN IMMEDIATE
   ```
   Simplest correct approach: use `conn.BeginTx` with a raw driver
   call, OR start the tx and immediately exec `PRAGMA locking_mode`
   is wrong. Best: use `database/sql` `BeginTx` — modernc.org/sqlite
   serializes writers at the file level in WAL mode anyway. Use
   `sql.LevelDefault` and document that WAL mode provides the
   required durability.
2. `reqLogStore.InsertTx(ctx, tx, reqRow)` — writes request_log.
3. If `billing.ProviderAssignedID != ""`:
   a. Compute credits via `ComputeCredits(...)`.
   b. Insert into `ledger_request_credits` (all fields from § 4.3).
   c. Insert into `ledger_operator_credits` (all fields from § 4.4),
      referencing the new ledger_request_credits.id.
   d. Insert into `ledger_provider_identity_snapshots` (§ 4.8),
      `resolved_from='pool_entry'`.
4. `tx.Commit()`.
5. On any error: `tx.Rollback()`, return error.

### C.4 recovery.go — startup scan and nightly reconciliation

```go
package billing

// RecoverInput is the explicit function input (§ 10.4 contract:
// same inputs → byte-identical outputs; no live network calls).
type RecoverInput struct {
    ScanFrom time.Time
    ScanTo   time.Time  // must be ≥ recovery_grace_seconds before wall clock
    Source   string     // 'startup_scan' or 'nightly_reconcile'
}

// RecoverLedger scans request_log rows in [ScanFrom, ScanTo) that are
// creditable but have no matching ledger_request_credits row.
// Writes recovery rows using the latest config snapshot whose
// effective_at_utc ≤ request_log.ts_utc.
// (v0.6 note: superseded — recovery now selects the EXACT identity-linked
// config_snapshot_id first, timestamp rule only as fallback; positive
// first-attempt cache rows quarantine instead. Normative: SPEC-005 §4.7/§10.2/§10.4.)
// Quarantines rows where no config or identity snapshot is available.
// Writes one ledger_reconciliation_runs row summarising the run.
// Idempotent: re-running the same window produces zero new rows.
func (s *Store) RecoverLedger(ctx context.Context, in RecoverInput) error

// StartStartupScan runs RecoverLedger once for the prior
// startup_reconcile_window_hours on coordinator startup.
// Must complete before serving requests or log a warning if it exceeds 30s.
func (s *Store) StartStartupScan(ctx context.Context, cfg SettlementConfig, now time.Time) error

// StartNightlyReconcile launches a goroutine that runs RecoverLedger
// daily (at UTC midnight + a short jitter to avoid thundering herd).
// Stops when ctx is cancelled.
func (s *Store) StartNightlyReconcile(ctx context.Context, cfg SettlementConfig)
```

Creditable request_log row (§ 10.2): provider_assigned_id IS NOT NULL
AND status != 503 AND NOT already in ledger_request_credits for this
(request_id, attempt_n, provider_assigned_id) triple. The D8 § 6.2
503 exception: if status == 503, skip (no ledger row to write).

### C.5 settlement.go — weekly settlement job

```go
package billing

// RunSettlement scans unsettled ledger_request_credits rows per
// provider for the closed window [windowStart, windowEnd).
// For each provider where SUM(provider_credits) >= min_payout_credits:
//   INSERT INTO ledger_payout_ready (idempotency key =
//   provider_id + "|" + window_start + "|" + window_end).
//   UPDATE ledger_request_credits SET settled=1, settlement_id=<id>
//   WHERE provider_id=? AND ts_utc >= windowStart AND ts_utc < windowEnd
//   AND settled=0.
// Idempotent: duplicate window skipped via UNIQUE(idempotency_key).
func (s *Store) RunSettlement(ctx context.Context, cfg SettlementConfig, windowStart, windowEnd time.Time) error

// StartWeeklySettlement launches a goroutine that fires RunSettlement
// at UTC Monday 00:00 each week. Stops when ctx is cancelled.
// Skips if cfg.JobEnabled is false (for tests).
func (s *Store) StartWeeklySettlement(ctx context.Context, cfg SettlementConfig)

// NextMondayUTC returns the next UTC Monday 00:00 after t.
// Used by StartWeeklySettlement and testable in isolation.
func NextMondayUTC(t time.Time) time.Time
```

### C.6 snapshot.go — config snapshot on startup/reload

```go
package billing

// InsertConfigSnapshot writes one ledger_config_snapshots row.
// Called on coordinator startup and after valid config reload.
// Idempotent: if config_hash already exists, no-op (returns nil).
func (s *Store) InsertConfigSnapshot(ctx context.Context, cfg RewardsConfig, now time.Time) (int64, error)

// LatestConfigSnapshotAt returns the ID and effective_at_utc of the
// most recent snapshot whose effective_at_utc <= t.
// Returns (0, zero, ErrNoSnapshot) if none exists.
func (s *Store) LatestConfigSnapshotAt(ctx context.Context, t time.Time) (id int64, effectiveAt time.Time, err error)

var ErrNoSnapshot = errors.New("no config snapshot found")
```

`config_hash` is `sha256(canonical JSON of provider_share_bps +
global_multiplier_ppm + rate_card sorted by key)` encoded as hex.

### C.7 endpoints.go — four JSON handlers

```go
package billing

// Handlers returns an http.ServeMux with the four SPEC-005 endpoints
// pre-registered. The mux is mounted by the caller at the right prefix.
//
// Admin endpoints (/admin/ledger/*) require the operator key passed
// as operatorKey. Use the same bearer-token check pattern as the
// existing /admin/* handlers in buyer/server.go.
//
// Provider earnings endpoint (/providers/{id}/earnings) requires a
// valid FR-P12 bearer token whose subject equals the path provider_id.
// When requireProviderTokens is false, this endpoint returns 503
// {"error":{"code":"unavailable","message":"provider tokens not enabled"}}.
//
// All 404 and method-not-allowed cases return the standard error envelope.
func (s *Store) Handlers(
    operatorKey string,
    tokenStore interface {
        ValidateToken(ctx context.Context, raw string) (providerID string, err error)
    },
    requireProviderTokens bool,
    earningsRateLimitPerMin int,
) http.Handler
```

Implement all four endpoints per §§ 11.1–11.5:

**GET /admin/ledger/summary**
Query: `SELECT SUM(provider_credits), SUM(operator_credits),
SUM(gross_credits) FROM ledger_request_credits WHERE quarantined=0`.
Current-window credits: WHERE ts_utc >= current Monday 00:00 UTC.
Pending payouts: `SELECT COUNT(*), SUM(provider_credits) FROM
ledger_payout_ready WHERE status='ready'`.
Quarantined count: `SELECT COUNT(*) FROM ledger_request_credits WHERE
quarantined=1`.
Fault count: `SELECT COUNT(*) FROM ledger_request_credits WHERE
fault_flag != 'none'`.
Last reconciliation delta: most recent `ledger_reconciliation_runs` row.

**GET /admin/ledger/providers**
Accept optional `limit` (default 50, max 200), `cursor` (last-seen
provider_id for pagination), `include_quarantined` (bool, default false).
Return one object per provider_id sorted alphabetically.

**GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD**
Both params required; return 400 if missing or malformed.
Compute buyer_equivalent_credits by running the D8 matrix from § 6
over request_log rows in range (read-only; do not write anything for
an admin-triggered reconcile except a `ledger_reconciliation_runs` row
with `run_type='admin_reconcile'`).
delta_gross_credits = provider_gross_credits - buyer_equivalent_credits.

**GET /providers/{id}/earnings**
Parse provider_id from URL path (use `strings.TrimPrefix` or a simple
pattern — no external router dependency).
Validate FR-P12 bearer token; subject must equal provider_id.
Return per-provider totals, last payout-ready row, provider_share_bps,
models_served (DISTINCT model from ledger_request_credits), rate_card
excerpt for those models, fault_count.

---

## PART D — Wire into buyer/server.go and main.go

### D.1 buyer/server.go

Add field to `Server`:
```go
billing *billing.Store // nil = disabled (test default)
billingCfg config.RewardsConfig
```

Add option:
```go
func WithBilling(s *billing.Store, cfg config.RewardsConfig) Option
```

In the `logRow` closure (Phase 0), when `s.billing != nil` and
`providerAssignedID != ""` and `status != 503`, replace the standalone
`s.reqLog.Insert(...)` call with `s.billing.WriteHotPath(...)` which
handles both the request_log write AND the ledger writes atomically.

When `status == 503` (provider-not-reached, § 6.2): still write
request_log only — call `s.reqLog.Insert(...)` directly (not via
billing.WriteHotPath).

When `s.billing == nil` (tests): keep calling `s.reqLog.Insert(...)`
as before — zero behaviour change for existing tests.

You will need to pass the current config snapshot ID and resolved
provider_id (stable, not assigned) into the closure. Resolve stable
provider_id via the pool registry: `s.pool.StableProviderID(assignedID)`
— add this method to the pool.Registry if it does not exist (or use the
provider's ProviderID field from the pool.Provider struct, which already
carries it). Check the pool.Provider struct before adding new methods.

### D.2 main.go

After `reqLogStore` is opened:

```go
billingStore, err := billing.NewStore(reqLogStore.DB())
if err != nil {
    fmt.Fprintf(os.Stderr, "billing: %v\n", err)
    os.Exit(1)
}
// Insert startup config snapshot
if _, err := billingStore.InsertConfigSnapshot(
    context.Background(), cfg.Rewards, time.Now().UTC(),
); err != nil {
    fmt.Fprintf(os.Stderr, "billing config snapshot: %v\n", err)
    os.Exit(1)
}
```

Pass `WithBilling(billingStore, cfg.Rewards)` to `buyer.NewServer`.

After the HTTP servers are constructed but before `ListenAndServe`:

```go
// Startup scan (blocks briefly; log warning if > 30s)
if err := billingStore.StartStartupScan(
    context.Background(), cfg.Settlement, time.Now().UTC(),
); err != nil {
    logger.Warn().Err(err).Msg("billing startup scan failed")
}

// Background jobs (stop on shutdown)
billingStore.StartNightlyReconcile(shutdownCtx, cfg.Settlement)
billingStore.StartWeeklySettlement(shutdownCtx, cfg.Settlement)
```

Mount billing handlers on the provider mux (operator-only admin
endpoints live on the provider port behind /admin/*):

```go
billingHandler := billingStore.Handlers(
    cfg.Auth.OperatorKey,
    tokenStore,
    cfg.Auth.RequireProviderTokens,
    cfg.Endpoints.ProviderEarningsRateLimitPerMinute,
)
providerMux.Handle("/admin/ledger/", billingHandler)
providerMux.Handle("/providers/", billingHandler)
```

---

## PART E — Tests

### E.1 formula_test.go

`TestComputeCredits_WorkedExamples` — verify all four worked examples
from § 5.4 exactly:
- 200, 1000 prompt + 2000 completion, 7B rates:
  gross=5000, provider=4500, operator=500
- 502 prompt-only, 1000 prompt, 7B rates: gross=1000, provider=900, operator=100
- Null usage error: gross=0, provider=0, operator=0
- Unknown model (default rates), 1000 prompt + 500 completion:
  verify fallback to default rates

`TestRoundHalfEven` — test the banker's rounding rule with values at
the boundary: .5 rounds to even; .4 rounds down; .6 rounds up.

`TestParseMultiplierPPM` — 1.0→1_000_000, 0.5→500_000, 2.0→2_000_000.

### E.2 store_test.go (billing)

`TestBillingMigration` — open a `:memory:` DB, run `NewStore`,
verify all six tables and all indexes exist via `PRAGMA table_info`
and `PRAGMA index_list`.

`TestInsertConfigSnapshot_Idempotent` — same config inserted twice
produces exactly one row.

`TestWriteHotPath_ACID` — open an in-memory DB shared between
`requestlog.NewStore` (add a NewStore(db) constructor if needed) and
`billing.NewStore`. Write a hot-path row. Verify request_log,
ledger_request_credits, ledger_operator_credits, and
ledger_provider_identity_snapshots all have exactly one row and their
FK relationships are consistent.

`TestWriteHotPath_503_NoLedgerRows` — status=503 path writes
request_log only; ledger tables have zero rows.

`TestWriteHotPath_NullError_ZeroCredits` — error_code set to
`error_model_not_loaded`; verify gross=0, provider=0, operator=0,
usage_source='null_error'.

`TestRecoverLedger_Idempotent` — insert a request_log row with no
matching ledger row; call RecoverLedger twice with the same window;
verify exactly one ledger_request_credits row exists after both calls.

`TestSettlement_ThresholdEnforced` — provider with
provider_credits < min_payout_credits gets no payout-ready row;
provider at or above threshold gets exactly one.

`TestSettlement_Idempotency` — run RunSettlement twice on the same
window; verify exactly one ledger_payout_ready row and no duplicate
settlement_id assignments.

`TestNextMondayUTC` — given a Wednesday, returns the following Monday
00:00:00 UTC.

### E.3 endpoints_test.go

`TestSummaryEndpoint` — insert known rows; call `/admin/ledger/summary`
with correct operator key; verify JSON shape matches § 11.1.

`TestProvidersEndpoint` — insert rows for two providers; verify both
appear in `/admin/ledger/providers` response.

`TestReconcileEndpoint_CleanDelta` — insert request_log rows with
matching ledger rows; call reconcile; verify delta_gross_credits=0.

`TestEarningsEndpoint_TokenRequired` — call `/providers/x/earnings`
without bearer token; expect 401. Call with wrong-subject token;
expect 403.

`TestEarningsEndpoint_DisabledWhenTokensOff` — `requireProviderTokens=false`;
call `/providers/x/earnings`; expect 503 with unavailable code.

---

## PART F — Final verification

```bash
cd phase4-coordinator && \
  GOCACHE=/private/tmp/macprovider-go-build-cache \
  go build ./... 2>&1 && \
  GOCACHE=/private/tmp/macprovider-go-build-cache \
  go test ./... 2>&1 | tail -50
```

All tests must pass, including all existing ones. Fix failures before
committing.

---

## PART G — Commit

```bash
git add \
  phase4-coordinator/internal/billing/ \
  phase4-coordinator/internal/requestlog/store.go \
  phase4-coordinator/internal/config/config.go \
  phase4-coordinator/internal/config/config_test.go \
  phase4-coordinator/internal/buyer/server.go \
  phase4-coordinator/internal/buyer/server_test.go \
  phase4-coordinator/cmd/coordinator/main.go \
  phase4-coordinator/coordinator.yaml.example

git commit -m "$(cat <<'EOF'
feat(coordinator): SPEC-005 billing — ledger, settlement, reconciliation, endpoints

Provider-credit ledger with ACID hot-path writes, weekly settlement-ready
batch, startup+nightly recovery, and four JSON visibility endpoints.
All D1–D12 locked decisions encoded. AC-H005 reconciliation passing.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

=== END PROMPT ===
```
