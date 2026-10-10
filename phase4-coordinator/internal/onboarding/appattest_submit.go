package onboarding

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/appattest"
	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// SPEC-033 §5.7.1: a provider proves App Attest with a single-use challenge
// bound to the provider id of its bearer credential.
const (
	AppAttestClientDataPurpose     = "malibu.app_attest.hardware_trust.v1"
	appAttestChallengeTTL          = 5 * time.Minute
	appAttestChallengeBytes        = 32
	defaultAppAttestMaxOutstanding = 4096
	appAttestSubmitMaxBody         = 32 * 1024
	appAttestChallengeMaxBody      = 1024
	appAttestStoreTimeout          = 2 * time.Second
)

// AppAttestRecordOutcome is the result of recording a verified attestation.
type AppAttestRecordOutcome int

const (
	// AppAttestRecorded means a new row was written for the provider.
	AppAttestRecorded AppAttestRecordOutcome = iota + 1
	// AppAttestAlreadyRecorded means the provider already had a row; its
	// first key is kept.
	AppAttestAlreadyRecorded
	// AppAttestKeyReused means the key is recorded for another provider.
	AppAttestKeyReused
)

// AppAttestRecorder is the app_attest_recorder surface (SPEC-033 §5.7).
type AppAttestRecorder interface {
	AppAttestRecorderConfigured() bool
	AppAttestVerificationRecorded(ctx context.Context, providerID string) (bool, error)
	RecordAppAttestVerification(ctx context.Context, providerID string, keyID []byte) (AppAttestRecordOutcome, error)
}

type appAttestChallenge struct {
	value     [appAttestChallengeBytes]byte
	expiresAt time.Time
}

// AppAttestChallengeStore holds outstanding challenges in coordinator memory:
// at most one per provider, each usable once and for appAttestChallengeTTL.
// A restart drops them; the provider fetches a new one.
type AppAttestChallengeStore struct {
	mu             sync.Mutex
	byProvider     map[string]appAttestChallenge
	maxOutstanding int
}

// NewAppAttestChallengeStore returns an empty store bounded to maxOutstanding
// challenges (default 4096 when <= 0).
func NewAppAttestChallengeStore(maxOutstanding int) *AppAttestChallengeStore {
	if maxOutstanding <= 0 {
		maxOutstanding = defaultAppAttestMaxOutstanding
	}
	return &AppAttestChallengeStore{byProvider: map[string]appAttestChallenge{}, maxOutstanding: maxOutstanding}
}

var errAppAttestChallengeStoreFull = errors.New("app attest challenge store full")

// Issue replaces any outstanding challenge of providerID with a fresh one.
func (s *AppAttestChallengeStore) Issue(providerID string, now time.Time) ([appAttestChallengeBytes]byte, time.Time, error) {
	var value [appAttestChallengeBytes]byte
	if _, err := rand.Read(value[:]); err != nil {
		return value, time.Time{}, err
	}
	expiresAt := now.Add(appAttestChallengeTTL)
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, replacing := s.byProvider[providerID]; !replacing && len(s.byProvider) >= s.maxOutstanding {
		for id, c := range s.byProvider {
			if !now.Before(c.expiresAt) {
				delete(s.byProvider, id)
			}
		}
		if len(s.byProvider) >= s.maxOutstanding {
			return value, time.Time{}, errAppAttestChallengeStoreFull
		}
	}
	s.byProvider[providerID] = appAttestChallenge{value: value, expiresAt: expiresAt}
	return value, expiresAt, nil
}

// Consume removes providerID's outstanding challenge, whatever the outcome,
// and reports whether it equals value and has not expired.
func (s *AppAttestChallengeStore) Consume(providerID string, value []byte, now time.Time) bool {
	s.mu.Lock()
	c, ok := s.byProvider[providerID]
	delete(s.byProvider, providerID)
	s.mu.Unlock()
	if !ok || len(value) != appAttestChallengeBytes || !now.Before(c.expiresAt) {
		return false
	}
	return subtle.ConstantTimeCompare(c.value[:], value) == 1
}

// AppAttestClientData is the exact client data a provider's App Attest key
// signs over: JCS of the challenge, the provider id and the coordinator's
// own pins. The coordinator recomputes it at submit; it never trusts a copy.
func AppAttestClientData(providerID, challengeB64 string, cfg AppAttestConfig) ([]byte, error) {
	return billing.CanonicalJSON(map[string]any{
		"bundle_id":          strings.TrimSpace(cfg.BundleID),
		"challenge":          challengeB64,
		"coordinator_domain": strings.ToLower(strings.TrimSuffix(strings.TrimSpace(cfg.CoordinatorDomain), "/")),
		"provider_id":        providerID,
		"purpose":            AppAttestClientDataPurpose,
		"team_id":            strings.TrimSpace(cfg.TeamID),
	})
}

