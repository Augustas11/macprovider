package ws

import (
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

func modelAdmissionOfferIdentity(p modelAdmissionOfferSubmitRequest) string {
	raw, _ := json.Marshal(struct {
		Provider, Candidate, Runtime, Served, Catalog, Discovery, Evaluation, Disclosure string
		Hashes                                                                           map[string]string
	}{p.ProviderID, p.CandidateID, p.RuntimeSource, p.ServedModelRef, p.CatalogModelKey, p.DiscoveryDigestSHA256, p.EvaluationDigestSHA256, p.RequestedDisclosureClass, p.ArtifactHashes})
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}
func modelAdmissionPending(state string) bool {
	return state == modelAdmissionOfferSubmitted || state == "sandbox_probe_only" || state == "network_admitted_unsettled" || state == "catalog_priced"
}

type modelAdmissionRetryRecord struct {
	Request ModelAdmissionEvent
	Outcome ModelAdmissionEvent
}
type modelAdmissionRetryStore interface {
	reserveModelAdmissionRetry(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, bool, error)
	completeModelAdmissionRetry(context.Context, ModelAdmissionEvent, ModelAdmissionEvent) error
}

func retryMatchesCurrent(request, current ModelAdmissionEvent) bool {
	return modelAdmissionPending(current.State) && request.OfferIdentitySHA256 != "" && request.OfferIdentitySHA256 == current.OfferIdentitySHA256
}
func (s *memoryModelAdmissionStore) reserveModelAdmissionRetry(_ context.Context, request ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.retries == nil {
		s.retries = map[string]modelAdmissionRetryRecord{}
	}
	var prior *modelAdmissionRetryRecord
	for _, key := range []string{request.ProviderID + "|request|" + request.RequestID, request.ProviderID + "|nonce|" + request.Nonce} {
		if record, ok := s.retries[key]; ok {
			if record.Request.PayloadDigestSHA256 != request.PayloadDigestSHA256 || (prior != nil && prior.Request.RequestID != record.Request.RequestID) {
				return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
			}
			copy := record
			prior = &copy
		}
	}
	if prior != nil {
		return prior.Outcome, true, nil
	}
	if _, ok := s.requestIDs[request.ProviderID+"|"+request.RequestID]; ok {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	if _, ok := s.nonces[request.ProviderID+"|"+request.Nonce]; ok {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	current, ok := s.latest[request.ProviderID+"|"+request.CandidateID]
	if !ok || !retryMatchesCurrent(request, current) {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	record := modelAdmissionRetryRecord{request, current}
	s.retries[request.ProviderID+"|request|"+request.RequestID] = record
	s.retries[request.ProviderID+"|nonce|"+request.Nonce] = record
	return current, false, nil
}
func (s *memoryModelAdmissionStore) completeModelAdmissionRetry(_ context.Context, request, outcome ModelAdmissionEvent) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	record := s.retries[request.ProviderID+"|request|"+request.RequestID]
	record.Outcome = outcome
	s.retries[request.ProviderID+"|request|"+request.RequestID] = record
	s.retries[request.ProviderID+"|nonce|"+request.Nonce] = record
	return nil
}
func (s *SQLiteModelAdmissionStore) reserveModelAdmissionRetry(ctx context.Context, request ModelAdmissionEvent) (outcome ModelAdmissionEvent, replay bool, err error) {
	err = sqliteutil.Transact(ctx, s.db, func(ctx context.Context, conn *sql.Conn) error {
		rows, err := conn.QueryContext(ctx, `SELECT request_id,payload_digest,outcome_json FROM model_admission_retries WHERE provider_id=? AND (request_id=? OR nonce=?)`, request.ProviderID, request.RequestID, request.Nonce)
		if err != nil {
			return err
		}
		var matchedRequest string
		for rows.Next() {
			var requestID, digest, raw string
			if err := rows.Scan(&requestID, &digest, &raw); err != nil {
				rows.Close()
				return err
			}
			if digest != request.PayloadDigestSHA256 || (matchedRequest != "" && matchedRequest != requestID) {
				rows.Close()
				return errModelAdmissionReplayConflict
			}
			if err := json.Unmarshal([]byte(raw), &outcome); err != nil {
				rows.Close()
				return err
			}
			matchedRequest = requestID
			replay = true
		}
		err = rows.Err()
		rows.Close()
		if err != nil {
			return err
		}
		if replay {
			return nil
		}
		var count int
		if err := conn.QueryRowContext(ctx, `SELECT COUNT(*) FROM model_admission_events WHERE provider_id=? AND (request_id=? OR nonce=?)`, request.ProviderID, request.RequestID, request.Nonce).Scan(&count); err != nil {
			return err
		}
		if count != 0 {
			return errModelAdmissionReplayConflict
		}
		current, found, err := scanModelAdmissionEvent(ctx, conn, modelAdmissionEventSelect(` FROM model_admission_events WHERE provider_id=? AND candidate_id=? ORDER BY id DESC LIMIT 1`), request.ProviderID, request.CandidateID)
		if err != nil {
			return err
		}
		if !found || !retryMatchesCurrent(request, current) {
			return errModelAdmissionReplayConflict
		}
		raw, err := json.Marshal(current)
		if err != nil {
			return err
		}
		_, err = conn.ExecContext(ctx, `INSERT INTO model_admission_retries(provider_id,request_id,nonce,payload_digest,outcome_json) VALUES(?,?,?,?,?)`, request.ProviderID, request.RequestID, request.Nonce, request.PayloadDigestSHA256, string(raw))
		outcome = current
		return err
	})
	return
}
func (s *SQLiteModelAdmissionStore) completeModelAdmissionRetry(ctx context.Context, request, outcome ModelAdmissionEvent) error {
	raw, err := json.Marshal(outcome)
	if err != nil {
		return err
	}
	_, err = s.db.ExecContext(ctx, `UPDATE model_admission_retries SET outcome_json=? WHERE provider_id=? AND request_id=? AND payload_digest=?`, string(raw), request.ProviderID, request.RequestID, request.PayloadDigestSHA256)
	return err
}

func (s *Server) handleProviderModelAdmissionRetry(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok := s.authenticateProviderReadOnly(w, r)
	if !ok {
		return
	}
	if s.modelAdmissionSubmitDisabled {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError(modelAdmissionSubmissionsDisabledCode, "model admission retries disabled"))
		return
	}
	if !s.allowModelAdmissionAttempt(providerID) {
		writeJSON(w, http.StatusTooManyRequests, modelAdmissionError("rate_limited", "model admission retry rejected"))
		return
	}
	var body modelAdmissionOfferSubmitRequest
	r.Body = http.MaxBytesReader(w, r.Body, modelAdmissionMaxBodyBytes+1)
	if decodeStrictJSON(r.Body, &body) != nil {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_json", "invalid model admission retry"))
		return
	}
	request, err := s.verifyModelAdmissionOffer(r.Context(), providerID, body)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_offer", "model admission retry rejected"))
		return
	}
	store, ok := s.modelAdmissions.(modelAdmissionRetryStore)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("retry_unavailable", "model admission retry unavailable"))
		return
	}
	current, replay, err := store.reserveModelAdmissionRetry(r.Context(), request)
	if err != nil {
		status := http.StatusInternalServerError
		if errors.Is(err, errModelAdmissionReplayConflict) {
			status = http.StatusConflict
		}
		writeJSON(w, status, modelAdmissionError("retry_conflict", "model admission retry rejected"))
		return
	}
	if !replay {
		ctx, cancel := modelAdmissionOfferProbeContext(r.Context())
		defer cancel()
		current = s.retryPendingModelAdmission(ctx, current)
		if err := store.completeModelAdmissionRetry(ctx, request, current); err != nil {
			writeJSON(w, http.StatusInternalServerError, modelAdmissionError("retry_store_error", "model admission retry readback unavailable"))
			return
		}
	}
	current, err = s.refreshArtifactAdmissionStatus(r.Context(), current)
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("model_admission_authority_unavailable", "current admission unavailable"))
		return
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionStatusResponseFromEvent(current, replay))
}

