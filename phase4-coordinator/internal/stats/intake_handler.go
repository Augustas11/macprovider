package stats

import (
	"encoding/json"
	"net/http"
	"time"
)

// SPEC-017 v0.2.1 §5.2b — GET /v1/stats/intake.
//
// Partner key REQUIRED and allow-listed per key (§5.2b.7); provider-bound
// keys refused; no query parameters; private, never shared-cached. The
// body is the singleton stats_intake_current row's two JSON objects
// wrapped in the closed `macprovider.stats-intake.v1` frame.

const intakeSchemaVersion = "macprovider.stats-intake.v1"

type intakeMethodology struct {
	Version         string `json:"version"`
	UnmatchedModels string `json:"unmatched_models"`
	FleetRAM        string `json:"fleet_ram"`
	Redaction       string `json:"redaction"`
}

var publicIntakeMethodology = intakeMethodology{
	Version:         "SPEC-017-v0.2.1",
	UnmatchedModels: "SPEC-023 §16.2(a) Space-Saving summary; a bucket is emitted only when at least k_anonymity_min distinct principals contributed; lower_bound = count - error is the only value that may satisfy a floor; only a complete window is admission evidence",
	FleetRAM:        "verified hardware profiles active in the trailing 30 days, bucketed by unified memory class floor; a class below k_anonymity_min is suppressed and counts as zero fit",
	Redaction:       "aggregated counts only; no buyer account, API key, IP, raw requested model string, principal token, provider id, pseudonym, or hardware identity material",
}

type intakeResponse struct {
	SchemaVersion   string            `json:"schema_version"`
	GeneratedAt     string            `json:"generated_at"`
	StaleAfter      string            `json:"stale_after"`
	UnmatchedModels json.RawMessage   `json:"unmatched_models"`
	FleetRAM        json.RawMessage   `json:"fleet_ram"`
	Methodology     intakeMethodology `json:"methodology"`
}

// intakeReaderAllowed applies §5.2b.7: the matched key's id must be listed
// and the key must not be provider-bound. An empty list refuses every key.
func (h *Handler) intakeReaderAllowed(ar authResult) bool {
	if ar.projection != "partner" || ar.matchedKey == nil {
		return false
	}
	if ar.matchedKey.ProviderID.Valid {
		return false
	}
	_, ok := h.IntakeReaderKeyIDs[ar.matchedKey.ID]
	return ok
}

func (h *Handler) handleIntake(w http.ResponseWriter, r *http.Request, ar authResult) {
	ctx := r.Context()
	now := h.nowFn()
	if !h.IntakeEnabled {
		writeError(w, r, http.StatusNotFound, codeBadRequest, "unknown endpoint", now, nil)
		return
	}
	if ar.projection != "partner" || ar.matchedKey == nil {
		writeError(w, r, http.StatusUnauthorized, codeUnauthorized, "unauthorized", now, nil)
		return
	}
	if !h.intakeReaderAllowed(ar) {
		writeError(w, r, http.StatusForbidden, codeUnauthorized, "unauthorized", now, nil)
		return
	}
	if len(r.URL.Query()) != 0 {
		writeError(w, r, http.StatusBadRequest, codeBadRequest, "no query parameters are accepted", now, nil)
		return
	}
	row, err := h.Store.Intake(ctx)
	if err != nil {
		writeError(w, r, http.StatusInternalServerError, codeInternal, "intake read failed", now, nil)
		return
	}
	if row == nil || intakeStaleFor503(now, row.GeneratedAt) {
		retry := 30
		gen := now
		if row != nil {
			gen = row.GeneratedAt
		}
		writeError(w, r, http.StatusServiceUnavailable, codeStatsStale, "intake is stale", gen, &retry)
		return
	}
	if obs := requestObsFromContext(ctx); obs != nil {
		obs.GeneratedAtAgeMs = time.Since(row.GeneratedAt).Milliseconds()
	}
	resp := intakeResponse{
		SchemaVersion:   intakeSchemaVersion,
		GeneratedAt:     row.GeneratedAt.UTC().Format(time.RFC3339),
		StaleAfter:      row.GeneratedAt.Add(15 * time.Minute).UTC().Format(time.RFC3339),
		UnmatchedModels: json.RawMessage(row.UnmatchedModelsJSON),
		FleetRAM:        json.RawMessage(row.FleetRAMJSON),
		Methodology:     publicIntakeMethodology,
	}
	writeJSON(w, r, http.StatusOK, resp, row.GeneratedAt, "private, max-age=900", varyForPartner(), ar)
}

func intakeStaleFor503(now, generatedAt time.Time) bool {
	if generatedAt.IsZero() {
		return true
	}
	t := thresholdsForComponent("intake")
	return now.Sub(generatedAt) > time.Duration(t.budgetSec)*time.Second
}
