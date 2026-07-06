// Package explorer provides the SPEC-007 coordinator explorer read model.
// Read-only invariant per SPEC-007 section 3.9; mutating queries MUST NOT be added to this file.
package explorer

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

var ErrBadCursor = errors.New("bad cursor")

type ReadDB interface {
	QueryContext(context.Context, string, ...any) (*sql.Rows, error)
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

type Store struct{}

type ListResult struct {
	Items        []map[string]any
	NextCursor   *string
	LatestCursor *string
}

func (Store) RecentSessions(ctx context.Context, q ReadDB, from, to time.Time, cursor string, limit int) (ListResult, error) {
	boundary, err := decodeOptionalCursor(cursor)
	if err != nil {
		return ListResult{}, err
	}
	cursorTS, cursorID := "", int64(0)
	if boundary != nil {
		cursorTS, cursorID = boundary.TS, boundary.ID
	}
	items, err := queryMaps(ctx, q, `
		SELECT rl.id AS request_log_id, rl.ts_utc, rl.request_id, rl.model, rl.provider_assigned_id,
		       rl.prompt_tokens, rl.completion_tokens, rl.total_tokens, rl.latency_ms, rl.routing_ms,
		       rl.status, rl.stream, rl.error, rl.error_code, rl.retried,
		       COALESCE(SUM(lrc.gross_credits), 0) AS gross_credits,
		       COALESCE(SUM(lrc.provider_credits), 0) AS provider_credits,
		       COALESCE(SUM(loc.operator_credits), 0) AS operator_credits
		FROM request_log rl
		LEFT JOIN ledger_request_credits lrc ON lrc.request_id = rl.request_id
		LEFT JOIN ledger_operator_credits loc ON loc.request_credit_id = lrc.id
		WHERE rl.ts_utc >= ? AND rl.ts_utc < ?
		  AND (? = '' OR rl.ts_utc < ? OR (rl.ts_utc = ? AND rl.id < ?))
		GROUP BY rl.id
		ORDER BY rl.ts_utc DESC, rl.id DESC
		LIMIT ?`, encodeTime(from), encodeTime(to), cursorTS, cursorTS, cursorTS, cursorID, limit+1)
	if err != nil {
		return ListResult{}, err
	}
	return pageResult(items, limit, "ts_utc", "request_log_id")
}

func (Store) SessionDetail(ctx context.Context, q ReadDB, requestID string) (map[string]any, error) {
	attempts, err := queryMaps(ctx, q, `
		SELECT id AS request_log_id, ts_utc, request_id, external_request_id, account_id, model, provider_assigned_id,
		       prompt_tokens, completion_tokens, total_tokens, latency_ms, routing_ms,
		       status, stream, buyer_ip, error, error_code, pref_header, provider_header, retried
		FROM request_log
		WHERE request_id = ?
		ORDER BY id ASC`, requestID)
	if err != nil {
		return nil, err
	}
	// SPEC-005 v0.4 §11.6.5 — LEFT JOIN ledger_quarantine_resolutions
	// and surface resolution_kind / resolution_operator_id /
	// resolution_reason / resolution_at_utc as the contract aliases
	// the explorer client reads. Force-voided rows have
	// `lrc.quarantined=1` AND a matching resolution row; the alias
	// columns are non-null only when a resolution exists.
	ledger, err := queryMaps(ctx, q, `
		SELECT lrc.id, lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.provider_assigned_id,
		       lrc.ts_utc, lrc.model, lrc.status, lrc.stream, lrc.prompt_tokens,
		       lrc.completion_tokens, lrc.estimated_completion_tokens, lrc.usage_source,
		       lrc.gross_credits, lrc.provider_credits, loc.operator_credits,
		       lrc.fault_flag, lrc.settled, lrc.settlement_id, lrc.quarantined,
		       lrc.quarantine_reason, lrc.recovery_source,
		       lqr.resolution_kind   AS resolution_kind,
		       lqr.operator_id       AS resolution_operator_id,
		       lqr.resolution_reason AS resolution_reason,
		       lqr.created_at_utc    AS resolution_at_utc
		FROM ledger_request_credits lrc
		LEFT JOIN ledger_operator_credits loc ON loc.request_credit_id = lrc.id
		LEFT JOIN ledger_quarantine_resolutions lqr ON lqr.request_credit_id = lrc.id
		WHERE lrc.request_id = ?
		ORDER BY lrc.attempt_n ASC, lrc.id ASC`, requestID)
	if err != nil {
		return nil, err
	}
	snapshots, err := queryMaps(ctx, q, `
		SELECT id, request_id, attempt_n, provider_assigned_id, provider_id, resolved_from,
		       pool_session_started_at_utc, created_at_utc
		FROM ledger_provider_identity_snapshots
		WHERE request_id = ?
		ORDER BY attempt_n ASC, id ASC`, requestID)
	if err != nil {
		return nil, err
	}
	if len(attempts) == 0 && len(ledger) == 0 && len(snapshots) == 0 {
		return nil, sql.ErrNoRows
	}
	return map[string]any{
		"request_id":                  requestID,
		"attempts":                    attempts,
		"ledger_rows":                 ledger,
		"provider_identity_snapshots": snapshots,
		"partial":                     false,
		"error":                       nil,
	}, nil
}

func (Store) Providers(ctx context.Context, q ReadDB, providers []pool.Provider) ([]map[string]any, error) {
	out := make([]map[string]any, 0, len(providers))
	for _, p := range providers {
		token, err := tokenStatus(ctx, q, p.ProviderID)
		if err != nil {
			return nil, err
		}
		out = append(out, providerMap(p, token))
	}
	return out, nil
}

func (Store) ProviderDetail(ctx context.Context, q ReadDB, p pool.Provider) (map[string]any, error) {
	token, err := tokenStatus(ctx, q, p.ProviderID)
	if err != nil {
		return nil, err
	}
	ledger, err := queryMaps(ctx, q, `
		SELECT id, request_id, attempt_n, ts_utc, model, status, prompt_tokens,
		       completion_tokens, gross_credits, provider_credits, fault_flag,
		       settled, settlement_id, quarantined
		FROM ledger_request_credits
		WHERE provider_id = ?
		ORDER BY ts_utc DESC, id DESC
		LIMIT 50`, p.ProviderID)
	if err != nil {
		return nil, err
	}
	settlements, err := queryMaps(ctx, q, `
		SELECT id, provider_id, window_start_utc, window_end_utc, gross_credits,
		       provider_credits, operator_credits, status, payout_currency, payout_external_id,
		       created_at_utc
		FROM ledger_payout_ready
		WHERE provider_id = ?
		ORDER BY window_end_utc DESC, id DESC
		LIMIT 50`, p.ProviderID)
	if err != nil {
		return nil, err
	}
	return map[string]any{"provider": providerMap(p, token), "ledger_rows": ledger, "settlements": settlements, "partial": false, "error": nil}, nil
}

func (Store) Ledger(ctx context.Context, q ReadDB, from, to time.Time, limit int) ([]map[string]any, error) {
	// SPEC-005 v0.4 §11.6.5 — LEFT JOIN ledger_quarantine_resolutions
	// surfaces the resolution alias columns on the ledger list view.
	return queryMaps(ctx, q, `
		SELECT lrc.id, lrc.request_id, lrc.attempt_n, lrc.provider_id, lrc.provider_assigned_id,
		       lrc.ts_utc, lrc.model, lrc.status, lrc.stream, lrc.prompt_tokens,
		       lrc.completion_tokens, lrc.estimated_completion_tokens, lrc.usage_source,
		       lrc.gross_credits, lrc.provider_credits, loc.operator_credits,
		       lrc.fault_flag, lrc.settled, lrc.settlement_id, lrc.quarantined,
		       lrc.quarantine_reason, lrc.recovery_source,
		       lqr.resolution_kind   AS resolution_kind,
		       lqr.operator_id       AS resolution_operator_id,
		       lqr.resolution_reason AS resolution_reason,
		       lqr.created_at_utc    AS resolution_at_utc
		FROM ledger_request_credits lrc
		LEFT JOIN ledger_operator_credits loc ON loc.request_credit_id = lrc.id
		LEFT JOIN ledger_quarantine_resolutions lqr ON lqr.request_credit_id = lrc.id
		WHERE lrc.ts_utc >= ? AND lrc.ts_utc < ?
		ORDER BY lrc.ts_utc DESC, lrc.id DESC
		LIMIT ?`, encodeTime(from), encodeTime(to), limit)
}

func (Store) Settlements(ctx context.Context, q ReadDB, from, to time.Time, status string, limit int) ([]map[string]any, error) {
	return queryMaps(ctx, q, `
		SELECT id, provider_id, window_start_utc, window_end_utc, cadence_days,
		       source_credit_count, gross_credits, provider_credits, operator_credits,
		       min_payout_credits, payout_currency, payout_external_id, status,
		       idempotency_key, created_at_utc
		FROM ledger_payout_ready
		WHERE window_end_utc >= ? AND window_end_utc < ?
		  AND (? = '' OR status = ?)
		ORDER BY window_end_utc DESC, id DESC
		LIMIT ?`, encodeTime(from), encodeTime(to), status, status, limit)
}

func (Store) SettlementDetail(ctx context.Context, q ReadDB, payoutID string) (map[string]any, error) {
	rows, err := queryMaps(ctx, q, `
		SELECT id, provider_id, window_start_utc, window_end_utc, cadence_days,
		       source_credit_count, gross_credits, provider_credits, operator_credits,
		       min_payout_credits, payout_currency, payout_external_id, status,
		       idempotency_key, created_at_utc
		FROM ledger_payout_ready
		WHERE id = ?
		LIMIT 1`, payoutID)
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, sql.ErrNoRows
	}
	return map[string]any{"settlement": rows[0], "partial": false, "error": nil}, nil
}

