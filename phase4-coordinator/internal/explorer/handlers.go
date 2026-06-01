package explorer

import (
	"context"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type Handler struct {
	cfg     config.Config
	db      *sql.DB
	pool    *pool.Registry
	started time.Time
	client  *http.Client
	store   Store
	mu      sync.Mutex
	stamps  map[string][]time.Time
}

func NewHandler(cfg config.Config, db *sql.DB, registry *pool.Registry, started time.Time) *Handler {
	return &Handler{
		cfg:     cfg,
		db:      db,
		pool:    registry,
		started: started.UTC(),
		client:  &http.Client{Timeout: time.Duration(cfg.Explorer.GatewayTimeoutMs) * time.Millisecond},
		stamps:  map[string][]time.Time{},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)
	path := strings.TrimPrefix(r.URL.Path, strings.TrimSuffix(h.cfg.Explorer.BindPath, "/"))
	if path == "" && r.Method == http.MethodGet {
		http.Redirect(w, r, h.cfg.Explorer.BindPath, http.StatusMovedPermanently)
		return
	}
	if r.Method == http.MethodGet && (path == "/" || path == "/index.html" || strings.HasPrefix(path, "/css/") || strings.HasPrefix(path, "/js/")) {
		h.serveStatic(w, r, path)
		return
	}
	if !h.authorized(r) {
		writeExplorerError(w, http.StatusUnauthorized, "invalid_operator_token", "invalid operator token")
		return
	}
	if !h.allowRequest(r) {
		writeExplorerError(w, http.StatusTooManyRequests, "rate_limited", "explorer request cap reached")
		return
	}
	if r.Method != http.MethodGet {
		if path == "/settlements" {
			w.Header().Set("Allow", http.MethodGet)
			writeExplorerError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
			return
		}
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(h.cfg.Explorer.QueryTimeoutMs)*time.Millisecond)
	defer cancel()

	switch {
	case path == "/overview":
		h.handleOverview(ctx, w, r)
	case path == "/sessions":
		h.handleSessions(ctx, w, r)
	case strings.HasPrefix(path, "/sessions/"):
		h.handleSessionDetail(ctx, w, r, strings.TrimPrefix(path, "/sessions/"))
	case path == "/providers":
		h.handleProviders(ctx, w)
	case strings.HasPrefix(path, "/providers/"):
		h.handleProviderDetail(ctx, w, strings.TrimPrefix(path, "/providers/"))
	case path == "/buyers":
		h.proxyGateway(w, r, "/admin/explorer/buyers")
	case strings.HasPrefix(path, "/buyers/"):
		h.proxyGateway(w, r, "/admin/explorer/buyers/"+url.PathEscape(strings.TrimPrefix(path, "/buyers/")))
	case path == "/ledger":
		h.handleLedger(ctx, w, r)
	case path == "/settlements":
		h.handleSettlements(ctx, w, r)
	case strings.HasPrefix(path, "/settlements/"):
		h.handleSettlementDetail(ctx, w, strings.TrimPrefix(path, "/settlements/"))
	case path == "/health":
		h.handleHealth(ctx, w, r)
	case path == "/activity":
		h.handleActivity(ctx, w, r, "")
	case strings.HasPrefix(path, "/activity/"):
		h.handleActivity(ctx, w, r, strings.TrimPrefix(path, "/activity/"))
	case path == "/feedback":
		q := r.URL.Query()
		q.Set("type", "feedback")
		r.URL.RawQuery = q.Encode()
		h.handleActivity(ctx, w, r, "")
	default:
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
	}
}

func (h *Handler) handleOverview(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	providers := h.pool.Snapshot()
	health, err := h.store.Health(ctx, h.db, h.started, len(providers))
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	overview, err := h.store.Overview(ctx, h.db, time.Now().UTC().Add(-24*time.Hour), time.Now().UTC())
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	includeGateway := r.URL.Query().Get("include_gateway") != "false"
	gateway := map[string]any{"health": "unknown", "capacity_tier": 0, "public_api_paused": false, "demo_paused": false, "error": nil}
	gatewayRaw := gateway
	partial := false
	if includeGateway && h.cfg.Explorer.GatewayBaseURL != "" {
		status, httpStatus, err := h.fetchGatewayJSONStatus(r, "/admin/explorer/health")
		if err != nil || httpStatus == 0 {
			partial = true
			gateway = map[string]any{"health": "unknown", "error": map[string]any{"code": "gateway_unavailable"}}
		} else if httpStatus < 200 || httpStatus >= 300 {
			partial = true
			gateway = map[string]any{"health": "unavailable", "error": map[string]any{"code": "gateway_bad_response"}}
		} else {
			gatewayRaw = status
			gateway = gatewayOverview(status)
			if gateway["health"] != "ok" {
				partial = true
			}
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"checked_at_utc":  encodeTime(time.Now().UTC()),
		"protocol_status": statusFromPartial(partial),
		"coordinator":     map[string]any{"health": "ok", "started_at_utc": encodeTime(h.started)},
		"gateway":         gateway,
		"pool":            poolOverview(providers),
		"traffic":         overview["traffic"],
		"buyers":          gatewayBuyerOverview(gatewayRaw),
		"ledger":          overview["ledger"],
		"reconciliation":  overview["reconciliation"],
		"health":          health,
		"partial":         partial,
		"error":           nil,
	})
}

func (h *Handler) handleSessions(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	window, limit, ok := h.windowAndLimit(w, r, h.cfg.Explorer.SessionsDefaultWindowHours, h.cfg.Explorer.SessionsMaxWindowDays)
	if !ok {
		return
	}
	result, err := h.store.RecentSessions(ctx, h.db, window.from, window.to, r.URL.Query().Get("cursor"), limit)
	if err != nil {
		if errors.Is(err, ErrBadCursor) {
			writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
			return
		}
		writeExplorerStorageError(w, err)
		return
	}
	writeListResult(w, "sessions", result, &window)
}

func (h *Handler) handleSessionDetail(ctx context.Context, w http.ResponseWriter, r *http.Request, requestID string) {
	if requestID == "" || strings.Contains(requestID, "/") {
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	detail, err := h.store.SessionDetail(ctx, h.db, requestID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) && h.cfg.Explorer.GatewayBaseURL != "" {
			gateway, status, gwErr := h.fetchGatewayJSONStatus(r, "/admin/explorer/sessions/"+url.PathEscape(requestID))
			if gwErr == nil && status >= 200 && status < 300 {
				writeJSON(w, http.StatusOK, map[string]any{
					"request_id": requestID, "attempts": []any{}, "ledger_rows": []any{},
					"provider_identity_snapshots": []any{}, "gateway": gateway,
					"partial": false, "error": nil,
				})
				return
			}
		}
		writeExplorerStorageError(w, err)
		return
	}
	if h.cfg.Explorer.GatewayBaseURL != "" {
		gateway, err := h.fetchGatewayJSON(r, "/admin/explorer/sessions/"+url.PathEscape(requestID))
		if err != nil {
			detail["partial"] = true
			detail["gateway"] = map[string]any{"error": map[string]any{"code": "gateway_unavailable"}}
		} else {
			detail["gateway"] = gateway
		}
	}
	writeJSON(w, http.StatusOK, detail)
}

func (h *Handler) handleProviders(ctx context.Context, w http.ResponseWriter) {
	items, err := h.store.Providers(ctx, h.db, h.pool.Snapshot())
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeList(w, "providers", items)
}

func (h *Handler) handleProviderDetail(ctx context.Context, w http.ResponseWriter, providerID string) {
	provider, ok := findProvider(h.pool.Snapshot(), providerID)
	if !ok {
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	detail, err := h.store.ProviderDetail(ctx, h.db, provider)
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

func (h *Handler) handleLedger(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	window, limit, ok := h.windowAndLimit(w, r, h.cfg.Explorer.LedgerDefaultWindowHours, h.cfg.Explorer.LedgerMaxWindowDays)
	if !ok {
		return
	}
	items, err := h.store.Ledger(ctx, h.db, window.from, window.to, limit)
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeList(w, "entries", items)
}

func (h *Handler) handleSettlements(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	window, limit, ok := h.windowAndLimit(w, r, h.cfg.Explorer.SettlementsDefaultWindowHours, h.cfg.Explorer.SettlementsMaxWindowDays)
	if !ok {
		return
	}
	items, err := h.store.Settlements(ctx, h.db, window.from, window.to, r.URL.Query().Get("status"), limit)
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeList(w, "settlements", items)
}

func (h *Handler) handleSettlementDetail(ctx context.Context, w http.ResponseWriter, payoutID string) {
	detail, err := h.store.SettlementDetail(ctx, h.db, payoutID)
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, detail)
}

func (h *Handler) handleHealth(ctx context.Context, w http.ResponseWriter, r *http.Request) {
	health, err := h.store.Health(ctx, h.db, h.started, len(h.pool.Snapshot()))
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	if h.cfg.Explorer.GatewayBaseURL == "" {
		health["gateway_health"] = "unknown"
	} else if gateway, status, err := h.fetchGatewayJSONStatus(r, "/admin/explorer/health"); err == nil && status >= 200 && status < 300 {
		for k, v := range gateway {
			health[k] = v
		}
		health["gateway_health"] = gatewayHealth(gateway)
	} else {
		health["gateway_health"] = "unavailable"
		health["gateway"] = map[string]any{"health": "unavailable", "error": map[string]any{"code": "gateway_unavailable"}}
		health["partial"] = true
	}
	writeJSON(w, http.StatusOK, health)
}

func (h *Handler) handleActivity(ctx context.Context, w http.ResponseWriter, r *http.Request, eventID string) {
	window, limit, ok := h.windowAndLimit(w, r, h.cfg.Explorer.ActivityDefaultWindowHours, h.cfg.Explorer.ActivityMaxWindowDays)
	if !ok {
		return
	}
	eventType := r.URL.Query().Get("type")
	cursor, err := decodeFederatedActivityCursor(r.URL.Query().Get("cursor"))
	if err != nil {
		writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
		return
	}
	sinceCursor, err := decodeFederatedActivityCursor(r.URL.Query().Get("since_cursor"))
	if err != nil {
		writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
		return
	}
	if r.URL.Query().Get("cursor") != "" && r.URL.Query().Get("since_cursor") != "" {
		writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
		return
	}
	sourceCursor := cursor
	localCursor := sourceCursor.Local
	localSinceCursor := ""
	if r.URL.Query().Get("since_cursor") != "" {
		sourceCursor = sinceCursor
		localCursor = ""
		localSinceCursor = sourceCursor.Local
	}
	result, err := h.store.Activity(ctx, h.db, window.from, window.to, localCursor, localSinceCursor, eventType, limit)
	if err != nil {
		if errors.Is(err, ErrBadCursor) {
			writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
			return
		}
		writeExplorerStorageError(w, err)
		return
	}
	items := result.Items
	partial := false
	warnings := []string{}
	gatewayResult := map[string]any{}
	if r.URL.Query().Get("include_gateway") != "false" && h.cfg.Explorer.GatewayBaseURL != "" {
		gateway, status, err := h.fetchGatewayJSONStatusRawQuery(r, "/admin/explorer/activity", gatewayActivityRawQuery(r, sourceCursor.Gateway))
		if status == http.StatusBadRequest {
			writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
			return
		}
		if err != nil || status == 0 || status < 200 || status >= 300 {
			partial = true
			warnings = append(warnings, "gateway_unavailable")
		} else {
			gatewayResult = gateway
			items = mergeActivity(items, gatewayList(gateway))
		}
	}
	items, nextCursor, latestCursor := federatedActivityPage(items, limit, sourceCursor, result, gatewayResult, r.URL.Query().Get("since_cursor") != "")
	if eventID != "" {
		for _, item := range items {
			if item["source_id"] == eventID || item["request_id"] == eventID {
				writeJSON(w, http.StatusOK, map[string]any{"event": item, "partial": partial, "warnings": warnings, "error": nil})
				return
			}
		}
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	writeActivityResult(w, items, nextCursor, latestCursor, partial, warnings)
}

func (h *Handler) proxyGateway(w http.ResponseWriter, r *http.Request, path string) {
	if h.cfg.Explorer.GatewayBaseURL == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"code": "gateway_disabled", "detail": "explorer.gateway_base_url not configured"}})
		return
	}
	body, status, err := h.fetchGateway(r, path)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"code": "gateway_unavailable"}})
		return
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": map[string]any{"code": "gateway_bad_response"}})
		return
	}
	if status == http.StatusNotFound {
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	if status < 200 || status >= 300 {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": map[string]any{"code": "gateway_bad_response"}})
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (h *Handler) fetchGatewayJSON(r *http.Request, path string) (map[string]any, error) {
	out, status, err := h.fetchGatewayJSONStatus(r, path)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		return nil, errors.New("gateway status")
	}
	return out, nil
}

func (h *Handler) fetchGatewayJSONStatus(r *http.Request, path string) (map[string]any, int, error) {
	return h.fetchGatewayJSONStatusRawQuery(r, path, r.URL.RawQuery)
}

func (h *Handler) fetchGatewayJSONStatusRawQuery(r *http.Request, path string, rawQuery string) (map[string]any, int, error) {
	body, status, err := h.fetchGatewayRawQuery(r, path, rawQuery)
	if err != nil {
		return nil, status, err
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, status, err
	}
	return out, status, nil
}

func (h *Handler) fetchGateway(r *http.Request, path string) ([]byte, int, error) {
	return h.fetchGatewayRawQuery(r, path, r.URL.RawQuery)
}

func (h *Handler) fetchGatewayRawQuery(r *http.Request, path string, rawQuery string) ([]byte, int, error) {
	base, err := url.Parse(h.cfg.Explorer.GatewayBaseURL)
	if err != nil {
		return nil, 0, err
	}
	base.Path = path
	base.RawQuery = rawQuery
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(h.cfg.Explorer.GatewayTimeoutMs)*time.Millisecond)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base.String(), nil)
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Authorization", "Bearer "+h.cfg.Auth.OperatorKey)
	resp, err := h.client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return body, resp.StatusCode, err
}

