package ws

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/google/uuid"
)

const (
	maxProviderAuthPolicyTTL        = 30 * 24 * time.Hour
	breakGlassProviderAuthPolicyTTL = 7 * 24 * time.Hour
	maxAdmissionIdentityRecoveryTTL = 24 * time.Hour
)

var (
	errAuthPolicyAdminUnavailable = errors.New("provider auth policy admin store unavailable")
	errDualControlRequired        = errors.New("dual_control_required")
	errPendingExemptionNotFound   = errors.New("pending exemption not found")
	errPendingExemptionCommitted  = errors.New("pending exemption already committed")
	errRenewalCapExceeded         = errors.New("renewal cap exceeded")
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
	if r.Method != http.MethodPost && r.Method != http.MethodDelete {
		w.Header().Set("Allow", http.MethodPost+", "+http.MethodDelete)
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
	if err := config.ValidateProviderID(providerID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid provider_id", "code": "invalid_provider_id"}})
		return
	}
	if r.Method == http.MethodDelete {
		admissionCleared, canaryCleared, err := s.recoverProvider(providerID)
		if err != nil {
			s.log.Error().Err(err).
				Str("admin_action", "provider_rejection_clear_failed").
				Str("provider_id", providerID).
				Msg("provider operator recovery failed")
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{
				"message": "provider recovery persistence failed",
				"code":    "provider_recovery_failed",
			}})
			return
		}
		s.log.Info().
			Str("admin_action", "provider_rejection_cleared").
			Str("provider_id", providerID).
			Bool("admission_rejection_cleared", admissionCleared).
			Bool("canary_sanction_cleared", canaryCleared).
			Msg("provider operator recovery completed")
		writeJSON(w, http.StatusOK, map[string]any{
			"provider_id":                 providerID,
			"status":                      "recovered",
			"admission_rejection_cleared": admissionCleared,
			"canary_sanction_cleared":     canaryCleared,
		})
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
				s.closeSession(session, CloseBanned, "banned: provider "+providerID+" has been rejected by operator")
			})
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"provider_id": providerID,
		"status":      "rejected",
	})
}

func (s *Server) recoverProvider(providerID string) (admissionCleared, canaryCleared bool, err error) {
	s.canaryRecoveryMu.Lock()
	defer s.canaryRecoveryMu.Unlock()

	// Invalidate every probe that captured the prior epoch. A probe already
	// applying its result holds the read lock and completes before this clear;
	// a probe still in flight observes the new epoch and discards its result.
	s.canaryEpoch(providerID).Add(1)
	if err := s.deleteCanarySanction(providerID); err != nil {
		return false, false, fmt.Errorf("delete durable canary sanction: %w", err)
	}
	if s.admission != nil {
		admissionCleared, err = s.admission.Unreject(providerID)
		if err != nil {
			return false, false, fmt.Errorf("persist admission recovery: %w", err)
		}
	}
	canaryCleared = s.pool.ClearCanarySanction(providerID)
	s.canaryDue.Delete(providerID)
	s.enforceNextCanary.Delete(providerID)
	return admissionCleared, canaryCleared, nil
}

