package billingmirror

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
	_ "github.com/lib/pq"
	_ "modernc.org/sqlite"
)

const (
	DefaultSQLitePath  = "/var/lib/macprovider/request-log.sqlite"
	DefaultBatchSize   = 5000
	DefaultOverlapRows = 1000
	DefaultRunTimeout  = 25 * time.Second

	StateSource = "sqlite-ledger-request-credits"
)

type Options struct {
	SQLitePath   string
	PostgresDSN  string
	BatchSize    int
	OverlapRows  int64
	SweepRows    int
	MaxBatches   int
	EnsureSchema bool
	DryRun       bool
	Stdout       io.Writer
}

type Result struct {
	RequestRowsRead     int
	RequestRowsUpserted int
	ProviderRowsRead    int
	ProviderRowsEnsured int
	LastRequestID       int64
	SweepAfterID        int64
	SourceMaxID         int64
	PendingRequestRows  int64
	DryRun              bool
}

type RequestCredit struct {
	SQLiteID                  int64
	RequestID                 string
	AttemptN                  int
	ProviderID                string
	TSUTC                     time.Time
	CreatedAtUTC              time.Time
	UpdatedAtUTC              sql.NullTime
	PromptTokens              sql.NullInt64
	CompletionTokens          sql.NullInt64
	EstimatedCompletionTokens sql.NullInt64
	UsageSource               string
	ProviderCredits           int64
	FaultFlag                 string
	Quarantined               bool
	SettlementPolicyMode      string
	Spec022Verified           bool
}

type ProviderIdentity struct {
	ProviderID   string
	ProviderName string
	CreatedAt    time.Time
	LastUsedAt   sql.NullTime
}

type State struct {
	LastRequestID int64
	SweepAfterID  int64
}

