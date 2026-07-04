package router

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func (s *Server) handleFeedbackSummary(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	days := 7
	if r.URL.Query().Get("window") == "14d" {
		days = 14
	} else if q := r.URL.Query().Get("window"); q != "" && q != "7d" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_window", "window must be 7d or 14d")
		return
	}
	end := s.now()
	start := end.AddDate(0, 0, -days)
	events, err := s.store.ListFeedbackEventsSinceLimit(r.Context(), start, 1000)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "feedback_summary_failed", "Could not summarize feedback")
		return
	}
	writeJSON(w, http.StatusOK, buildFeedbackSummary(events, start, end))
}

func (s *Server) handleKillSwitch(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	var req struct {
		DemoOnly     *bool `json:"demo_only"`
		AllPublicAPI *bool `json:"all_public_api"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_kill_switch", "Invalid kill switch request")
		return
	}
	s.mu.RLock()
	old := s.cfg.KillSwitch
	next := s.cfg
	s.mu.RUnlock()
	if req.DemoOnly != nil {
		next.KillSwitch.DemoOnly = *req.DemoOnly
	}
	if req.AllPublicAPI != nil {
		next.KillSwitch.AllPublicAPI = *req.AllPublicAPI
	}
	if err := s.store.SetKillSwitch(r.Context(), storage.KillSwitchState{
		DemoOnly:     next.KillSwitch.DemoOnly,
		AllPublicAPI: next.KillSwitch.AllPublicAPI,
		UpdatedAt:    s.now(),
	}); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "kill_switch_persist_failed", "Could not persist kill switch")
		return
	}
	s.mu.Lock()
	s.cfg.KillSwitch = next.KillSwitch
	s.mu.Unlock()
	_ = s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
		EventID: mustID("audit"), RequestID: requestID(r), Actor: "operator", Type: "kill_switch_toggled",
		Payload:   fmt.Sprintf(`{"old_demo_only":%t,"new_demo_only":%t,"old_all_public_api":%t,"new_all_public_api":%t}`, old.DemoOnly, next.KillSwitch.DemoOnly, old.AllPublicAPI, next.KillSwitch.AllPublicAPI),
		CreatedAt: s.now(),
	})
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "kill_switch": next.KillSwitch})
}

func (s *Server) handleCapacitySignal(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	var req struct {
		Signal    string  `json:"signal"`
		Value     float64 `json:"value"`
		Threshold float64 `json:"threshold"`
		Firing    bool    `json:"firing"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Signal == "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_capacity_signal", "Invalid capacity signal")
		return
	}
	event := storage.CapacitySignalEvent{EventID: mustID("cap"), Signal: req.Signal, Value: req.Value, Threshold: req.Threshold, Firing: req.Firing, CreatedAt: s.now()}
	if err := s.store.InsertCapacitySignalEvent(r.Context(), event); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_signal_store_failed", "Could not store capacity signal")
		return
	}
	if req.Firing {
		tier, _ := s.store.GetCapacityTier(r.Context())
		if req.Signal == "monthly_cost" && req.Value >= float64(s.cfg.Capacity.MonthlyBudgetUSD) {
			_ = s.setCapacityTier(r.Context(), 3, req.Signal, "capacity_tier_escalated")
			s.setAllPublicPaused(r.Context(), true, "capacity_tier_3")
		} else if req.Signal == "provider_drop" && req.Value >= 2 {
			_ = s.setCapacityTier(r.Context(), 3, req.Signal, "capacity_tier_escalated")
			s.setAllPublicPaused(r.Context(), true, "capacity_tier_3")
		} else if tier.Tier == 0 {
			_ = s.setCapacityTier(r.Context(), 1, req.Signal, "capacity_tier_escalated")
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "event_id": event.EventID})
}

func (s *Server) handleCapacityEvaluate(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	if !s.operatorAuthorized(w, r) {
		return
	}
	tier, err := s.store.GetCapacityTier(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_tier_load_failed", "Could not load capacity tier")
		return
	}
	signals, err := s.store.LatestCapacitySignals(r.Context())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "capacity_signal_load_failed", "Could not load capacity signals")
		return
	}
	anyFiring := false
	for _, signal := range signals {
		anyFiring = anyFiring || signal.Firing
	}
	previous := tier.Tier
	next := previous
	below := !anyFiring
	if previous == 1 && !below && s.now().Sub(tier.UpdatedAt) >= 7*24*time.Hour {
		next = 2
		_ = s.setCapacityTier(r.Context(), next, "tier_1_signal_still_firing", "capacity_tier_escalated")
	} else if previous > 0 && below && s.now().Sub(tier.UpdatedAt) >= time.Duration(s.cfg.Capacity.TierCooldownSeconds)*time.Second {
		next = previous - 1
		_ = s.setCapacityTier(r.Context(), next, "signals_below_threshold", "capacity_tier_deescalated")
		if previous == 3 {
			s.setAllPublicPaused(r.Context(), false, "capacity_tier_deescalated")
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"previous_tier": previous, "new_tier": next, "signals_below_threshold": below})
}

