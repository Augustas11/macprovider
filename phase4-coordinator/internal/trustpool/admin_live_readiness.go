package trustpool

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

func (h *adminHandler) onCallAuthorityKeySHA256() string {
	return strings.TrimSpace(os.Getenv("MACPROVIDER_SPEC043_ONCALL_AUTHORITY_KEY_SHA256"))
}

func (h *adminHandler) handleOnCallReadiness(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		envID := strings.TrimSpace(r.URL.Query().Get("launch_environment_id"))
		if envID == "" {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
			return
		}
		rec, ok, err := h.deps.Store.OnCallReadiness(r.Context(), envID)
		if err != nil {
			h.writeMutationError(w, err)
			return
		}
		if !ok {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
		writeAdminJSON(w, http.StatusOK, map[string]any{
			"on_call_readiness": rec,
			"expired":           rec.Expired(time.Now().UTC()),
		})
	case http.MethodPost:
		var rec OnCallReadiness
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&rec); err != nil {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
			return
		}
		var trailing struct{}
		if err := dec.Decode(&trailing); err != io.EOF {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
			return
		}
		operationID, err := resolveOperationID(strings.TrimSpace(rec.OperationID), r.Header)
		if err != nil {
			h.writeMutationError(w, err)
			return
		}
		rec.OperationID = operationID
		stored, err := h.deps.Store.UpsertOnCallReadiness(r.Context(), rec, h.onCallAuthorityKeySHA256())
		if err != nil {
			h.writeMutationError(w, err)
			return
		}
		writeAdminJSON(w, http.StatusOK, map[string]any{
			"on_call_readiness": stored,
		})
	default:
		w.Header().Set("Allow", "GET, POST")
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
	}
}

func (h *adminHandler) handleReviewedArtifactLifecycle(w http.ResponseWriter, r *http.Request) {
	poolID := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/admin/trust-pools/pools/"), "/reviewed-artifact-lifecycle")
	poolID = strings.Trim(poolID, "/")
	if poolID == "" || strings.Contains(poolID, "/") {
		writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
		return
	}
	switch r.Method {
	case http.MethodGet:
		rec, ok, err := h.deps.Store.ReviewedArtifactLifecycle(r.Context(), poolID)
		if err != nil {
			h.writeMutationError(w, err)
			return
		}
		if !ok {
			writeAdminJSON(w, http.StatusNotFound, map[string]any{"error": map[string]string{"code": "not_found"}})
			return
		}
		writeAdminJSON(w, http.StatusOK, map[string]any{"reviewed_artifact_lifecycle": rec})
	case http.MethodPost:
		var rec ReviewedArtifactLifecycle
		dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxAdminEventBodyBytes))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&rec); err != nil {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
			return
		}
		var trailing struct{}
		if err := dec.Decode(&trailing); err != io.EOF {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
			return
		}
		if rec.PoolID == "" {
			rec.PoolID = poolID
		} else if rec.PoolID != poolID {
			writeAdminJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]string{"code": "invalid_json"}})
			return
		}
		operationID, err := resolveOperationID(strings.TrimSpace(rec.OperationID), r.Header)
		if err != nil {
			h.writeMutationError(w, err)
			return
		}
		rec.OperationID = operationID
		stored, err := h.deps.Store.UpsertReviewedArtifactLifecycle(r.Context(), rec)
		if err != nil {
			h.writeMutationError(w, err)
			return
		}
		writeAdminJSON(w, http.StatusOK, map[string]any{"reviewed_artifact_lifecycle": stored})
	default:
		w.Header().Set("Allow", "GET, POST")
		writeAdminJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": map[string]string{"code": "method_not_allowed"}})
	}
}