func Run(parent context.Context, opts Options) (Result, error) {
	opts = normalizeOptions(opts)
	out := opts.Stdout
	if out == nil {
		out = io.Discard
	}
	if opts.SQLitePath == "" {
		return Result{}, errors.New("sqlite path is required")
	}
	if opts.PostgresDSN == "" && !opts.DryRun {
		return Result{}, errors.New("postgres dsn is required")
	}

	ctx, cancel := context.WithTimeout(parent, DefaultRunTimeout)
	defer cancel()

	source, err := OpenSQLite(opts.SQLitePath)
	if err != nil {
		return Result{}, err
	}
	defer source.Close()

	var pg *sql.DB
	var state State
	if !opts.DryRun {
		pg, err = OpenPostgres(opts.PostgresDSN)
		if err != nil {
			return Result{}, err
		}
		defer pg.Close()
		if opts.EnsureSchema {
			if err := EnsureSchema(ctx, pg); err != nil {
				return Result{}, err
			}
		}
		state, err = LoadState(ctx, pg)
		if err != nil {
			return Result{}, err
		}
	}

	maxSourceID, err := FetchMaxRequestCreditID(ctx, source)
	if err != nil {
		return Result{}, err
	}
	newRows := make([]RequestCredit, 0, opts.BatchSize)
	newCursor := state.LastRequestID
	for batch := 0; batch < opts.MaxBatches; batch++ {
		batchRows, err := FetchRequestCredits(ctx, source, newCursor, opts.BatchSize)
		if err != nil {
			return Result{}, err
		}
		if len(batchRows) == 0 {
			break
		}
		newRows = append(newRows, batchRows...)
		newCursor = maxSQLiteID(batchRows, newCursor)
		if len(batchRows) < opts.BatchSize {
			break
		}
	}
	nextLastRequestID := maxSQLiteID(newRows, state.LastRequestID)
	rows := newRows
	if state.LastRequestID > 0 && opts.OverlapRows > 0 {
		startID := state.LastRequestID - opts.OverlapRows
		if startID < 0 {
			startID = 0
		}
		overlapRows, err := FetchRequestCreditsThrough(ctx, source, startID, state.LastRequestID, minInt(opts.BatchSize, int(opts.OverlapRows)))
		if err != nil {
			return Result{}, err
		}
		rows = mergeRequestCredits(overlapRows, rows)
	}
	nextSweepAfterID := state.SweepAfterID
	if opts.SweepRows > 0 && maxSourceID > 0 {
		sweepStart := state.SweepAfterID
		if sweepStart >= maxSourceID {
			sweepStart = 0
		}
		sweepRows, err := FetchRequestCreditsThrough(ctx, source, sweepStart, maxSourceID, opts.SweepRows)
		if err != nil {
			return Result{}, err
		}
		rows = mergeRequestCredits(rows, sweepRows)
		nextSweepAfterID = maxSQLiteID(sweepRows, sweepStart)
		if nextSweepAfterID >= maxSourceID {
			nextSweepAfterID = 0
		}
	}
	providers, err := FetchProviderIdentities(ctx, source)
	if err != nil {
		return Result{}, err
	}
	result := Result{
		RequestRowsRead:  len(rows),
		ProviderRowsRead: len(providers),
		DryRun:           opts.DryRun,
		LastRequestID:    nextLastRequestID,
		SweepAfterID:     nextSweepAfterID,
		SourceMaxID:      maxSourceID,
	}
	if maxSourceID > result.LastRequestID {
		result.PendingRequestRows = maxSourceID - result.LastRequestID
	}
	if opts.DryRun {
		fmt.Fprintf(out, "would upsert %d request credit rows and ensure %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsRead, result.ProviderRowsRead, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
		return result, nil
	}

	if err := Apply(ctx, pg, rows, providers, State{LastRequestID: result.LastRequestID, SweepAfterID: result.SweepAfterID}); err != nil {
		return Result{}, err
	}
	result.RequestRowsUpserted = len(rows)
	result.ProviderRowsEnsured = len(providers)
	fmt.Fprintf(out, "upserted %d request credit rows and ensured %d provider identities (last_request_id=%d source_max_id=%d pending_request_rows=%d sweep_after_id=%d)\n", result.RequestRowsUpserted, result.ProviderRowsEnsured, result.LastRequestID, result.SourceMaxID, result.PendingRequestRows, result.SweepAfterID)
	return result, nil
}

func normalizeOptions(opts Options) Options {
	opts.SQLitePath = strings.TrimSpace(opts.SQLitePath)
	if opts.SQLitePath == "" {
		opts.SQLitePath = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_SQLITE"))
	}
	if opts.SQLitePath == "" {
		opts.SQLitePath = DefaultSQLitePath
	}
	opts.PostgresDSN = strings.TrimSpace(opts.PostgresDSN)
	if opts.PostgresDSN == "" {
		opts.PostgresDSN = strings.TrimSpace(os.Getenv("STATS_BILLING_MIRROR_DSN"))
	}
	if opts.BatchSize <= 0 {
		opts.BatchSize = DefaultBatchSize
	}
	if opts.BatchSize > 50000 {
		opts.BatchSize = 50000
	}
	if opts.MaxBatches <= 0 {
		opts.MaxBatches = 5
	}
	if opts.MaxBatches > 20 {
		opts.MaxBatches = 20
	}
	if opts.OverlapRows < 0 {
		opts.OverlapRows = 0
	}
	if opts.OverlapRows == 0 {
		opts.OverlapRows = DefaultOverlapRows
	}
	if opts.OverlapRows > int64(opts.BatchSize) {
		opts.OverlapRows = int64(opts.BatchSize)
	}
	if opts.SweepRows < 0 {
		opts.SweepRows = 0
	}
	if opts.SweepRows == 0 {
		opts.SweepRows = opts.BatchSize
	}
	if opts.SweepRows > opts.BatchSize {
		opts.SweepRows = opts.BatchSize
	}
	return opts
}

func OpenSQLite(path string) (*sql.DB, error) {
	db, err := sql.Open("sqlite", sqliteutil.ReadOnlyDSN(path))
	if err != nil {
		return nil, fmt.Errorf("open sqlite: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	return db, nil
}

func OpenPostgres(dsn string) (*sql.DB, error) {
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("open postgres: %w", err)
	}
	db.SetMaxOpenConns(1)
	db.SetMaxIdleConns(1)
	db.SetConnMaxLifetime(5 * time.Minute)
	db.SetConnMaxIdleTime(time.Minute)
	return db, nil
}

func FetchRequestCredits(ctx context.Context, db *sql.DB, startID int64, limit int) ([]RequestCredit, error) {
	caps, err := detectRequestCreditSourceCapabilities(ctx, db)
	if err != nil {
		return nil, err
	}
	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, false), startID, limit)
}

func FetchMaxRequestCreditID(ctx context.Context, db *sql.DB) (int64, error) {
	var maxID sql.NullInt64
	if err := db.QueryRowContext(ctx, `SELECT MAX(id) FROM ledger_request_credits`).Scan(&maxID); err != nil {
		return 0, fmt.Errorf("select max ledger_request_credits id: %w", err)
	}
	if !maxID.Valid {
		return 0, nil
	}
	return maxID.Int64, nil
}

