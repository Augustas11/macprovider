package ws

import (
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/jcs"
	"github.com/augstar/macprovider-coordinator/internal/sqliteutil"
)

const (
	modelAdmissionOfferSubmitSchema = "model_admission_offer_submit.v1"
	modelAdmissionStatusSchema      = "model_admission_status.v1"
	modelAdmissionSignedDomain      = "macprovider.model_admission.offer.v1"
	modelAdmissionOfferSubmitted    = "offer_submitted"
	modelAdmissionNotOffered        = "not_offered"
	modelAdmissionActorProvider     = "provider"
	modelAdmissionMaxBodyBytes      = 64 * 1024
	modelAdmissionMaxEvents         = 256
	modelAdmissionMaxCandidates     = 64
	modelAdmissionMaxClockSkew      = 5 * time.Minute
)

var (
	errModelAdmissionReplayConflict = errors.New("model admission replay conflict")
	errModelAdmissionCapExceeded    = errors.New("model admission cap exceeded")
	errModelAdmissionRateLimited    = errors.New("model admission rate limited")
	modelAdmissionCandidatePattern  = regexp.MustCompile(`^byom_[a-z2-7]{52}$`)
	modelAdmissionCLIVersionPattern = regexp.MustCompile(`^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$`)
	modelAdmissionServedRefPattern  = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$`)
)

type ModelAdmissionStore interface {
	AppendModelAdmissionOffer(context.Context, ModelAdmissionEvent) (ModelAdmissionEvent, bool, error)
	LatestModelAdmissionStatus(context.Context, string, string) (ModelAdmissionEvent, bool, error)
}

type ModelAdmissionEvent struct {
	CoordinatorEventID       string
	Actor                    string
	ProviderID               string
	CandidateID              string
	ServedModelRef           string
	CatalogModelKey          string
	DiscoveryDigestSHA256    string
	EvaluationDigestSHA256   string
	RequestedDisclosureClass string
	PreviousState            string
	State                    string
	NextState                string
	ReasonCode               string
	RequestID                string
	Nonce                    string
	PayloadDigestSHA256      string
	SignatureDigestSHA256    string
	CreatedAt                time.Time
}

type memoryModelAdmissionStore struct {
	mu            sync.Mutex
	events        []ModelAdmissionEvent
	latest        map[string]ModelAdmissionEvent
	requestIDs    map[string]ModelAdmissionEvent
	nonces        map[string]ModelAdmissionEvent
	candidates    map[string]map[string]struct{}
	providerEvent map[string][]time.Time
}

func NewMemoryModelAdmissionStore() ModelAdmissionStore {
	return &memoryModelAdmissionStore{
		latest:        map[string]ModelAdmissionEvent{},
		requestIDs:    map[string]ModelAdmissionEvent{},
		nonces:        map[string]ModelAdmissionEvent{},
		candidates:    map[string]map[string]struct{}{},
		providerEvent: map[string][]time.Time{},
	}
}

func (s *memoryModelAdmissionStore) AppendModelAdmissionOffer(_ context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := event.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	event.CreatedAt = now.UTC()
	if existing, ok := s.requestIDs[event.ProviderID+"|"+event.RequestID]; ok {
		if existing.PayloadDigestSHA256 == event.PayloadDigestSHA256 {
			return existing, true, nil
		}
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	if existing, ok := s.nonces[event.ProviderID+"|"+event.Nonce]; ok {
		if existing.PayloadDigestSHA256 == event.PayloadDigestSHA256 {
			return existing, true, nil
		}
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	window := pruneModelAdmissionWindow(s.providerEvent[event.ProviderID], now)
	if len(window) >= modelAdmissionMaxEvents {
		return ModelAdmissionEvent{}, false, errModelAdmissionRateLimited
	}
	candidateSet := s.candidates[event.ProviderID]
	if candidateSet == nil {
		candidateSet = map[string]struct{}{}
		s.candidates[event.ProviderID] = candidateSet
	}
	if _, known := candidateSet[event.CandidateID]; !known && len(candidateSet) >= modelAdmissionMaxCandidates {
		return ModelAdmissionEvent{}, false, errModelAdmissionCapExceeded
	}
	previousState := modelAdmissionNotOffered
	if previous, ok := s.latest[event.ProviderID+"|"+event.CandidateID]; ok {
		previousState = previous.State
		if !sameModelAdmissionTuple(previous, event) {
			return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
		}
		if modelAdmissionRequiresRefreshedEvidence(previousState) && !modelAdmissionEvidenceRefreshed(previous, event) {
			return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
		}
	}
	if !modelAdmissionCanSubmitOffer(previousState) {
		return ModelAdmissionEvent{}, false, errModelAdmissionReplayConflict
	}
	event = prepareModelAdmissionTransition(event, previousState)
	candidateSet[event.CandidateID] = struct{}{}
	s.providerEvent[event.ProviderID] = append(window, now)
	s.events = append(s.events, event)
	s.latest[event.ProviderID+"|"+event.CandidateID] = event
	s.requestIDs[event.ProviderID+"|"+event.RequestID] = event
	s.nonces[event.ProviderID+"|"+event.Nonce] = event
	return event, false, nil
}

func (s *memoryModelAdmissionStore) LatestModelAdmissionStatus(_ context.Context, providerID, candidateID string) (ModelAdmissionEvent, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	event, ok := s.latest[providerID+"|"+candidateID]
	return event, ok, nil
}

type SQLiteModelAdmissionStore struct {
	db *sql.DB
}

func NewSQLiteModelAdmissionStore(db *sql.DB) (*SQLiteModelAdmissionStore, error) {
	if db == nil {
		return nil, fmt.Errorf("db is required")
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE TABLE IF NOT EXISTS model_admission_events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider_id TEXT NOT NULL,
    candidate_id TEXT NOT NULL,
    served_model_ref TEXT NOT NULL,
    catalog_model_key TEXT NOT NULL,
    discovery_digest_sha256 TEXT NOT NULL,
    evaluation_digest_sha256 TEXT NOT NULL,
    requested_disclosure_class TEXT NOT NULL,
    previous_state TEXT NOT NULL,
    state TEXT NOT NULL,
    next_state TEXT NOT NULL,
    actor TEXT NOT NULL,
    coordinator_event_id TEXT NOT NULL,
    reason_code TEXT NOT NULL,
    request_id TEXT NOT NULL,
    nonce TEXT NOT NULL,
    payload_digest_sha256 TEXT NOT NULL,
    signature_digest_sha256 TEXT NOT NULL,
    created_at_utc TEXT NOT NULL
)`); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE UNIQUE INDEX IF NOT EXISTS model_admission_events_provider_request_id
ON model_admission_events(provider_id, request_id)`); err != nil {
		return nil, err
	}
	if _, err := db.ExecContext(context.Background(), `
