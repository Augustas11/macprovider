package explorer

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
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
}

func NewHandler(cfg config.Config, db *sql.DB, registry *pool.Registry, started time.Time) *Handler {
	return &Handler{
		cfg:     cfg,
		db:      db,
		pool:    registry,
		started: started.UTC(),
		client:  &http.Client{Timeout: time.Duration(cfg.Explorer.GatewayTimeoutMs) * time.Millisecond},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	setSecurityHeaders(w)
	path := strings.TrimPrefix(r.URL.Path, strings.TrimSuffix(h.cfg.Explorer.BindPath, "/"))
	if path == "" {
		http.Redirect(w, r, h.cfg.Explorer.BindPath, http.StatusMovedPermanently)
		return
	}
	if path == "/" || path == "/index.html" || strings.HasPrefix(path, "/css/") || strings.HasPrefix(path, "/js/") {
		h.serveStatic(w, r, path)
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
	if !h.authorized(r) {
		writeExplorerError(w, http.StatusUnauthorized, "invalid_operator_token", "invalid operator token")
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
	includeGateway := r.URL.Query().Get("include_gateway") != "false"
	gateway := map[string]any{"health": "unknown", "error": nil}
	partial := false
	if includeGateway && h.cfg.Explorer.GatewayBaseURL != "" {
		status, err := h.fetchGatewayJSON(r, "/admin/explorer/health")
		if err != nil {
			partial = true
			gateway = map[string]any{"health": "unknown", "error": map[string]any{"code": "gateway_unavailable"}}
		} else {
			gateway = status
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"checked_at_utc":  encodeTime(time.Now().UTC()),
		"protocol_status": statusFromPartial(partial),
		"coordinator":     map[string]any{"health": "ok", "started_at_utc": encodeTime(h.started)},
		"gateway":         gateway,
		"pool":            map[string]any{"total_providers": len(providers), "ready_providers": countReady(providers)},
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
	writeListResult(w, result)
}

func (h *Handler) handleSessionDetail(ctx context.Context, w http.ResponseWriter, r *http.Request, requestID string) {
	if requestID == "" || strings.Contains(requestID, "/") {
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	detail, err := h.store.SessionDetail(ctx, h.db, requestID)
	if err != nil {
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
	writeList(w, items)
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
	writeList(w, items)
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
	writeList(w, items)
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
		health["gateway"] = map[string]any{"health": "unknown"}
	} else if gateway, err := h.fetchGatewayJSON(r, "/admin/explorer/health"); err == nil {
		health["gateway"] = gateway
	} else {
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
	result, err := h.store.Activity(ctx, h.db, window.from, window.to, r.URL.Query().Get("cursor"), r.URL.Query().Get("since_cursor"), limit)
	if err != nil {
		if errors.Is(err, ErrBadCursor) {
			writeExplorerError(w, http.StatusBadRequest, "bad_request", "invalid cursor")
			return
		}
		writeExplorerStorageError(w, err)
		return
	}
	if eventID != "" {
		for _, item := range result.Items {
			if item["source_id"] == eventID || item["request_id"] == eventID {
				writeJSON(w, http.StatusOK, map[string]any{"event": item, "partial": false, "error": nil})
				return
			}
		}
		writeExplorerError(w, http.StatusNotFound, "not_found", "not found")
		return
	}
	writeListResult(w, result)
}

func (h *Handler) proxyGateway(w http.ResponseWriter, r *http.Request, path string) {
	if h.cfg.Explorer.GatewayBaseURL == "" {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"code": "gateway_disabled", "detail": "explorer.gateway_base_url not configured"}})
		return
	}
	body, status, err := h.fetchGateway(r, path)
	if err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": map[string]any{"code": "gateway_bad_response"}})
		return
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": map[string]any{"code": "gateway_unauthorized"}})
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
	body, status, err := h.fetchGateway(r, path)
	if err != nil {
		return nil, err
	}
	if status < 200 || status >= 300 {
		return nil, errors.New("gateway status")
	}
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func (h *Handler) fetchGateway(r *http.Request, path string) ([]byte, int, error) {
	base, err := url.Parse(h.cfg.Explorer.GatewayBaseURL)
	if err != nil {
		return nil, 0, err
	}
	base.Path = path
	base.RawQuery = r.URL.RawQuery
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

func statusFromPartial(partial bool) string {
	if partial {
		return "degraded"
	}
	return "ok"
}

func writeList(w http.ResponseWriter, items any) {
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "next_cursor": nil, "partial": false, "error": nil})
}

func writeListResult(w http.ResponseWriter, result ListResult) {
	writeJSON(w, http.StatusOK, map[string]any{"items": result.Items, "next_cursor": result.NextCursor, "latest_cursor": result.LatestCursor, "partial": false, "error": nil})
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
