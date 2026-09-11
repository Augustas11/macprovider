package billing

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

const (
	wholesaleStatementsPath  = "/admin/ledger/wholesale-statements"
	wholesaleStatementDraft  = "draft"
	wholesaleStatementIssued = "issued"
)

var (
	errWholesaleStatementIssued = errors.New("wholesale statement already issued")
	errWholesaleAccountRequired = errors.New("account_id is required")
	errWholesalePeriodInvalid   = errors.New("period must be YYYY-MM UTC")
)

type WholesaleStatement struct {
	WholesaleStatementID string                       `json:"wholesale_statement_id"`
	AccountID            string                       `json:"account_id"`
	Period               string                       `json:"period"`
	PeriodStartUTC       string                       `json:"period_start_utc"`
	PeriodEndUTC         string                       `json:"period_end_utc"`
	Status               string                       `json:"status"`
	RequestCount         int64                        `json:"request_count"`
	PromptTokens         int64                        `json:"prompt_tokens"`
	CompletionTokens     int64                        `json:"completion_tokens"`
	GrossCredits         int64                        `json:"gross_credits"`
	USDMicro             int64                        `json:"usd_micro"`
	USD                  string                       `json:"usd"`
	LineItems            []WholesaleStatementLineItem `json:"line_items"`
	GeneratedAtUTC       string                       `json:"generated_at_utc"`
}

type WholesaleStatementLineItem struct {
	Model            string `json:"model"`
	IsFree           bool   `json:"is_free"`
	RequestCount     int64  `json:"request_count"`
	PromptTokens     int64  `json:"prompt_tokens"`
	CompletionTokens int64  `json:"completion_tokens"`
	GrossCredits     int64  `json:"gross_credits"`
	USDMicro         int64  `json:"usd_micro"`
	USD              string `json:"usd"`
}

type wholesaleGenerateRequest struct {
	AccountID string `json:"account_id"`
	Period    string `json:"period"`
	Force     bool   `json:"force"`
}

func (s *Store) ensureWholesaleStatementTables(ctx context.Context) error {
	_, err := s.db.ExecContext(ctx, `
CREATE TABLE IF NOT EXISTS wholesale_period_statements (
    wholesale_statement_id TEXT PRIMARY KEY,
    account_id TEXT NOT NULL,
    period TEXT NOT NULL,
    period_start_utc TEXT NOT NULL,
    period_end_utc TEXT NOT NULL,
    status TEXT NOT NULL CHECK(status IN ('draft','issued')),
    request_count INTEGER NOT NULL CHECK(request_count >= 0),
    prompt_tokens INTEGER NOT NULL CHECK(prompt_tokens >= 0),
    completion_tokens INTEGER NOT NULL CHECK(completion_tokens >= 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    usd_micro INTEGER NOT NULL CHECK(usd_micro >= 0),
    generated_at_utc TEXT NOT NULL,
    UNIQUE(account_id, period_start_utc, period_end_utc)
);
CREATE INDEX IF NOT EXISTS idx_wps_account_period ON wholesale_period_statements(account_id, period);
CREATE TABLE IF NOT EXISTS wholesale_statement_line_items (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    wholesale_statement_id TEXT NOT NULL REFERENCES wholesale_period_statements(wholesale_statement_id) ON DELETE CASCADE,
    model TEXT NOT NULL,
    is_free INTEGER NOT NULL CHECK(is_free IN (0,1)),
    request_count INTEGER NOT NULL CHECK(request_count >= 0),
    prompt_tokens INTEGER NOT NULL CHECK(prompt_tokens >= 0),
    completion_tokens INTEGER NOT NULL CHECK(completion_tokens >= 0),
    gross_credits INTEGER NOT NULL CHECK(gross_credits >= 0),
    usd_micro INTEGER NOT NULL CHECK(usd_micro >= 0),
    UNIQUE(wholesale_statement_id, model)
);
CREATE INDEX IF NOT EXISTS idx_wsli_statement ON wholesale_statement_line_items(wholesale_statement_id);
`)
	return err
}

func (s *Store) wholesalePricing() (RewardsConfig, float64) {
	s.wholesaleMu.RLock()
	defer s.wholesaleMu.RUnlock()
	usd := s.usdPerMillionCredits
	if usd <= 0 {
		usd = 1
	}
	return s.wholesaleRewards, usd
}