CREATE UNIQUE INDEX IF NOT EXISTS model_admission_events_provider_nonce
ON model_admission_events(provider_id, nonce)`); err != nil {
		return nil, err
	}
	return &SQLiteModelAdmissionStore{db: db}, nil
}

func (s *SQLiteModelAdmissionStore) AppendModelAdmissionOffer(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	now := event.CreatedAt
	if now.IsZero() {
		now = time.Now().UTC()
	}
	event.CreatedAt = now.UTC()
	var stored ModelAdmissionEvent
	var replay bool
	err := sqliteutil.Transact(ctx, s.db, func(txCtx context.Context, conn *sql.Conn) error {
		existing, found, err := scanModelAdmissionEvent(txCtx, conn, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND (request_id = ? OR nonce = ?)
 ORDER BY id DESC
 LIMIT 1`), event.ProviderID, event.RequestID, event.Nonce)
		if err != nil {
			return err
		}
		if found {
			if existing.PayloadDigestSHA256 == event.PayloadDigestSHA256 {
				stored = existing
				replay = true
				return nil
			}
			return errModelAdmissionReplayConflict
		}
		windowStart := now.Add(-time.Hour).UTC().Format(time.RFC3339Nano)
		var eventsInWindow int
		if err := conn.QueryRowContext(txCtx, `
SELECT COUNT(*) FROM model_admission_events WHERE provider_id = ? AND created_at_utc >= ?`,
			event.ProviderID, windowStart).Scan(&eventsInWindow); err != nil {
			return err
		}
		if eventsInWindow >= modelAdmissionMaxEvents {
			return errModelAdmissionRateLimited
		}
		var candidates int
		if err := conn.QueryRowContext(txCtx, `
SELECT COUNT(DISTINCT candidate_id) FROM model_admission_events WHERE provider_id = ? AND candidate_id <> ?`,
			event.ProviderID, event.CandidateID).Scan(&candidates); err != nil {
			return err
		}
		if candidates >= modelAdmissionMaxCandidates {
			return errModelAdmissionCapExceeded
		}
		previousState := modelAdmissionNotOffered
		previous, found, err := scanModelAdmissionEvent(txCtx, conn, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND candidate_id = ?
 ORDER BY id DESC
 LIMIT 1`), event.ProviderID, event.CandidateID)
		if err != nil {
			return err
		}
		if found {
			previousState = previous.State
			if !sameModelAdmissionTuple(previous, event) {
				return errModelAdmissionReplayConflict
			}
			if modelAdmissionRequiresRefreshedEvidence(previousState) && !modelAdmissionEvidenceRefreshed(previous, event) {
				return errModelAdmissionReplayConflict
			}
		}
		if !modelAdmissionCanSubmitOffer(previousState) {
			return errModelAdmissionReplayConflict
		}
		event = prepareModelAdmissionTransition(event, previousState)
		if _, err := conn.ExecContext(txCtx, `
INSERT INTO model_admission_events(
    provider_id, candidate_id, served_model_ref, catalog_model_key,
    discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
    previous_state, state, next_state, actor, coordinator_event_id,
    reason_code, request_id, nonce, payload_digest_sha256,
    signature_digest_sha256, created_at_utc
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			event.ProviderID,
			event.CandidateID,
			event.ServedModelRef,
			event.CatalogModelKey,
			event.DiscoveryDigestSHA256,
			event.EvaluationDigestSHA256,
			event.RequestedDisclosureClass,
			event.PreviousState,
			event.State,
			event.NextState,
			event.Actor,
			event.CoordinatorEventID,
			event.ReasonCode,
			event.RequestID,
			event.Nonce,
			event.PayloadDigestSHA256,
			event.SignatureDigestSHA256,
			event.CreatedAt.Format(time.RFC3339Nano),
		); err != nil {
			return err
		}
		stored = event
		return nil
	})
	return stored, replay, err
}

