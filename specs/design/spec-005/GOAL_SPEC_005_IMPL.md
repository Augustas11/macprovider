/goal

Working directory: /Users/augstar/macprovider-poc

Read specs/SPEC-005-billing.md in full before writing any code.
Pay special attention to:
  § 2   locked decisions D1–D12 (read-only; do not change or relitigate)
  § 4   table schemas and migration ordering MIG-005-001 to MIG-005-009
  § 5   integer arithmetic and round-half-to-even rule
  § 6   D8 credit matrix (11 request states, §§ 6.1–6.11)
  § 7   settlement cadence, threshold, idempotency
  § 10  ACID transaction contract and recovery algorithm
  § 11  four JSON endpoint contracts with example payloads
  § 13  coordinator.yaml config keys

After completing each Part below, run:
  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...
Fix any build errors before moving to the next Part.
Run the full test suite only at Part F.

---

## PART A — Shared DB connection

File: phase4-coordinator/internal/requestlog/store.go

Add one method if it does not already exist:

  func (s *Store) DB() *sql.DB { return s.db }

This allows the billing package to share the same SQLite connection for
ACID transactions that span request_log + ledger tables (D9 requirement).

Build check:
  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...

---

## PART B — Config additions

File: phase4-coordinator/internal/config/config.go

Add the following structs and wire them into the root Config struct.
Follow the existing pattern (YAML tags, setDefaults, validate).

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
      CadenceDays                 int   `yaml:"cadence_days"`
      MinPayoutCredits            int64 `yaml:"min_payout_credits"`
      StartupReconcileWindowHours int   `yaml:"startup_reconcile_window_hours"`
      NightlyReconcileWindowDays  int   `yaml:"nightly_reconcile_window_days"`
      RecoveryGraceSeconds        int   `yaml:"recovery_grace_seconds"`
      JobEnabled                  bool  `yaml:"job_enabled"`
  }

  type EndpointsConfig struct {
      ProviderEarningsRateLimitPerMinute int `yaml:"provider_earnings_rate_limit_per_minute"`
  }

Wire into root Config:
  Rewards    RewardsConfig    `yaml:"rewards"`
  Settlement SettlementConfig `yaml:"settlement"`
  Endpoints  EndpointsConfig  `yaml:"endpoints"`

Defaults in setDefaults():
  GlobalMultiplier                        = 1.0
  ProviderShare                           = 0.90
  RateCard["default"].PromptCredits       = 500000
  RateCard["default"].CompletionCredits   = 1000000
  CadenceDays                             = 7
  MinPayoutCredits                        = 500000
  StartupReconcileWindowHours             = 24
  NightlyReconcileWindowDays              = 7
  RecoveryGraceSeconds                    = 30
  JobEnabled                              = true
  ProviderEarningsRateLimitPerMinute      = 60

Validation:
  - ProviderShare must be in [0.0, 1.0]
  - GlobalMultiplier must be > 0
  - CadenceDays must be > 0
  - MinPayoutCredits must be >= 0
  - RateCard must contain a "default" entry
  - Each rate card entry: both fields must be >= 0

File: phase4-coordinator/coordinator.yaml.example

Add the SPEC-005 section:

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

Build check:
  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...

---

## PART C — Billing package

Create phase4-coordinator/internal/billing/ with the files below.
Use modernc.org/sqlite (already a dependency). No new modules.

### C.1 store.go — SQLite migration and base store

  package billing

  type Store struct {
      db *sql.DB  // shared with requestlog.Store — same connection
  }

  func NewStore(db *sql.DB) (*Store, error)

NewStore runs migrate(ctx) and returns the store.

Migration implements MIG-005-001 through MIG-005-009 exactly as
specified in SPEC-005 § 4.9. Use CREATE TABLE IF NOT EXISTS for each
table using the exact schema from §§ 4.3–4.8: column names, types,
CHECK constraints, UNIQUE constraints, and all named indexes.

Key constraints to encode faithfully:
  - ledger_request_credits:    UNIQUE(request_id, attempt_n, provider_id)
  - ledger_payout_ready:       UNIQUE(provider_id, window_start_utc, window_end_utc)
                               UNIQUE(idempotency_key)
  - ledger_provider_identity_snapshots: UNIQUE(request_id, attempt_n, provider_assigned_id)
  - ledger_reconciliation_runs.run_type CHECK includes 'spec_007_claim'
    (MIG-005-008 folded into initial CREATE)
  - ledger_reconciliation_runs: use buyer_equivalent_credits as the
    canonical column; do NOT create buyer_debit_credits (MIG-005-009:
    skip deprecated column entirely for new deployments)