func parseWholesalePeriod(period string) (start, end time.Time, label string, err error) {
	period = strings.TrimSpace(period)
	if period == "" {
		return time.Time{}, time.Time{}, "", errWholesalePeriodInvalid
	}
	start, err = time.ParseInLocation("2006-01", period, time.UTC)
	if err != nil {
		return time.Time{}, time.Time{}, "", errWholesalePeriodInvalid
	}
	end = start.AddDate(0, 1, 0)
	return start, end, start.Format("2006-01"), nil
}

func wholesaleStatementID(accountID, periodStartUTC string) string {
	sum := sha256.Sum256([]byte(accountID + "\n" + periodStartUTC))
	return "ws_" + hex.EncodeToString(sum[:12])
}

func usdMicroString(micro int64) string {
	if micro == 0 {
		return "0"
	}
	sign := ""
	if micro < 0 {
		sign = "-"
		micro = -micro
	}
	whole := micro / 1_000_000
	frac := micro % 1_000_000
	return sign + strconv.FormatInt(whole, 10) + "." + fmt.Sprintf("%06d", frac)
}

func creditsToUSDMicro(credits int64, usdPerMillionCredits float64) int64 {
	if credits <= 0 || usdPerMillionCredits <= 0 {
		return 0
	}
	return int64(math.Round(float64(credits) * usdPerMillionCredits))
}