func (s *SQLiteModelAdmissionStore) LatestModelAdmissionStatus(ctx context.Context, providerID, candidateID string) (ModelAdmissionEvent, bool, error) {
	return scanModelAdmissionEvent(ctx, s.db, modelAdmissionEventSelect(`
  FROM model_admission_events
 WHERE provider_id = ? AND candidate_id = ?
 ORDER BY id DESC
 LIMIT 1`), providerID, candidateID)
}

type modelAdmissionQueryer interface {
	QueryRowContext(context.Context, string, ...any) *sql.Row
}

func scanModelAdmissionEvent(ctx context.Context, q modelAdmissionQueryer, query string, args ...any) (ModelAdmissionEvent, bool, error) {
	var event ModelAdmissionEvent
	var createdAt string
	err := q.QueryRowContext(ctx, query, args...).Scan(
		&event.CoordinatorEventID,
		&event.Actor,
		&event.ProviderID,
		&event.CandidateID,
		&event.ServedModelRef,
		&event.CatalogModelKey,
		&event.DiscoveryDigestSHA256,
		&event.EvaluationDigestSHA256,
		&event.RequestedDisclosureClass,
		&event.PreviousState,
		&event.State,
		&event.NextState,
		&event.ReasonCode,
		&event.RequestID,
		&event.Nonce,
		&event.PayloadDigestSHA256,
		&event.SignatureDigestSHA256,
		&createdAt,
	)
	if err == sql.ErrNoRows {
		return ModelAdmissionEvent{}, false, nil
	}
	if err != nil {
		return ModelAdmissionEvent{}, false, err
	}
	parsed, err := time.Parse(time.RFC3339Nano, createdAt)
	if err != nil {
		return ModelAdmissionEvent{}, false, err
	}
	event.CreatedAt = parsed.UTC()
	return event, true, nil
}

func modelAdmissionEventSelect(tail string) string {
	return `SELECT coordinator_event_id, actor, provider_id, candidate_id, served_model_ref, catalog_model_key,
       discovery_digest_sha256, evaluation_digest_sha256, requested_disclosure_class,
       previous_state, state, next_state, reason_code, request_id, nonce, payload_digest_sha256,
       signature_digest_sha256, created_at_utc` + tail
}

func modelAdmissionCanSubmitOffer(previousState string) bool {
	switch previousState {
	case modelAdmissionNotOffered, "offer_rejected", "withdrawn", "revoked":
		return true
	default:
		return false
	}
}

func sameModelAdmissionTuple(previous, next ModelAdmissionEvent) bool {
	// CandidateID + ServedModelRef are the stable candidate identity. The
	// catalog binding is dynamic (looked up from the signed catalog, which can
	// change between offers), so it is NOT part of the identity tuple — a fresh
	// re-offer (from offer_rejected/withdrawn/revoked, with refreshed evidence)
	// is allowed to carry a newly discovered or dropped catalog_model_key. It
	// stays a provider claim until verified against exact catalog-body evidence.
	return previous.CandidateID == next.CandidateID &&
		previous.ServedModelRef == next.ServedModelRef
}

func modelAdmissionRequiresRefreshedEvidence(previousState string) bool {
	switch previousState {
	case "offer_rejected", "withdrawn", "revoked":
		return true
	default:
		return false
	}
}

func modelAdmissionEvidenceRefreshed(previous, next ModelAdmissionEvent) bool {
	return previous.DiscoveryDigestSHA256 != next.DiscoveryDigestSHA256 ||
		previous.EvaluationDigestSHA256 != next.EvaluationDigestSHA256
}

func prepareModelAdmissionTransition(event ModelAdmissionEvent, previousState string) ModelAdmissionEvent {
	event.Actor = modelAdmissionActorProvider
	event.PreviousState = previousState
	event.NextState = modelAdmissionOfferSubmitted
	sum := sha256.Sum256([]byte(strings.Join([]string{
		event.ProviderID,
		event.CandidateID,
		event.RequestID,
		event.Nonce,
		event.PreviousState,
		event.NextState,
		event.PayloadDigestSHA256,
	}, "\x00")))
	event.CoordinatorEventID = hex.EncodeToString(sum[:])
	return event
}

