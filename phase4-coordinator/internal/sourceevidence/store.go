package sourceevidence

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/requestlog"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

type Store struct {
	db      *sql.DB
	hmacKey []byte
	now     func() time.Time
}

type ClosureInput struct {
	TerminalKind string
	Row          requestlog.Row
}

type closureRow struct {
	ID                        int64
	RequestScopeCommitment    string
	InternalRequestCommitment string
	RequestID                 string
	RequestLogID              int64
	TerminalKind              string
	RequestLogStatus          int
	RequestLogErrorMessage    string
	RequestLogModelBlank      bool
	ClosedAtUTC               string
	CreatedAtUTC              string
}

type TableAbsence struct {
	Count int64 `json:"count"`
	MaxID int64 `json:"max_id"`
}

type ResolvedRecord struct {
	Scope         Scope
	Closure       closureRow
	ClosureIDHMAC string
	LogStatus     int
	AttemptN      int
	ProviderSet   bool
	Absence       map[string]TableAbsence
}

func NewStore(db *sql.DB, hmacKey []byte, now func() time.Time) (*Store, error) {
	if db == nil {
		return nil, fmt.Errorf("source evidence db is required")
	}
	if len(hmacKey) < 32 {
		return nil, fmt.Errorf("source evidence hmac key must be at least 32 bytes")
	}
	if now == nil {
		now = func() time.Time { return time.Now().UTC() }
	}
	return &Store{db: db, hmacKey: append([]byte(nil), hmacKey...), now: now}, nil
}

func (s *Store) HMACKey() []byte { return append([]byte(nil), s.hmacKey...) }

func Migrate(ctx context.Context, db *sql.DB) error {
	if db == nil {
		return fmt.Errorf("source evidence db is required")
	}
	_, err := db.ExecContext(ctx, schemaSQL)
	return err
}

func (s *Store) RecordNoDispatch(ctx context.Context, in ClosureInput) error {
	if s == nil {
		return ErrDisabled
	}
	if in.Row.ProviderAssignedID != "" {
		return fmt.Errorf("%w: provider assigned", ErrUnavailable)
	}
	if in.Row.Model != "" {
		return fmt.Errorf("%w: no-dispatch model must be blank", ErrUnavailable)
	}
	if in.Row.RequestID == "" || in.Row.AccountID == "" || in.Row.ExternalRequestID == "" {
		return fmt.Errorf("%w: missing request identity", ErrUnavailable)
	}
	if in.TerminalKind != TerminalModelNotFound && in.TerminalKind != TerminalPoolUnavailable {
		return fmt.Errorf("%w: unsupported terminal", ErrUnavailable)
	}
	if in.TerminalKind == TerminalModelNotFound && (in.Row.Status != 404 || in.Row.Error != "No provider has advertised the requested model") {
		return fmt.Errorf("%w: model-not-found row mismatch", ErrUnavailable)
	}
	if in.TerminalKind == TerminalPoolUnavailable && (in.Row.Status != 503 || in.Row.Error != "Pool unavailable") {
		return fmt.Errorf("%w: pool-unavailable row mismatch", ErrUnavailable)
	}
	scope := Scope{AccountID: in.Row.AccountID, ExternalRequestID: in.Row.ExternalRequestID, RequiredInternalRequestID: in.Row.RequestID}
	requestScope := ScopeCommitment(s.hmacKey, scope)
	internalScope := InternalRequestCommitment(s.hmacKey, in.Row.RequestID)
	nowText := sqliteTimeText(s.now())
	return sqliteutil.TransactObserved(ctx, s.db, "source_evidence_closure", nil, func(ctx context.Context, conn *sql.Conn) error {
		if count, err := countSettlementRows(ctx, conn, in.Row.RequestID); err != nil {
			return err
		} else if count != 0 {
			return fmt.Errorf("%w: settlement rows already exist", ErrUnavailable)
		}
		logID, err := requestlog.InsertExecReturningID(ctx, conn, in.Row)
		if err != nil {
			return err
		}
		var attemptN int
		if err := conn.QueryRowContext(ctx, `SELECT COALESCE(attempt_n, -1) FROM request_log WHERE id = ?`, logID).Scan(&attemptN); err != nil {
			return err
		}
		if attemptN != 0 {
			return fmt.Errorf("%w: no-dispatch closure requires first attempt", ErrUnavailable)
		}
		_, err = conn.ExecContext(ctx, `
INSERT INTO coordinator_source_no_dispatch_closures (
 request_scope_commitment, internal_request_commitment, account_id, external_request_id, request_id,
 request_log_id, terminal_kind, request_log_status, request_log_error_message, request_log_model_blank,
 closed_at_utc, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`, requestScope, internalScope, in.Row.AccountID, in.Row.ExternalRequestID, in.Row.RequestID, logID, in.TerminalKind, in.Row.Status, in.Row.Error, boolInt(in.Row.Model == ""), nowText, nowText)
		if err != nil {
			return fmt.Errorf("source evidence closure insert: %w", err)
		}
		return nil
	})
}