type windowRange struct {
	from time.Time
	to   time.Time
}

func (h *Handler) windowAndLimit(w http.ResponseWriter, r *http.Request, defaultHours, maxDays int) (windowRange, int, bool) {
	window, err := parseWindow(r, defaultHours, maxDays)
	if err != nil {
		writeExplorerError(w, http.StatusBadRequest, "bad_request", err.Error())
		return windowRange{}, 0, false
	}
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed <= 0 {
			writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid limit")
			return windowRange{}, 0, false
		}
		limit = parsed
	}
	if limit > 200 {
		limit = 200
	}
	return window, limit, true
}

func parseWindow(r *http.Request, defaultHours, maxDays int) (windowRange, error) {
	to := time.Now().UTC()
	var err error
	if raw := r.URL.Query().Get("to"); raw != "" {
		to, err = time.Parse(time.RFC3339, raw)
		if err != nil {
			return windowRange{}, errors.New("invalid to")
		}
	}
	from := to.Add(-time.Duration(defaultHours) * time.Hour)
	if raw := r.URL.Query().Get("window_hours"); raw != "" {
		hours, err := strconv.Atoi(raw)
		if err != nil || hours <= 0 {
			return windowRange{}, errors.New("invalid window_hours")
		}
		if hours > maxDays*24 {
			hours = maxDays * 24
		}
		from = to.Add(-time.Duration(hours) * time.Hour)
	}
	if raw := r.URL.Query().Get("from"); raw != "" {
		from, err = time.Parse(time.RFC3339, raw)
		if err != nil {
			return windowRange{}, errors.New("invalid from")
		}
	}
	if !from.Before(to) {
		return windowRange{}, errors.New("from must be before to")
	}
	if to.Sub(from) > time.Duration(maxDays)*24*time.Hour {
		return windowRange{}, errors.New("window exceeds maximum")
	}
	return windowRange{from: from.UTC(), to: to.UTC()}, nil
}