func FetchRequestCreditsThrough(ctx context.Context, db *sql.DB, startID, endID int64, limit int) ([]RequestCredit, error) {
	caps, err := detectRequestCreditSourceCapabilities(ctx, db)
	if err != nil {
		return nil, err
	}
	return scanRequestCredits(ctx, db, requestCreditsQuery(caps, true), startID, endID, limit)
}

type requestCreditSourceCapabilities struct {
	HasSettlementPolicyMode bool
	HasSpec022PayableView   bool
}

func detectRequestCreditSourceCapabilities(ctx context.Context, db *sql.DB) (requestCreditSourceCapabilities, error) {
	hasPolicy, err := sqliteColumnExists(ctx, db, "ledger_request_credits", "settlement_policy_mode")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	hasPayable, err := sqliteObjectExists(ctx, db, "spec022_payable_request_credits")
	if err != nil {
		return requestCreditSourceCapabilities{}, err
	}
	return requestCreditSourceCapabilities{
		HasSettlementPolicyMode: hasPolicy,
		HasSpec022PayableView:   hasPayable,
	}, nil
}

func requestCreditsQuery(caps requestCreditSourceCapabilities, bounded bool) string {
	policyExpr := "'legacy'"
	if caps.HasSettlementPolicyMode {
		policyExpr = "COALESCE(lrc.settlement_policy_mode, 'legacy')"
	}
	verifiedExpr := "0"
	if caps.HasSpec022PayableView {
		verifiedExpr = fmt.Sprintf(`CASE
           WHEN %s = 'enforce'
            AND EXISTS (SELECT 1 FROM spec022_payable_request_credits payable WHERE payable.id = lrc.id)
           THEN 1 ELSE 0
       END`, policyExpr)
	}
	where := "WHERE lrc.id > ?"
	if bounded {
		where += "\n   AND lrc.id <= ?"
	}
	return fmt.Sprintf(`
SELECT lrc.id, lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.ts_utc, lrc.created_at_utc, lrc.updated_at_utc,
       lrc.prompt_tokens, lrc.completion_tokens, lrc.estimated_completion_tokens, lrc.usage_source,
       lrc.provider_credits, lrc.fault_flag, lrc.quarantined,
       %s AS settlement_policy_mode,
       %s AS spec022_verified
  FROM ledger_request_credits lrc
 %s
 ORDER BY lrc.id
 LIMIT ?`, policyExpr, verifiedExpr, where)
}

func sqliteColumnExists(ctx context.Context, db *sql.DB, table, column string) (bool, error) {
	rows, err := db.QueryContext(ctx, `PRAGMA table_info(`+table+`)`)
	if err != nil {
		return false, fmt.Errorf("inspect sqlite table %s: %w", table, err)
	}
	defer rows.Close()
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			return false, err
		}
		if name == column {
			return true, nil
		}
	}
	return false, rows.Err()
}

func sqliteObjectExists(ctx context.Context, db *sql.DB, name string) (bool, error) {
	var exists bool
	err := db.QueryRowContext(ctx, `
        SELECT EXISTS (
            SELECT 1 FROM sqlite_master
             WHERE name = ?
               AND type IN ('table', 'view')
        )
    `, name).Scan(&exists)
	return exists, err
}

func scanRequestCredits(ctx context.Context, db *sql.DB, q string, args ...any) ([]RequestCredit, error) {
	cur, err := db.QueryContext(ctx, q, args...)
	if err != nil {
		return nil, fmt.Errorf("select ledger_request_credits: %w", err)
	}
	defer cur.Close()
	var out []RequestCredit
	for cur.Next() {
		var row RequestCredit
		var ts, created sql.NullString
		var updated sql.NullString
		var quarantined, spec022Verified int
		if err := cur.Scan(
			&row.SQLiteID, &row.RequestID, &row.AttemptN, &row.ProviderID,
			&ts, &created, &updated,
			&row.PromptTokens, &row.CompletionTokens, &row.EstimatedCompletionTokens,
			&row.UsageSource, &row.ProviderCredits, &row.FaultFlag, &quarantined,
			&row.SettlementPolicyMode, &spec022Verified,
		); err != nil {
			return nil, fmt.Errorf("scan ledger_request_credits: %w", err)
		}
		row.TSUTC, err = parseRequiredTime(ts, "ts_utc")
		if err != nil {
			return nil, err
		}
		row.CreatedAtUTC, err = parseRequiredTime(created, "created_at_utc")
		if err != nil {
			return nil, err
		}
		row.UpdatedAtUTC, err = parseOptionalTime(updated)
		if err != nil {
			return nil, fmt.Errorf("updated_at_utc: %w", err)
		}
		row.Quarantined = quarantined != 0
		row.Spec022Verified = spec022Verified != 0
		out = append(out, row)
	}
	if err := cur.Err(); err != nil {
		return nil, fmt.Errorf("iterate ledger_request_credits: %w", err)
	}
	return out, nil
}