func (s *Store) GenerateWholesaleStatement(ctx context.Context, accountID, period string, force bool) (WholesaleStatement, error) {
	accountID = strings.TrimSpace(accountID)
	if accountID == "" {
		return WholesaleStatement{}, errWholesaleAccountRequired
	}
	start, end, label, err := parseWholesalePeriod(period)
	if err != nil {
		return WholesaleStatement{}, err
	}
	rewards, usdPeg := s.wholesalePricing()
	startText := start.UTC().Format(time.RFC3339Nano)
	endText := end.UTC().Format(time.RFC3339Nano)
	nowText := s.now().UTC().Format(time.RFC3339Nano)
	id := wholesaleStatementID(accountID, startText)

	type aggRow struct {
		Model            string
		RequestCount     int64
		PromptTokens     int64
		CompletionTokens int64
	}
	var aggs []aggRow
	rows, err := s.db.QueryContext(ctx, `
SELECT model,
       COUNT(*) AS request_count,
       COALESCE(SUM(prompt_tokens), 0) AS prompt_tokens,
       COALESCE(SUM(completion_tokens), 0) AS completion_tokens
  FROM request_log
 WHERE account_id = ?
   AND status = 200
   AND julianday(ts_utc) >= julianday(?)
   AND julianday(ts_utc) < julianday(?)
 GROUP BY model
 ORDER BY model`, accountID, startText, endText)
	if err != nil {
		return WholesaleStatement{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var row aggRow
		if err := rows.Scan(&row.Model, &row.RequestCount, &row.PromptTokens, &row.CompletionTokens); err != nil {
			return WholesaleStatement{}, err
		}
		aggs = append(aggs, row)
	}
	if err := rows.Err(); err != nil {
		return WholesaleStatement{}, err
	}

	items := make([]WholesaleStatementLineItem, 0, len(aggs))
	var totalRequests, totalPrompt, totalCompletion, totalGross, totalUSD int64
	multiplierPPM := ParseMultiplierPPM(rewards.GlobalMultiplier)
	if multiplierPPM == 0 {
		multiplierPPM = globalMultiplierDenom
	}
	shareBps := ParseShareBps(rewards.ProviderShare)
	if shareBps == 0 {
		shareBps = 9000
	}
	for _, agg := range aggs {
		prompt := agg.PromptTokens
		completion := agg.CompletionTokens
		billed := ComputeCredits(&prompt, &completion, nil, UsageProviderReported, FaultNone, RateFor(rewards.RateCard, agg.Model), multiplierPPM, shareBps)
		item := WholesaleStatementLineItem{
			Model:            agg.Model,
			IsFree:           IsWholesaleFreeSKU(agg.Model),
			RequestCount:     agg.RequestCount,
			PromptTokens:     agg.PromptTokens,
			CompletionTokens: agg.CompletionTokens,
			GrossCredits:     billed.GrossCredits,
		}
		if !item.IsFree {
			item.USDMicro = creditsToUSDMicro(billed.GrossCredits, usdPeg)
		}
		item.USD = usdMicroString(item.USDMicro)
		items = append(items, item)
		totalRequests += item.RequestCount
		totalPrompt += item.PromptTokens
		totalCompletion += item.CompletionTokens
		totalGross += item.GrossCredits
		totalUSD += item.USDMicro
	}

	err = sqliteutil.TransactObserved(ctx, s.db, "wholesale_statement", s.sqliteMetric, func(ctx context.Context, conn *sql.Conn) error {
		var existingID, existingStatus string
		err := conn.QueryRowContext(ctx, `
SELECT wholesale_statement_id, status
  FROM wholesale_period_statements
 WHERE account_id = ? AND period_start_utc = ? AND period_end_utc = ?`,
			accountID, startText, endText).Scan(&existingID, &existingStatus)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return err
		}
		if err == nil {
			if existingStatus == wholesaleStatementIssued && !force {
				return errWholesaleStatementIssued
			}
			id = existingID
			if _, err := conn.ExecContext(ctx, `DELETE FROM wholesale_statement_line_items WHERE wholesale_statement_id = ?`, id); err != nil {
				return err
			}
			if _, err := conn.ExecContext(ctx, `
UPDATE wholesale_period_statements
   SET status = ?,
       request_count = ?,
       prompt_tokens = ?,
       completion_tokens = ?,
       gross_credits = ?,
       usd_micro = ?,
       generated_at_utc = ?
 WHERE wholesale_statement_id = ?`,
				wholesaleStatementDraft, totalRequests, totalPrompt, totalCompletion, totalGross, totalUSD, nowText, id); err != nil {
				return err
			}
		} else {
			if _, err := conn.ExecContext(ctx, `
INSERT INTO wholesale_period_statements (
    wholesale_statement_id, account_id, period, period_start_utc, period_end_utc,
    status, request_count, prompt_tokens, completion_tokens, gross_credits, usd_micro, generated_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				id, accountID, label, startText, endText, wholesaleStatementDraft,
				totalRequests, totalPrompt, totalCompletion, totalGross, totalUSD, nowText); err != nil {
				return err
			}
		}
		for _, item := range items {
			free := 0
			if item.IsFree {
				free = 1
			}
			if _, err := conn.ExecContext(ctx, `
INSERT INTO wholesale_statement_line_items (
    wholesale_statement_id, model, is_free, request_count, prompt_tokens, completion_tokens, gross_credits, usd_micro
) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
				id, item.Model, free, item.RequestCount, item.PromptTokens, item.CompletionTokens, item.GrossCredits, item.USDMicro); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return WholesaleStatement{}, err
	}
	return s.getWholesaleStatement(ctx, id)
}

func (s *Store) ListWholesaleStatements(ctx context.Context, accountID, period string) ([]WholesaleStatement, error) {
	query := `
SELECT wholesale_statement_id, account_id, period, period_start_utc, period_end_utc, status,
       request_count, prompt_tokens, completion_tokens, gross_credits, usd_micro, generated_at_utc
  FROM wholesale_period_statements`
	var args []any
	var where []string
	if accountID = strings.TrimSpace(accountID); accountID != "" {
		where = append(where, "account_id = ?")
		args = append(args, accountID)
	}
	if period = strings.TrimSpace(period); period != "" {
		if _, _, label, err := parseWholesalePeriod(period); err != nil {
			return nil, err
		} else {
			where = append(where, "period = ?")
			args = append(args, label)
		}
	}
	if len(where) > 0 {
		query += " WHERE " + strings.Join(where, " AND ")
	}
	query += " ORDER BY period_start_utc DESC, account_id"
	rows, err := s.db.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []WholesaleStatement
	for rows.Next() {
		stmt, err := scanWholesaleStatement(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, stmt)
	}
	return out, rows.Err()
}

func (s *Store) getWholesaleStatement(ctx context.Context, statementID string) (WholesaleStatement, error) {
	row := s.db.QueryRowContext(ctx, `
SELECT wholesale_statement_id, account_id, period, period_start_utc, period_end_utc, status,
       request_count, prompt_tokens, completion_tokens, gross_credits, usd_micro, generated_at_utc
  FROM wholesale_period_statements
 WHERE wholesale_statement_id = ?`, statementID)
	stmt, err := scanWholesaleStatement(row)
	if err != nil {
		return WholesaleStatement{}, err
	}
	itemRows, err := s.db.QueryContext(ctx, `
SELECT model, is_free, request_count, prompt_tokens, completion_tokens, gross_credits, usd_micro
  FROM wholesale_statement_line_items
 WHERE wholesale_statement_id = ?
 ORDER BY model`, statementID)
	if err != nil {
		return WholesaleStatement{}, err
	}
	defer itemRows.Close()
	for itemRows.Next() {
		var item WholesaleStatementLineItem
		var free int
		if err := itemRows.Scan(&item.Model, &free, &item.RequestCount, &item.PromptTokens, &item.CompletionTokens, &item.GrossCredits, &item.USDMicro); err != nil {
			return WholesaleStatement{}, err
		}
		item.IsFree = free == 1
		item.USD = usdMicroString(item.USDMicro)
		stmt.LineItems = append(stmt.LineItems, item)
	}
	if err := itemRows.Err(); err != nil {
		return WholesaleStatement{}, err
	}
	if stmt.LineItems == nil {
		stmt.LineItems = []WholesaleStatementLineItem{}
	}
	return stmt, nil
}

type wholesaleScanner interface {
	Scan(dest ...any) error
}

func scanWholesaleStatement(row wholesaleScanner) (WholesaleStatement, error) {
	var stmt WholesaleStatement
	if err := row.Scan(
		&stmt.WholesaleStatementID,
		&stmt.AccountID,
		&stmt.Period,
		&stmt.PeriodStartUTC,
		&stmt.PeriodEndUTC,
		&stmt.Status,
		&stmt.RequestCount,
		&stmt.PromptTokens,
		&stmt.CompletionTokens,
		&stmt.GrossCredits,
		&stmt.USDMicro,
		&stmt.GeneratedAtUTC,
	); err != nil {
		return WholesaleStatement{}, err
	}
	stmt.USD = usdMicroString(stmt.USDMicro)
	stmt.LineItems = []WholesaleStatementLineItem{}
	return stmt, nil
}

func (h *handler) wholesaleStatements(w http.ResponseWriter, r *http.Request) {
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	if !h.allowAdminRequest(w) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		stmts, err := h.store.ListWholesaleStatements(r.Context(), r.URL.Query().Get("account_id"), r.URL.Query().Get("period"))
		if err != nil {
			if errors.Is(err, errWholesalePeriodInvalid) {
				writeError(w, http.StatusBadRequest, "bad_request", err.Error())
				return
			}
			writeError(w, http.StatusInternalServerError, "internal_error", "could not list wholesale statements")
			return
		}
		if stmts == nil {
			stmts = []WholesaleStatement{}
		}
		writeJSON(w, http.StatusOK, map[string]any{"statements": stmts})
	case http.MethodPost:
		var req wholesaleGenerateRequest
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&req); err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", "invalid json")
			return
		}
		stmt, err := h.store.GenerateWholesaleStatement(r.Context(), req.AccountID, req.Period, req.Force)
		if err != nil {
			switch {
			case errors.Is(err, errWholesaleAccountRequired), errors.Is(err, errWholesalePeriodInvalid):
				writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			case errors.Is(err, errWholesaleStatementIssued):
				writeError(w, http.StatusConflict, "conflict", "wholesale statement already issued")
			default:
				writeError(w, http.StatusInternalServerError, "internal_error", "could not generate wholesale statement")
			}
			return
		}
		writeJSON(w, http.StatusOK, stmt)
	default:
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
	}
}