func (s *Store) ResolveClosed(ctx context.Context, scope Scope) (ResolvedRecord, error) {
	records, err := s.ResolveClosedBatch(ctx, []Scope{scope})
	if err != nil {
		return ResolvedRecord{}, err
	}
	if len(records) != 1 {
		return ResolvedRecord{}, ErrScopeNotClosed
	}
	return records[0], nil
}

func (s *Store) ResolveClosedBatch(ctx context.Context, scopes []Scope) ([]ResolvedRecord, error) {
	if s == nil {
		return nil, ErrDisabled
	}
	if len(scopes) == 0 {
		return nil, ErrInvalidRequest
	}
	conn, err := s.db.Conn(ctx)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if _, err := conn.ExecContext(ctx, `BEGIN`); err != nil {
		return nil, err
	}
	committed := false
	defer func() {
		if !committed {
			_, _ = conn.ExecContext(context.Background(), `ROLLBACK`)
		}
	}()
	out := make([]ResolvedRecord, 0, len(scopes))
	for _, scope := range scopes {
		resolved, err := s.resolveClosedInReadTx(ctx, conn, scope)
		if err != nil {
			return nil, err
		}
		out = append(out, resolved)
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		return nil, err
	}
	committed = true
	return out, nil
}

func (s *Store) resolveClosedInReadTx(ctx context.Context, conn *sql.Conn, scope Scope) (ResolvedRecord, error) {
	requestScope := ScopeCommitment(s.hmacKey, scope)
	var out ResolvedRecord
	out.Scope = scope
	var c closureRow
	err := conn.QueryRowContext(ctx, `
SELECT id, request_scope_commitment, internal_request_commitment, request_id, request_log_id, terminal_kind,
       request_log_status, request_log_error_message, request_log_model_blank, closed_at_utc, created_at_utc
  FROM coordinator_source_no_dispatch_closures
 WHERE account_id = ? AND external_request_id = ? AND request_id = ? AND request_scope_commitment = ?`, scope.AccountID, scope.ExternalRequestID, scope.RequiredInternalRequestID, requestScope).Scan(&c.ID, &c.RequestScopeCommitment, &c.InternalRequestCommitment, &c.RequestID, &c.RequestLogID, &c.TerminalKind, &c.RequestLogStatus, &c.RequestLogErrorMessage, &c.RequestLogModelBlank, &c.ClosedAtUTC, &c.CreatedAtUTC)
	if errors.Is(err, sql.ErrNoRows) {
		return out, ErrScopeNotClosed
	}
	if err != nil {
		return out, err
	}
	var ts string
	var model string
	var errorMsg string
	var provider sql.NullString
	var account, external, requestID string
	if err := conn.QueryRowContext(ctx, `SELECT ts_utc, account_id, external_request_id, request_id, model, error, provider_assigned_id, status, COALESCE(attempt_n,-1) FROM request_log WHERE id = ?`, c.RequestLogID).Scan(&ts, &account, &external, &requestID, &model, &errorMsg, &provider, &out.LogStatus, &out.AttemptN); err != nil {
		return out, err
	}
	if account != scope.AccountID || external != scope.ExternalRequestID || requestID != scope.RequiredInternalRequestID || requestID != c.RequestID || out.LogStatus != c.RequestLogStatus {
		return out, fmt.Errorf("%w: closure mismatch", ErrScopeNotClosed)
	}
	if provider.Valid && provider.String != "" {
		return out, fmt.Errorf("%w: provider assigned", ErrScopeNotClosed)
	}
	out.ProviderSet = provider.Valid && provider.String != ""
	if model != "" || !c.RequestLogModelBlank {
		return out, fmt.Errorf("%w: privacy redaction", ErrScopeNotClosed)
	}
	switch c.TerminalKind {
	case TerminalModelNotFound:
		if out.LogStatus != 404 || errorMsg != "No provider has advertised the requested model" || c.RequestLogErrorMessage != errorMsg {
			return out, fmt.Errorf("%w: privacy redaction", ErrScopeNotClosed)
		}
	case TerminalPoolUnavailable:
		if out.LogStatus != 503 || errorMsg != "Pool unavailable" || c.RequestLogErrorMessage != errorMsg {
			return out, fmt.Errorf("%w: closure mismatch", ErrScopeNotClosed)
		}
	default:
		return out, fmt.Errorf("%w: terminal kind", ErrScopeNotClosed)
	}
	if scope.NotBeforeUnixMS > 0 {
		fence := time.UnixMilli(scope.NotBeforeUnixMS).UTC()
		logTS, err := parseSQLiteTime(ts)
		if err != nil {
			return out, err
		}
		closedTS, err := parseSQLiteTime(c.ClosedAtUTC)
		if err != nil {
			return out, err
		}
		if logTS.Before(fence) || closedTS.Before(fence) {
			return out, fmt.Errorf("%w: stale scope fence", ErrScopeNotClosed)
		}
	}
	absence, err := settlementAbsence(ctx, conn, c.RequestID)
	if err != nil {
		return out, err
	}
	for _, a := range absence {
		if a.Count != 0 {
			return out, fmt.Errorf("%w: settlement rows after closure", ErrScopeNotClosed)
		}
	}
	out.Closure = c
	out.ClosureIDHMAC = ClosureIDCommitment(s.hmacKey, c.ID)
	out.Absence = absence
	return out, nil
}

