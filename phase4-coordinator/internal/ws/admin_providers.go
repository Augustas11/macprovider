package ws

import (
	"context"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/providerevents"
)

type adminProviderView struct {
	ProviderID      string     `json:"provider_id"`
	Presence        string     `json:"presence"`
	AssignedID      string     `json:"assigned_id,omitempty"`
	BinaryVersion   string     `json:"binary_version,omitempty"`
	ModelID         string     `json:"model_id,omitempty"`
	State           string     `json:"state,omitempty"`
	AuthState       string     `json:"auth_state,omitempty"`
	ConnectedAt     *time.Time `json:"connected_at,omitempty"`
	LastHeartbeatAt *time.Time `json:"last_heartbeat_at,omitempty"`
	LastActivityAt  *time.Time `json:"last_activity_at,omitempty"`
	LastSeenAt      time.Time  `json:"last_seen_at"`
	RoutingEligible bool       `json:"routing_eligible"`
	RecentEvents    int        `json:"recent_event_count,omitempty"`
}

func (s *Server) handleAdminProviders(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.connectionEvents == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider connection events unavailable", "code": "events_unavailable"}})
		return
	}

	path := strings.TrimPrefix(r.URL.Path, "/admin/providers")
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		s.writeAdminProviderList(w, r)
		return
	}
	parts := strings.Split(path, "/")
	providerID := parts[0]
	if err := config.ValidateProviderID(providerID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid provider_id", "code": "invalid_provider_id"}})
		return
	}
	if len(parts) == 1 {
		s.writeAdminProviderDetail(w, r, providerID)
		return
	}
	if len(parts) == 2 && parts[1] == "events" {
		s.writeAdminProviderEvents(w, r, providerID)
		return
	}
	writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "not found", "code": "not_found"}})
}

func (s *Server) writeAdminProviderList(w http.ResponseWriter, r *http.Request) {
	live := map[string]pool.Provider{}
	for _, p := range s.pool.Snapshot() {
		live[p.ProviderID] = p
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	known, err := s.connectionEvents.ListLastKnown(ctx)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "list last-known failed", "code": "events_store_error"}})
		return
	}

	out := make([]adminProviderView, 0, len(live)+len(known))
	seen := map[string]struct{}{}
	for _, p := range live {
		view := adminViewFromLive(p)
		out = append(out, view)
		seen[p.ProviderID] = struct{}{}
	}
	for _, snap := range known {
		if _, ok := seen[snap.ProviderID]; ok {
			continue
		}
		snap.Presence = "offline"
		out = append(out, adminViewFromLastKnown(snap))
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"providers": out,
		"summary": map[string]any{
			"total":     len(out),
			"connected": len(live),
			"offline":   len(out) - len(live),
		},
	})
}

func (s *Server) writeAdminProviderDetail(w http.ResponseWriter, r *http.Request, providerID string) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()

	var view adminProviderView
	if p, ok := s.pool.Resolve(providerID, ""); ok {
		view = adminViewFromLive(p)
	} else {
		snap, found, err := s.connectionEvents.GetLastKnown(ctx, providerID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "last-known lookup failed", "code": "events_store_error"}})
			return
		}
		if !found {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider not found", "code": "provider_not_found"}})
			return
		}
		snap.Presence = "offline"
		view = adminViewFromLastKnown(snap)
	}

	events, err := s.connectionEvents.ListEvents(ctx, providerID, 20)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "event list failed", "code": "events_store_error"}})
		return
	}
	view.RecentEvents = len(events)
	writeJSON(w, http.StatusOK, map[string]any{
		"provider": view,
		"events":   events,
	})
}

func (s *Server) writeAdminProviderEvents(w http.ResponseWriter, r *http.Request, providerID string) {
	limit := 50
	if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
		n, err := strconv.Atoi(raw)
		if err != nil || n <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid limit", "code": "invalid_request"}})
			return
		}
		limit = n
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	events, err := s.connectionEvents.ListEvents(ctx, providerID, limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "event list failed", "code": "events_store_error"}})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id": providerID,
		"events":      events,
		"count":       len(events),
	})
}

func adminViewFromLive(p pool.Provider) adminProviderView {
	view := adminProviderView{
		ProviderID:      p.ProviderID,
		Presence:        "connected",
		AssignedID:      p.AssignedID,
		BinaryVersion:   p.BinaryVersion,
		ModelID:         p.ModelID,
		State:           string(p.State),
		AuthState:       string(p.AuthState),
		RoutingEligible: p.RoutingEligible(),
	}
	if !p.ConnectedAt.IsZero() {
		t := p.ConnectedAt.UTC()
		view.ConnectedAt = &t
		view.LastSeenAt = t
	}
	if !p.LastHeartbeatAt.IsZero() {
		t := p.LastHeartbeatAt.UTC()
		view.LastHeartbeatAt = &t
		view.LastSeenAt = t
	}
	if !p.LastActivityAt.IsZero() {
		t := p.LastActivityAt.UTC()
		view.LastActivityAt = &t
		view.LastSeenAt = t
	}
	if view.LastSeenAt.IsZero() {
		view.LastSeenAt = time.Now().UTC()
	}
	return view
}

func adminViewFromLastKnown(snap providerevents.LastKnown) adminProviderView {
	presence := snap.Presence
	if presence == "" {
		presence = "offline"
	}
	return adminProviderView{
		ProviderID:      snap.ProviderID,
		Presence:        presence,
		AssignedID:      snap.AssignedID,
		BinaryVersion:   snap.BinaryVersion,
		ModelID:         snap.ModelID,
		State:           snap.State,
		AuthState:       snap.AuthState,
		ConnectedAt:     snap.ConnectedAt,
		LastHeartbeatAt: snap.LastHeartbeatAt,
		LastActivityAt:  snap.LastActivityAt,
		LastSeenAt:      snap.LastSeenAt,
		RoutingEligible: snap.RoutingEligible,
	}
}