func (Store) Health(ctx context.Context, q ReadDB, started time.Time, poolSize int) (map[string]any, error) {
	reconciliation, err := queryMaps(ctx, q, `
		SELECT id, run_type, from_utc, to_utc, reconciliation_delta_credits,
		       status, error, started_at_utc, finished_at_utc
		FROM ledger_reconciliation_runs
		ORDER BY started_at_utc DESC, id DESC
		LIMIT 1`)
	if err != nil {
		return nil, err
	}
	delta := any(nil)
	if len(reconciliation) > 0 {
		delta = reconciliation[0]["reconciliation_delta_credits"]
	}
	return map[string]any{
		"checked_at_utc":            encodeTime(time.Now().UTC()),
		"coordinator_health":        "ok",
		"started_at_utc":            encodeTime(started),
		"pool_size":                 poolSize,
		"last_reconciliation":       firstOrNil(reconciliation),
		"last_reconciliation_delta": delta,
		"provider_reconnect_count":  nil,
		"coordinator_restart_count": nil,
		"partial":                   false,
		"error":                     nil,
	}, nil
}

func (Store) Overview(ctx context.Context, q ReadDB, from, to time.Time) (map[string]any, error) {
	trafficRows, err := queryMaps(ctx, q, `
		SELECT COUNT(*) AS requests_window,
		       COALESCE(SUM(total_tokens), 0) AS tokens_window,
		       COALESCE(SUM(CASE WHEN status >= 400 THEN 1 ELSE 0 END), 0) AS error_count_window,
		       COALESCE(SUM(CASE WHEN retried != 0 THEN 1 ELSE 0 END), 0) AS retry_count_window
		FROM request_log
		WHERE ts_utc >= ? AND ts_utc < ?`, encodeTime(from), encodeTime(to))
	if err != nil {
		return nil, err
	}
	// R3 fix (SEC-M2): payable totals (current_window_provider_credits,
	// total_gross_credits, total_provider_credits) must mirror the
	// SPEC-005 v0.4 §11 payable predicate (lrc.quarantined=0). Without
	// this filter, quarantined and force-voided rows inflate the
	// explorer overview totals, which then disagree with the
	// /admin/ledger/summary numbers operators read.
	ledgerRows, err := queryMaps(ctx, q, `
		SELECT COALESCE(SUM(CASE WHEN lrc.quarantined=0 AND lrc.ts_utc >= ? AND lrc.ts_utc < ? THEN lrc.provider_credits ELSE 0 END), 0) AS current_window_provider_credits,
		       COALESCE(SUM(CASE WHEN lrc.quarantined=0 THEN lrc.gross_credits ELSE 0 END), 0) AS total_gross_credits,
		       COALESCE(SUM(CASE WHEN lrc.quarantined=0 THEN lrc.provider_credits ELSE 0 END), 0) AS total_provider_credits,
		       COALESCE(SUM(CASE WHEN lrc.quarantined=0 THEN loc.operator_credits ELSE 0 END), 0) AS total_operator_credits,
		       COALESCE((SELECT COUNT(*) FROM ledger_payout_ready WHERE status = 'ready'), 0) AS pending_payout_count,
		       COALESCE((SELECT SUM(provider_credits) FROM ledger_payout_ready WHERE status = 'ready'), 0) AS pending_payout_credits,
		       -- SPEC-005 v0.4 §11.6.5 OPEN_PREDICATE: surface only
		       -- quarantined rows AWAITING operator decision
		       -- (force-voided rows are resolved-and-excluded).
		       COALESCE(SUM(CASE WHEN lrc.quarantined != 0 AND NOT EXISTS (
		             SELECT 1 FROM ledger_quarantine_resolutions r WHERE r.request_credit_id = lrc.id
		       ) THEN 1 ELSE 0 END), 0) AS quarantined_count,
		       COALESCE(SUM(CASE WHEN lrc.fault_flag != '' AND lrc.fault_flag != 'none' THEN 1 ELSE 0 END), 0) AS fault_count
		FROM ledger_request_credits lrc
		LEFT JOIN ledger_operator_credits loc ON loc.request_credit_id = lrc.id`, encodeTime(from), encodeTime(to))
	if err != nil {
		return nil, err
	}
	reconciliationRows, err := queryMaps(ctx, q, `
		SELECT id AS last_run_id, status AS last_status,
		       reconciliation_delta_credits AS last_delta_credits,
		       finished_at_utc AS last_finished_at_utc
		FROM ledger_reconciliation_runs
		ORDER BY started_at_utc DESC, id DESC
		LIMIT 1`)
	if err != nil {
		return nil, err
	}
	reconciliation := map[string]any{"last_run_id": nil, "last_status": nil, "last_delta_credits": nil, "last_finished_at_utc": nil}
	if len(reconciliationRows) > 0 {
		reconciliation = reconciliationRows[0]
	}
	return map[string]any{
		"traffic":        firstOrNil(trafficRows),
		"ledger":         firstOrNil(ledgerRows),
		"reconciliation": reconciliation,
	}, nil
}