func (s *Server) retryPendingModelAdmission(ctx context.Context, current ModelAdmissionEvent) ModelAdmissionEvent {
	// A provider has at most one in-flight probe and one retry per 30 seconds.
	s.modelAdmissionProbeMu.Lock()
	if s.modelAdmissionProbes == nil {
		s.modelAdmissionProbes = map[string]time.Time{}
	}
	next := s.modelAdmissionProbes[current.ProviderID]
	if s.now().Before(next) {
		s.modelAdmissionProbeMu.Unlock()
		return current
	}
	s.modelAdmissionProbes[current.ProviderID] = s.now().Add(modelAdmissionSyntheticProbeTimeout + 30*time.Second)
	s.modelAdmissionProbeMu.Unlock()
	defer func() {
		s.modelAdmissionProbeMu.Lock()
		s.modelAdmissionProbes[current.ProviderID] = s.now().Add(30 * time.Second)
		s.modelAdmissionProbeMu.Unlock()
	}()
	provider, ok := s.modelAdmissionSyntheticProbeProvider(current.ProviderID)
	if !ok || s.providerModelAdmissionSanctioned(current.ProviderID) {
		return current
	}
	if current.State == modelAdmissionOfferSubmitted || current.State == "sandbox_probe_only" {
		return s.maybeRunModelAdmissionSyntheticProbeForOffer(ctx, current, false)
	}
	if current.State != "network_admitted_unsettled" && current.State != "catalog_priced" {
		return current
	}
	passed, wireID, err := s.executeModelAdmissionWireProbe(ctx, current, provider)
	if err != nil {
		return current
	}
	if !passed {
		revoked := modelAdmissionCoordinatorDecisionFromCurrent(current, "revoked", "synthetic_probe_failed", "macprovider.model_admission.retry_probe.v1", wireID, s.now())
		if stored, err := s.modelAdmissions.AppendModelAdmissionDecision(ctx, revoked); err == nil {
			return stored
		}
		return current
	}
	return s.promoteModelAdmission(ctx, current, provider, s.now())
}
