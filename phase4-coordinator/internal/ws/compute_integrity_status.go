package ws

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

// ComputeIntegrityStatusSource is the read-only live telemetry seam for SPEC-036
// status. Implementations must return sanitized StatusSnapshot values only.
type ComputeIntegrityStatusSource interface {
	ComputeIntegrityStatus(ctx context.Context, providerID string) ([]computeintegrity.StatusSnapshot, error)
}

type computeIntegrityReadOnlyTokenValidator interface {
	ValidateTokenReadOnly(context.Context, string) (string, bool, error)
}

func (s *Server) handleAdminComputeIntegrity(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if r.Method == http.MethodPost {
		s.handleAdminComputeIntegrityAction(w, r)
		return
	}
	if s.computeIntegrityStatus == nil && s.computeScoring.Load() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "compute-integrity status unavailable", "code": "compute_integrity_status_unavailable"}})
		return
	}
	providerID := strings.Trim(strings.TrimPrefix(r.URL.Path, "/admin/compute-integrity"), "/")
	if providerID == "" {
		providerID = strings.TrimSpace(r.URL.Query().Get("provider_id"))
	}
	if err := config.ValidateProviderID(providerID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid provider_id", "code": "invalid_provider_id"}})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	statuses, scoring, err := s.computeIntegrityStatuses(ctx, providerID, false)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "compute-integrity status lookup failed", "code": "compute_integrity_status_error"}})
		return
	}
	for _, status := range statuses {
		if status.ProviderID != providerID {
			s.log.Warn().
				Str("authenticated_provider_id", providerID).
				Str("status_provider_id", status.ProviderID).
				Msg("compute-integrity status source returned mismatched provider")
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "compute-integrity status lookup failed", "code": "compute_integrity_status_error"}})
			return
		}
	}
	body := map[string]any{
		"provider_id": providerID,
		"count":       len(statuses),
		"statuses":    statuses,
		"disclosure":  computeintegrity.StatusCopyV1,
	}
	if scoring != nil {
		body["scoring"] = scoring
	}
	writeJSON(w, http.StatusOK, body)
}

func (s *Server) handleProviderComputeIntegrity(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.cfg.Auth.RequireProviderTokens {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider tokens not enabled", "code": "provider_tokens_not_enabled"}})
		return
	}
	if s.tokens == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider tokens unavailable", "code": "provider_tokens_unavailable"}})
		return
	}
	if s.computeIntegrityStatus == nil && s.computeScoring.Load() == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "compute-integrity status unavailable", "code": "compute_integrity_status_unavailable"}})
		return
	}
	raw := bearerToken(r.Header.Get("Authorization"))
	if raw == "" {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "provider bearer token required", "code": "unauthorized"}})
		return
	}
	readOnlyTokens, ok := s.tokens.(computeIntegrityReadOnlyTokenValidator)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "provider token read-only validation unavailable", "code": "provider_tokens_read_only_unavailable"}})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	providerID, ok, err := readOnlyTokens.ValidateTokenReadOnly(ctx, raw)
	if err != nil || !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "provider bearer token required", "code": "unauthorized"}})
		return
	}
	statuses, scoring, err := s.computeIntegrityStatuses(ctx, providerID, true)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "compute-integrity status lookup failed", "code": "compute_integrity_status_error"}})
		return
	}
	for _, status := range statuses {
		if status.ProviderID != providerID {
			s.log.Warn().
				Str("authenticated_provider_id", providerID).
				Str("status_provider_id", status.ProviderID).
				Msg("compute-integrity status source returned mismatched provider")
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "compute-integrity status lookup failed", "code": "compute_integrity_status_error"}})
			return
		}
	}
	body := map[string]any{
		"provider_id": providerID,
		"count":       len(statuses),
		"statuses":    statuses,
		"disclosure":  computeintegrity.StatusCopyV1,
	}
	if scoring != nil {
		body["scoring"] = scoring
	}
	writeJSON(w, http.StatusOK, body)
}

// computeIntegrityStatuses reads the SPEC-036 FR-15 statuses (when that
// source is wired) and the §5A scoring section (when the engine runs).
func (s *Server) computeIntegrityStatuses(ctx context.Context, providerID string, forProvider bool) ([]computeintegrity.StatusSnapshot, *ComputeScoringStatus, error) {
	statuses := []computeintegrity.StatusSnapshot{}
	if s.computeIntegrityStatus != nil {
		got, err := s.computeIntegrityStatus.ComputeIntegrityStatus(ctx, providerID)
		if err != nil {
			return nil, nil, err
		}
		statuses = got
	}
	scoring, err := s.computeScoringStatusFor(ctx, providerID, forProvider)
	if err != nil {
		return nil, nil, err
	}
	return statuses, scoring, nil
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimSpace(strings.TrimPrefix(header, prefix))
}