func (h *handler) wholesaleStatementItem(w http.ResponseWriter, r *http.Request) {
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	if !h.allowAdminRequest(w) {
		return
	}
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	id := strings.TrimPrefix(r.URL.Path, wholesaleStatementsPath+"/")
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	stmt, err := h.store.getWholesaleStatement(r.Context(), id)
	if errors.Is(err, sql.ErrNoRows) {
		writeError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", "could not load wholesale statement")
		return
	}
	if strings.EqualFold(r.URL.Query().Get("format"), "csv") {
		w.Header().Set("Content-Type", "text/csv; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(wholesaleStatementCSV(stmt)))
		return
	}
	writeJSON(w, http.StatusOK, stmt)
}

func wholesaleStatementCSV(stmt WholesaleStatement) string {
	var b strings.Builder
	b.WriteString("wholesale_statement_id,account_id,period,model,is_free,request_count,prompt_tokens,completion_tokens,gross_credits,usd_micro,usd\n")
	for _, item := range stmt.LineItems {
		fmt.Fprintf(&b, "%s,%s,%s,%s,%t,%d,%d,%d,%d,%d,%s\n",
			stmt.WholesaleStatementID, stmt.AccountID, stmt.Period, item.Model, item.IsFree,
			item.RequestCount, item.PromptTokens, item.CompletionTokens, item.GrossCredits, item.USDMicro, item.USD)
	}
	return b.String()
}