func (s *Server) handleProviderModelAdmissionOffer(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok := s.authenticateProviderReadOnly(w, r)
	if !ok {
		return
	}
	if !s.allowModelAdmissionAttempt(providerID) {
		writeJSON(w, http.StatusTooManyRequests, modelAdmissionError("rate_limited", "model admission offer rejected"))
		return
	}
	var body modelAdmissionOfferSubmitRequest
	r.Body = http.MaxBytesReader(w, r.Body, modelAdmissionMaxBodyBytes+1)
	if err := decodeStrictJSON(r.Body, &body); err != nil {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_json", "invalid model admission offer package"))
		return
	}
	event, err := s.verifyModelAdmissionOffer(r.Context(), providerID, body)
	if err != nil {
		status := http.StatusBadRequest
		code := "invalid_offer"
		switch {
		case errors.Is(err, errModelAdmissionRateLimited):
			status, code = http.StatusTooManyRequests, "rate_limited"
		case errors.Is(err, errModelAdmissionCapExceeded):
			status, code = http.StatusTooManyRequests, "candidate_cap_exceeded"
		case errors.Is(err, errModelAdmissionReplayConflict):
			status, code = http.StatusConflict, "replay_conflict"
		case errors.Is(err, errModelAdmissionUnauthorized):
			status, code = http.StatusUnauthorized, "unauthorized"
		}
		writeJSON(w, status, modelAdmissionError(code, "model admission offer rejected"))
		return
	}
	stored, replay, err := s.modelAdmissions.AppendModelAdmissionOffer(r.Context(), event)
	if err != nil {
		status := http.StatusInternalServerError
		code := "model_admission_store_error"
		switch {
		case errors.Is(err, errModelAdmissionRateLimited):
			status, code = http.StatusTooManyRequests, "rate_limited"
		case errors.Is(err, errModelAdmissionCapExceeded):
			status, code = http.StatusTooManyRequests, "candidate_cap_exceeded"
		case errors.Is(err, errModelAdmissionReplayConflict):
			status, code = http.StatusConflict, "replay_conflict"
		}
		writeJSON(w, status, modelAdmissionError(code, "model admission offer rejected"))
		return
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionStatusResponseFromEvent(stored, replay))
}

func (s *Server) handleProviderModelAdmissionStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		w.Header().Set("Allow", http.MethodGet)
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	providerID, ok := s.authenticateProviderReadOnly(w, r)
	if !ok {
		return
	}
	candidateID := strings.TrimSpace(r.URL.Query().Get("candidate_id"))
	if !validModelAdmissionCandidateID(candidateID) {
		writeJSON(w, http.StatusBadRequest, modelAdmissionError("invalid_candidate_id", "invalid model admission candidate_id"))
		return
	}
	event, found, err := s.modelAdmissions.LatestModelAdmissionStatus(r.Context(), providerID, candidateID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, modelAdmissionError("model_admission_store_error", "model admission status lookup failed"))
		return
	}
	if !found {
		event = ModelAdmissionEvent{
			ProviderID:  providerID,
			CandidateID: candidateID,
			State:       modelAdmissionNotOffered,
			NextState:   modelAdmissionNotOffered,
			ReasonCode:  "not_offered",
			CreatedAt:   s.now().UTC(),
		}
	}
	writeJSON(w, http.StatusOK, s.modelAdmissionStatusResponseFromEvent(event, false))
}

var errModelAdmissionUnauthorized = errors.New("model admission unauthorized")

func (s *Server) authenticateProviderReadOnly(w http.ResponseWriter, r *http.Request) (string, bool) {
	if !s.cfg.Auth.RequireProviderTokens {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("provider_tokens_not_enabled", "provider tokens not enabled"))
		return "", false
	}
	if s.tokens == nil {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("provider_tokens_unavailable", "provider tokens unavailable"))
		return "", false
	}
	raw := bearerToken(r.Header.Get("Authorization"))
	if raw == "" {
		writeJSON(w, http.StatusUnauthorized, modelAdmissionError("unauthorized", "provider bearer token required"))
		return "", false
	}
	readOnlyTokens, ok := s.tokens.(computeIntegrityReadOnlyTokenValidator)
	if !ok {
		writeJSON(w, http.StatusServiceUnavailable, modelAdmissionError("provider_tokens_read_only_unavailable", "provider token read-only validation unavailable"))
		return "", false
	}
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	providerID, valid, err := readOnlyTokens.ValidateTokenReadOnly(ctx, raw)
	if err != nil || !valid {
		writeJSON(w, http.StatusUnauthorized, modelAdmissionError("unauthorized", "provider bearer token required"))
		return "", false
	}
	return providerID, true
}