func (Store) Activity(ctx context.Context, q ReadDB, from, to time.Time, cursor, sinceCursor, eventType string, limit int) (ListResult, error) {
	if cursor != "" && sinceCursor != "" {
		return ListResult{}, ErrBadCursor
	}
	if sinceCursor != "" {
		boundary, err := decodeCursor(sinceCursor)
		if err != nil {
			return ListResult{}, err
		}
		items, err := queryMaps(ctx, q, `
			SELECT id AS request_log_id, ts_utc AS event_time_utc, 'request_completed' AS event_type, 'coordinator' AS source, request_id AS source_id,
			       request_id, provider_assigned_id, model, status, error_code, total_tokens, queue_wait_ms
			FROM request_log
			WHERE ts_utc >= ? AND ts_utc < ?
			  AND (? = '' OR 'request_completed' = ?)
			  AND (ts_utc > ? OR (ts_utc = ? AND id > ?))
			ORDER BY ts_utc ASC, id ASC
			LIMIT ?`, encodeTime(from), encodeTime(to), eventType, eventType, boundary.TS, boundary.TS, boundary.ID, limit+1)
		if err != nil {
			return ListResult{}, err
		}
		return incrementalResult(items, limit, "event_time_utc", "request_log_id")
	}
	boundary, err := decodeOptionalCursor(cursor)
	if err != nil {
		return ListResult{}, err
	}
	cursorTS, cursorID := "", int64(0)
	if boundary != nil {
		cursorTS, cursorID = boundary.TS, boundary.ID
	}
	items, err := queryMaps(ctx, q, `
			SELECT id AS request_log_id, ts_utc AS event_time_utc, 'request_completed' AS event_type, 'coordinator' AS source, request_id AS source_id,
			       request_id, provider_assigned_id, model, status, error_code, total_tokens, queue_wait_ms
			FROM request_log
			WHERE ts_utc >= ? AND ts_utc < ?
			  AND (? = '' OR 'request_completed' = ?)
			  AND (? = '' OR ts_utc < ? OR (ts_utc = ? AND id < ?))
			ORDER BY ts_utc DESC, id DESC
			LIMIT ?`, encodeTime(from), encodeTime(to), eventType, eventType, cursorTS, cursorTS, cursorTS, cursorID, limit+1)
	if err != nil {
		return ListResult{}, err
	}
	return pageResult(items, limit, "event_time_utc", "request_log_id")
}

