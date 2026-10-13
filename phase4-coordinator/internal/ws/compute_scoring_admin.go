package ws

// SPEC-036 FR-25 provider/operator visibility and operator controls for
// cross-provider scoring, and SPEC-022 R-16.4 operator hold release.

import (
	"context"
	"errors"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/computeintegrity"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

// ComputeScoringKeyStatus is one model's FR-25 status.
type ComputeScoringKeyStatus struct {
	ModelID   string    `json:"model_id"`
	State     string    `json:"state"`
	Reason    string    `json:"reason,omitempty"`
	Since     time.Time `json:"since"`
	NextStep  string    `json:"next_step"`
	InBand    int       `json:"in_band_measurements"`
	OutOfBand int       `json:"out_of_band_measurements"`
}

// ComputeScoringStatus is the FR-25 scoring section of the status surfaces.
type ComputeScoringStatus struct {
	Enabled bool                            `json:"enabled"`
	Models  []ComputeScoringKeyStatus       `json:"models"`
	Holds   []computeintegrity.EarningsHold `json:"holds"`
	Scorer  map[string]bool                 `json:"scorer"`
}

func (e *computeScoringEngine) providerStatus(ctx context.Context, providerID string) (ComputeScoringStatus, error) {
	out := ComputeScoringStatus{Enabled: e.deps.Config.Enabled, Models: []ComputeScoringKeyStatus{}, Holds: []computeintegrity.EarningsHold{}}
	e.mu.Lock()
	for key, st := range e.states {
		if key.providerID != providerID {
			continue
		}
		out.Models = append(out.Models, ComputeScoringKeyStatus{
			ModelID: st.ModelID, State: string(st.State), Reason: string(st.Reason), Since: st.Since,
			NextStep: st.NextStep(), InBand: st.InBandTotal, OutOfBand: st.OutOfBandTotal,
		})
	}
	e.mu.Unlock()
	sort.Slice(out.Models, func(i, j int) bool { return out.Models[i].ModelID < out.Models[j].ModelID })
	out.Scorer = map[string]bool{"excluded": e.scorers.Excluded(providerID)}
	holds, err := e.deps.Holds.ComputeIntegrityHolds(ctx, providerID)
	if err != nil {
		return out, err
	}
	if holds != nil {
		out.Holds = holds
	}
	return out, nil
}

// operatorClear resets one key to unverified and lifts its suspension.
// Holds are untouched (SPEC-022 R-16.4).
func (e *computeScoringEngine) operatorClear(ctx context.Context, providerID, modelID string) (bool, error) {
	now := e.s.now()
	e.mu.Lock()
	defer e.mu.Unlock()
	key := computeScoringKey{providerID, modelID}
	st := e.states[key]
	if st == nil {
		return false, nil
	}
	tr := st.OperatorClear(now)
	if !e.applyTransitionLocked(ctx, st, tr, now) {
		return true, errors.New("compute-integrity clear not applied")
	}
	delete(e.nextDue, key)
	return true, nil
}

func (e *computeScoringEngine) clearScorer(ctx context.Context, providerID string) error {
	e.scorers.Clear(providerID)
	return e.deps.Store.ClearScorerExclusion(ctx, providerID)
}

type computeIntegrityOperatorAction struct {
	ModelID    string `json:"model_id,omitempty"`
	OperatorID string `json:"operator_id"`
	Reason     string `json:"reason"`
}

func validOperatorText(value string, max int) bool {
	value = strings.TrimSpace(value)
	return value != "" && len(value) <= max && !containsControlChar(value)
}

// handleAdminComputeIntegrityAction serves
//
//	POST /admin/compute-integrity/<provider_id>/clear        {model_id, operator_id, reason}
//	POST /admin/compute-integrity/<provider_id>/clear-scorer {operator_id, reason}
//	POST /admin/compute-integrity/holds/<hold_id>/release    {operator_id, reason}
func (s *Server) handleAdminComputeIntegrityAction(w http.ResponseWriter, r *http.Request) {
	e := s.computeScoring.Load()
	if e == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"error": map[string]any{"message": "compute-integrity scoring unavailable", "code": "compute_integrity_scoring_unavailable"}})
		return
	}
	parts := strings.Split(strings.Trim(strings.TrimPrefix(r.URL.Path, "/admin/compute-integrity"), "/"), "/")
	if len(parts) != 3 && len(parts) != 2 {
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "not found", "code": "not_found"}})
		return
	}
	var action computeIntegrityOperatorAction
	r.Body = http.MaxBytesReader(w, r.Body, 4096)
	if err := decodeStrictJSON(r.Body, &action); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid request body", "code": "invalid_request"}})
		return
	}
	if !validOperatorText(action.OperatorID, 128) || !validOperatorText(action.Reason, 512) {
		writeJSON(w, http.StatusUnprocessableEntity, map[string]any{"error": map[string]any{"message": "operator_id and reason are required", "code": "invalid_operator_action"}})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()
	now := s.now()
	audit := s.log.Warn().
		Str("event", "compute_integrity_operator_action").
		Str("operator_id", action.OperatorID).
		Str("reason", action.Reason)
	switch {
	case len(parts) == 3 && parts[0] == "holds" && parts[2] == "release":
		holdID, err := strconv.ParseInt(parts[1], 10, 64)
		if err != nil || holdID <= 0 {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid hold id", "code": "invalid_hold_id"}})
			return
		}
		hold, err := e.deps.Holds.ReleaseComputeIntegrityHold(ctx, holdID, action.OperatorID, action.Reason, now)
		if err != nil {
			status, code := http.StatusInternalServerError, "compute_integrity_hold_release_failed"
			switch {
			case errors.Is(err, computeintegrity.ErrHoldNotFound):
				status, code = http.StatusNotFound, "compute_integrity_hold_not_found"
			case errors.Is(err, computeintegrity.ErrHoldAlreadyReleased):
				status, code = http.StatusConflict, "compute_integrity_hold_already_released"
			}
			writeJSON(w, status, map[string]any{"error": map[string]any{"message": "hold release failed", "code": code}})
			return
		}
		audit.Str("action", "release_hold").Int64("hold_id", holdID).Str("provider_id", hold.ProviderID).Str("model_id", hold.ModelID).Msg("compute-integrity hold released")
		writeJSON(w, http.StatusOK, map[string]any{"hold": hold})
	case len(parts) == 2 && parts[1] == "clear":
		providerID := parts[0]
		if config.ValidateProviderID(providerID) != nil || !boundedPrintable(action.ModelID, 1, 256) {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid provider_id or model_id", "code": "invalid_request"}})
			return
		}
		found, err := e.operatorClear(ctx, providerID, action.ModelID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "clear failed", "code": "compute_integrity_clear_failed"}})
			return
		}
		if !found {
			writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "no verification state for that model", "code": "compute_integrity_key_not_found"}})
			return
		}
		audit.Str("action", "clear").Str("provider_id", providerID).Str("model_id", action.ModelID).Msg("compute-integrity key cleared")
		writeJSON(w, http.StatusOK, map[string]any{"provider_id": providerID, "model_id": action.ModelID, "state": string(computeintegrity.VerificationUnverified)})
	case len(parts) == 2 && parts[1] == "clear-scorer":
		providerID := parts[0]
		if config.ValidateProviderID(providerID) != nil {
			writeJSON(w, http.StatusBadRequest, map[string]any{"error": map[string]any{"message": "invalid provider_id", "code": "invalid_provider_id"}})
			return
		}
		if err := e.clearScorer(ctx, providerID); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"error": map[string]any{"message": "clear failed", "code": "compute_integrity_clear_failed"}})
			return
		}
		audit.Str("action", "clear_scorer").Str("provider_id", providerID).Msg("compute-integrity scorer exclusion cleared")
		writeJSON(w, http.StatusOK, map[string]any{"provider_id": providerID, "scorer_excluded": false})
	default:
		writeJSON(w, http.StatusNotFound, map[string]any{"error": map[string]any{"message": "not found", "code": "not_found"}})
	}
}

// computeScoringStatusFor returns the scoring section, or nil when the
// engine is not running.
func (s *Server) computeScoringStatusFor(ctx context.Context, providerID string) (*ComputeScoringStatus, error) {
	e := s.computeScoring.Load()
	if e == nil {
		return nil, nil
	}
	status, err := e.providerStatus(ctx, providerID)
	if err != nil {
		return nil, err
	}
	return &status, nil
}
