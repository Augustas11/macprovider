package billing

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type tokenValidator interface {
	ValidateToken(ctx context.Context, raw string) (providerID string, ok bool, err error)
}

func (s *Store) Handlers(operatorKey string, tokenStore tokenValidator, requireProviderTokens bool, earningsRateLimitPerMin int) http.Handler {
	h := &handler{
		store:                   s,
		operatorKey:             operatorKey,
		tokenStore:              tokenStore,
		requireProviderTokens:   requireProviderTokens,
		earningsRateLimitPerMin: earningsRateLimitPerMin,
		lastEarnings:            map[string][]time.Time{},
	}
	return http.HandlerFunc(h.serveHTTP)
}

type handler struct {
	store                   *Store
	operatorKey             string
	tokenStore              tokenValidator
	requireProviderTokens   bool
	earningsRateLimitPerMin int
	mu                      sync.Mutex
	lastEarnings            map[string][]time.Time
}

func (h *handler) serveHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/admin/ledger/summary":
		h.admin(w, r, h.summary)
	case r.URL.Path == "/admin/ledger/providers":
		h.admin(w, r, h.providers)
	case r.URL.Path == "/admin/ledger/reconcile":
		h.admin(w, r, h.reconcile)
	case strings.HasPrefix(r.URL.Path, "/providers/") && strings.HasSuffix(r.URL.Path, "/earnings"):
		h.earnings(w, r)
	default:
		writeError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func (h *handler) admin(w http.ResponseWriter, r *http.Request, fn func(http.ResponseWriter, *http.Request)) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if h.operatorKey != "" && r.Header.Get("Authorization") != "Bearer "+h.operatorKey {
		writeError(w, http.StatusForbidden, "forbidden", "operator key required")
		return
	}
	fn(w, r)
}

func (h *handler) summary(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	current := currentMondayUTC(time.Now().UTC()).Format(time.RFC3339Nano)
	resp := map[string]any{
		"total_gross_credits":               h.sum(ctx, `SELECT SUM(gross_credits) FROM ledger_request_credits WHERE quarantined=0`),
		"total_provider_credits":            h.sum(ctx, `SELECT SUM(provider_credits) FROM ledger_request_credits WHERE quarantined=0`),
		"total_operator_credits":            h.sum(ctx, `SELECT SUM(gross_credits - provider_credits) FROM ledger_request_credits WHERE quarantined=0`),
		"current_window_provider_credits":   h.sum(ctx, `SELECT SUM(provider_credits) FROM ledger_request_credits WHERE quarantined=0 AND ts_utc >= ?`, current),
		"pending_payout_count":              h.sum(ctx, `SELECT COUNT(*) FROM ledger_payout_ready WHERE status='ready'`),
		"pending_payout_credits":            h.sum(ctx, `SELECT SUM(provider_credits) FROM ledger_payout_ready WHERE status='ready'`),
		"quarantined_count":                 h.sum(ctx, `SELECT COUNT(*) FROM ledger_request_credits WHERE quarantined=1`),
		"fault_count":                       h.sum(ctx, `SELECT COUNT(*) FROM ledger_request_credits WHERE fault_flag != 'none'`),
		"last_reconciliation_delta_credits": h.sum(ctx, `SELECT reconciliation_delta_credits FROM ledger_reconciliation_runs ORDER BY started_at_utc DESC, id DESC LIMIT 1`),
	}
	writeJSON(w, http.StatusOK, resp)
}