func (s *Server) verifyModelAdmissionOffer(ctx context.Context, authenticatedProviderID string, body modelAdmissionOfferSubmitRequest) (ModelAdmissionEvent, error) {
	if s.providerModelAdmissionSanctioned(authenticatedProviderID) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	if body.Schema != modelAdmissionOfferSubmitSchema {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid schema")
	}
	if body.SignatureDomain != modelAdmissionSignedDomain || body.ProviderID != authenticatedProviderID {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	if err := validateModelAdmissionPayload(body); err != nil {
		return ModelAdmissionEvent{}, err
	}
	if body.SignatureAlgorithm != "ed25519" {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid signature algorithm")
	}
	signature, err := base64.StdEncoding.DecodeString(body.ProviderSignature)
	if err != nil || len(signature) != ed25519.SignatureSize {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid signature")
	}
	activePubkey, found, blocked := s.durableIdentitySignaturePubkey(ctx, authenticatedProviderID)
	if blocked || !found {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	pubkeyDigest := sha256.Sum256(activePubkey)
	if body.SigningKeyDigest != hex.EncodeToString(pubkeyDigest[:]) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	canonical, err := jcs.CanonicalJSON(body.canonicalMap())
	if err != nil {
		return ModelAdmissionEvent{}, err
	}
	if !ed25519.Verify(ed25519.PublicKey(activePubkey), canonical, signature) {
		return ModelAdmissionEvent{}, errModelAdmissionUnauthorized
	}
	payloadDigest := sha256.Sum256(canonical)
	signatureDigest := sha256.Sum256(signature)
	signedAt, err := time.Parse(time.RFC3339Nano, body.Timestamp)
	if err != nil {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid timestamp")
	}
	now := s.now().UTC()
	if signedAt.Before(now.Add(-modelAdmissionMaxClockSkew)) || signedAt.After(now.Add(modelAdmissionMaxClockSkew)) {
		return ModelAdmissionEvent{}, fmt.Errorf("invalid timestamp")
	}
	return ModelAdmissionEvent{
		ProviderID:               body.ProviderID,
		CandidateID:              body.CandidateID,
		ServedModelRef:           body.ServedModelRef,
		CatalogModelKey:          body.CatalogModelKey,
		DiscoveryDigestSHA256:    body.DiscoveryDigestSHA256,
		EvaluationDigestSHA256:   body.EvaluationDigestSHA256,
		RequestedDisclosureClass: body.RequestedDisclosureClass,
		State:                    modelAdmissionOfferSubmitted,
		ReasonCode:               "provider_offer_submitted",
		RequestID:                body.IdempotencyKey,
		Nonce:                    body.Nonce,
		PayloadDigestSHA256:      hex.EncodeToString(payloadDigest[:]),
		SignatureDigestSHA256:    hex.EncodeToString(signatureDigest[:]),
		CreatedAt:                now,
	}, nil
}

func (s *Server) providerModelAdmissionSanctioned(providerID string) bool {
	if s.admission != nil && s.admission.Rejected(providerID) {
		return true
	}
	if s.pool == nil {
		return false
	}
	for _, sanction := range s.pool.CanarySanctions() {
		if sanction.ProviderID == providerID && sanction.FailCount > 0 {
			return true
		}
	}
	return false
}

func (s *Server) allowModelAdmissionAttempt(providerID string) bool {
	now := s.now().UTC()
	s.modelAdmissionAttemptMu.Lock()
	defer s.modelAdmissionAttemptMu.Unlock()
	if s.modelAdmissionAttempts == nil {
		s.modelAdmissionAttempts = map[string][]time.Time{}
	}
	window := pruneModelAdmissionWindow(s.modelAdmissionAttempts[providerID], now)
	if len(window) >= modelAdmissionMaxEvents {
		s.modelAdmissionAttempts[providerID] = window
		return false
	}
	s.modelAdmissionAttempts[providerID] = append(window, now)
	return true
}

type modelAdmissionOfferSubmitRequest struct {
	Schema                   string                              `json:"schema"`
	SignatureDomain          string                              `json:"signature_domain"`
	ProviderID               string                              `json:"provider_id"`
	CandidateID              string                              `json:"candidate_id"`
	RuntimeSource            string                              `json:"runtime_source"`
	ServedModelRef           string                              `json:"served_model_ref"`
	CatalogModelKey          string                              `json:"catalog_model_key"`
	DiscoveryDigestSHA256    string                              `json:"discovery_digest_sha256"`
	EvaluationDigestSHA256   string                              `json:"evaluation_digest_sha256"`
	ArtifactHashes           map[string]string                   `json:"artifact_hashes"`
	AdvisoryCapabilities     *modelAdmissionAdvisoryCapabilities `json:"advisory_capabilities"`
	FitEvidenceSource        string                              `json:"fit_evidence_source"`
	LocalReadiness           string                              `json:"local_readiness"`
	RequestedDisclosureClass string                              `json:"requested_disclosure_class"`
	Timestamp                string                              `json:"timestamp"`
	Nonce                    string                              `json:"nonce"`
	IdempotencyKey           string                              `json:"idempotency_key"`
	SigningKeyDigest         string                              `json:"signing_key_digest"`
	SignatureAlgorithm       string                              `json:"signature_algorithm"`
	ProviderSignature        string                              `json:"provider_signature"`
	CLIVersion               string                              `json:"cli_version"`
}

func (p modelAdmissionOfferSubmitRequest) canonicalMap() map[string]any {
	return map[string]any{
		"signature_domain":           p.SignatureDomain,
		"provider_id":                p.ProviderID,
		"candidate_id":               p.CandidateID,
		"runtime_source":             p.RuntimeSource,
		"served_model_ref":           p.ServedModelRef,
		"catalog_model_key":          p.CatalogModelKey,
		"discovery_digest_sha256":    p.DiscoveryDigestSHA256,
		"evaluation_digest_sha256":   p.EvaluationDigestSHA256,
		"artifact_hashes":            modelAdmissionArtifactHashesCanonicalMap(p.ArtifactHashes),
		"advisory_capabilities":      p.AdvisoryCapabilities.canonicalMap(),
		"fit_evidence_source":        p.FitEvidenceSource,
		"local_readiness":            p.LocalReadiness,
		"requested_disclosure_class": p.RequestedDisclosureClass,
		"timestamp":                  p.Timestamp,
		"nonce":                      p.Nonce,
		"idempotency_key":            p.IdempotencyKey,
		"signing_key_digest":         p.SigningKeyDigest,
		"cli_version":                p.CLIVersion,
	}
}

type modelAdmissionAdvisoryCapabilities struct {
	ChatCompletions             *bool   `json:"chat_completions"`
	Streaming                   *bool   `json:"streaming"`
	ToolCallPassthrough         *bool   `json:"tool_call_passthrough"`
	StructuredOutputPassthrough *bool   `json:"structured_output_passthrough"`
	JSONMode                    *bool   `json:"json_mode"`
	UsageReporting              *bool   `json:"usage_reporting"`
	MaxContextTokens            *int    `json:"max_context_tokens"`
	Quantization                *string `json:"quantization"`
	Family                      *string `json:"family"`
	RuntimeVersion              *string `json:"runtime_version"`
}

func (c *modelAdmissionAdvisoryCapabilities) canonicalMap() map[string]any {
	if c == nil {
		return map[string]any{}
	}
	return map[string]any{
		"chat_completions":              modelAdmissionBoolOrNull(c.ChatCompletions),
		"streaming":                     modelAdmissionBoolOrNull(c.Streaming),
		"tool_call_passthrough":         modelAdmissionBoolOrNull(c.ToolCallPassthrough),
		"structured_output_passthrough": modelAdmissionBoolOrNull(c.StructuredOutputPassthrough),
		"json_mode":                     modelAdmissionBoolOrNull(c.JSONMode),
		"usage_reporting":               modelAdmissionBoolOrNull(c.UsageReporting),
		"max_context_tokens":            modelAdmissionIntOrNull(c.MaxContextTokens),
		"quantization":                  modelAdmissionStringOrNull(c.Quantization),
		"family":                        modelAdmissionStringOrNull(c.Family),
		"runtime_version":               modelAdmissionStringOrNull(c.RuntimeVersion),
	}
}

func modelAdmissionBoolOrNull(value *bool) any {
	if value == nil {
		return nil
	}
	return *value
}

func modelAdmissionIntOrNull(value *int) any {
	if value == nil {
		return nil
	}
	return *value
}

func modelAdmissionStringOrNull(value *string) any {
	if value == nil {
		return nil
	}
	return *value
}

func (c *modelAdmissionAdvisoryCapabilities) validate() error {
	if c == nil {
		return fmt.Errorf("invalid model admission evidence")
	}
	if c.MaxContextTokens != nil && *c.MaxContextTokens < 0 {
		return fmt.Errorf("invalid model admission evidence")
	}
	for _, value := range []*string{c.Quantization, c.Family, c.RuntimeVersion} {
		if value != nil && (len(*value) > 128 || unsafeModelAdmissionMaterial(*value)) {
			return fmt.Errorf("invalid model admission evidence")
		}
	}
	return nil
}

func modelAdmissionArtifactHashesCanonicalMap(hashes map[string]string) map[string]any {
	canonical := make(map[string]any, len(hashes))
	for key, value := range hashes {
		canonical[key] = value
	}
	return canonical
}

func validateModelAdmissionPayload(payload modelAdmissionOfferSubmitRequest) error {
	if err := config.ValidateProviderID(payload.ProviderID); err != nil {
		return err
	}
	if !validModelAdmissionCandidateID(payload.CandidateID) {
		return fmt.Errorf("invalid candidate_id")
	}
	values := []string{
		payload.CatalogModelKey,
		payload.FitEvidenceSource,
		payload.LocalReadiness,
		payload.RequestedDisclosureClass,
		payload.Nonce,
		payload.IdempotencyKey,
		payload.SigningKeyDigest,
	}
	for _, value := range values {
		if unsafeModelAdmissionMaterial(value) {
			return fmt.Errorf("unsafe model admission material")
		}
	}
	if !validModelAdmissionServedModelRef(payload.ServedModelRef) {
		return fmt.Errorf("invalid served_model_ref")
	}
	if !validModelAdmissionRuntimeSource(payload.RuntimeSource) {
		return fmt.Errorf("invalid runtime_source")
	}
	if payload.CatalogModelKey != "" && len(payload.CatalogModelKey) > 128 {
		return fmt.Errorf("invalid catalog_model_key")
	}
	if payload.ArtifactHashes == nil || payload.AdvisoryCapabilities == nil {
		return fmt.Errorf("invalid model admission evidence")
	}
	if len(payload.ArtifactHashes) > 16 {
		return fmt.Errorf("invalid model admission evidence")
	}
	for key, value := range payload.ArtifactHashes {
		if !validModelAdmissionToken(key) || !validModelAdmissionSHA256Hex(value) {
			return fmt.Errorf("invalid model admission evidence")
		}
	}
	if err := payload.AdvisoryCapabilities.validate(); err != nil {
		return err
	}
	if payload.FitEvidenceSource == "" || len(payload.FitEvidenceSource) > 64 ||
		payload.LocalReadiness == "" || len(payload.LocalReadiness) > 64 {
		return fmt.Errorf("invalid model admission evidence")
	}
	if payload.RequestedDisclosureClass != "non_earning_provider_asserted" &&
		payload.RequestedDisclosureClass != "catalog_binding_requested" {
		return fmt.Errorf("invalid requested_disclosure_class")
	}
	if !validModelAdmissionSHA256Hex(payload.DiscoveryDigestSHA256) {
		return fmt.Errorf("invalid discovery digest")
	}
	if payload.EvaluationDigestSHA256 != "" && !validModelAdmissionSHA256Hex(payload.EvaluationDigestSHA256) {
		return fmt.Errorf("invalid evaluation digest")
	}
	if !validModelAdmissionToken(payload.Nonce) || !validModelAdmissionToken(payload.IdempotencyKey) {
		return fmt.Errorf("invalid replay key")
	}
	if !validModelAdmissionSHA256Hex(payload.SigningKeyDigest) {
		return fmt.Errorf("invalid signing key digest")
	}
	if !validModelAdmissionCLIVersion(payload.CLIVersion) {
		return fmt.Errorf("invalid cli_version")
	}
	if _, err := time.Parse(time.RFC3339Nano, payload.Timestamp); err != nil {
		return fmt.Errorf("invalid timestamp")
	}
	return nil
}

func (s *Server) modelAdmissionStatusResponseFromEvent(event ModelAdmissionEvent, _ bool) map[string]any {
	return map[string]any{
		"schema":                 modelAdmissionStatusSchema,
		"generated_at":           s.now().UTC().Format(time.RFC3339Nano),
		"cli_version":            s.version,
		"provider_id":            event.ProviderID,
		"candidate_id":           event.CandidateID,
		"served_model_ref":       event.ServedModelRef,
		"catalog_model_key":      nullString(event.CatalogModelKey),
		"admission_state":        event.State,
		"admission_state_source": "coordinator",
		"coordinator_event_id":   nullString(event.CoordinatorEventID),
		"state_observed_at":      event.CreatedAt.UTC().Format(time.RFC3339Nano),
		"provider_guidance":      modelAdmissionProviderGuidance(event),
		"allowed_next_states":    modelAdmissionAllowedNextStates(event.State),
		"warnings":               []string{},
	}
}

func modelAdmissionProviderGuidance(event ModelAdmissionEvent) map[string]any {
	nextAction := "wait_for_coordinator"
	stateMeaning := "byom.admission.not_earning"
	earningPath := "no_earning_path_in_v0_1"
	transitionReason := any(nil)
	switch event.State {
	case modelAdmissionNotOffered:
		nextAction = "submit_offer"
		stateMeaning = "byom.admission.not_offered"
		earningPath = "local_inventory_only"
	case modelAdmissionOfferSubmitted:
		nextAction = "wait_for_coordinator"
		earningPath = modelAdmissionNonSettlementEarningPath(event.CatalogModelKey)
	case "offer_rejected":
		nextAction = "revise_and_reoffer"
		transitionReason = event.ReasonCode
	case "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced":
		nextAction = "withdraw"
		earningPath = modelAdmissionNonSettlementEarningPath(event.CatalogModelKey)
		if modelAdmissionDemotionRequiresReason(event) {
			transitionReason = event.ReasonCode
		}
	case "settlement_capable":
		nextAction = "maintain_runtime"
		earningPath = "settlement_capable"
	case "withdrawn", "revoked":
		nextAction = "submit_offer"
		transitionReason = event.ReasonCode
	}
	return map[string]any{
		"state_label_key":        "byom.admission." + event.State,
		"state_meaning_key":      stateMeaning,
		"next_action":            nextAction,
		"transition_reason_code": transitionReason,
		"earning_path_class":     earningPath,
	}
}

// modelAdmissionNonSettlementEarningPath returns the honest v0.1 earning-path
// disclosure for a non-settlement admitted state: a catalog-matched candidate
// still has a catalog/receipt path, but a genuinely non-catalog candidate has
// NO earning path in v0.1 (SPEC-047-R004) and must not be shown otherwise.
func modelAdmissionNonSettlementEarningPath(catalogModelKey string) string {
	if catalogModelKey != "" {
		return "not_earning_yet_catalog_or_receipt_path_exists"
	}
	return "no_earning_path_in_v0_1"
}

func modelAdmissionAllowedNextStates(state string) []string {
	switch state {
	case modelAdmissionNotOffered, "withdrawn", "revoked":
		return []string{modelAdmissionOfferSubmitted}
	case "offer_rejected":
		return []string{modelAdmissionOfferSubmitted, "revoked"}
	case modelAdmissionOfferSubmitted:
		return []string{"offer_rejected", "sandbox_probe_only", "network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	case "sandbox_probe_only":
		return []string{"network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	case "network_visible_unpriced":
		return []string{"network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	case "network_admitted_unsettled":
		return []string{"catalog_priced", "settlement_capable", "withdrawn", "revoked"}
	case "catalog_priced":
		return []string{"network_admitted_unsettled", "settlement_capable", "withdrawn", "revoked"}
	case "settlement_capable":
		return []string{"network_admitted_unsettled", "catalog_priced", "withdrawn", "revoked"}
	default:
		return []string{}
	}
}

func modelAdmissionError(code, message string) map[string]any {
	return map[string]any{"error": map[string]any{"code": code, "message": message}}
}

func pruneModelAdmissionWindow(window []time.Time, now time.Time) []time.Time {
	cutoff := now.Add(-time.Hour)
	kept := window[:0]
	for _, ts := range window {
		if ts.After(cutoff) {
			kept = append(kept, ts)
		}
	}
	return kept
}

func validModelAdmissionCandidateID(value string) bool {
	return modelAdmissionCandidatePattern.MatchString(value)
}

func validModelAdmissionToken(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, r := range value {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') ||
			r == '-' || r == '_' {
			continue
		}
		return false
	}
	return true
}

func validModelAdmissionRuntimeSource(value string) bool {
	switch value {
	case "mlx_cache", "ollama_loopback":
		return true
	default:
		return false
	}
}

func validModelAdmissionCLIVersion(value string) bool {
	return modelAdmissionCLIVersionPattern.MatchString(value)
}

func validModelAdmissionServedModelRef(value string) bool {
	if value == "" || !modelAdmissionServedRefPattern.MatchString(value) {
		return false
	}
	if unsafeModelAdmissionTextMaterial(value) {
		return false
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "://") || strings.Contains(lower, "@") {
		return false
	}
	if strings.HasPrefix(lower, "ollama:") {
		return modelAdmissionRefSegmentsSafe(value[len("ollama:"):])
	}
	return modelAdmissionRefSegmentsSafe(value)
}

// modelAdmissionRefSegmentsSafe rejects a served-model reference whose ANY
// path segment looks like a network location (SPEC-047-R007 privacy). Every
// "/"-delimited segment is checked, not just the first, so endpoint material
// cannot hide after the leading segment (e.g. "model/inference:8080").
func modelAdmissionRefSegmentsSafe(name string) bool {
	if name == "" ||
		strings.HasPrefix(name, "/") ||
		strings.Contains(name, "//") ||
		strings.Contains(name, "../") ||
		strings.Contains(name, `..\`) {
		return false
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == "" || looksLikeModelAdmissionNetworkLocation(seg) {
			return false
		}
	}
	return true
}

func modelAdmissionDemotionRequiresReason(event ModelAdmissionEvent) bool {
	switch event.PreviousState {
	case "settlement_capable":
		return event.State == "catalog_priced" || event.State == "network_admitted_unsettled"
	case "catalog_priced":
		return event.State == "network_admitted_unsettled"
	default:
		return false
	}
}

func validModelAdmissionSHA256Hex(value string) bool {
	if len(value) != 64 {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil && strings.ToLower(value) == value
}

func unsafeModelAdmissionMaterial(value string) bool {
	if unsafeModelAdmissionTextMaterial(value) {
		return true
	}
	if looksLikeModelAdmissionNetworkLocation(value) {
		return true
	}
	return false
}

func unsafeModelAdmissionTextMaterial(value string) bool {
	if value == "" {
		return false
	}
	lower := strings.ToLower(value)
	if strings.Contains(lower, "api_key") || strings.Contains(lower, "secret") ||
		strings.Contains(lower, "token=") || strings.Contains(lower, "authorization") {
		return true
	}
	if strings.ContainsAny(value, "\x00\r\n\t") {
		return true
	}
	if strings.ContainsAny(value, "<>\"'`;") {
		return true
	}
	if strings.HasPrefix(value, "/") || strings.HasPrefix(value, "~") ||
		strings.Contains(value, "../") || strings.Contains(value, `..\`) ||
		strings.Contains(value, `\`) {
		return true
	}
	if parsed, err := url.Parse(value); err == nil && parsed.Scheme != "" {
		switch strings.ToLower(parsed.Scheme) {
		case "http", "https", "ws", "wss", "file", "ssh", "sftp", "ftp":
			return true
		}
	}
	if strings.Contains(value, "://") {
		return true
	}
	return false
}

func looksLikeModelAdmissionNetworkLocation(value string) bool {
	trimmed := strings.Trim(strings.TrimSpace(value), "[]")
	lower := strings.ToLower(trimmed)
	if strings.HasSuffix(trimmed, ".") && strings.Contains(trimmed, ".") {
		return true
	}
	if strings.Contains(lower, "localhost") {
		return true
	}
	if host, port, err := net.SplitHostPort(value); err == nil {
		// A host:port shape is itself an endpoint signal when the port is
		// numeric, regardless of whether the host looks like a network location
		// (e.g. "inference:8080" must be rejected, not accepted).
		if _, perr := strconv.ParseUint(port, 10, 16); perr == nil {
			return true
		}
		return looksLikeModelAdmissionNetworkLocation(host)
	}
	if strings.HasPrefix(value, "[") && strings.Contains(value, "]:") {
		if host, _, err := net.SplitHostPort(value); err == nil {
			return looksLikeModelAdmissionNetworkLocation(host)
		}
	}
	if ip := net.ParseIP(trimmed); ip != nil {
		return true
	}
	if strings.HasPrefix(lower, "0x") {
		if n, err := strconv.ParseUint(strings.TrimPrefix(lower, "0x"), 16, 32); err == nil && n > 0 {
			return true
		}
	}
	if n, err := strconv.ParseUint(lower, 10, 32); err == nil && (n <= 65535 || n >= 0x01000000) {
		return true
	}
	if strings.Count(trimmed, ".") >= 1 {
		labels := strings.Split(trimmed, ".")
		allNumeric := true
		for _, label := range labels {
			if label == "" {
				return false
			}
			if _, err := strconv.ParseUint(label, 0, 8); err != nil {
				allNumeric = false
			}
		}
		// A DNS hostname ends in a pure-alpha TLD (com, co, tech, local...).
		// A model version token ends in an alphanumeric label (e.g.
		// "Llama-3.2-3B-Instruct-4bit"), which must NOT be treated as a host.
		if allNumeric || isPureAlphaTLD(labels[len(labels)-1]) {
			return true
		}
	}
	return false
}

func isPureAlphaTLD(label string) bool {
	if len(label) < 2 {
		return false
	}
	for _, r := range label {
		if (r < 'a' || r > 'z') && (r < 'A' || r > 'Z') {
			return false
		}
	}
	return true
}

func nullString(value string) any {
	if value == "" {
		return nil
	}
	return value
}