func (h *Handler) authorized(r *http.Request) bool {
	return h.cfg.Auth.OperatorKey != "" && r.Header.Get("Authorization") == "Bearer "+h.cfg.Auth.OperatorKey
}

func (h *Handler) allowRequest(r *http.Request) bool {
	cap := h.cfg.Explorer.RequestsPerMinuteCap
	if cap <= 0 {
		return true
	}
	key := clientAddrKey(r.RemoteAddr)
	now := time.Now()
	cutoff := now.Add(-time.Minute)
	h.mu.Lock()
	defer h.mu.Unlock()
	stamps := h.stamps[key][:0]
	for _, at := range h.stamps[key] {
		if at.After(cutoff) {
			stamps = append(stamps, at)
		}
	}
	if len(stamps) >= cap {
		h.stamps[key] = stamps
		return false
	}
	stamps = append(stamps, now)
	h.stamps[key] = stamps
	return true
}

func clientAddrKey(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

func statusFromPartial(partial bool) string {
	if partial {
		return "degraded"
	}
	return "ok"
}

func gatewayOverview(gateway map[string]any) map[string]any {
	return map[string]any{
		"health":            gatewayHealth(gateway),
		"capacity_tier":     valueOrZero(gateway["capacity_tier"]),
		"public_api_paused": valueOrFalse(gateway["public_api_paused"]),
		"demo_paused":       valueOrFalse(gateway["demo_paused"]),
		"error":             nil,
	}
}

func gatewayHealth(gateway map[string]any) string {
	if v, ok := gateway["gateway_health"].(string); ok && v == "ok" {
		return "ok"
	}
	return "unavailable"
}

func gatewayBuyerOverview(gateway map[string]any) map[string]any {
	return map[string]any{
		"active_accounts_window": valueOrZero(gateway["active_accounts_window"]),
		"new_accounts_window":    valueOrZero(gateway["new_accounts_window"]),
		"active_api_keys":        valueOrZero(gateway["active_api_keys"]),
		"error":                  gateway["error"],
	}
}

func poolOverview(providers []pool.Provider) map[string]any {
	models := map[string]bool{}
	out := map[string]any{
		"total_providers":       len(providers),
		"ready_providers":       0,
		"busy_providers":        0,
		"degraded_providers":    0,
		"draining_providers":    0,
		"unavailable_providers": 0,
		"models_available":      []string{},
		"slots_free":            0,
		"slots_total":           0,
	}
	for _, p := range providers {
		switch p.State {
		case pool.StateReady:
			out["ready_providers"] = out["ready_providers"].(int) + 1
		case pool.StateBusy:
			out["busy_providers"] = out["busy_providers"].(int) + 1
		case pool.StateDegraded:
			out["degraded_providers"] = out["degraded_providers"].(int) + 1
		case pool.StateDraining:
			out["draining_providers"] = out["draining_providers"].(int) + 1
		case pool.StateUnavailable:
			out["unavailable_providers"] = out["unavailable_providers"].(int) + 1
		}
		if p.ModelID != "" {
			models[p.ModelID] = true
		}
		out["slots_free"] = out["slots_free"].(int) + p.SlotsFree
		out["slots_total"] = out["slots_total"].(int) + p.SlotsTotal
	}
	list := make([]string, 0, len(models))
	for model := range models {
		list = append(list, model)
	}
	sort.Strings(list)
	out["models_available"] = list
	return out
}

func gatewayList(gateway map[string]any) []map[string]any {
	raw, ok := gateway["events"]
	if !ok {
		raw = gateway["items"]
	}
	rows, ok := raw.([]any)
	if !ok {
		return nil
	}
	out := make([]map[string]any, 0, len(rows))
	for _, row := range rows {
		if m, ok := row.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

type federatedActivityCursor struct {
	Version int    `json:"v,omitempty"`
	Local   string `json:"local,omitempty"`
	Gateway string `json:"gateway,omitempty"`
}

func decodeFederatedActivityCursor(raw string) (federatedActivityCursor, error) {
	if raw == "" {
		return federatedActivityCursor{}, nil
	}
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return federatedActivityCursor{}, ErrBadCursor
	}
	var cursor federatedActivityCursor
	if err := json.Unmarshal(b, &cursor); err == nil && cursor.Version == 1 {
		if cursor.Local != "" {
			if _, err := decodeCursor(cursor.Local); err != nil {
				return federatedActivityCursor{}, err
			}
		}
		if cursor.Gateway != "" {
			if err := validateGatewayActivityCursor(cursor.Gateway); err != nil {
				return federatedActivityCursor{}, err
			}
		}
		return cursor, nil
	}
	if _, err := decodeCursor(raw); err != nil {
		return federatedActivityCursor{}, err
	}
	return federatedActivityCursor{Version: 1, Local: raw}, nil
}

func validateGatewayActivityCursor(raw string) error {
	b, err := base64.RawURLEncoding.DecodeString(raw)
	if err != nil {
		return ErrBadCursor
	}
	var cursor struct {
		TS string `json:"ts"`
		ID string `json:"id"`
	}
	if err := json.Unmarshal(b, &cursor); err != nil {
		return ErrBadCursor
	}
	if cursor.TS == "" || cursor.ID == "" {
		return ErrBadCursor
	}
	if _, err := time.Parse(time.RFC3339Nano, cursor.TS); err != nil {
		return ErrBadCursor
	}
	return nil
}

func encodeFederatedActivityCursor(cursor federatedActivityCursor) *string {
	if cursor.Local == "" && cursor.Gateway == "" {
		return nil
	}
	cursor.Version = 1
	b, err := json.Marshal(cursor)
	if err != nil {
		return nil
	}
	out := base64.RawURLEncoding.EncodeToString(b)
	return &out
}

func gatewayActivityRawQuery(r *http.Request, cursor string) string {
	q := r.URL.Query()
	q.Del("cursor")
	q.Del("since_cursor")
	if r.URL.Query().Get("since_cursor") != "" {
		if cursor != "" {
			q.Set("since_cursor", cursor)
		}
	} else if cursor != "" {
		q.Set("cursor", cursor)
	}
	return q.Encode()
}

func federatedActivityPage(items []map[string]any, limit int, input federatedActivityCursor, local ListResult, gateway map[string]any, newer bool) ([]map[string]any, *string, *string) {
	if newer {
		sort.SliceStable(items, func(i, j int) bool {
			ti := timeFromAny(items[i]["event_time_utc"])
			tj := timeFromAny(items[j]["event_time_utc"])
			if !ti.Equal(tj) {
				return ti.Before(tj)
			}
			return sourceRank(items[i]["source"]) < sourceRank(items[j]["source"])
		})
	}
	overflow := limit > 0 && len(items) > limit
	if limit > 0 && len(items) > limit {
		items = items[:limit]
	}
	next := federatedActivityCursor{Version: 1, Local: input.Local, Gateway: input.Gateway}
	if c := lastSourceCursor(items, "coordinator"); c != "" {
		next.Local = c
	}
	if c := lastSourceCursor(items, "gateway"); c != "" {
		next.Gateway = c
	}
	var nextCursor *string
	if overflow || local.NextCursor != nil || stringValue(gateway["next_cursor"]) != "" {
		nextCursor = encodeFederatedActivityCursor(next)
	}

	latest := federatedActivityCursor{Version: 1, Local: input.Local, Gateway: input.Gateway}
	if local.LatestCursor != nil {
		latest.Local = *local.LatestCursor
	}
	if c := stringValue(gateway["latest_cursor"]); c != "" {
		latest.Gateway = c
	}
	if newer {
		if c := lastSourceCursor(items, "coordinator"); c != "" {
			latest.Local = c
		}
		if c := lastSourceCursor(items, "gateway"); c != "" {
			latest.Gateway = c
		}
	}
	return items, nextCursor, encodeFederatedActivityCursor(latest)
}

func lastSourceCursor(items []map[string]any, source string) string {
	for i := len(items) - 1; i >= 0; i-- {
		if items[i]["source"] == source {
			return stringValue(items[i]["cursor"])
		}
	}
	return ""
}

func stringValue(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

func mergeActivity(local, gateway []map[string]any) []map[string]any {
	out := append(append([]map[string]any{}, local...), gateway...)
	sort.SliceStable(out, func(i, j int) bool {
		ti := timeFromAny(out[i]["event_time_utc"])
		tj := timeFromAny(out[j]["event_time_utc"])
		if !ti.Equal(tj) {
			return ti.After(tj)
		}
		return sourceRank(out[i]["source"]) > sourceRank(out[j]["source"])
	})
	return out
}

func sourceRank(v any) int {
	if s, _ := v.(string); s == "coordinator" {
		return 100
	}
	return 80
}

func timeFromAny(v any) time.Time {
	switch t := v.(type) {
	case time.Time:
		return t
	case string:
		parsed, _ := time.Parse(time.RFC3339Nano, t)
		return parsed
	default:
		return time.Time{}
	}
}

func valueOrZero(v any) any {
	if v == nil {
		return 0
	}
	return v
}

func valueOrFalse(v any) any {
	if v == nil {
		return false
	}
	return v
}

func writeList(w http.ResponseWriter, key string, items any) {
	writeJSON(w, http.StatusOK, map[string]any{key: items, "next_cursor": nil, "partial": false, "error": nil})
}

func writeListResult(w http.ResponseWriter, key string, result ListResult, window *windowRange) {
	body := map[string]any{key: result.Items, "next_cursor": result.NextCursor, "partial": false, "error": nil}
	if window != nil {
		body["window"] = map[string]any{"from_utc": encodeTime(window.from), "to_utc": encodeTime(window.to)}
	}
	writeJSON(w, http.StatusOK, body)
}

func writeActivityResult(w http.ResponseWriter, items []map[string]any, next, latest *string, partial bool, warnings []string) {
	writeJSON(w, http.StatusOK, map[string]any{"events": items, "next_cursor": next, "latest_cursor": latest, "partial": partial, "warnings": warnings, "error": nil})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeExplorerError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{"error": map[string]any{"code": code, "message": message, "source": "coordinator", "retryable": false}})
}

func writeExplorerStorageError(w http.ResponseWriter, err error) {
	if errors.Is(err, sql.ErrNoRows) {
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	if errors.Is(err, context.DeadlineExceeded) {
		writeExplorerError(w, http.StatusRequestTimeout, "query_timeout", "query timeout")
		return
	}
	writeExplorerError(w, http.StatusInternalServerError, "internal_error", "internal error")
}

func setSecurityHeaders(w http.ResponseWriter) {
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("X-Frame-Options", "DENY")
	w.Header().Set("Referrer-Policy", "no-referrer")
}
