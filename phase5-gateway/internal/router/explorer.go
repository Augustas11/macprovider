package router

import (
	"context"
	"encoding/json"
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
	out, err := s.readStore().ExplorerListBuyers(ctx, q)
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
	out, err := s.readStore().ExplorerBuyerDetail(ctx, accountID, storage.ExplorerDetailQuery{
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
	out, err := s.readStore().ExplorerListSessions(ctx, storage.ExplorerSessionQuery{
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
	rawSegment := strings.TrimPrefix(r.URL.Path, "/admin/explorer/sessions/")
	if rawSegment == "" || strings.Contains(rawSegment, "/") {
		writeError(w, http.StatusNotFound, "invalid_request_error", "not_found", "Explorer resource not found")
		return
	}
	// #231 SPEC-007 v0.4 path-segment typing (deprecation window):
	// accept `ext_<external_request_id>` prefix as the typed gateway
	// form. Untyped (bare-id) segments are still resolved AS the
	// external_request_id (v0.3 behavior) but emit a deprecation
	// audit row so operators see the upcoming v0.5 break.
	requestID, typed := parseTypedSegment(rawSegment, "ext_")
	if !typed {
		// Fire-and-forget — do not block the request path on audit
		// emit failure, but surface in audit_events when it works.
		// json.Marshal-safe payload (R1 SEC MEDIUM closure).
		payloadJSON, _ := json.Marshal(map[string]any{
			"endpoint":    "GET /admin/explorer/sessions",
			"severity":    "WARN",
			"deprecation": "v0.5 will reject untyped with 400 session_id_untyped — use ext_<external_request_id>",
		})
		_ = s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
			EventID:   mustID("audit"),
			RequestID: requestID,
			Actor:     "explorer",
			Type:      "payout_explorer_path_segment_untyped",
			Payload:   string(payloadJSON),
			CreatedAt: s.now(),
		})
	}
	// Issue #196: a request_id can now legitimately match rows in
	// multiple accounts under the composite-PK schema. Operators
	// disambiguate with ?account_id=<id>.
	accountID := r.URL.Query().Get("account_id")
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(explorerQueryTimeoutMs)*time.Millisecond)
	defer cancel()
	out, err := s.readStore().ExplorerSessionDetail(ctx, accountID, requestID)
	if err != nil {
		// Surface the ambiguity case as 409 with the matching
		// account list so the UI can render a disambiguation
		// picker rather than a generic 500.
		if errors.Is(err, storage.ErrExplorerAmbiguousRequestID) {
			body := map[string]any{
				"error": map[string]any{
					"type":    "invalid_request_error",
					"code":    "ambiguous_request_id",
					"message": "request_id matches multiple accounts; supply ?account_id= to disambiguate",
				},
				"request_id":                    requestID,
				"matched_account_ids":           out.MatchedAccountIDs,
				"matched_account_ids_truncated": out.MatchedAccountIDsTruncated,
			}
			// #231 v0.4: when truncation fired, emit a bounded
			// sample of the FULL account_id list to audit_events
			// for forensic retrieval. The forensic emit is capped
			// at storage.ExplorerForensicMatchedAccountIDsCap so neither
			// the 409 response NOR the audit row can be flooded by
			// a malicious cross-account-collision attacker (R1
			// SEC HIGH closure). When the unbounded SELECT returns
			// MORE than the forensic cap, `forensic_truncated_at`
			// is set in the payload to surface the partial capture.
			if out.MatchedAccountIDsTruncated {
				forensic := out.MatchedAccountIDsForensicSample
				var forensicTruncatedAt int
				if len(forensic) > storage.ExplorerForensicMatchedAccountIDsCap {
					forensicTruncatedAt = storage.ExplorerForensicMatchedAccountIDsCap
					forensic = forensic[:storage.ExplorerForensicMatchedAccountIDsCap]
				}
				payload := map[string]any{
					"matched_account_ids": forensic,
					"cap":                 storage.ExplorerMatchedAccountIDsCap,
					"forensic_cap":        storage.ExplorerForensicMatchedAccountIDsCap,
					"severity":            "WARN",
				}
				if forensicTruncatedAt > 0 {
					payload["forensic_truncated_at"] = forensicTruncatedAt
				}
				// #231 R2 CODE MEDIUM closure: when the forensic
				// SELECT failed and storage fell back to the
				// response probe, surface the source so operators
				// can tell a partial sample apart from a real
				// "exactly cap+1 accounts" result.
				if out.MatchedAccountIDsForensicDegraded {
					payload["forensic_source"] = "response_probe"
				} else {
					payload["forensic_source"] = "forensic_select"
				}
				// json.Marshal is a stdlib JSON encoder — closes R1
				// CODE M2 / SEC MEDIUM (hand-rolled quotedCSV was
				// not C0-safe).
				payloadJSON, jerr := json.Marshal(payload)
				if jerr == nil {
					_ = s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
						EventID:   mustID("audit"),
						RequestID: requestID,
						Actor:     "explorer",
						Type:      "explorer_matched_account_ids_truncated",
						Payload:   string(payloadJSON),
						CreatedAt: s.now(),
					})
				}
			}
			writeJSON(w, http.StatusConflict, body)
			return
		}
		writeExplorerStorageError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// parseTypedSegment accepts the #231 SPEC-007 v0.4 typed-prefix path
// segment. Returns (stripped_id, true) when the prefix matches;
// (raw, false) for the legacy bare-id form. Empty prefix is rejected
// to avoid ambiguity with a literal "ext_" or "int_" id substring.
func parseTypedSegment(raw, prefix string) (string, bool) {
	if prefix != "" && strings.HasPrefix(raw, prefix) {
		stripped := strings.TrimPrefix(raw, prefix)
		if stripped == "" {
			return raw, false
		}
		return stripped, true
	}
	return raw, false
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
	out, err := s.readStore().ExplorerActivity(ctx, storage.ExplorerActivityQuery{
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
	out, err := s.readStore().ExplorerHealth(ctx, s.now().Add(-time.Duration(windowHours)*time.Hour))
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
			return explorerWindow{}, errors.New("window exceeds maximum")
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
		return explorerWindow{}, errors.New("window exceeds maximum")
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
	if !s.operatorAuthorized(w, r) {
		return false
	}
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return false
	}
	return true
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
	if errors.Is(err, storage.ErrBadCursor) {
		writeExplorerBadRequest(w, "invalid cursor")
		return
	}
	if errors.Is(err, context.DeadlineExceeded) {
		writeError(w, http.StatusRequestTimeout, "server_error", "query_timeout", "Explorer query timed out")
		return
	}
	writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Explorer query failed")
}