func countSettlementRows(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, requestID string) (int64, error) {
	var total int64
	for _, table := range settlementTables {
		var n int64
		if err := q.QueryRowContext(ctx, `SELECT COUNT(*) FROM `+table+` WHERE request_id = ?`, requestID).Scan(&n); err != nil {
			return 0, err
		}
		total += n
	}
	return total, nil
}

func settlementAbsence(ctx context.Context, q interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}, requestID string) (map[string]TableAbsence, error) {
	out := make(map[string]TableAbsence, len(settlementTables))
	for _, table := range settlementTables {
		var a TableAbsence
		if err := q.QueryRowContext(ctx, `SELECT COUNT(*), COALESCE(MAX(id),0) FROM `+table+` WHERE request_id = ?`, requestID).Scan(&a.Count, &a.MaxID); err != nil {
			return nil, err
		}
		out[table] = a
	}
	return out, nil
}

var settlementTables = []string{"ledger_request_credits", "settlement_route_snapshots", "settlement_attempt_outputs", "settlement_receipt_verdicts"}

func boolInt(v bool) int {
	if v {
		return 1
	}
	return 0
}
func sqliteTimeText(t time.Time) string           { return t.UTC().Format("2006-01-02T15:04:05.000000000Z") }
func parseSQLiteTime(s string) (time.Time, error) { return time.Parse(time.RFC3339Nano, s) }

const schemaSQL = `
CREATE TABLE IF NOT EXISTS coordinator_source_no_dispatch_closures (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_scope_commitment TEXT NOT NULL UNIQUE CHECK(length(request_scope_commitment)=64 AND request_scope_commitment NOT GLOB '*[^0-9a-f]*'),
    internal_request_commitment TEXT NOT NULL CHECK(length(internal_request_commitment)=64 AND internal_request_commitment NOT GLOB '*[^0-9a-f]*'),
    account_id TEXT NOT NULL,
    external_request_id TEXT NOT NULL,
    request_id TEXT NOT NULL UNIQUE,
    request_log_id INTEGER NOT NULL UNIQUE,
    terminal_kind TEXT NOT NULL CHECK(terminal_kind IN ('model_not_found_no_dispatch','pool_unavailable_no_dispatch')),
    request_log_status INTEGER NOT NULL CHECK(request_log_status IN (404,503)),
    request_log_error_message TEXT NOT NULL,
    request_log_model_blank INTEGER NOT NULL CHECK(request_log_model_blank IN (0,1)),
    closed_at_utc TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    UNIQUE(account_id, external_request_id, request_id)
);
CREATE TRIGGER IF NOT EXISTS trg_csndc_no_update BEFORE UPDATE ON coordinator_source_no_dispatch_closures BEGIN SELECT RAISE(ABORT, 'coordinator no-dispatch closure is immutable'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_no_delete BEFORE DELETE ON coordinator_source_no_dispatch_closures BEGIN SELECT RAISE(ABORT, 'coordinator no-dispatch closure is immutable'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_lrc_no_insert_after_closure BEFORE INSERT ON ledger_request_credits WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot receive ledger credit'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_lrc_no_update_after_closure BEFORE UPDATE ON ledger_request_credits WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id OR c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot mutate ledger credit'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_lrc_no_delete_after_closure BEFORE DELETE ON ledger_request_credits WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot delete ledger credit'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_srs_no_insert_after_closure BEFORE INSERT ON settlement_route_snapshots WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot receive route snapshot'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_srs_no_update_after_closure BEFORE UPDATE ON settlement_route_snapshots WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id OR c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot mutate route snapshot'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_srs_no_delete_after_closure BEFORE DELETE ON settlement_route_snapshots WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot delete route snapshot'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_sao_no_insert_after_closure BEFORE INSERT ON settlement_attempt_outputs WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot receive settlement output'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_sao_no_update_after_closure BEFORE UPDATE ON settlement_attempt_outputs WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id OR c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot mutate settlement output'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_sao_no_delete_after_closure BEFORE DELETE ON settlement_attempt_outputs WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot delete settlement output'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_srv_no_insert_after_closure BEFORE INSERT ON settlement_receipt_verdicts WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot receive settlement verdict'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_srv_no_update_after_closure BEFORE UPDATE ON settlement_receipt_verdicts WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id OR c.request_id = NEW.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot mutate settlement verdict'); END;
CREATE TRIGGER IF NOT EXISTS trg_csndc_srv_no_delete_after_closure BEFORE DELETE ON settlement_receipt_verdicts WHEN EXISTS (SELECT 1 FROM coordinator_source_no_dispatch_closures c WHERE c.request_id = OLD.request_id) BEGIN SELECT RAISE(ABORT, 'closed no-dispatch request cannot delete settlement verdict'); END;`