func (h *handler) providers(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 {
			limit = n
		}
	}
	if limit > 200 {
		limit = 200
	}
	cursor := r.URL.Query().Get("cursor")
	includeQuarantined := r.URL.Query().Get("include_quarantined") == "true"
	current := currentMondayUTC(time.Now().UTC()).Format(time.RFC3339Nano)
	quarantineFilter := "AND quarantined=0"
	if includeQuarantined {
		quarantineFilter = ""
	}
	rows, err := h.store.db.QueryContext(ctx, `
SELECT provider_id,
       SUM(provider_credits),
       SUM(CASE WHEN ts_utc >= ? THEN provider_credits ELSE 0 END),
       MAX(ts_utc),
       SUM(CASE WHEN fault_flag != 'none' THEN 1 ELSE 0 END),
       SUM(CASE WHEN quarantined=1 THEN 1 ELSE 0 END),
       MAX(attestation_class)
  FROM ledger_request_credits
 WHERE provider_id > ? `+quarantineFilter+`
 GROUP BY provider_id
 ORDER BY provider_id
 LIMIT ?`, current, cursor, limit+1)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	defer rows.Close()
	items := []map[string]any{}
	nextCursor := any(nil)
	for rows.Next() {
		var providerID string
		var total, currentWindow, faultCount, quarantinedCount sql.NullInt64
		var lastActivity, attestation sql.NullString
		if err := rows.Scan(&providerID, &total, &currentWindow, &lastActivity, &faultCount, &quarantinedCount, &attestation); err != nil {
			writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
			return
		}
		if len(items) == limit {
			nextCursor = items[len(items)-1]["provider_id"]
			break
		}
		items = append(items, map[string]any{
			"provider_id":            providerID,
			"total_provider_credits": nullInt(total),
			"current_window_credits": nullInt(currentWindow),
			"pending_payout_credits": h.sum(ctx, `SELECT SUM(provider_credits) FROM ledger_payout_ready WHERE provider_id=? AND status='ready'`, providerID),
			"last_activity_utc":      nullStringAny(lastActivity),
			"fault_count":            nullInt(faultCount),
			"quarantined_count":      nullInt(quarantinedCount),
			"attestation_class":      nullStringAny(attestation),
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"providers": items, "next_cursor": nextCursor})
}