MIG-005-007: after all tables are created, verify request_log has the
required columns (id, ts_utc, request_id, model, provider_assigned_id,
prompt_tokens, completion_tokens, error_code, retried) via
PRAGMA table_info(request_log). Fail migration if any are missing.
Do NOT alter request_log.

### C.2 formula.go — pure arithmetic (no DB, fully testable)

  type BilledRow struct {
      GrossCredits          int64
      ProviderCredits       int64
      OperatorCredits       int64
      UsageSource           string  // 'provider_reported'|'byte_estimated'|'null_error'
      FaultFlag             string  // 'none'|'breaker_qualifying'|'null_usage_error'
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
  func RoundHalfEven(numerator, denominator int64) int64

  // ComputeCredits applies § 5.3 and § 6 to one request attempt.
  // Fault and null-error overrides zero ALL credits before formula.
  // 503 provider-not-reached: caller must not call this — document in comment.
  func ComputeCredits(
      promptTokens, completionTokens *int64,
      estimatedCompletionTokens *int64,
      usageSource string,
      faultFlag string,
      rateEntry RateCardEntry,
      multiplierPPM int64,
      providerShareBps int64,
  ) BilledRow

ComputeCredits must handle all 11 cases from § 6:
  - null_error (error_code in SPEC-001 set): zero all credits,
    usage_source='null_error', fault_flag='null_usage_error' unless
    faultFlag='breaker_qualifying' which takes precedence.
  - breaker_qualifying fault (§ 6.11): zero all credits,
    fault_flag='breaker_qualifying'.
  - byte_estimated (§ 6.8): use estimatedCompletionTokens for effective
    completion tokens.
  - All other cases: full § 5.3 formula using integer arithmetic only.

§ 5.3 closed-form formula:
  effective_completion = completion_tokens          (provider_reported)
                       = estimated_completion_tokens (byte_estimated)
                       = 0                           (null_error)
  base_numerator = prompt_tokens * prompt_rate_per_mtok
                 + effective_completion * completion_rate_per_mtok
  rate_scaled = base_numerator * global_multiplier_ppm
  gross_credits = RoundHalfEven(rate_scaled, 1_000_000 * 1_000_000)
  provider_credits = RoundHalfEven(gross_credits * provider_share_bps, 10_000)
  operator_credits = gross_credits - provider_credits

### C.3 hotpath.go — ACID hot-path write

  type HotPathInput struct {
      // From request context
      RequestID           string
      AttemptN            int
      ProviderAssignedID  string  // empty → 503 path, write request_log only
      ProviderID          string  // stable ID from pool entry
      Model               string
      Status              int
      Stream              bool
      TSUtc               time.Time
      PromptTokens        *int64
      CompletionTokens    *int64
      EstimatedCompTokens *int64
      ErrorCode           string  // SPEC-001 error enum; empty if none
      FaultFlag           string  // 'none'|'breaker_qualifying'

      // From current config snapshot
      ConfigSnapshotID int64
      RateEntry        RateCardEntry
      MultiplierPPM    int64
      ProviderShareBps int64
  }

  // WriteHotPath writes request_log + all ledger rows in a single
  // transaction on the shared DB.
  // If ProviderAssignedID is empty (503 path), writes request_log only.
  func (s *Store) WriteHotPath(
      ctx context.Context,
      reqLogStore *requestlog.Store,
      reqRow requestlog.Row,
      in HotPathInput,
  ) error

Implementation:
  1. tx, err := s.db.BeginTx(ctx, nil)  — shared DB, WAL mode serialises writers
  2. reqLogStore.InsertTx(ctx, tx, reqRow)
  3. If in.ProviderAssignedID != "":
       a. result := ComputeCredits(...)
       b. INSERT INTO ledger_request_credits (all fields from § 4.3)
       c. INSERT INTO ledger_operator_credits (all fields from § 4.4,
          referencing the new ledger_request_credits.id)
       d. INSERT INTO ledger_provider_identity_snapshots (§ 4.8,
          resolved_from='pool_entry')
  4. tx.Commit()
  5. On any error: tx.Rollback(), return error

### C.4 recovery.go — startup scan and nightly reconciliation

  type RecoverInput struct {
      ScanFrom time.Time
      ScanTo   time.Time  // must be ≥ recovery_grace_seconds before wall clock
      Source   string     // 'startup_scan' or 'nightly_reconcile'
  }

  // RecoverLedger scans request_log rows in [ScanFrom, ScanTo) that
  // are creditable but have no matching ledger_request_credits row.
  // Writes recovery rows using the latest config snapshot whose
  // effective_at_utc <= request_log.ts_utc.
  // (v0.6 note: superseded — recovery now selects the EXACT identity-linked
  // config_snapshot_id first, with the timestamp rule only as fallback; a
  // positive first-attempt cache row quarantines instead of falling back.
  // Normative: SPEC-005 §4.7 / §10.2 / §10.4.)
  // Quarantines rows where no config or identity snapshot is available.
  // Writes one ledger_reconciliation_runs row summarising the run.
  // Idempotent: re-running the same window produces zero new rows.
  func (s *Store) RecoverLedger(ctx context.Context, in RecoverInput) error

  // StartStartupScan runs RecoverLedger once for the prior
  // startup_reconcile_window_hours on coordinator startup.
  func (s *Store) StartStartupScan(ctx context.Context, cfg SettlementConfig, now time.Time) error

  // StartNightlyReconcile launches a goroutine that runs RecoverLedger
  // daily at UTC midnight. Stops when ctx is cancelled.
  func (s *Store) StartNightlyReconcile(ctx context.Context, cfg SettlementConfig)

Creditable request_log row definition:
  provider_assigned_id IS NOT NULL
  AND status != 503
  AND NOT already in ledger_request_credits for this
      (request_id, attempt_n, provider_assigned_id) triple

503 exception (§ 6.2): status == 503 means no ledger row — skip.

### C.5 settlement.go — weekly settlement job

  // RunSettlement scans unsettled ledger_request_credits rows per provider
  // for the closed window [windowStart, windowEnd).
  // For each provider where SUM(provider_credits) >= min_payout_credits:
  //   INSERT INTO ledger_payout_ready with idempotency_key =
  //     provider_id + "|" + window_start_utc + "|" + window_end_utc
  //   UPDATE ledger_request_credits SET settled=1, settlement_id=<id>
  //     WHERE provider_id=? AND ts_utc IN window AND settled=0
  // Idempotent: duplicate window skipped via UNIQUE(idempotency_key).
  func (s *Store) RunSettlement(ctx context.Context, cfg SettlementConfig, windowStart, windowEnd time.Time) error

  // StartWeeklySettlement fires RunSettlement at UTC Monday 00:00 each week.
  // Skips if cfg.JobEnabled is false (test-disable switch).
  func (s *Store) StartWeeklySettlement(ctx context.Context, cfg SettlementConfig)

  // NextMondayUTC returns the next UTC Monday 00:00 after t.
  func NextMondayUTC(t time.Time) time.Time

### C.6 snapshot.go — config snapshot on startup/reload

  // InsertConfigSnapshot writes one ledger_config_snapshots row.
  // Called on coordinator startup and after valid config reload.
  // Idempotent: if config_hash already exists, returns (existing_id, nil).
  func (s *Store) InsertConfigSnapshot(ctx context.Context, cfg RewardsConfig, now time.Time) (int64, error)

  // LatestConfigSnapshotAt returns the id of the most recent snapshot
  // whose effective_at_utc <= t. Returns (0, ErrNoSnapshot) if none.
  func (s *Store) LatestConfigSnapshotAt(ctx context.Context, t time.Time) (int64, error)

  var ErrNoSnapshot = errors.New("no config snapshot found")

config_hash is sha256(canonical JSON of provider_share_bps +
global_multiplier_ppm + rate_card sorted by key) encoded as hex.

### C.7 endpoints.go — four JSON handlers

  // Handlers returns an http.Handler with the four SPEC-005 endpoints.
  // Mounted by the caller:
  //   providerMux.Handle("/admin/ledger/", billingHandler)
  //   providerMux.Handle("/providers/", billingHandler)
  //
  // Admin endpoints require the operator key (same bearer-token check
  // as existing /admin/* handlers in buyer/server.go).
  //
  // Provider earnings endpoint requires a valid FR-P12 bearer token
  // whose subject equals the path provider_id.
  //
  // When requireProviderTokens is false, /providers/{id}/earnings
  // returns 503 {"error":{"code":"unavailable",
  // "message":"provider tokens not enabled"}}.
  func (s *Store) Handlers(
      operatorKey string,
      tokenStore interface {
          ValidateToken(ctx context.Context, raw string) (providerID string, err error)
      },
      requireProviderTokens bool,
      earningsRateLimitPerMin int,
  ) http.Handler

Implement all four endpoints per §§ 11.1–11.5 with the exact JSON
shapes shown in the spec examples:

GET /admin/ledger/summary
  Totals: SUM(provider_credits), SUM(operator_credits), SUM(gross_credits)
  from ledger_request_credits WHERE quarantined=0.
  current_window_provider_credits: WHERE ts_utc >= current Monday 00:00 UTC.
  Pending payouts: COUNT(*) + SUM(provider_credits) from ledger_payout_ready
  WHERE status='ready'.
  quarantined_count: COUNT(*) from ledger_request_credits WHERE quarantined=1.
  fault_count: COUNT(*) WHERE fault_flag != 'none'.
  last_reconciliation_delta_credits: most recent ledger_reconciliation_runs row.

GET /admin/ledger/providers
  Optional: limit (default 50, max 200), cursor (last provider_id seen),
  include_quarantined (bool, default false).
  One object per provider_id sorted alphabetically.

GET /admin/ledger/reconcile?from=YYYY-MM-DD&to=YYYY-MM-DD
  Both params required; return 400 if missing or malformed.
  Compute buyer_equivalent_credits by running the D8 matrix (§ 6) over
  request_log rows in range — read-only scan, no ledger mutations.
  Write one ledger_reconciliation_runs row with run_type='admin_reconcile'.
  delta_gross_credits = provider_gross_credits - buyer_equivalent_credits.
  split_delta_rows = count of rows where provider_credits + operator_credits
  != gross_credits.

GET /providers/{provider_id}/earnings
  Parse provider_id from URL path.
  Validate FR-P12 bearer token; subject must equal provider_id.
  Return: total_credits, current_window_credits, last_payout_ready row
  (window dates, provider_credits, status), provider_share_bps,
  models_served (DISTINCT model from ledger_request_credits),
  rate_card_excerpt for those models, fault_count.
  401 if no token. 403 if subject mismatch. 404 if provider_id unknown.

All error responses use envelope:
  {"error":{"code":"...","message":"..."}}

Build check after C.7:
  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...

---

## PART D — Wire into buyer/server.go and main.go

### D.1 buyer/server.go

Add fields to Server struct:
  billing    *billing.Store
  billingCfg config.RewardsConfig

Add functional option:
  func WithBilling(s *billing.Store, cfg config.RewardsConfig) Option

In the logRow closure (the Phase 0 request-log write hook):

  When s.billing != nil AND providerAssignedID != "" AND status != 503:
    Replace the standalone s.reqLog.Insert(...) call with
    s.billing.WriteHotPath(...) which handles both request_log write
    AND ledger writes atomically in one transaction.

  When status == 503 (provider-not-reached, § 6.2):
    Write request_log only — call s.reqLog.Insert(...) directly.
    WriteHotPath is NOT called for 503.

  When s.billing == nil (existing tests):
    Keep calling s.reqLog.Insert(...) as before.
    Zero behaviour change for all existing tests.

To call WriteHotPath you need the stable provider_id (not assigned_id).
Check the pool.Provider struct — it should carry a stable ProviderID
field already. Use it directly from the provider variable already in
scope in handleChatCompletions. Do not add new methods to pool.Registry
unless the field is genuinely absent.

You also need the current config snapshot ID. Fetch it once at server
construction and cache it in the Server struct, refreshed on config
reload. Add a field:
  billingSnapshotID int64
Set it during billing.InsertConfigSnapshot in main.go and pass it in
via a server option, or expose a SetSnapshotID method. Choose the
simplest approach.

### D.2 main.go

After reqLogStore is opened:

  billingStore, err := billing.NewStore(reqLogStore.DB())
  if err != nil {
      fmt.Fprintf(os.Stderr, "billing: %v\n", err)
      os.Exit(1)
  }

  snapshotID, err := billingStore.InsertConfigSnapshot(
      context.Background(), cfg.Rewards, time.Now().UTC(),
  )
  if err != nil {
      fmt.Fprintf(os.Stderr, "billing config snapshot: %v\n", err)
      os.Exit(1)
  }

Pass to buyer.NewServer:
  buyer.WithBilling(billingStore, cfg.Rewards),
  buyer.WithBillingSnapshotID(snapshotID),  // or however you pass the ID

After servers are constructed, before ListenAndServe:

  // Startup scan
  if err := billingStore.StartStartupScan(
      context.Background(), cfg.Settlement, time.Now().UTC(),
  ); err != nil {
      logger.Warn().Err(err).Msg("billing startup scan failed")
  }

  // Background jobs — use the existing shutdown context
  billingStore.StartNightlyReconcile(shutdownCtx, cfg.Settlement)
  billingStore.StartWeeklySettlement(shutdownCtx, cfg.Settlement)

Mount billing handlers:
  billingHandler := billingStore.Handlers(
      cfg.Auth.OperatorKey,
      tokenStore,
      cfg.Auth.RequireProviderTokens,
      cfg.Endpoints.ProviderEarningsRateLimitPerMinute,
  )
  providerMux.Handle("/admin/ledger/", billingHandler)
  providerMux.Handle("/providers/", billingHandler)

Build check:
  cd phase4-coordinator && GOCACHE=/private/tmp/macprovider-go-build-cache go build ./...

---

## PART E — Tests

### E.1 phase4-coordinator/internal/billing/formula_test.go

TestComputeCredits_WorkedExamples — verify all four worked examples
from SPEC-005 § 5.4 exactly:
  200, 1000 prompt + 2000 completion, 7B rates (1M/2M):
    gross=5000, provider=4500, operator=500
  502 prompt-only, 1000 prompt, 7B rates:
    gross=1000, provider=900, operator=100
  null_error: gross=0, provider=0, operator=0
  Unknown model falls back to default rates (500K/1M):
    1000 prompt + 500 completion → verify default rates used

TestRoundHalfEven — banker's rounding:
  numerator=5, denominator=10 → 0 (rounds to even 0)
  numerator=15, denominator=10 → 2 (rounds to even 2)
  numerator=4, denominator=10 → 0 (rounds down)
  numerator=6, denominator=10 → 1 (rounds up)

TestParseMultiplierPPM:
  1.0 → 1_000_000
  0.5 → 500_000
  2.0 → 2_000_000

TestParseShareBps:
  0.90 → 9000
  1.0  → 10000
  0.0  → 0

### E.2 phase4-coordinator/internal/billing/store_test.go

TestBillingMigration — open an in-memory *sql.DB (modernc.org/sqlite
with "file::memory:?cache=shared" or ":memory:"), run NewStore,
verify all six tables exist via PRAGMA table_info, and verify
idx_request_log_ts_utc and idx_request_log_request_id_id exist on
request_log via PRAGMA index_list. First create the request_log table
manually in the test DB using the same schema from requestlog/store.go
so MIG-005-007 validation passes.

TestInsertConfigSnapshot_Idempotent — insert same config twice,
verify exactly one row in ledger_config_snapshots.

TestWriteHotPath_ACID — shared in-memory DB for both requestlog and
billing stores. Write a hot-path row with providerAssignedID set.
Verify request_log, ledger_request_credits, ledger_operator_credits,
and ledger_provider_identity_snapshots each have exactly one row.
Verify ledger_operator_credits.request_credit_id references the
ledger_request_credits.id.

TestWriteHotPath_503_NoLedgerRows — ProviderAssignedID empty. Verify
request_log has one row; all three ledger tables have zero rows.

TestWriteHotPath_NullError_ZeroCredits — ErrorCode="error_model_not_loaded".
Verify gross_credits=0, provider_credits=0, operator_credits=0,
usage_source='null_error' in ledger_request_credits.

TestRecoverLedger_Idempotent — insert a request_log row with no
matching ledger row. Call RecoverLedger twice with the same window.
Verify exactly one ledger_request_credits row after both calls.

TestSettlement_ThresholdEnforced — provider_credits below threshold:
no ledger_payout_ready row. Provider at threshold: exactly one row.

TestSettlement_Idempotency — run RunSettlement twice on the same window.
Verify exactly one ledger_payout_ready row and no duplicate settlement_id.

TestNextMondayUTC — given Wednesday 2026-06-03, expect Monday 2026-06-08
00:00:00 UTC.

### E.3 phase4-coordinator/internal/billing/endpoints_test.go

TestSummaryEndpoint — insert known rows, call GET /admin/ledger/summary
with correct operator key, verify JSON keys match § 11.1 example shape
and total_provider_credits is correct.

TestProvidersEndpoint — insert rows for two providers, verify both
appear in GET /admin/ledger/providers response.

TestReconcileEndpoint_CleanDelta — insert request_log rows with matching
ledger rows using consistent token counts; call
GET /admin/ledger/reconcile?from=...&to=...; verify delta_gross_credits=0.

TestReconcileEndpoint_MissingParams — call without from/to params;
expect 400.

TestEarningsEndpoint_TokenRequired — call GET /providers/x/earnings
without bearer token; expect 401. Call with wrong-subject token;
expect 403.

TestEarningsEndpoint_DisabledWhenTokensOff — requireProviderTokens=false;
call /providers/x/earnings; expect 503 with code "unavailable".

---

## PART F — Full test suite

  cd phase4-coordinator && \
    GOCACHE=/private/tmp/macprovider-go-build-cache \
    go test ./... 2>&1 | tail -60

All tests must pass including all existing ones. Fix any failure before
proceeding to Part G.

---

## PART G — Commit

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