type opaqueCursor struct {
	TS string `json:"ts"`
	ID int64  `json:"id"`
}

func decodeOptionalCursor(raw string) (*opaqueCursor, error) {
	if raw == "" {
		return nil, nil
	}
	c, err := decodeCursor(raw)
	if err != nil {
		return nil, err
	}
	return &c, nil
}

func decodeCursor(raw string) (opaqueCursor, error) {
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return opaqueCursor{}, ErrBadCursor
	}
	var c opaqueCursor
	if err := json.Unmarshal(b, &c); err != nil {
		return opaqueCursor{}, ErrBadCursor
	}
	if c.TS == "" || c.ID <= 0 {
		return opaqueCursor{}, ErrBadCursor
	}
	if _, err := time.Parse(time.RFC3339Nano, c.TS); err != nil {
		return opaqueCursor{}, ErrBadCursor
	}
	return c, nil
}

func encodeCursorFromItem(item map[string]any, tsKey, idKey string) (string, bool) {
	ts, ok := item[tsKey].(string)
	if !ok || ts == "" {
		return "", false
	}
	id, ok := int64Value(item[idKey])
	if !ok || id <= 0 {
		return "", false
	}
	b, err := json.Marshal(opaqueCursor{TS: ts, ID: id})
	if err != nil {
		return "", false
	}
	return base64.RawURLEncoding.EncodeToString(b), true
}