func (s *Server) setCapacityTier(ctx context.Context, tier int, signals, eventType string) error {
	now := s.now()
	if err := s.store.SetCapacityTier(ctx, storage.CapacityTier{Tier: tier, Signals: signals, UpdatedAt: now}); err != nil {
		return err
	}
	return s.store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID: mustID("audit"), RequestID: mustID("req"), Actor: "capacity_monitor", Type: eventType,
		Payload: fmt.Sprintf(`{"new_tier":%d,"signals":%q}`, tier, signals), CreatedAt: now,
	})
}

func (s *Server) setAllPublicPaused(ctx context.Context, paused bool, reason string) {
	s.mu.Lock()
	old := s.cfg.KillSwitch.AllPublicAPI
	s.cfg.KillSwitch.AllPublicAPI = paused
	s.mu.Unlock()
	if old == paused {
		return
	}
	if err := s.store.SetKillSwitch(ctx, storage.KillSwitchState{
		DemoOnly:     s.demoPaused(),
		AllPublicAPI: paused,
		UpdatedAt:    s.now(),
	}); err != nil {
		slog.Error("kill switch persistence failed", "error", err, "reason", reason)
	}
	_ = s.store.InsertAuditEvent(ctx, storage.AuditEvent{
		EventID: mustID("audit"), RequestID: mustID("req"), Actor: "capacity_monitor", Type: "kill_switch_toggled",
		Payload: fmt.Sprintf(`{"old_all_public_api":%t,"new_all_public_api":%t,"reason":%q}`, old, paused, reason), CreatedAt: s.now(),
	})
}

func buildFeedbackSummary(events []storage.FeedbackSummaryEvent, start, end time.Time) map[string]any {
	latest := map[string]storage.FeedbackSummaryEvent{}
	for _, event := range events {
		key := event.EventID
		if event.RequestID != "" {
			key = event.AccountID + "\x00" + event.RequestID
		}
		if existing, ok := latest[key]; !ok || event.CreatedAt.After(existing.CreatedAt) {
			latest[key] = event
		}
	}
	distribution := map[string]int{"1": 0, "2": 0, "3": 0, "4": 0}
	type scopeAgg struct {
		count int
		sum   int
	}
	scopes := map[string]*scopeAgg{
		"request": {}, "session": {}, "account": {}, "playground": {},
	}
	var sum int
	var low int
	comments := []map[string]any{}
	for _, event := range latest {
		distribution[strconv.Itoa(event.Rating)]++
		sum += event.Rating
		if event.Rating <= 2 {
			low++
		}
		if _, ok := scopes[event.Scope]; !ok {
			scopes[event.Scope] = &scopeAgg{}
		}
		scopes[event.Scope].count++
		scopes[event.Scope].sum += event.Rating
		if event.Comment != "" {
			comments = append(comments, map[string]any{
				"rating": event.Rating, "comment": event.Comment, "scope": event.Scope, "timestamp": event.CreatedAt.Format(time.RFC3339),
			})
		}
	}
	sort.Slice(comments, func(i, j int) bool {
		return comments[i]["timestamp"].(string) > comments[j]["timestamp"].(string)
	})
	if len(comments) > 20 {
		comments = comments[:20]
	}
	count := len(latest)
	mean := 0.0
	share := 0.0
	if count > 0 {
		mean = float64(sum) / float64(count)
		share = float64(low) / float64(count)
	}
	byScope := map[string]any{}
	for scope, agg := range scopes {
		scopeMean := 0.0
		if agg.count > 0 {
			scopeMean = float64(agg.sum) / float64(agg.count)
		}
		byScope[scope] = map[string]any{"rating_count": agg.count, "mean": scopeMean}
	}
	return map[string]any{
		"window_start":    start.Format(time.RFC3339),
		"window_end":      end.Format(time.RFC3339),
		"rating_count":    count,
		"mean":            mean,
		"distribution":    distribution,
		"by_scope":        byScope,
		"trend":           map[string]any{"7d_share_1_2": share, "14d_share_1_2": share, "delta_pct": 0.0, "iteration_trigger": count >= 20 && share > 0.4},
		"comment_samples": comments,
	}
}