func (s *Server) handleProviderAuthPolicySeedCutover(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	actor, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.authPolicyAdmin == nil {
		writeAuthPolicyError(w, errAuthPolicyAdminUnavailable)
		return
	}
	if s.authStore == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "auth store unavailable", "code": "auth_store_unavailable"}})
		return
	}
	var body struct {
		Confirm string `json:"confirm"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	if body.Confirm != "spec-026-cutover" {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "confirm must equal spec-026-cutover", "code": "invalid_request"}})
		return
	}
	cutover := s.now().UTC()
	cliProviderIDs, err := s.authStore.ListActiveProviderIDsCreatedBefore(r.Context(), cutover)
	if err != nil {
		s.log.Warn().Err(err).Msg("provider auth policy cutover CLI snapshot failed")
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "cutover snapshot failed", "code": "cutover_snapshot_failed"}})
		return
	}
	seeded, err := s.authPolicyAdmin.SeedProviderAuthPolicyCutover(r.Context(), cutover, cliProviderIDs)
	if err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	exemptUntil := cutover.Add(breakGlassProviderAuthPolicyTTL)
	s.log.Info().
		Str("admin_action", "provider_auth_policy_cutover_seeded").
		Str("actor", actor).
		Time("cutover_time", cutover).
		Time("signature_exempt_until", exemptUntil).
		Int("cli_provider_count", len(cliProviderIDs)).
		Int64("seeded_count", seeded).
		Msg("provider auth policy cutover seeded")
	writeJSON(w, http.StatusOK, map[string]any{
		"status":                 "seeded",
		"cutover_time":           cutover.Format(time.RFC3339),
		"signature_exempt_until": exemptUntil.Format(time.RFC3339),
		"cli_provider_count":     len(cliProviderIDs),
		"seeded_count":           seeded,
	})
}

func (s *Server) handleProviderAuthPolicyExemptRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	requestedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.authPolicyAdmin == nil {
		writeAuthPolicyError(w, errAuthPolicyAdminUnavailable)
		return
	}
	var body struct {
		ProviderID     string `json:"provider_id"`
		RequestedBy    string `json:"requested_by"`
		RequestedUntil string `json:"requested_until"`
		Reason         string `json:"reason"`
		IncidentID     string `json:"incident_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.ProviderID = strings.TrimSpace(body.ProviderID)
	body.RequestedBy = strings.TrimSpace(body.RequestedBy)
	body.Reason = strings.TrimSpace(body.Reason)
	body.IncidentID = strings.TrimSpace(body.IncidentID)
	if body.RequestedBy != "" && body.RequestedBy != requestedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "requested_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	requestedUntil, err := time.Parse(time.RFC3339, strings.TrimSpace(body.RequestedUntil))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "requested_until must be RFC3339", "code": "invalid_request"}})
		return
	}
	requestedUntil = requestedUntil.UTC()
	if err := s.validateProviderAuthPolicyRequest(r, body.ProviderID, requestedBy, requestedUntil, body.Reason, body.IncidentID); err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	pendingID := s.newUUID()
	if _, err := uuid.Parse(pendingID); err != nil {
		writeAuthPolicyError(w, errors.New("generated pending_id is invalid"))
		return
	}
	if err := s.authPolicyAdmin.RequestProviderAuthPolicyExemption(r.Context(), pendingID, body.ProviderID, requestedBy, requestedUntil, body.Reason, body.IncidentID); err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	ttl := requestedUntil.Sub(s.now())
	s.log.Info().
		Str("admin_action", "exempt_provider_id_requested").
		Str("provider_id", body.ProviderID).
		Str("pending_id", pendingID).
		Str("actor", requestedBy).
		Str("reason", body.Reason).
		Str("incident_id", body.IncidentID).
		Dur("ttl", ttl).
		Msg("provider auth policy exemption requested")
	writeJSON(w, http.StatusAccepted, map[string]any{
		"pending_id":      pendingID,
		"provider_id":     body.ProviderID,
		"requested_by":    requestedBy,
		"requested_until": requestedUntil.Format(time.RFC3339),
		"status":          "pending",
	})
}

