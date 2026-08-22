package auth

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

type portalSessionMintRequest struct {
	ProviderID string `json:"provider_id"`
}

func NewPortalSessionMintHandler(store *Store, operatorKey, portalBaseURL string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			w.Header().Set("Allow", http.MethodPost)
			writePortalSessionJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
			return
		}
		if !OperatorOnlyBearerMatches(r.Header, operatorKey) {
			writePortalSessionJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		if store == nil {
			writePortalSessionJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		var body portalSessionMintRequest
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<12))
		if err := dec.Decode(&body); err != nil {
			writePortalSessionJSON(w, http.StatusBadRequest, map[string]any{"error": "invalid_request"})
			return
		}
		mint, err := store.MintPortalReadSession(r.Context(), body.ProviderID, portalBaseURL, time.Now().UTC())
		if errors.Is(err, ErrPortalSessionUnknownProvider) {
			writePortalSessionJSON(w, http.StatusNotFound, map[string]any{"error": "unknown_provider"})
			return
		}
		if errors.Is(err, ErrPortalSessionRateLimited) {
			w.Header().Set("Retry-After", "3600")
			writePortalSessionJSON(w, http.StatusTooManyRequests, map[string]any{"error": "rate_limited"})
			return
		}
		if err != nil {
			if strings.Contains(err.Error(), "provider id is required") {
				writePortalSessionJSON(w, http.StatusBadRequest, map[string]any{"error": "provider_id_required"})
				return
			}
			writePortalSessionJSON(w, http.StatusInternalServerError, map[string]any{"error": "internal_error"})
			return
		}
		writePortalSessionJSON(w, http.StatusOK, map[string]any{
			"provider_id": mint.ProviderID,
			"expires_at":  mint.ExpiresAt.UTC().Format(time.RFC3339),
			"portal_url":  mint.PortalURL,
			"scope":       "portal_read",
		})
	})
}

func NewPortalSessionMeHandler(store *Store) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			w.Header().Set("Allow", http.MethodGet)
			writePortalSessionJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "method_not_allowed"})
			return
		}
		if store == nil {
			writePortalSessionJSON(w, http.StatusServiceUnavailable, map[string]any{"error": "unavailable"})
			return
		}
		raw := bearerFromAuthorization(r.Header.Get("Authorization"))
		session, ok, err := store.LookupPortalReadSession(r.Context(), raw, time.Now().UTC())
		if err != nil {
			writePortalSessionJSON(w, http.StatusInternalServerError, map[string]any{"error": "internal_error"})
			return
		}
		if !ok {
			writePortalSessionJSON(w, http.StatusUnauthorized, map[string]any{"error": "unauthorized"})
			return
		}
		writePortalSessionJSON(w, http.StatusOK, map[string]any{
			"provider_id": session.ProviderID,
			"expires_at":  session.ExpiresAt.UTC().Format(time.RFC3339),
			"scope":       "portal_read",
		})
	})
}

func bearerFromAuthorization(header string) string {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, prefix))
}

func writePortalSessionJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