type appAttestChallengeResponse struct {
	Status     string `json:"status"`
	ProviderID string `json:"provider_id"`
	Challenge  string `json:"challenge,omitempty"`
	ClientData string `json:"client_data,omitempty"`
	ExpiresAt  string `json:"expires_at,omitempty"`
}

type appAttestSubmitRequest struct {
	Challenge   string `json:"challenge"`
	KeyID       string `json:"key_id"`
	Attestation string `json:"attestation"`
}

// appAttestDeps resolves the token-bound provider id and the recorder, or
// writes the error response and returns ok=false.
func (h *Handler) appAttestDeps(w http.ResponseWriter, r *http.Request) (string, AppAttestRecorder, bool) {
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", http.MethodPost)
		writeJSONError(w, http.StatusMethodNotAllowed, "method_not_allowed", "method not allowed")
		return "", nil, false
	}
	if h.StatsDB == nil || h.AuthTokenStore == nil {
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "onboarding dependencies unavailable")
		return "", nil, false
	}
	providerID, ok, err := h.AuthTokenStore.ValidateToken(r.Context(), bearerToken(r.Header))
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "unavailable", "token validation unavailable")
		return "", nil, false
	}
	if !ok || strings.TrimSpace(providerID) == "" {
		writeJSONError(w, http.StatusUnauthorized, "unauthorized", "provider bearer token required")
		return "", nil, false
	}
	recorder, isRecorder := h.StatsDB.(AppAttestRecorder)
	if !isRecorder || !recorder.AppAttestRecorderConfigured() || h.AppAttestChallenges == nil || h.AppAttestVerifier == nil ||
		strings.TrimSpace(h.AppAttestConfig.TeamID) == "" || strings.TrimSpace(h.AppAttestConfig.BundleID) == "" ||
		strings.TrimSpace(h.AppAttestConfig.CoordinatorDomain) == "" {
		writeJSONError(w, http.StatusServiceUnavailable, "app_attest_unavailable", "app attest recording is not configured")
		return "", nil, false
	}
	if h.AppAttestIPRateLimiter != nil && !h.AppAttestIPRateLimiter.Allow(clientIP(r, h.TrustedProxies)) {
		w.Header().Set("Retry-After", "60")
		writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "app attest ip rate limit exceeded")
		return "", nil, false
	}
	return providerID, recorder, true
}

// HandleAppAttestChallenge issues a single-use challenge for the provider id
// bound to the bearer credential (SPEC-033 §5.7.1 step 1). Any body is ignored.
func (h *Handler) HandleAppAttestChallenge(w http.ResponseWriter, r *http.Request) {
	providerID, recorder, ok := h.appAttestDeps(w, r)
	if !ok {
		return
	}
	_, _ = io.Copy(io.Discard, http.MaxBytesReader(w, r.Body, appAttestChallengeMaxBody))
	if h.AppAttestProviderRateLimiter != nil && !h.AppAttestProviderRateLimiter.Allow(providerID) {
		w.Header().Set("Retry-After", "60")
		writeJSONError(w, http.StatusTooManyRequests, "rate_limited", "app attest provider rate limit exceeded")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), appAttestStoreTimeout)
	recorded, err := recorder.AppAttestVerificationRecorded(ctx, providerID)
	cancel()
	if err != nil {
		writeJSONError(w, http.StatusServiceUnavailable, "app_attest_unavailable", "app attest record lookup failed")
		return
	}
	if recorded {
		writeJSON(w, http.StatusOK, appAttestChallengeResponse{Status: "already_recorded", ProviderID: providerID})
		return
	}
	value, expiresAt, err := h.AppAttestChallenges.Issue(providerID, h.appAttestNow())
	if err != nil {
		w.Header().Set("Retry-After", "60")
		writeJSONError(w, http.StatusServiceUnavailable, "app_attest_unavailable", "app attest challenge unavailable")
		return
	}
	challenge := base64.StdEncoding.EncodeToString(value[:])
	clientData, err := AppAttestClientData(providerID, challenge, h.AppAttestConfig)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "internal_error", "app attest client data failed")
		return
	}
	writeJSON(w, http.StatusOK, appAttestChallengeResponse{
		Status:     "challenge",
		ProviderID: providerID,
		Challenge:  challenge,
		ClientData: string(clientData),
		ExpiresAt:  expiresAt.UTC().Format(time.RFC3339),
	})
}