func (s *Server) handleProviderAuthPolicyExemptApprove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	approvedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.authPolicyAdmin == nil {
		writeAuthPolicyError(w, errAuthPolicyAdminUnavailable)
		return
	}
	pendingID := strings.TrimPrefix(r.URL.Path, "/admin/provider-auth-policy/exempt/")
	pendingID = strings.TrimSuffix(pendingID, "/approve")
	if pendingID == "" || !strings.HasSuffix(r.URL.Path, "/approve") {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "admin path not found", "code": "not_found"}})
		return
	}
	if _, err := uuid.Parse(pendingID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "pending_id must be UUID", "code": "invalid_request"}})
		return
	}
	var body struct {
		ApprovedBy string `json:"approved_by"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.ApprovedBy = strings.TrimSpace(body.ApprovedBy)
	if body.ApprovedBy != "" && body.ApprovedBy != approvedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "approved_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	providerID, requestedBy, requestedUntil, reason, incidentID, err := s.authPolicyAdmin.ApproveProviderAuthPolicyExemption(r.Context(), pendingID, approvedBy)
	if err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	ttl := requestedUntil.UTC().Sub(s.now())
	s.log.Info().
		Str("admin_action", "exempt_provider_id_approved").
		Str("provider_id", providerID).
		Str("pending_id", pendingID).
		Str("actor", approvedBy).
		Str("requested_by", requestedBy).
		Str("reason", reason).
		Str("incident_id", incidentID).
		Dur("ttl", ttl).
		Msg("provider auth policy exemption approved")
	writeJSON(w, http.StatusOK, map[string]any{
		"pending_id":       pendingID,
		"provider_id":      providerID,
		"requested_by":     requestedBy,
		"approved_by":      approvedBy,
		"requested_until":  requestedUntil.UTC().Format(time.RFC3339),
		"status":           "committed",
		"signature_exempt": true,
	})
}

func (s *Server) handleAdmissionIdentityRecoveryRequest(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.providerAuthPolicyDualControlAvailable() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "two distinct operator keys are required", "code": "dual_control_unavailable"}})
		return
	}
	requestedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.admissionIdentityRecoveryAdmin == nil {
		writeAuthPolicyError(w, errAuthPolicyAdminUnavailable)
		return
	}
	var body struct {
		ProviderID               string `json:"provider_id"`
		CandidatePublicKeySHA256 string `json:"candidate_public_key_sha256"`
		RequestedBy              string `json:"requested_by"`
		RequestedUntil           string `json:"requested_until"`
		Reason                   string `json:"reason"`
		IncidentID               string `json:"incident_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.ProviderID = strings.TrimSpace(body.ProviderID)
	body.CandidatePublicKeySHA256 = strings.ToLower(strings.TrimSpace(body.CandidatePublicKeySHA256))
	body.RequestedBy = strings.TrimSpace(body.RequestedBy)
	body.Reason = strings.TrimSpace(body.Reason)
	body.IncidentID = strings.TrimSpace(body.IncidentID)
	if body.RequestedBy != "" && body.RequestedBy != requestedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "requested_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	requestedUntil, err := time.Parse(time.RFC3339, strings.TrimSpace(body.RequestedUntil))
	if err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "requested_until must be RFC3339", "code": "invalid_request"}})
		return
	}
	requestedUntil = requestedUntil.UTC()
	selection := s.durableIdentitySignatureSelection(r.Context(), AuthRequest{ProviderID: body.ProviderID})
	if !selection.Found || selection.Blocked || len(selection.ActivePubkey) == 0 {
		writeAuthPolicyError(w, errPendingExemptionNotFound)
		return
	}
	currentDigest := sha256.Sum256(selection.ActivePubkey)
	expectedCurrentPublicKeySHA256 := hex.EncodeToString(currentDigest[:])
	if err := s.validateAdmissionIdentityRecoveryRequest(
		r, body.ProviderID, body.CandidatePublicKeySHA256,
		expectedCurrentPublicKeySHA256, selection.Generation,
		requestedBy, requestedUntil, body.Reason, body.IncidentID,
	); err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	pendingID := s.newUUID()
	if _, err := uuid.Parse(pendingID); err != nil {
		writeAuthPolicyError(w, errors.New("generated pending_id is invalid"))
		return
	}
	authorization := AdmissionIdentityRecoveryAuthorization{
		PendingID:                      pendingID,
		ProviderID:                     body.ProviderID,
		CandidatePublicKeySHA256:       body.CandidatePublicKeySHA256,
		ExpectedCurrentPublicKeySHA256: expectedCurrentPublicKeySHA256,
		ExpectedGeneration:             selection.Generation,
		RequestedBy:                    requestedBy,
		RequestedUntil:                 requestedUntil,
		Reason:                         body.Reason,
		IncidentID:                     body.IncidentID,
	}
	canonical, err := s.admissionIdentityRecoveryAdmin.RequestAdmissionIdentityRecovery(r.Context(), authorization, s.now())
	if err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	authorization = canonical
	s.log.Warn().
		Str("admin_action", "admission_identity_recovery_requested").
		Str("provider_id", authorization.ProviderID).
		Str("pending_id", authorization.PendingID).
		Str("actor", requestedBy).
		Str("candidate_public_key_sha256", authorization.CandidatePublicKeySHA256).
		Str("expected_current_public_key_sha256", authorization.ExpectedCurrentPublicKeySHA256).
		Int("expected_generation", authorization.ExpectedGeneration).
		Str("incident_id", authorization.IncidentID).
		Time("requested_until", authorization.RequestedUntil).
		Msg("admission identity recovery requested")
	writeJSON(w, http.StatusAccepted, map[string]any{
		"pending_id":                         authorization.PendingID,
		"provider_id":                        authorization.ProviderID,
		"candidate_public_key_sha256":        authorization.CandidatePublicKeySHA256,
		"expected_current_public_key_sha256": authorization.ExpectedCurrentPublicKeySHA256,
		"expected_generation":                authorization.ExpectedGeneration,
		"requested_by":                       authorization.RequestedBy,
		"requested_until":                    authorization.RequestedUntil.Format(time.RFC3339),
		"incident_id":                        authorization.IncidentID,
		"status":                             "pending",
	})
}