func (h *handler) reconcile(w http.ResponseWriter, r *http.Request) {
	fromRaw, toRaw := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	fromDay, err1 := time.Parse("2006-01-02", fromRaw)
	toDay, err2 := time.Parse("2006-01-02", toRaw)
	if fromRaw == "" || toRaw == "" || err1 != nil || err2 != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", "from and to must be YYYY-MM-DD")
		return
	}
	from, to := fromDay.UTC(), toDay.UTC()
	if !to.After(from) || to.Sub(from) > 31*24*time.Hour {
		writeError(w, http.StatusBadRequest, "invalid_request", "reconcile range must be > 0 and <= 31 days")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	rowsScanned, err := h.sumErr(ctx, `SELECT COUNT(*) FROM request_log WHERE ts_utc >= ? AND ts_utc < ?`, from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	providerGross, err := h.sumErr(ctx, `SELECT SUM(gross_credits) FROM ledger_request_credits WHERE ts_utc >= ? AND ts_utc < ? AND quarantined=0`, from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	buyerEquivalent, err := h.buyerEquivalentCredits(ctx, from, to)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	splitDelta, err := h.sumErr(ctx, `
SELECT COUNT(*)
  FROM ledger_request_credits lrc
  LEFT JOIN ledger_operator_credits loc ON loc.request_credit_id = lrc.id
 WHERE lrc.ts_utc >= ? AND lrc.ts_utc < ?
   AND lrc.quarantined = 0
   AND (loc.id IS NULL OR lrc.provider_credits + loc.operator_credits != lrc.gross_credits)`,
		from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	rowsRecovered := int64(0)
	rowsQuarantined, err := h.sumErr(ctx, `SELECT COUNT(*) FROM ledger_request_credits WHERE ts_utc >= ? AND ts_utc < ? AND quarantined=1`, from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	delta := providerGross - buyerEquivalent
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if _, err := h.store.db.ExecContext(ctx, `
INSERT INTO ledger_reconciliation_runs (
    run_type, from_utc, to_utc, request_log_rows_scanned,
    missing_credit_rows_created, orphan_credit_rows_quarantined,
    buyer_equivalent_credits, provider_gross_credits,
    reconciliation_delta_credits, started_at_utc, finished_at_utc, status,
    error, created_at_utc
) VALUES ('admin_reconcile', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'complete', NULL, ?)`,
		from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano), rowsScanned,
		rowsRecovered, rowsQuarantined, buyerEquivalent, providerGross, delta, now, now, now,
	); err != nil {
		writeError(w, http.StatusInternalServerError, "internal_error", err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"from_utc":                 from.Format(time.RFC3339),
		"to_utc":                   to.Format(time.RFC3339),
		"buyer_equivalent_credits": buyerEquivalent,
		"provider_gross_credits":   providerGross,
		"delta_gross_credits":      delta,
		"split_delta_rows":         splitDelta,
		"rows_scanned":             rowsScanned,
		"rows_recovered":           rowsRecovered,
		"rows_quarantined":         rowsQuarantined,
	})
}

func (h *handler) buyerEquivalentCredits(ctx context.Context, from, to time.Time) (int64, error) {
	rows, err := h.store.db.QueryContext(ctx, `
SELECT rl.request_id, rl.ts_utc, rl.model, rl.prompt_tokens, rl.completion_tokens, rl.status, rl.error_code,
       COALESCE((
         SELECT COUNT(*) - 1 FROM request_log prior
          WHERE prior.request_id = rl.request_id AND prior.id <= rl.id
       ), 0) AS attempt_n
  FROM request_log rl
 WHERE rl.ts_utc >= ? AND rl.ts_utc < ?
 ORDER BY rl.ts_utc, rl.id`, from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	total := int64(0)
	for rows.Next() {
		var requestID, tsText, model string
		var prompt, completion sql.NullInt64
		var status, attemptN int
		var errorCode sql.NullString
		if err := rows.Scan(&requestID, &tsText, &model, &prompt, &completion, &status, &errorCode, &attemptN); err != nil {
			return 0, err
		}
		if status == http.StatusServiceUnavailable {
			continue
		}
		ts, err := time.Parse(time.RFC3339Nano, tsText)
		if err != nil {
			return 0, err
		}
		var pp, cp *int64
		if prompt.Valid {
			v := prompt.Int64
			pp = &v
		}
		if completion.Valid {
			v := completion.Int64
			cp = &v
		}
		if gross, ok, err := h.byteEstimatedLedgerGross(ctx, requestID, attemptN, pp); err != nil {
			return 0, err
		} else if ok {
			total += gross
			continue
		}
		_, rewards, multiplier, share, err := h.store.snapshotAt(ctx, ts)
		if err != nil {
			continue
		}
		row := ComputeCredits(pp, cp, nil, usageFor(errorCode.String, nil), FaultNone, RateFor(rewards.RateCard, model), multiplier, share)
		total += row.GrossCredits
	}
	return total, rows.Err()
}

func (h *handler) byteEstimatedLedgerGross(ctx context.Context, requestID string, attemptN int, promptTokens *int64) (int64, bool, error) {
	rows, err := h.store.db.QueryContext(ctx, `
SELECT estimated_completion_tokens, fault_flag, prompt_rate_per_mtok,
       completion_rate_per_mtok, global_multiplier_ppm, provider_share_bps
  FROM ledger_request_credits
 WHERE request_id = ? AND attempt_n = ? AND quarantined = 0 AND usage_source = 'byte_estimated'`, requestID, attemptN)
	if err != nil {
		return 0, false, err
	}
	defer rows.Close()
	count := 0
	var estimated sql.NullInt64
	var faultFlag string
	var promptRate, completionRate, multiplier, share int64
	for rows.Next() {
		count++
		if count > 1 {
			return 0, false, nil
		}
		if err := rows.Scan(&estimated, &faultFlag, &promptRate, &completionRate, &multiplier, &share); err != nil {
			return 0, false, err
		}
	}
	if err := rows.Err(); err != nil {
		return 0, false, err
	}
	if count != 1 || !estimated.Valid {
		return 0, false, nil
	}
	row := ComputeCredits(promptTokens, nil, intPtrFromNull(estimated), UsageByteEstimated, faultFlag, RateCardEntry{
		PromptCreditsPerMtok:     promptRate,
		CompletionCreditsPerMtok: completionRate,
	}, multiplier, share)
	return row.GrossCredits, true, nil
}

func (h *handler) earnings(w http.ResponseWriter, r *http.Request) {
	if !h.requireProviderTokens {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "provider tokens not enabled")
		return
	}
	providerID := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/providers/"), "/earnings")
	raw := bearer(r.Header.Get("Authorization"))
	if raw == "" {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return
	}
	if h.tokenStore == nil {
		writeError(w, http.StatusServiceUnavailable, "unavailable", "provider tokens not available")
		return
	}
	subject, ok, err := h.tokenStore.ValidateToken(r.Context(), raw)
	if err != nil || !ok {
		writeError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return
	}
	if subject != providerID {
		writeError(w, http.StatusForbidden, "forbidden", "provider token subject mismatch")
		return
	}
	if !h.allowEarnings(providerID) {
		writeError(w, http.StatusTooManyRequests, "rate_limited", "provider earnings rate limit exceeded")
		return
	}
	if h.sum(r.Context(), `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=?`, providerID) == 0 {
		writeError(w, http.StatusNotFound, "not_found", "provider not found")
		return
	}
	rangeFrom, rangeTo, hasRange, err := parseOptionalDayRange(r)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request", err.Error())
		return
	}
	rangeSQL, rangeArgs := earningsRangeFilter(rangeFrom, rangeTo, hasRange)
	current := currentMondayUTC(time.Now().UTC()).Format(time.RFC3339Nano)
	models := h.modelsServed(r.Context(), providerID, rangeSQL, rangeArgs...)
	totalArgs := append([]any{providerID}, rangeArgs...)
	currentArgs := append([]any{providerID, current}, rangeArgs...)
	faultArgs := append([]any{providerID}, rangeArgs...)
	resp := map[string]any{
		"provider_id":            providerID,
		"total_credits":          h.sum(r.Context(), `SELECT SUM(provider_credits) FROM ledger_request_credits WHERE provider_id=? AND quarantined=0`+rangeSQL, totalArgs...),
		"current_window_credits": h.sum(r.Context(), `SELECT SUM(provider_credits) FROM ledger_request_credits WHERE provider_id=? AND quarantined=0 AND ts_utc >= ?`+rangeSQL, currentArgs...),
		"last_payout_ready":      h.lastPayout(r.Context(), providerID),
		"provider_share_bps":     h.latestShareBps(r.Context()),
		"models_served":          models,
		"rate_card_excerpt":      h.rateCardExcerpt(r.Context(), models),
		"fault_count":            h.sum(r.Context(), `SELECT COUNT(*) FROM ledger_request_credits WHERE provider_id=? AND fault_flag != 'none'`+rangeSQL, faultArgs...),
	}
	if hasRange {
		resp["from_utc"] = rangeFrom.Format(time.RFC3339)
		resp["to_utc"] = rangeTo.Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, resp)
}

func parseOptionalDayRange(r *http.Request) (time.Time, time.Time, bool, error) {
	fromRaw, toRaw := r.URL.Query().Get("from"), r.URL.Query().Get("to")
	if fromRaw == "" && toRaw == "" {
		return time.Time{}, time.Time{}, false, nil
	}
	if fromRaw == "" || toRaw == "" {
		return time.Time{}, time.Time{}, false, errors.New("from and to must be YYYY-MM-DD")
	}
	fromDay, err1 := time.Parse("2006-01-02", fromRaw)
	toDay, err2 := time.Parse("2006-01-02", toRaw)
	if err1 != nil || err2 != nil {
		return time.Time{}, time.Time{}, false, errors.New("from and to must be YYYY-MM-DD")
	}
	from, to := fromDay.UTC(), toDay.UTC()
	if !to.After(from) || to.Sub(from) > 31*24*time.Hour {
		return time.Time{}, time.Time{}, false, errors.New("earnings range must be > 0 and <= 31 days")
	}
	return from, to, true, nil
}

func earningsRangeFilter(from, to time.Time, enabled bool) (string, []any) {
	if !enabled {
		return "", nil
	}
	return " AND ts_utc >= ? AND ts_utc < ?", []any{from.Format(time.RFC3339Nano), to.Format(time.RFC3339Nano)}
}

func (h *handler) sum(ctx context.Context, query string, args ...any) int64 {
	n, err := h.sumErr(ctx, query, args...)
	if err != nil {
		return 0
	}
	return n
}

func (h *handler) sumErr(ctx context.Context, query string, args ...any) (int64, error) {
	var n sql.NullInt64
	if err := h.store.db.QueryRowContext(ctx, query, args...).Scan(&n); err != nil {
		return 0, err
	}
	if !n.Valid {
		return 0, nil
	}
	return n.Int64, nil
}

func (h *handler) allowEarnings(providerID string) bool {
	if h.earningsRateLimitPerMin <= 0 {
		return true
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	cutoff := time.Now().Add(-time.Minute)
	kept := h.lastEarnings[providerID][:0]
	for _, t := range h.lastEarnings[providerID] {
		if t.After(cutoff) {
			kept = append(kept, t)
		}
	}
	if len(kept) >= h.earningsRateLimitPerMin {
		h.lastEarnings[providerID] = kept
		return false
	}
	h.lastEarnings[providerID] = append(kept, time.Now())
	return true
}

func (h *handler) modelsServed(ctx context.Context, providerID string, rangeSQL string, rangeArgs ...any) []string {
	args := append([]any{providerID}, rangeArgs...)
	rows, err := h.store.db.QueryContext(ctx, `SELECT DISTINCT model FROM ledger_request_credits WHERE provider_id=?`+rangeSQL+` ORDER BY model`, args...)
	if err != nil {
		return []string{}
	}
	defer rows.Close()
	models := []string{}
	for rows.Next() {
		var model string
		if rows.Scan(&model) == nil {
			models = append(models, model)
		}
	}
	return models
}

func (h *handler) rateCardExcerpt(ctx context.Context, models []string) map[string]RateCardEntry {
	var raw string
	if err := h.store.db.QueryRowContext(ctx, `SELECT rate_card_json FROM ledger_config_snapshots ORDER BY effective_at_utc DESC, id DESC LIMIT 1`).Scan(&raw); err != nil {
		return map[string]RateCardEntry{}
	}
	var card map[string]RateCardEntry
	if err := json.Unmarshal([]byte(raw), &card); err != nil {
		return map[string]RateCardEntry{}
	}
	out := map[string]RateCardEntry{}
	for _, model := range models {
		out[model] = RateFor(card, model)
	}
	return out
}

func (h *handler) latestShareBps(ctx context.Context) int64 {
	return h.sum(ctx, `SELECT provider_share_bps FROM ledger_config_snapshots ORDER BY effective_at_utc DESC, id DESC LIMIT 1`)
}

func (h *handler) lastPayout(ctx context.Context, providerID string) any {
	row := h.store.db.QueryRowContext(ctx, `
SELECT window_start_utc, window_end_utc, provider_credits, status
  FROM ledger_payout_ready
 WHERE provider_id = ?
 ORDER BY window_end_utc DESC, id DESC LIMIT 1`, providerID)
	var start, end, status string
	var credits int64
	if err := row.Scan(&start, &end, &credits, &status); errors.Is(err, sql.ErrNoRows) {
		return nil
	} else if err != nil {
		return nil
	}
	return map[string]any{
		"window_start_utc": start,
		"window_end_utc":   end,
		"provider_credits": credits,
		"status":           status,
	}
}

func currentMondayUTC(t time.Time) time.Time {
	day := time.Date(t.UTC().Year(), t.UTC().Month(), t.UTC().Day(), 0, 0, 0, 0, time.UTC)
	days := (int(day.Weekday()) - int(time.Monday) + 7) % 7
	return day.AddDate(0, 0, -days)
}

func bearer(auth string) string {
	token, ok := strings.CutPrefix(strings.TrimSpace(auth), "Bearer ")
	if !ok {
		return ""
	}
	return strings.TrimSpace(token)
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": message}})
}

func nullInt(v sql.NullInt64) int64 {
	if !v.Valid {
		return 0
	}
	return v.Int64
}

func nullStringAny(v sql.NullString) any {
	if !v.Valid {
		return nil
	}
	return v.String
}
