package ws

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func (s *Server) handleAdminProvisional(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	connected := map[string]bool{}
	for _, p := range s.pool.Snapshot() {
		if p.Tier == pool.TierProvisional {
			connected[p.ProviderID] = true
		}
	}
	records := s.admission.Records(connected)
	summary := struct {
		TotalProvisional   int `json:"total_provisional"`
		CurrentlyConnected int `json:"currently_connected"`
		Promoted           int `json:"promoted"`
	}{TotalProvisional: len(records)}
	for _, r := range records {
		if r.CurrentlyConnected {
			summary.CurrentlyConnected++
		}
		if r.PromotedAt != nil {
			summary.Promoted++
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"provisional": records, "summary": summary})
}

func (s *Server) handleAdminPromote(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	providerID := strings.TrimPrefix(r.URL.Path, "/admin/promote/")
	if providerID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "missing provider_id", "code": "invalid_request"}})
		return
	}
	provider, ok := s.pool.Resolve(providerID, "")
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider " + providerID + " not found", "code": "provider_not_found"}})
		return
	}
	if provider.Tier == pool.TierPinned {
		writeJSON(w, http.StatusConflict, map[string]any{"error": map[string]any{"message": "provider already pinned", "code": "already_pinned"}})
		return
	}
	previous := string(provider.Tier)
	s.admission.Promote(providerID)
	if updated, ok := s.pool.SetTier(providerID, pool.TierPinned); ok {
		provider = updated
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id":   provider.ProviderID,
		"previous_tier": previous,
		"new_tier":      string(provider.Tier),
		"note":          "Runtime promotion only. Add to coordinator.yaml for persistence across restarts.",
	})
}

func (s *Server) handleAdminReject(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	providerID := strings.TrimPrefix(r.URL.Path, "/admin/reject/")
	if providerID == "" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "missing provider_id", "code": "invalid_request"}})
		return
	}
	var body struct {
		Reason string `json:"reason"`
	}
	_ = json.NewDecoder(r.Body).Decode(&body)
	s.admission.Reject(providerID, body.Reason)
	if provider, ok := s.pool.Resolve(providerID, ""); ok {
		if session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID); ok {
			_ = session.send([]byte(`{"type":"drain"}`))
			s.pool.MarkState(provider.ProviderID, provider.AssignedID, pool.StateDraining)
			time.AfterFunc(200*time.Millisecond, func() {
				s.close(session.conn, CloseBanned, "banned: provider "+providerID+" has been rejected by operator")
				_ = session.conn.Close()
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id": providerID,
		"status":      "rejected",
	})
}