func (s *Server) handleAdmissionIdentityRecoveryApprove(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.providerAuthPolicyDualControlAvailable() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "two distinct operator keys are required", "code": "dual_control_unavailable"}})
		return
	}
	approvedBy, ok := s.authorizedProviderAuthPolicyOperator(r)
	if !ok {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	if s.admissionIdentityRecoveryAdmin == nil {
		writeAuthPolicyError(w, errAuthPolicyAdminUnavailable)
		return
	}
	pendingID := strings.TrimPrefix(r.URL.Path, "/admin/provider-admission-identity/recover/")
	pendingID = strings.TrimSuffix(pendingID, "/approve")
	if pendingID == "" || !strings.HasSuffix(r.URL.Path, "/approve") {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "admin path not found", "code": "not_found"}})
		return
	}
	if _, err := uuid.Parse(pendingID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "pending_id must be UUID", "code": "invalid_request"}})
		return
	}
	var body struct {
		ApprovedBy string `json:"approved_by"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	body.ApprovedBy = strings.TrimSpace(body.ApprovedBy)
	if body.ApprovedBy != "" && body.ApprovedBy != approvedBy {
		writeJSON(w, http.StatusForbidden, map[string]any{"error": map[string]any{"message": "approved_by must match authenticated operator", "code": "operator_actor_mismatch"}})
		return
	}
	authorization, err := s.admissionIdentityRecoveryAdmin.ApproveAdmissionIdentityRecovery(r.Context(), pendingID, approvedBy, s.now())
	if err != nil {
		writeAuthPolicyError(w, err)
		return
	}
	s.log.Warn().
		Str("admin_action", "admission_identity_recovery_approved").
		Str("provider_id", authorization.ProviderID).
		Str("pending_id", authorization.PendingID).
		Str("actor", approvedBy).
		Str("requested_by", authorization.RequestedBy).
		Str("candidate_public_key_sha256", authorization.CandidatePublicKeySHA256).
		Str("expected_current_public_key_sha256", authorization.ExpectedCurrentPublicKeySHA256).
		Int("expected_generation", authorization.ExpectedGeneration).
		Str("incident_id", authorization.IncidentID).
		Time("requested_until", authorization.RequestedUntil).
		Msg("admission identity recovery approved")
	writeJSON(w, http.StatusOK, map[string]any{
		"pending_id":                         authorization.PendingID,
		"provider_id":                        authorization.ProviderID,
		"candidate_public_key_sha256":        authorization.CandidatePublicKeySHA256,
		"expected_current_public_key_sha256": authorization.ExpectedCurrentPublicKeySHA256,
		"expected_generation":                authorization.ExpectedGeneration,
		"requested_by":                       authorization.RequestedBy,
		"approved_by":                        authorization.ApprovedBy,
		"requested_until":                    authorization.RequestedUntil.Format(time.RFC3339),
		"incident_id":                        authorization.IncidentID,
		"status":                             "approved",
		"one_shot":                           true,
	})
}

func (s *Server) validateAdmissionIdentityRecoveryRequest(
	r *http.Request,
	providerID, candidateDigest, currentDigest string,
	expectedGeneration int,
	requestedBy string,
	requestedUntil time.Time,
	reason, incidentID string,
) error {
	if providerID == "" || !s.providerIDExistsForAuthPolicy(r, providerID) {
		return errPendingExemptionNotFound
	}
	if !validSHA256Hex(candidateDigest) || !validSHA256Hex(currentDigest) {
		return errors.New("public key digests must be lowercase SHA-256 hex")
	}
	if candidateDigest == currentDigest {
		return errors.New("candidate key must differ from expected current key")
	}
	if expectedGeneration < 1 {
		return errors.New("expected_generation must be positive")
	}
	if !validOperatorActor(requestedBy) {
		return errors.New("requested_by must use operator:<admin_id>")
	}
	if reason == "" {
		return errors.New("reason is required")
	}
	if incidentID == "" {
		return errors.New("incident_id is required")
	}
	now := s.now()
	if !requestedUntil.After(now) {
		return errors.New("requested_until must be in the future")
	}
	if requestedUntil.Sub(now) > maxAdmissionIdentityRecoveryTTL {
		return errors.New("requested_until exceeds 24 hour ceiling")
	}
	return nil
}

func validSHA256Hex(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, c := range value {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

func (s *Server) providerAuthPolicyDualControlAvailable() bool {
	if len(s.cfg.Auth.OperatorKeys) < 2 {
		return false
	}
	seen := make(map[string]struct{}, len(s.cfg.Auth.OperatorKeys))
	for actor, secret := range s.cfg.Auth.OperatorKeys {
		if !validOperatorActor(normalizedOperatorActor(actor)) {
			return false
		}
		secret = strings.TrimSpace(secret)
		if secret == "" {
			return false
		}
		if _, exists := seen[secret]; exists {
			return false
		}
		seen[secret] = struct{}{}
	}
	return true
}

func (s *Server) validateProviderAuthPolicyRequest(r *http.Request, providerID, requestedBy string, requestedUntil time.Time, reason, incidentID string) error {
	if providerID == "" {
		return errors.New("provider_id is required")
	}
	if !validOperatorActor(requestedBy) {
		return errors.New("requested_by must use operator:<admin_id>")
	}
	if reason == "" {
		return errors.New("reason is required")
	}
	now := s.now()
	if !requestedUntil.After(now) {
		return errors.New("requested_until must be in the future")
	}
	ttl := requestedUntil.Sub(now)
	if ttl > maxProviderAuthPolicyTTL {
		return errors.New("requested_until exceeds 30 day ceiling")
	}
	if ttl > breakGlassProviderAuthPolicyTTL && incidentID == "" {
		return errors.New("incident_id required for exemptions over 7 days")
	}
	if !s.providerIDExistsForAuthPolicy(r, providerID) {
		return errPendingExemptionNotFound
	}
	return nil
}

func validOperatorActor(actor string) bool {
	actor = strings.TrimSpace(actor)
	return strings.HasPrefix(actor, "operator:") && strings.TrimSpace(strings.TrimPrefix(actor, "operator:")) != ""
}

func (s *Server) authorizedProviderAuthPolicyOperator(r *http.Request) (string, bool) {
	for actorID, operatorKey := range s.cfg.Auth.OperatorKeys {
		if !auth.OperatorOnlyBearerMatches(r.Header, operatorKey) {
			continue
		}
		actor := normalizedOperatorActor(actorID)
		if !validOperatorActor(actor) {
			return "", false
		}
		s.log.Info().
			Str("event", "internal_bearer_accepted").
			Str("key", "operator_keys").
			Str("actor", actor).
			Str("path", r.URL.Path).
			Str("remote_addr", r.RemoteAddr).
			Msg("internal bearer accepted")
		return actor, true
	}
	return "", false
}

func normalizedOperatorActor(actorID string) string {
	actorID = strings.TrimSpace(actorID)
	if strings.HasPrefix(actorID, "operator:") {
		return actorID
	}
	return "operator:" + actorID
}

func (s *Server) providerIDExistsForAuthPolicy(r *http.Request, providerID string) bool {
	if strings.HasPrefix(providerID, "p_") {
		if s.identitySignatures == nil {
			return false
		}
		_, ok, err := s.identitySignatures.LookupProviderIdentityPubkey(r.Context(), providerID)
		return err == nil && ok
	}
	if s.issuer != nil {
		ok, err := s.issuer.HasActiveTokenForProvider(r.Context(), providerID)
		if err == nil && ok {
			return true
		}
		if err != nil {
			s.log.Warn().Err(err).Str("provider_id", providerID).Msg("provider auth policy token existence lookup failed")
		}
	}
	_, ok := s.pool.Resolve(providerID, "")
	return ok
}

func writeAuthPolicyError(w http.ResponseWriter, err error) {
	msg := strings.ToLower(err.Error())
	status := http.StatusBadRequest
	code := "invalid_request"
	switch {
	case errors.Is(err, errAuthPolicyAdminUnavailable):
		status = http.StatusServiceUnavailable
		code = "auth_policy_admin_unavailable"
	case errors.Is(err, errDualControlRequired) || strings.Contains(msg, "dual_control_required"):
		status = http.StatusForbidden
		code = "dual_control_required"
	case errors.Is(err, errPendingExemptionNotFound) || strings.Contains(msg, "not found"):
		status = http.StatusNotFound
		code = "provider_not_found"
	case errors.Is(err, errPendingExemptionCommitted) || strings.Contains(msg, "already committed"):
		status = http.StatusConflict
		code = "pending_already_committed"
	case strings.Contains(msg, "cutover seed already completed"):
		status = http.StatusConflict
		code = "cutover_seed_already_completed"
	case errors.Is(err, errRenewalCapExceeded) || strings.Contains(msg, "renewal cap"):
		status = http.StatusConflict
		code = "renewal_cap_exceeded"
	case strings.Contains(msg, "30 day"):
		code = "ttl_too_long"
	case strings.Contains(msg, "incident_id"):
		code = "incident_id_required"
	}
	writeJSON(w, status, map[string]any{"error": map[string]any{"message": err.Error(), "code": code}})
}
