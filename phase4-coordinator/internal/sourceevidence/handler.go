package sourceevidence

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

const defaultMaxBodyBytes = int64(64 << 10)

type Handler struct {
	operatorKey string
	producer    *Producer
	maxBody     int64
}

func NewHandler(operatorKey string, producer *Producer, maxBodyBytes int64) http.Handler {
	if maxBodyBytes <= 0 {
		maxBodyBytes = defaultMaxBodyBytes
	}
	return &Handler{operatorKey: operatorKey, producer: producer, maxBody: maxBodyBytes}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		writeEvidenceError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return
	}
	if !auth.OperatorOnlyBearerMatches(r.Header, h.operatorKey) {
		writeEvidenceError(w, http.StatusUnauthorized, "unauthorized", "operator bearer token required")
		return
	}
	if h.producer == nil {
		writeEvidenceError(w, http.StatusServiceUnavailable, "source_evidence_unavailable", "source evidence unavailable")
		return
	}
	dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, h.maxBody))
	dec.DisallowUnknownFields()
	var req ExportRequest
	if err := dec.Decode(&req); err != nil {
		writeEvidenceError(w, http.StatusBadRequest, "invalid_source_evidence_request", "invalid source evidence request")
		return
	}
	envelope, err := h.producer.Export(r.Context(), req)
	if err != nil {
		switch {
		case errors.Is(err, ErrInvalidRequest):
			writeEvidenceError(w, http.StatusBadRequest, "invalid_source_evidence_request", "invalid source evidence request")
		case errors.Is(err, ErrScopeNotClosed):
			writeEvidenceError(w, http.StatusConflict, "source_evidence_scope_not_closed", "source evidence scope is not closed")
		default:
			writeEvidenceError(w, http.StatusServiceUnavailable, "source_evidence_unavailable", "source evidence unavailable")
		}
		return
	}
	w.WriteHeader(http.StatusOK)
	_ = json.NewEncoder(w).Encode(envelope)
}

func writeEvidenceError(w http.ResponseWriter, status int, code, message string) {
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{"code": code, "message": message}})
}