// HandleAppAttestSubmit verifies an attestation over the coordinator's own
// recomputation of the client data and records it for the token-bound
// provider id (SPEC-033 §5.7.1 steps 3-4, SPEC-033-R004).
func (h *Handler) HandleAppAttestSubmit(w http.ResponseWriter, r *http.Request) {
	providerID, recorder, ok := h.appAttestDeps(w, r)
	if !ok {
		return
	}
	// Any authenticated submit spends the provider's outstanding challenge,
	// whatever the outcome (SPEC-033 §5.7.1 step 3).
	now := h.appAttestNow()
	body, err := readBoundedBody(w, r, appAttestSubmitMaxBody)
	if err != nil {
		h.AppAttestChallenges.Consume(providerID, nil, now)
		writeJSONError(w, http.StatusRequestEntityTooLarge, "request_too_large", "body exceeds 32 KiB")
		return
	}
	var req appAttestSubmitRequest
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil || dec.Decode(&struct{}{}) != io.EOF {
		h.AppAttestChallenges.Consume(providerID, nil, now)
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "body must be exactly one {challenge, key_id, attestation} object")
		return
	}
	challenge, errC := base64.StdEncoding.DecodeString(req.Challenge)
	keyID, errK := base64.StdEncoding.DecodeString(req.KeyID)
	attestation, errA := base64.StdEncoding.DecodeString(req.Attestation)
	if errC != nil || errK != nil || errA != nil || len(challenge) != appAttestChallengeBytes ||
		len(keyID) != appattest.KeyIDBytes || len(attestation) == 0 || len(attestation) > appattest.MaxAttestationBytes {
		h.AppAttestChallenges.Consume(providerID, nil, now)
		writeJSONError(w, http.StatusBadRequest, "invalid_request", "challenge, key_id and attestation must be standard base64 of the required sizes")
		return
	}
	if !h.AppAttestChallenges.Consume(providerID, challenge, now) {
		writeJSONError(w, http.StatusConflict, "challenge_invalid", "challenge is unknown, used, expired, or issued to another provider")
		return
	}
	clientData, err := AppAttestClientData(providerID, base64.StdEncoding.EncodeToString(challenge), h.AppAttestConfig)
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, "internal_error", "app attest client data failed")
		return
	}
	verifyCtx, cancelVerify := context.WithTimeout(r.Context(), appAttestStoreTimeout)
	attested, err := h.AppAttestVerifier.Verify(verifyCtx, AppAttestEvidence{
		Object:         attestation,
		KeyID:          keyID,
		ClientDataHash: sha256.Sum256(clientData),
	})
	cancelVerify()
	switch {
	case err == nil && attested:
	case err == nil, errors.Is(err, ErrAppAttestBinding):
		writeJSONError(w, http.StatusUnprocessableEntity, "app_attest_rejected", "attestation did not verify under the production policy")
		return
	default:
		writeJSONError(w, http.StatusServiceUnavailable, "app_attest_unavailable", "app attest verification unavailable")
		return
	}
	recordCtx, cancelRecord := context.WithTimeout(context.Background(), appAttestStoreTimeout)
	outcome, err := recorder.RecordAppAttestVerification(recordCtx, providerID, keyID)
	cancelRecord()
	if err != nil {
		// Fail-safe (the Mac stays on operator approval) but never silent: a
		// structured line for journald alerting, without the error text.
		fmt.Printf("app_attest_record_failed provider_id=%s\n", providerID)
		writeJSONError(w, http.StatusServiceUnavailable, "app_attest_unavailable", "app attest record failed")
		return
	}
	switch outcome {
	case AppAttestRecorded:
		writeJSON(w, http.StatusOK, appAttestChallengeResponse{Status: "recorded", ProviderID: providerID})
	case AppAttestAlreadyRecorded:
		writeJSON(w, http.StatusOK, appAttestChallengeResponse{Status: "already_recorded", ProviderID: providerID})
	default:
		writeJSONError(w, http.StatusConflict, "app_attest_key_reused", "app attest key is recorded for another provider")
	}
}

func (h *Handler) appAttestNow() time.Time {
	if h.Now != nil {
		return h.Now()
	}
	return time.Now()
}