func pageResult(items []map[string]any, limit int, tsKey, idKey string) (ListResult, error) {
	result := ListResult{Items: items}
	if len(items) > 0 {
		if latest, ok := encodeCursorFromItem(items[0], tsKey, idKey); ok {
			result.LatestCursor = &latest
		}
	}
	if len(items) > limit {
		last := items[limit-1]
		items = items[:limit]
		result.Items = items
		if next, ok := encodeCursorFromItem(last, tsKey, idKey); ok {
			result.NextCursor = &next
		}
	}
	for _, item := range result.Items {
		if cursor, ok := encodeCursorFromItem(item, tsKey, idKey); ok {
			item["cursor"] = cursor
		}
	}
	return result, nil
}

func incrementalResult(items []map[string]any, limit int, tsKey, idKey string) (ListResult, error) {
	result := ListResult{Items: items}
	hasMore := len(items) > limit
	if len(items) > limit {
		items = items[:limit]
		result.Items = items
	}
	if len(result.Items) > 0 {
		last := result.Items[len(result.Items)-1]
		if latest, ok := encodeCursorFromItem(last, tsKey, idKey); ok {
			result.LatestCursor = &latest
			if hasMore {
				result.NextCursor = &latest
			}
		}
	}
	for _, item := range result.Items {
		if cursor, ok := encodeCursorFromItem(item, tsKey, idKey); ok {
			item["cursor"] = cursor
		}
	}
	return result, nil
}

