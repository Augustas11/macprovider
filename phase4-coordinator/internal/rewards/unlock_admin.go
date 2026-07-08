package rewards

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
)

// TrustAdminDeps wires operator dual-control trust promotion endpoints.
type TrustAdminDeps struct {
	DB          *sql.DB
	OperatorKey string
}

// NewTrustPromotionRequestHandler serves POST /admin/trust-promotion/request.
func NewTrustPromotionRequestHandler(deps TrustAdminDeps) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		actor, ok := authorizedTrustOperator(r, deps.OperatorKey)
		if !ok {
			writeTrustJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		if deps.DB == nil {
			writeTrustJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		var body struct {
			ProviderID  string `json:"provider_id"`
			RequestedBy string `json:"requested_by"`
			Reason      string `json:"reason"`
			IncidentID  string `json:"incident_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			writeTrustJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_json"})
			return
		}
		body.ProviderID = strings.TrimSpace(body.ProviderID)
		body.Reason = strings.TrimSpace(body.Reason)
		body.IncidentID = strings.TrimSpace(body.IncidentID)
		if body.RequestedBy != "" && body.RequestedBy != actor {
			writeTrustJSON(w, http.StatusForbidden, map[string]any{"error": "operator_actor_mismatch"})
			return
		}
		pendingID := uuid.NewString()
		if err := RequestTrustPromotion(r.Context(), deps.DB, pendingID, body.ProviderID, actor, body.Reason, body.IncidentID); err != nil {
			writeTrustJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeTrustJSON(w, http.StatusAccepted, map[string]any{
			"pending_id":   pendingID,
			"provider_id":  body.ProviderID,
			"requested_by": actor,
			"status":       "pending",
		})
	})
}

// NewTrustPromotionApproveHandler serves POST /admin/trust-promotion/{pending_id}/approve.
func NewTrustPromotionApproveHandler(deps TrustAdminDeps) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		actor, ok := authorizedTrustOperator(r, deps.OperatorKey)
		if !ok {
			writeTrustJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		if deps.DB == nil {
			writeTrustJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		path := strings.TrimPrefix(r.URL.Path, "/admin/trust-promotion/")
		path = strings.TrimSuffix(path, "/approve")
		pendingID := strings.TrimSpace(path)
		if pendingID == "" || !strings.HasSuffix(r.URL.Path, "/approve") {
			writeTrustJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
			return
		}
		providerID, err := ApproveTrustPromotion(r.Context(), deps.DB, pendingID, actor)
		if err != nil {
			writeTrustJSON(w, http.StatusBadRequest, map[string]any{"error": err.Error()})
			return
		}
		writeTrustJSON(w, http.StatusOK, map[string]any{
			"pending_id":  pendingID,
			"provider_id": providerID,
			"approved_by": actor,
			"status":      "committed",
			"trust_tier":  TierTrusted,
			"promoted_at": time.Now().UTC().Format(time.RFC3339),
		})
	})
}

func authorizedTrustOperator(r *http.Request, operatorKey string) (actor string, ok bool) {
	if operatorKey == "" {
		return "", false
	}
	auth := strings.TrimSpace(r.Header.Get("Authorization"))
	const prefix = "Bearer "
	if !strings.HasPrefix(auth, prefix) {
		return "", false
	}
	token := strings.TrimSpace(strings.TrimPrefix(auth, prefix))
	if token != operatorKey {
		return "", false
	}
	actor = strings.TrimSpace(r.Header.Get("X-Operator-Actor"))
	if actor == "" {
		actor = "operator:unknown"
	}
	return actor, true
}

func writeTrustJSON(w http.ResponseWriter, status int, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