func FetchProviderIdentities(ctx context.Context, db *sql.DB) ([]ProviderIdentity, error) {
	const q = `
SELECT provider_id,
       COALESCE(MAX(NULLIF(provider_name, '')), provider_id) AS provider_name,
       COALESCE(MIN(created_at), strftime('%Y-%m-%dT%H:%M:%SZ', 'now')) AS created_at,
       MAX(last_used_at) AS last_used_at
  FROM provider_tokens
 WHERE provider_id <> ''
 GROUP BY provider_id
 ORDER BY provider_id`
	cur, err := db.QueryContext(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("select provider_tokens: %w", err)
	}
	defer cur.Close()
	var out []ProviderIdentity
	for cur.Next() {
		var p ProviderIdentity
		var created sql.NullString
		var lastUsed sql.NullString
		if err := cur.Scan(&p.ProviderID, &p.ProviderName, &created, &lastUsed); err != nil {
			return nil, fmt.Errorf("scan provider_tokens: %w", err)
		}
		createdAt, err := parseRequiredTime(created, "provider_tokens.created_at")
		if err != nil {
			return nil, err
		}
		p.CreatedAt = createdAt
		p.LastUsedAt, err = parseOptionalTime(lastUsed)
		if err != nil {
			return nil, fmt.Errorf("provider_tokens.last_used_at: %w", err)
		}
		out = append(out, p)
	}
	if err := cur.Err(); err != nil {
		return nil, fmt.Errorf("iterate provider_tokens: %w", err)
	}
	return out, nil
}

func Apply(ctx context.Context, db *sql.DB, rows []RequestCredit, providers []ProviderIdentity, state State) error {
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin mirror transaction: %w", err)
	}
	committed := false
	defer func() {
		if !committed {
			_ = tx.Rollback()
		}
	}()
	var locked bool
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock(47017, 1711)`).Scan(&locked); err != nil {
		return fmt.Errorf("acquire mirror advisory lock: %w", err)
	}
	if !locked {
		return errors.New("another stats billing mirror run is active")
	}
	for _, p := range providers {
		if err := ensureProvider(ctx, tx, p); err != nil {
			return err
		}
	}
	for _, row := range rows {
		if err := upsertRequestCredit(ctx, tx, row); err != nil {
			return err
		}
	}
	if err := SaveState(ctx, tx, state); err != nil {
		return err
	}
	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit mirror transaction: %w", err)
	}
	committed = true
	return nil
}

func EnsureSchema(ctx context.Context, db *sql.DB) error {
	for _, stmt := range schemaStatements {
		if _, err := db.ExecContext(ctx, stmt); err != nil {
			return fmt.Errorf("ensure stats billing mirror schema: %w", err)
		}
	}
	return nil
}

func LoadState(ctx context.Context, db *sql.DB) (State, error) {
	var state State
	if err := db.QueryRowContext(ctx, `SELECT last_request_credit_id, sweep_after_request_credit_id FROM stats_billing_mirror_load_state($1)`, StateSource).Scan(&state.LastRequestID, &state.SweepAfterID); err != nil {
		return State{}, fmt.Errorf("load mirror state: %w", err)
	}
	return state, nil
}

func SaveState(ctx context.Context, tx *sql.Tx, state State) error {
	if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_save_state($1, $2, $3)`,
		StateSource, state.LastRequestID, state.SweepAfterID); err != nil {
		return fmt.Errorf("save mirror state: %w", err)
	}
	return nil
}

