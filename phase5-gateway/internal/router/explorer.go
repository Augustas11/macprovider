package router

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

const (
	explorerDefaultLimit      = 50
	explorerMaxLimit          = 200
	explorerQueryTimeoutMs    = 3000
	explorerActivityWindowHrs = 24
	explorerActivityMaxDays   = 7
	explorerBuyersWindowHrs   = 168
	explorerBuyersMaxDays     = 31
	explorerSessionsWindowHrs = 24
	explorerSessionsMaxDays   = 7
)

func (s *Server) handleExplorerBuyers(w http.ResponseWriter, r *http.Request) {
	if !s.explorerAllowed(w, r) {
		return
	}
	q, err := s.parseExplorerBuyerQuery(r, explorerBuyersWindowHrs, explorerBuyersMaxDays)
	if err != nil {
		writeExplorerBadRequest(w, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.store.ExplorerListBuyers(ctx, q)
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleExplorerBuyerDetail(w http.ResponseWriter, r *http.Request) {
	if !s.explorerAllowed(w, r) {
		return
	}
	accountID := strings.TrimPrefix(r.URL.Path, "/admin/explorer/buyers/")
	if accountID == "" || strings.Contains(accountID, "/") {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Explorer resource not found")
		return
	}
	window, err := parseExplorerWindow(r, explorerBuyersWindowHrs, explorerBuyersMaxDays)
	if err != nil {
		writeExplorerBadRequest(w, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.store.ExplorerBuyerDetail(ctx, accountID, storage.ExplorerDetailQuery{
		From: window.from, To: window.to, Limit: parseExplorerLimit(r),
	})
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleExplorerSessions(w http.ResponseWriter, r *http.Request) {
	if !s.explorerAllowed(w, r) {
		return
	}
	window, err := parseExplorerWindow(r, explorerSessionsWindowHrs, explorerSessionsMaxDays)
	if err != nil {
		writeExplorerBadRequest(w, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.store.ExplorerListSessions(ctx, storage.ExplorerSessionQuery{
		From: window.from, To: window.to, AccountID: r.URL.Query().Get("account_id"),
		Limit: parseExplorerLimit(r), Cursor: r.URL.Query().Get("cursor"),
	})
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleExplorerSessionDetail(w http.ResponseWriter, r *http.Request) {
	if !s.explorerAllowed(w, r) {
		return
	}
	requestID := strings.TrimPrefix(r.URL.Path, "/admin/explorer/sessions/")
	if requestID == "" || strings.Contains(requestID, "/") {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Explorer resource not found")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.store.ExplorerSessionDetail(ctx, requestID)
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleExplorerActivity(w http.ResponseWriter, r *http.Request) {
	if !s.explorerAllowed(w, r) {
		return
	}
	window, err := parseExplorerWindow(r, explorerActivityWindowHrs, explorerActivityMaxDays)
	if err != nil {
		writeExplorerBadRequest(w, err.Error())
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.store.ExplorerActivity(ctx, storage.ExplorerActivityQuery{
		From: window.from, To: window.to, Type: r.URL.Query().Get("type"),
		AccountID: r.URL.Query().Get("account_id"), RequestID: r.URL.Query().Get("request_id"),
		Limit: parseExplorerLimit(r), Cursor: r.URL.Query().Get("cursor"),
		SinceCursor: r.URL.Query().Get("since_cursor"),
	})
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleExplorerHealth(w http.ResponseWriter, r *http.Request) {
	if !s.explorerAllowed(w, r) {
		return
	}
	windowHours := 24
	switch r.URL.Query().Get("window") {
	case "", "24h":
		windowHours = 24
	case "7d":
		windowHours = 24 * 7
	default:
		writeExplorerBadRequest(w, "window must be 24h or 7d")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.store.ExplorerHealth(ctx, s.now().Add(-time.Duration(windowHours)*time.Hour))
	if err != nil {
		writeExplorerStorageError(w, err)
		return
	}
	out.CheckedAtUTC = s.now()
	out.PublicAPIPaused = s.cfg.KillSwitch.AllPublicAPI
	out.DemoPaused = s.cfg.KillSwitch.DemoOnly
	if out.PublicAPIPaused {
		out.PublicStatus = "paused"
	}
	writeJSON(w, http.StatusOK, out)
}

type explorerWindow struct {
	from time.Time
	to   time.Time
}

func (s *Server) parseExplorerBuyerQuery(r *http.Request, defaultHours, maxDays int) (storage.ExplorerBuyerQuery, error) {
	values := r.URL.Query()
	if values.Get("email") != "" && values.Get("email_prefix") != "" {
		return storage.ExplorerBuyerQuery{}, errors.New("email and email_prefix cannot both be set")
	}
	window, err := parseExplorerWindow(r, defaultHours, maxDays)
	if err != nil {
		return storage.ExplorerBuyerQuery{}, err
	}
	status := values.Get("status")
	if status != "" && status != "active" && status != "blocked" {
		return storage.ExplorerBuyerQuery{}, errors.New("status must be active or blocked")
	}
	keyStatus := values.Get("key_status")
	if keyStatus != "" && keyStatus != "active" && keyStatus != "revoked" {
		return storage.ExplorerBuyerQuery{}, errors.New("key_status must be active or revoked")
	}
	return storage.ExplorerBuyerQuery{
		From: window.from, To: window.to, Status: status,
		QuotaClass: values.Get("quota_class"), ConcurrencyClass: values.Get("concurrency_class"),
		AccountID: values.Get("account_id"), Email: values.Get("email"), EmailPrefix: values.Get("email_prefix"),
		KeyStatus: keyStatus, Limit: parseExplorerLimit(r), Cursor: values.Get("cursor"),
	}, nil
}

func parseExplorerWindow(r *http.Request, defaultHours, maxDays int) (explorerWindow, error) {
	values := r.URL.Query()
	to := time.Now().UTC()
	var err error
	if raw := values.Get("to"); raw != "" {
		to, err = time.Parse(time.RFC3339, raw)
		if err != nil {
			return explorerWindow{}, errors.New("to must be RFC3339")
		}
	}
	from := to.Add(-time.Duration(defaultHours) * time.Hour)
	if raw := values.Get("window_hours"); raw != "" {
		hours, err := strconv.Atoi(raw)
		if err != nil || hours <= 0 {
			return explorerWindow{}, errors.New("window_hours must be a positive integer")
		}
		maxHours := maxDays * 24
		if hours > maxHours {
			hours = maxHours
		}
		from = to.Add(-time.Duration(hours) * time.Hour)
	}
	if raw := values.Get("from"); raw != "" {
		from, err = time.Parse(time.RFC3339, raw)
		if err != nil {
			return explorerWindow{}, errors.New("from must be RFC3339")
		}
	}
	if !from.Before(to) {
		return explorerWindow{}, errors.New("from must be before to")
	}
	if to.Sub(from) > time.Duration(maxDays)*24*time.Hour {
		from = to.Add(-time.Duration(maxDays) * 24 * time.Hour)
	}
	return explorerWindow{from: from.UTC(), to: to.UTC()}, nil
}

func parseExplorerLimit(r *http.Request) int {
	limit := explorerDefaultLimit
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if parsed, err := strconv.Atoi(raw); err == nil && parsed > 0 {
			limit = parsed
		}
	}
	if limit > explorerMaxLimit {
		limit = explorerMaxLimit
	}
	return limit
}

func (s *Server) explorerAllowed(w http.ResponseWriter, r *http.Request) bool {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return false
	}
	return s.operatorAuthorized(w, r)
}

func writeExplorerBadRequest(w http.ResponseWriter, detail string) {
	writeJSON(w, http.StatusBadRequest, map[string]any{
		"partial": false,
		"error": map[string]any{
			"code":   "bad_request",
			"detail": detail,
		},
	})
}

func writeExplorerStorageError(w http.ResponseWriter, err error) {
	if errors.Is(err, storage.ErrNotFound) {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Explorer resource not found")
		return
	}
	if errors.Is(err, context.DeadlineExceeded) {
		writeError(w, http.StatusRequestTimeout, "server_error", "query_timeout", "Explorer query timed out")
		return
	}
	writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Explorer query failed")
}
