package rewards

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/google/uuid"
)

// TrustAdminDeps wires operator dual-control trust promotion endpoints.
//
// Dual control is enforced by DISTINCT operator credentials, not by a
// self-asserted actor header (SEC-1). The requester and approver must
// present DIFFERENT bearer tokens drawn from OperatorKeys, and the acting
// identity is derived from the matched key — never from a client-supplied
// X-Operator-Actor header. OperatorKeys maps an operator actor id to its
// secret; at least two entries with unique, non-empty secrets are required
// or the route fails closed. This mirrors the provider-auth-policy operator
// model in internal/ws/admin_endpoints.go.
type TrustAdminDeps struct {
	DB           *sql.DB
	OperatorKeys map[string]string
}

// dualControlReady reports whether the configured operator keys can support
// two-person control: at least two actors, every secret non-empty and
// unique. With duplicate secrets a single credential could match more than
// one actor id, which would defeat the requested_by != approved_by check.
func dualControlReady(keys map[string]string) bool {
	if len(keys) < 2 {
		return false
	}
	seen := make(map[string]struct{}, len(keys))
	for _, secret := range keys {
		secret = strings.TrimSpace(secret)
		if secret == "" {
			return false
		}
		if _, dup := seen[secret]; dup {
			return false
		}
		seen[secret] = struct{}{}
	}
	return true
}

// NewTrustPromotionRequestHandler serves POST /admin/trust-promotion/request.
func NewTrustPromotionRequestHandler(deps TrustAdminDeps) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if !dualControlReady(deps.OperatorKeys) {
			writeTrustJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "dual_control_unavailable"})
			return
		}
		actor, ok := authorizedTrustOperator(r, deps.OperatorKeys)
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
		// requested_by, when supplied, is advisory only and must match the
		// credential-derived actor; the actor of record is always the one
		// bound to the matched operator key.
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
		if !dualControlReady(deps.OperatorKeys) {
			writeTrustJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "dual_control_unavailable"})
			return
		}
		actor, ok := authorizedTrustOperator(r, deps.OperatorKeys)
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
		// ApproveTrustPromotion rejects approved_by == requested_by. Because
		// each actor is bound to a distinct operator key, that check now means
		// a DIFFERENT credential must approve than the one that requested.
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

// authorizedTrustOperator matches the request bearer against the configured
// operator keys using a constant-time comparison and returns the operator
// identity bound to the MATCHED key. It never trusts a client-supplied
// X-Operator-Actor header (SEC-1) and never short-circuits on a plain string
// compare (SEC-2). Fails closed unless dual control is configured; because
// dualControlReady guarantees unique secrets, at most one key can match, so
// the returned actor is deterministic despite random map iteration.
func authorizedTrustOperator(r *http.Request, keys map[string]string) (actor string, ok bool) {
	if !dualControlReady(keys) {
		return "", false
	}
	for actorID, secret := range keys {
		if !auth.OperatorOnlyBearerMatches(r.Header, secret) {
			continue
		}
		return normalizedTrustOperatorActor(actorID), true
	}
	return "", false
}

// normalizedTrustOperatorActor renders an operator map key as an
// operator:<id> identity, matching internal/ws normalizedOperatorActor.
func normalizedTrustOperatorActor(actorID string) string {
	actorID = strings.TrimSpace(actorID)
	if strings.HasPrefix(actorID, "operator:") {
		return actorID
	}
	return "operator:" + actorID
}

func writeTrustJSON(w http.ResponseWriter, status int, payload map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