func ensureProvider(ctx context.Context, tx *sql.Tx, p ProviderIdentity) error {
	tokenHash := syntheticTokenHash(p.ProviderID)
	if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_ensure_provider($1, $2, $3, $4, $5)`,
		tokenHash, p.ProviderID, p.ProviderName, p.CreatedAt, nullTimeArg(p.LastUsedAt)); err != nil {
		return fmt.Errorf("ensure provider %q: %w", p.ProviderID, err)
	}
	return nil
}

func upsertRequestCredit(ctx context.Context, tx *sql.Tx, row RequestCredit) error {
	if _, err := tx.ExecContext(ctx, `SELECT stats_billing_mirror_upsert_request_credit(
    $1, $2, $3, $4, $5, $6, $7,
    $8, $9, $10, $11,
    $12, $13, $14, $15, $16
)`,
		row.SQLiteID, row.RequestID, row.AttemptN, row.ProviderID, row.TSUTC, row.CreatedAtUTC, nullTimeArg(row.UpdatedAtUTC),
		nullInt64Arg(row.PromptTokens), nullInt64Arg(row.CompletionTokens), nullInt64Arg(row.EstimatedCompletionTokens),
		row.UsageSource, row.ProviderCredits, row.FaultFlag, row.Quarantined, row.SettlementPolicyMode, row.Spec022Verified); err != nil {
		return fmt.Errorf("upsert request credit %q/%d/%q: %w", row.RequestID, row.AttemptN, row.ProviderID, err)
	}
	return nil
}

func mergeRequestCredits(a, b []RequestCredit) []RequestCredit {
	if len(b) == 0 {
		return a
	}
	byKey := make(map[string]RequestCredit, len(a)+len(b))
	for _, row := range a {
		byKey[requestCreditKey(row)] = row
	}
	for _, row := range b {
		byKey[requestCreditKey(row)] = row
	}
	out := make([]RequestCredit, 0, len(byKey))
	for _, row := range byKey {
		out = append(out, row)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].SQLiteID == out[j].SQLiteID {
			return requestCreditKey(out[i]) < requestCreditKey(out[j])
		}
		return out[i].SQLiteID < out[j].SQLiteID
	})
	return out
}

func requestCreditKey(row RequestCredit) string {
	return row.RequestID + "\x00" + fmt.Sprint(row.AttemptN) + "\x00" + row.ProviderID
}

func maxSQLiteID(rows []RequestCredit, floor int64) int64 {
	out := floor
	for _, row := range rows {
		if row.SQLiteID > out {
			out = row.SQLiteID
		}
	}
	return out
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func syntheticTokenHash(providerID string) string {
	sum := sha256.Sum256([]byte("stats-billing-mirror\x00" + providerID))
	return "stats-mirror-sha256:" + hex.EncodeToString(sum[:])
}

func parseRequiredTime(v sql.NullString, field string) (time.Time, error) {
	if !v.Valid || strings.TrimSpace(v.String) == "" {
		return time.Time{}, fmt.Errorf("%s is required", field)
	}
	t, err := parseTimeText(v.String)
	if err != nil {
		return time.Time{}, fmt.Errorf("%s: %w", field, err)
	}
	return t, nil
}

func parseOptionalTime(v sql.NullString) (sql.NullTime, error) {
	if !v.Valid || strings.TrimSpace(v.String) == "" {
		return sql.NullTime{}, nil
	}
	t, err := parseTimeText(v.String)
	if err != nil {
		return sql.NullTime{}, err
	}
	return sql.NullTime{Time: t, Valid: true}, nil
}

func parseTimeText(raw string) (time.Time, error) {
	raw = strings.TrimSpace(raw)
	for _, layout := range []string{time.RFC3339Nano, time.RFC3339, "2006-01-02 15:04:05.999999999Z07:00", "2006-01-02 15:04:05"} {
		if t, err := time.Parse(layout, raw); err == nil {
			return t.UTC(), nil
		}
	}
	return time.Time{}, fmt.Errorf("invalid timestamp %q", raw)
}

func nullTimeArg(v sql.NullTime) any {
	if !v.Valid {
		return nil
	}
	return v.Time.UTC()
}

func nullInt64Arg(v sql.NullInt64) any {
	if !v.Valid {
		return nil
	}
	return v.Int64
}

var schemaStatements = []string{
	`CREATE TABLE IF NOT EXISTS ledger_request_credits (
    id BIGSERIAL PRIMARY KEY,
    sqlite_lrc_id BIGINT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL CHECK (attempt_n >= 0),
    provider_id TEXT NOT NULL,
    ts_utc TIMESTAMPTZ NOT NULL,
    created_at_utc TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at_utc TIMESTAMPTZ,
    prompt_tokens BIGINT CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0),
    completion_tokens BIGINT CHECK (completion_tokens IS NULL OR completion_tokens >= 0),
    estimated_completion_tokens BIGINT CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0),
    usage_source TEXT NOT NULL DEFAULT 'provider_reported' CHECK (usage_source IN ('provider_reported','byte_estimated','null_error')),
    provider_credits BIGINT NOT NULL DEFAULT 0 CHECK (provider_credits >= 0),
    fault_flag TEXT NOT NULL DEFAULT 'none' CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error')),
    quarantined BOOLEAN NOT NULL DEFAULT FALSE,
    settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy' CHECK (settlement_policy_mode IN ('legacy','observe','enforce')),
    spec022_verified BOOLEAN NOT NULL DEFAULT FALSE
)`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS sqlite_lrc_id BIGINT`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS request_id TEXT`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS attempt_n INTEGER`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_id TEXT`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS ts_utc TIMESTAMPTZ`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS created_at_utc TIMESTAMPTZ DEFAULT now()`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS updated_at_utc TIMESTAMPTZ`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS prompt_tokens BIGINT`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS completion_tokens BIGINT`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS estimated_completion_tokens BIGINT`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS usage_source TEXT DEFAULT 'provider_reported'`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS provider_credits BIGINT DEFAULT 0`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS fault_flag TEXT DEFAULT 'none'`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS quarantined BOOLEAN DEFAULT FALSE`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS settlement_policy_mode TEXT DEFAULT 'legacy'`,
	`ALTER TABLE ledger_request_credits ADD COLUMN IF NOT EXISTS spec022_verified BOOLEAN DEFAULT FALSE`,
	`UPDATE ledger_request_credits SET settlement_policy_mode = 'legacy' WHERE settlement_policy_mode IS NULL`,
	`UPDATE ledger_request_credits SET spec022_verified = FALSE WHERE spec022_verified IS NULL`,
	`DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_attempt_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_attempt_nonnegative CHECK (attempt_n >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_prompt_tokens_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_prompt_tokens_nonnegative CHECK (prompt_tokens IS NULL OR prompt_tokens >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_completion_tokens_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_completion_tokens_nonnegative CHECK (completion_tokens IS NULL OR completion_tokens >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_estimated_completion_tokens_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_estimated_completion_tokens_nonnegative CHECK (estimated_completion_tokens IS NULL OR estimated_completion_tokens >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_usage_source_enum') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_usage_source_enum CHECK (usage_source IN ('provider_reported','byte_estimated','null_error'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_provider_credits_nonnegative') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_provider_credits_nonnegative CHECK (provider_credits >= 0);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_fault_flag_enum') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_fault_flag_enum CHECK (fault_flag IN ('none','breaker_qualifying','null_usage_error'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_settlement_policy_mode_enum') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_settlement_policy_mode_enum CHECK (settlement_policy_mode IN ('legacy','observe','enforce'));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_spec022_verified_not_null') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_not_null CHECK (spec022_verified IS NOT NULL);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'lrc_mirror_spec022_verified_enforce_check') THEN
        ALTER TABLE ledger_request_credits ADD CONSTRAINT lrc_mirror_spec022_verified_enforce_check CHECK (spec022_verified = FALSE OR settlement_policy_mode = 'enforce');
    END IF;
END $$`,
	`CREATE UNIQUE INDEX IF NOT EXISTS idx_lrc_mirror_unique_attempt ON ledger_request_credits(request_id, attempt_n, provider_id)`,
	`CREATE INDEX IF NOT EXISTS idx_lrc_mirror_provider_ts ON ledger_request_credits(provider_id, ts_utc)`,
	`CREATE TABLE IF NOT EXISTS ledger_request_credit_spec022_verified_audit (
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    sqlite_lrc_id BIGINT,
    provider_credits BIGINT NOT NULL,
    settlement_policy_mode TEXT NOT NULL CHECK (settlement_policy_mode = 'enforce'),
    source TEXT NOT NULL DEFAULT 'stats_billing_mirror',
    mirrored_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (request_id, attempt_n, provider_id)
)`,
	`CREATE TABLE IF NOT EXISTS provider_tokens (
    id BIGSERIAL PRIMARY KEY,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL DEFAULT '',
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at TIMESTAMPTZ,
    last_used_at TIMESTAMPTZ
)`,
	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS token_prefix TEXT DEFAULT ''`,
	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_id TEXT DEFAULT ''`,
	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS provider_name TEXT DEFAULT ''`,
	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT now()`,
	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS revoked_at TIMESTAMPTZ`,
	`ALTER TABLE provider_tokens ADD COLUMN IF NOT EXISTS last_used_at TIMESTAMPTZ`,
	`CREATE UNIQUE INDEX IF NOT EXISTS idx_provider_tokens_one_active_per_provider
    ON provider_tokens(provider_id)
    WHERE revoked_at IS NULL AND provider_id <> ''`,
	`CREATE TABLE IF NOT EXISTS stats_billing_mirror_state (
    source TEXT PRIMARY KEY,
    last_request_credit_id BIGINT NOT NULL DEFAULT 0,
    sweep_after_request_credit_id BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
)`,
	`ALTER TABLE stats_billing_mirror_state ADD COLUMN IF NOT EXISTS sweep_after_request_credit_id BIGINT NOT NULL DEFAULT 0`,
	`CREATE OR REPLACE FUNCTION stats_billing_mirror_load_state(p_source TEXT)