func int64Value(v any) (int64, bool) {
	switch n := v.(type) {
	case int:
		return int64(n), true
	case int64:
		return n, true
	case int32:
		return int64(n), true
	case int16:
		return int64(n), true
	case int8:
		return int64(n), true
	case uint:
		return int64(n), true
	case uint64:
		if n > uint64(^uint64(0)>>1) {
			return 0, false
		}
		return int64(n), true
	case uint32:
		return int64(n), true
	case uint16:
		return int64(n), true
	case uint8:
		return int64(n), true
	default:
		return 0, false
	}
}

func queryMaps(ctx context.Context, q ReadDB, query string, args ...any) ([]map[string]any, error) {
	rows, err := q.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	cols, err := rows.Columns()
	if err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for rows.Next() {
		values := make([]any, len(cols))
		ptrs := make([]any, len(cols))
		for i := range values {
			ptrs[i] = &values[i]
		}
		if err := rows.Scan(ptrs...); err != nil {
			return nil, err
		}
		item := map[string]any{}
		for i, col := range cols {
			switch v := values[i].(type) {
			case []byte:
				item[col] = string(v)
			default:
				item[col] = v
			}
		}
		out = append(out, item)
	}
	return out, rows.Err()
}

func tokenStatus(ctx context.Context, q ReadDB, providerID string) (map[string]any, error) {
	var prefix string
	var revoked sql.NullString
	err := q.QueryRowContext(ctx, `
		SELECT token_prefix, revoked_at
		FROM provider_tokens
		WHERE provider_id = ? AND provider_id != ''
		ORDER BY id DESC
		LIMIT 1`, providerID).Scan(&prefix, &revoked)
	if err == sql.ErrNoRows {
		return map[string]any{"status": "missing", "token_prefix": ""}, nil
	}
	if err != nil {
		return nil, err
	}
	status := "active"
	if revoked.Valid {
		status = "revoked"
	}
	return map[string]any{"status": status, "token_prefix": prefix, "revoked_at": nullString(revoked)}, nil
}

func providerMap(p pool.Provider, token map[string]any) map[string]any {
	return map[string]any{
		"provider_id":             p.ProviderID,
		"assigned_id":             p.AssignedID,
		"hostname":                p.Hostname,
		"model_id":                p.ModelID,
		"state":                   p.State,
		"tier":                    p.Tier,
		"inference_path":          p.InferencePath,
		"slots_free":              p.SlotsFree,
		"slots_total":             p.SlotsTotal,
		"throughput_tps_estimate": p.ThroughputTPSEstimate,
		"max_context_tokens":      p.MaxContextTokens,
		"last_heartbeat_at":       encodeTime(p.LastHeartbeatAt),
		"last_activity_at":        encodeTime(p.LastActivityAt),
		"connected_at":            encodeTime(p.ConnectedAt),
		"binary_version":          p.BinaryVersion,
		"hash_status":             p.HashStatus,
		"attestation_status":      p.AttestationStatus,
		"encrypted_leg":           p.EncryptedLeg,
		"token_status":            token["status"],
		"token_prefix":            token["token_prefix"],
		// auth_state surfaces WHY a session is (non-)routable per
		// SPEC-003 FR-C9.4 (#82 item 4). Empty string is the legacy
		// pre-FR-C9 admit; operators see the same distinct values
		// /poolz exposes (bearer_validated / self_minted /
		// bearerless_duplicate / mint_failed).
		"auth_state": p.AuthState,
	}
}

func firstOrNil(rows []map[string]any) any {
	if len(rows) == 0 {
		return nil
	}
	return rows[0]
}

func nullString(v sql.NullString) any {
	if !v.Valid {
		return nil
	}
	return v.String
}

func encodeTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339Nano)
}

func countReady(providers []pool.Provider) int {
	n := 0
	for _, p := range providers {
		if p.State == pool.StateReady {
			n++
		}
	}
	return n
}

func findProvider(providers []pool.Provider, providerID string) (pool.Provider, bool) {
	for _, p := range providers {
		if p.ProviderID == providerID {
			return p, true
		}
	}
	return pool.Provider{}, false
}
