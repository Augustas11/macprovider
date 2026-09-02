package ws

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
)

type admissionCanaryProviderSnapshot struct {
	ProviderID                       string `json:"provider_id"`
	AssignedID                       string `json:"assigned_id"`
	ModelID                          string `json:"model_id"`
	RoutingEligible                  bool   `json:"routing_eligible"`
	ServingCapable                   bool   `json:"serving_capable"`
	AdmissionCeilingExcluded         bool   `json:"admission_ceiling_excluded"`
	AdmissionEvidenceStale           bool   `json:"admission_evidence_stale"`
	AdmissionSandboxed               bool   `json:"admission_sandboxed"`
	MaxAdmittedModelID               string `json:"max_admitted_model_id"`
	MaxAdmittedMinRAMGB              int    `json:"max_admitted_min_ram_gb"`
	HasAdmittedTuple                 bool   `json:"has_admitted_tuple"`
	AdmissionSandboxCredentialBypass bool   `json:"admission_sandbox_credential_bypassed"`
}

func admissionCanarySnapshot(p pool.Provider) admissionCanaryProviderSnapshot {
	return admissionCanaryProviderSnapshot{
		ProviderID:                       p.ProviderID,
		AssignedID:                       p.AssignedID,
		ModelID:                          p.ModelID,
		RoutingEligible:                  p.RoutingEligible(),
		ServingCapable:                   p.ServingCapable(),
		AdmissionCeilingExcluded:         p.AdmissionCeilingExcluded,
		AdmissionEvidenceStale:           p.AdmissionEvidenceStale,
		AdmissionSandboxed:               p.AdmissionSandboxed,
		MaxAdmittedModelID:               p.MaxAdmittedModelID,
		MaxAdmittedMinRAMGB:              p.MaxAdmittedMinRAMGB,
		HasAdmittedTuple:                 providerHasAdmittedTuple(p),
		AdmissionSandboxCredentialBypass: p.AdmissionSandboxCredentialBypassed,
	}
}

func (s *Server) handleAdmissionCanaryClearAdmittedTuple(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.cfg.AdmissionCanaryHarness.Enabled {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "admission canary harness disabled", "code": "not_found"}})
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	var req struct {
		ProviderID string `json:"provider_id"`
		AssignedID string `json:"assigned_id,omitempty"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid json", "code": "invalid_request"}})
		return
	}
	req.ProviderID = strings.TrimSpace(req.ProviderID)
	req.AssignedID = strings.TrimSpace(req.AssignedID)
	if err := config.ValidateProviderID(req.ProviderID); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid provider_id", "code": "invalid_provider_id"}})
		return
	}
	before, after, ok := s.pool.ClearAdmittedTupleForCanary(req.ProviderID, req.AssignedID)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "provider session not found", "code": "provider_not_found"}})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status":      "ok",
		"provider_id": req.ProviderID,
		"assigned_id": after.AssignedID,
		"before":      admissionCanarySnapshot(before),
		"after":       admissionCanarySnapshot(after),
	})
}

func (s *Server) handleAdmissionCanaryProofOfWeights(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if !s.cfg.AdmissionCanaryHarness.Enabled {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "admission canary harness disabled", "code": "not_found"}})
		return
	}
	if !s.authorizedOperator(r) {
		writeJSON(w, http.StatusUnauthorized, map[string]any{"error": map[string]any{"message": "unauthorized", "code": "invalid_operator_token"}})
		return
	}
	current := s.proofOfWeightsConfig()
	lastConfig, lastReload, lastAt, haveLastReload := s.LastProofOfWeightsReloadResult()
	last := map[string]any{
		"present": haveLastReload,
	}
	if haveLastReload {
		last = map[string]any{
			"present":     true,
			"observed_at": lastAt.UTC().Format(time.RFC3339Nano),
			"config": map[string]any{
				"require_autotune_hello_gate": lastConfig.RequireAutotuneHelloGate,
				"autotune_evidence_ttl_days":  lastConfig.AutotuneEvidenceTTLDays,
			},
			"result": proofOfWeightsReloadResultJSON(lastReload),
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
		"config": map[string]any{
			"require_autotune_hello_gate": current.RequireAutotuneHelloGate,
			"autotune_evidence_ttl_days":  current.AutotuneEvidenceTTLDays,
		},
		"last_reload": last,
		"pool":        admissionCanaryPoolSnapshot(s.pool.Snapshot()),
	})
}

func proofOfWeightsReloadResultJSON(reload ProofOfWeightsReloadResult) map[string]any {
	return map[string]any{
		"generation":              reload.Generation,
		"pre_quarantined":         reload.PreQuarantined,
		"revalidated":             reload.Revalidated,
		"sandboxed":               reload.Sandboxed,
		"route_excluded":          reload.RouteExcluded,
		"still_evidence_stale":    reload.StillEvidenceStale,
		"cleared_gate_exclusions": reload.ClearedGateExclusions,
	}
}

func admissionCanaryPoolSnapshot(providers []pool.Provider) []admissionCanaryProviderSnapshot {
	out := make([]admissionCanaryProviderSnapshot, 0, len(providers))
	for _, p := range providers {
		out = append(out, admissionCanarySnapshot(p))
	}
	return out
}