RETURNS TABLE(last_request_credit_id BIGINT, sweep_after_request_credit_id BIGINT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO stats_billing_mirror_state (source, last_request_credit_id, sweep_after_request_credit_id)
    VALUES (p_source, 0, 0)
    ON CONFLICT (source) DO NOTHING;

    SELECT s.last_request_credit_id, s.sweep_after_request_credit_id
      FROM stats_billing_mirror_state s
     WHERE s.source = p_source;
$$`,
	`CREATE OR REPLACE FUNCTION stats_billing_mirror_save_state(p_source TEXT, p_last_request_credit_id BIGINT, p_sweep_after_request_credit_id BIGINT)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO stats_billing_mirror_state (source, last_request_credit_id, sweep_after_request_credit_id, updated_at)
    VALUES (p_source, p_last_request_credit_id, p_sweep_after_request_credit_id, now())
    ON CONFLICT (source) DO UPDATE SET
        last_request_credit_id = GREATEST(stats_billing_mirror_state.last_request_credit_id, EXCLUDED.last_request_credit_id),
        sweep_after_request_credit_id = EXCLUDED.sweep_after_request_credit_id,
        updated_at = EXCLUDED.updated_at;
$$`,
	`CREATE OR REPLACE FUNCTION stats_billing_mirror_ensure_provider(
    p_token_hash TEXT,
    p_provider_id TEXT,
    p_provider_name TEXT,
    p_created_at TIMESTAMPTZ,
    p_last_used_at TIMESTAMPTZ
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
    INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
    SELECT p_token_hash, 'stats-mirror', p_provider_id, p_provider_name, p_created_at, p_last_used_at
    WHERE NOT EXISTS (
        SELECT 1 FROM provider_tokens WHERE provider_id = p_provider_id AND provider_id <> ''
    )
    ON CONFLICT (token_hash) DO UPDATE SET
        provider_id = EXCLUDED.provider_id,
        provider_name = EXCLUDED.provider_name,
        last_used_at = EXCLUDED.last_used_at;
$$`,
	`CREATE OR REPLACE FUNCTION stats_billing_mirror_upsert_request_credit(
    p_sqlite_lrc_id BIGINT,
    p_request_id TEXT,
    p_attempt_n INTEGER,
    p_provider_id TEXT,
    p_ts_utc TIMESTAMPTZ,
    p_created_at_utc TIMESTAMPTZ,
    p_updated_at_utc TIMESTAMPTZ,
    p_prompt_tokens BIGINT,
    p_completion_tokens BIGINT,
    p_estimated_completion_tokens BIGINT,
    p_usage_source TEXT,
    p_provider_credits BIGINT,
    p_fault_flag TEXT,
    p_quarantined BOOLEAN,
    p_settlement_policy_mode TEXT,
    p_spec022_verified BOOLEAN
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_settlement_policy_mode TEXT := COALESCE(NULLIF(p_settlement_policy_mode, ''), 'legacy');
    v_spec022_verified BOOLEAN;
    v_was_spec022_verified BOOLEAN;
BEGIN
    IF v_settlement_policy_mode NOT IN ('legacy','observe','enforce') THEN
        RAISE EXCEPTION 'invalid settlement_policy_mode: %', v_settlement_policy_mode;
    END IF;

    v_spec022_verified :=
        v_settlement_policy_mode = 'enforce'
        AND COALESCE(p_spec022_verified, FALSE)
        AND COALESCE(p_provider_credits, 0) > 0
        AND NOT COALESCE(p_quarantined, FALSE);

    SELECT spec022_verified
      INTO v_was_spec022_verified
      FROM ledger_request_credits
     WHERE request_id = p_request_id
       AND attempt_n = p_attempt_n
       AND provider_id = p_provider_id
     FOR UPDATE;

    INSERT INTO ledger_request_credits (
        sqlite_lrc_id, request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
        prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
        provider_credits, fault_flag, quarantined, settlement_policy_mode, spec022_verified
    ) VALUES (
        p_sqlite_lrc_id, p_request_id, p_attempt_n, p_provider_id, p_ts_utc, p_created_at_utc, p_updated_at_utc,
        p_prompt_tokens, p_completion_tokens, p_estimated_completion_tokens, p_usage_source,
        p_provider_credits, p_fault_flag, COALESCE(p_quarantined, FALSE), v_settlement_policy_mode, v_spec022_verified
    )
    ON CONFLICT (request_id, attempt_n, provider_id) DO UPDATE SET
        sqlite_lrc_id = EXCLUDED.sqlite_lrc_id,
        ts_utc = EXCLUDED.ts_utc,
        created_at_utc = EXCLUDED.created_at_utc,
        updated_at_utc = EXCLUDED.updated_at_utc,
        prompt_tokens = EXCLUDED.prompt_tokens,
        completion_tokens = EXCLUDED.completion_tokens,
        estimated_completion_tokens = EXCLUDED.estimated_completion_tokens,
        usage_source = EXCLUDED.usage_source,
        provider_credits = EXCLUDED.provider_credits,
        fault_flag = EXCLUDED.fault_flag,
        quarantined = EXCLUDED.quarantined,
        settlement_policy_mode = EXCLUDED.settlement_policy_mode,
        spec022_verified = EXCLUDED.spec022_verified;

    IF v_spec022_verified AND NOT COALESCE(v_was_spec022_verified, FALSE) THEN
        INSERT INTO ledger_request_credit_spec022_verified_audit (
            request_id, attempt_n, provider_id, sqlite_lrc_id,
            provider_credits, settlement_policy_mode
        ) VALUES (
            p_request_id, p_attempt_n, p_provider_id, p_sqlite_lrc_id,
            p_provider_credits, v_settlement_policy_mode
        )
        ON CONFLICT (request_id, attempt_n, provider_id) DO NOTHING;
    END IF;
END;
$$`,
	`DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_rollup') THEN
        GRANT SELECT ON ledger_request_credits TO stats_rollup;
        GRANT SELECT ON provider_tokens TO stats_rollup;
    END IF;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rewards_writer') THEN
        GRANT SELECT ON ledger_request_credits TO rewards_writer;
    END IF;
    REVOKE ALL ON FUNCTION stats_billing_mirror_load_state(TEXT) FROM PUBLIC;
    REVOKE ALL ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) FROM PUBLIC;
    REVOKE ALL ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) FROM PUBLIC;
    IF EXISTS (
        SELECT 1
          FROM pg_proc p
          JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public'
           AND p.proname = 'stats_billing_mirror_upsert_request_credit'
           AND p.pronargs = 14
    ) THEN
        REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN) FROM PUBLIC;
    END IF;
    REVOKE ALL ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) FROM PUBLIC;
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'stats_billing_mirror_writer') THEN
        REVOKE ALL ON ledger_request_credits FROM stats_billing_mirror_writer;
        REVOKE ALL ON provider_tokens FROM stats_billing_mirror_writer;
        REVOKE ALL ON stats_billing_mirror_state FROM stats_billing_mirror_writer;
        REVOKE ALL ON ledger_request_credit_spec022_verified_audit FROM stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_load_state(TEXT) TO stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_save_state(TEXT, BIGINT, BIGINT) TO stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_ensure_provider(TEXT, TEXT, TEXT, TIMESTAMPTZ, TIMESTAMPTZ) TO stats_billing_mirror_writer;
        GRANT EXECUTE ON FUNCTION stats_billing_mirror_upsert_request_credit(BIGINT, TEXT, INTEGER, TEXT, TIMESTAMPTZ, TIMESTAMPTZ, TIMESTAMPTZ, BIGINT, BIGINT, BIGINT, TEXT, BIGINT, TEXT, BOOLEAN, TEXT, BOOLEAN) TO stats_billing_mirror_writer;
    END IF;
END $$`,
}
