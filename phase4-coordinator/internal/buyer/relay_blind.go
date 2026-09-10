package buyer

import (
	"bytes"
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
	providerws "github.com/augstar/macprovider-coordinator/internal/ws"
)

const (
	relayBlindExecutionAuthorizationHeader = "X-MacProvider-Relay-Blind-Execution-Authorization"
	relayBlindValidatedHeader              = "X-MacProvider-Relay-Blind-Validated"
	relayBlindInputTokensHeader            = "X-MacProvider-Relay-Blind-Input-Tokens"
	// The encrypted request limit applies to decoded ciphertext. JSON carries
	// that ciphertext as unpadded base64url plus tightly bounded metadata.
	maxRelayBlindEnvelopeBodyBytes = ((relayblind.MaxEncryptedRequestBytes*4 + 2) / 3) + (8 << 10)
	relayBlindScope                = "request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays"
)

type relayBlindService struct {
	cfg     config.RelayBlindConfig
	store   *relayblind.Store
	relay   RelayBlindRelayFunc
	mu      sync.Mutex
	windows map[string][]time.Time
}

func WithRelayBlind(cfg config.RelayBlindConfig, store *relayblind.Store, relay RelayBlindRelayFunc) Option {
	return func(s *Server) {
		s.relayBlind = &relayBlindService{cfg: cfg, store: store, relay: relay, windows: make(map[string][]time.Time)}
	}
}

func (s *Server) relayBlindAvailable() bool {
	return s != nil && s.relayBlind != nil && s.relayBlind.cfg.Enabled && s.relayBlind.store != nil && s.relayBlind.relay != nil && !s.settlementEnforceMode()
}

func setRelayBlindNoStore(w http.ResponseWriter) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Pragma", "no-cache")
}

type relayBlindErrorShape struct {
	Status      int
	Retryable   bool
	RetryAction string
}

var relayBlindErrors = map[string]relayBlindErrorShape{
	"relay_blind_disabled":                  {http.StatusServiceUnavailable, false, "none"},
	"relay_blind_required_unavailable":      {http.StatusServiceUnavailable, false, "none"},
	"relay_blind_key_expired":               {http.StatusServiceUnavailable, true, "new_reservation_and_envelope"},
	"relay_blind_envelope_invalid":          {http.StatusBadRequest, false, "none"},
	"relay_blind_route_reservation_invalid": {http.StatusBadRequest, false, "none"},
	"relay_blind_endpoint_unsupported":      {http.StatusBadRequest, false, "none"},
	"relay_blind_replay":                    {http.StatusConflict, false, "do_not_resubmit"},
	"relay_blind_metadata_rate_limited":     {http.StatusTooManyRequests, true, "new_reservation_and_envelope"},
	"relay_blind_downgrade_rejected":        {http.StatusBadRequest, false, "none"},
	"relay_blind_decrypt_failed":            {http.StatusBadGateway, true, "new_reservation_and_envelope"},
	"relay_blind_ciphertext_invalid":        {http.StatusBadRequest, false, "none"},
	"relay_blind_committed_failed":          {http.StatusInternalServerError, false, "do_not_resubmit"},
	"relay_blind_provider_unsupported":      {http.StatusServiceUnavailable, true, "new_reservation_and_envelope"},
}

func writeRelayBlindError(w http.ResponseWriter, code, message string) {
	shape, ok := relayBlindErrors[code]
	if !ok {
		shape = relayBlindErrors["relay_blind_required_unavailable"]
		code = "relay_blind_required_unavailable"
	}
	effectiveOutcome := "relay_blind_unavailable"
	if strings.TrimSpace(w.Header().Get(relayBlindValidatedHeader)) != "" {
		effectiveOutcome = "relay_blind_satisfied"
	}
	setRelayBlindNoStore(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(shape.Status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]any{
		"message": message, "type": errorType(shape.Status), "param": nil, "code": code,
		"retryable": shape.Retryable, "retry_action": shape.RetryAction,
		"macprovider": map[string]any{
			"requested_privacy_mode": "relay_blind_required", "effective_privacy_outcome": effectiveOutcome,
			"scope": relayBlindScope, "retry_action": shape.RetryAction,
			"settlement": map[string]any{
				"verified_model_settlement": "unavailable_for_relay_blind_request",
				"usage_settlement":          "standard_usage_settlement_and_clear_cap_enforcement_still_apply",
			},
		},
	}})
}

func (s *Server) relayBlindMetadataAllowed(key string) bool {
	service := s.relayBlind
	if service == nil || service.cfg.MetadataRequestsPerMinute <= 0 {
		return false
	}
	now := s.now()
	cutoff := now.Add(-time.Minute)
	service.mu.Lock()
	defer service.mu.Unlock()
	if _, exists := service.windows[key]; !exists && len(service.windows) >= service.cfg.MaxActiveReservations {
		for candidate, timestamps := range service.windows {
			fresh := timestamps[:0]
			for _, at := range timestamps {
				if at.After(cutoff) {
					fresh = append(fresh, at)
				}
			}
			if len(fresh) == 0 {
				delete(service.windows, candidate)
			} else {
				service.windows[candidate] = fresh
			}
		}
		if len(service.windows) >= service.cfg.MaxActiveReservations {
			return false
		}
	}
	prior := service.windows[key]
	keep := prior[:0]
	for _, at := range prior {
		if at.After(cutoff) {
			keep = append(keep, at)
		}
	}
	if len(keep) >= service.cfg.MetadataRequestsPerMinute {
		service.windows[key] = keep
		return false
	}
	service.windows[key] = append(keep, now)
	return true
}

func relayBlindWalletSession(r *http.Request) (string, bool) {
	value := strings.TrimSpace(r.Header.Get("X-MacProvider-Wallet-Session"))
	return value, len(value) <= 256 && !relayBlindControlCharacter(value)
}

func relayBlindControlCharacter(value string) bool {
	for _, r := range value {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}

func relayBlindPoolIntent(r *http.Request) bool {
	for key, values := range r.Header {
		lower := strings.ToLower(key)
		if lower != "x-macprovider-pool" && !strings.HasPrefix(lower, "x-macprovider-pool-") {
			continue
		}
		for _, value := range values {
			if strings.TrimSpace(value) != "" {
				return true
			}
		}
	}
	return false
}

func (s *Server) handleRelayBlindReservation(w http.ResponseWriter, r *http.Request) {
	setRelayBlindNoStore(w)
	account, ok := authenticatedAccountFromContext(r.Context())
	walletSession, validSession := relayBlindWalletSession(r)
	if !ok || !validSession || relayBlindPoolIntent(r) {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind requests require the global pool and trusted account context")
		return
	}
	if s.relayBlind == nil || !s.relayBlind.cfg.Enabled {
		writeRelayBlindError(w, "relay_blind_disabled", "Relay-blind requests are disabled")
		return
	}
	if !s.relayBlindAvailable() {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind requests are unavailable")
		return
	}
	if !s.relayBlindMetadataAllowed(account.ID() + "\x00" + walletSession) {
		writeRelayBlindError(w, "relay_blind_metadata_rate_limited", "Relay-blind metadata rate limit exceeded")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, (16<<10)+1))
	if err != nil || len(body) > 16<<10 {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Invalid route reservation")
		return
	}
	request, err := relayblind.ParseReservationRequest(body)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Invalid route reservation")
		return
	}
	provider, key, found := s.selectRelayBlindProvider(r.Context(), request.Model, request.EncryptedRequestBytes, false)
	if !found {
		writeRelayBlindError(w, "relay_blind_provider_unsupported", "No relay-blind provider is available")
		return
	}
	expires := s.now().Add(time.Duration(s.relayBlind.cfg.ReservationTTLSeconds) * time.Second).Unix()
	if key.ExpiresAtUnix < expires {
		expires = key.ExpiresAtUnix
	}
	reservation, err := s.relayBlind.store.CreateReservation(r.Context(), relayblind.ReservationCreate{
		AccountID: account.ID(), WalletSession: walletSession, ProviderID: provider.ProviderID, AssignedSession: provider.AssignedID,
		KeyRecord: key, Model: request.Model, ProviderModel: provider.ModelID, Stream: request.Stream,
		MaxEncryptedRequestBytes: request.EncryptedRequestBytes, MaxOutputTokens: request.MaxOutputTokens,
		InputTokenUpperBound: request.InputTokenUpperBound, ExpiresAtUnix: expires, MaxActive: s.relayBlind.cfg.MaxActiveReservations,
		ReplayRetention: time.Duration(s.relayBlind.cfg.ReplayRetentionSeconds) * time.Second,
	}, s.now())
	if err != nil {
		code := "relay_blind_required_unavailable"
		if errors.Is(err, relayblind.ErrCapacity) {
			code = "relay_blind_metadata_rate_limited"
		}
		writeRelayBlindError(w, code, "Could not create relay-blind reservation")
		return
	}
	response := relayblind.ReservationResponse{
		Version: relayblind.ReservationVersion, ProviderBinding: reservation.ProviderBinding, BuyerBinding: reservation.BuyerBinding,
		KeyRecordDigest: key.KeyRecordDigest, KeyRecord: key, KID: key.KID, EndpointFamily: relayblind.EndpointChatCompletions,
		Model: request.Model, ProviderModel: provider.ModelID, Stream: request.Stream, MaxEncryptedRequestBytes: uint64(request.EncryptedRequestBytes),
		MaxOutputTokens: request.MaxOutputTokens, InputTokenUpperBound: request.InputTokenUpperBound,
		ReservationTokenCap: request.InputTokenUpperBound + request.MaxOutputTokens, ExpiresAtUnix: expires,
		CachePolicy: relayblind.CachePolicyNoStore, FailoverPolicy: relayblind.FailoverPolicyDisabled,
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

func (s *Server) selectRelayBlindProvider(ctx context.Context, model string, encryptedBytes int64, requireFree bool) (pool.Provider, relayblind.KeyRecord, bool) {
	providers := s.pool.Snapshot()
	sort.Slice(providers, func(i, j int) bool { return providers[i].AssignedID < providers[j].AssignedID })
	for _, provider := range providers {
		eligible := provider.ServingCapable()
		if requireFree {
			eligible = provider.RoutingEligible()
		}
		if !eligible || !provider.IsWSTunneled() || !modelIDEqual(provider.ModelID, model) {
			continue
		}
		records, err := s.relayBlind.store.FreshKeyRecords(ctx, provider.ProviderID, provider.AssignedID, model, encryptedBytes, s.now())
		if err == nil && len(records) > 0 {
			return provider, records[0], true
		}
	}
	return pool.Provider{}, relayblind.KeyRecord{}, false
}

func (s *Server) handleRelayBlindConsume(w http.ResponseWriter, r *http.Request) {
	setRelayBlindNoStore(w)
	account, ok := authenticatedAccountFromContext(r.Context())
	walletSession, validSession := relayBlindWalletSession(r)
	if !ok || !validSession || relayBlindPoolIntent(r) {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind requests require trusted global-pool context")
		return
	}
	if s.relayBlind == nil || s.relayBlind.store == nil {
		writeRelayBlindError(w, "relay_blind_disabled", "Relay-blind requests are disabled")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxRelayBlindEnvelopeBodyBytes+1))
	if err != nil || len(body) > maxRelayBlindEnvelopeBodyBytes {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	envelope, err := relayblind.ParseEnvelope(body)
	if err != nil || envelope.Validate(s.now(), time.Duration(s.relayBlind.cfg.MaxClockSkewSeconds)*time.Second) != nil {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	digest, err := relayblind.DigestEnvelopeBytes(body)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	response, err := s.relayBlind.store.Consume(r.Context(), relayblind.ConsumeInput{AccountID: account.ID(), WalletSession: walletSession, Envelope: envelope, EnvelopeDigest: digest, Now: s.now()})
	if err != nil {
		code := "relay_blind_route_reservation_invalid"
		switch {
		case errors.Is(err, relayblind.ErrReplay):
			code = "relay_blind_replay"
		case errors.Is(err, relayblind.ErrReservationExpired), errors.Is(err, relayblind.ErrKeyRevoked):
			code = "relay_blind_key_expired"
		}
		writeRelayBlindError(w, code, "Relay-blind reservation could not be consumed")
		return
	}
	if !s.relayBlind.cfg.Enabled {
		_ = s.relayBlind.store.RejectPredispatch(r.Context(), envelope.ProviderBinding, "relay_blind_disabled", s.now())
		writeRelayBlindError(w, "relay_blind_disabled", "Relay-blind requests are disabled")
		return
	}
	if !s.relayBlindAvailable() {
		_ = s.relayBlind.store.RejectPredispatch(r.Context(), envelope.ProviderBinding, "relay_blind_required_unavailable", s.now())
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind requests are unavailable")
		return
	}
	reservation, err := s.relayBlind.store.LookupReservation(r.Context(), envelope.ProviderBinding)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind state is unavailable")
		return
	}
	provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
	_, keyErr := s.relayBlind.store.LookupKeyRecord(r.Context(), reservation.ProviderID, reservation.AssignedSession, reservation.KID, reservation.KeyRecordDigest, s.now())
	if !live || !provider.ServingCapable() || !provider.IsWSTunneled() || keyErr != nil {
		_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_key_expired", s.now())
		writeRelayBlindError(w, "relay_blind_key_expired", "Relay-blind provider session or key expired")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

func relayBlindEnvelopeNamespace(body []byte) bool {
	var value struct {
		Version string `json:"version"`
	}
	return json.Unmarshal(body, &value) == nil && strings.HasPrefix(value.Version, "relay-blind-request-")
}

func (s *Server) handleRelayBlindChat(w http.ResponseWriter, r *http.Request, rec *billingRecorder, internalRequestID string) {
	setRelayBlindNoStore(w)
	account, ok := authenticatedAccountFromContext(r.Context())
	walletSession, validSession := relayBlindWalletSession(r)
	authorization := strings.TrimSpace(r.Header.Get(relayBlindExecutionAuthorizationHeader))
	if !ok || !validSession || relayBlindPoolIntent(r) || authorization == "" {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind execution requires trusted global-pool context")
		return
	}
	if s.relayBlind == nil || s.relayBlind.store == nil {
		writeRelayBlindError(w, "relay_blind_disabled", "Relay-blind execution is disabled")
		return
	}
	if encoding := strings.TrimSpace(r.Header.Get("Content-Encoding")); encoding != "" && !strings.EqualFold(encoding, "identity") {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Relay-blind envelopes do not support content encoding")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxRelayBlindEnvelopeBodyBytes+1))
	if err != nil || len(body) > maxRelayBlindEnvelopeBodyBytes {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	envelope, err := relayblind.ParseEnvelope(body)
	if err != nil || envelope.Validate(s.now(), time.Duration(s.relayBlind.cfg.MaxClockSkewSeconds)*time.Second) != nil {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	digest, err := relayblind.DigestEnvelopeBytes(body)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	reservation, err := s.relayBlind.store.LookupConsumedAuthorization(r.Context(), account.ID(), walletSession, authorization, s.now())
	if err != nil || subtle.ConstantTimeCompare([]byte(reservation.EnvelopeDigest), []byte(digest)) != 1 || reservation.RequestID != envelope.RequestID {
		code := "relay_blind_route_reservation_invalid"
		if errors.Is(err, relayblind.ErrReplay) {
			code = "relay_blind_replay"
		}
		writeRelayBlindError(w, code, "Relay-blind execution authorization is invalid")
		return
	}
	if !s.relayBlind.cfg.Enabled {
		_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_disabled", s.now())
		writeRelayBlindError(w, "relay_blind_disabled", "Relay-blind execution is disabled")
		return
	}
	if !s.relayBlindAvailable() {
		_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_required_unavailable", s.now())
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind execution is unavailable")
		return
	}
	provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
	_, keyErr := s.relayBlind.store.LookupKeyRecord(r.Context(), reservation.ProviderID, reservation.AssignedSession, reservation.KID, reservation.KeyRecordDigest, s.now())
	if !live || !provider.RoutingEligible() || !provider.IsWSTunneled() || keyErr != nil {
		_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_key_expired", s.now())
		writeRelayBlindError(w, "relay_blind_key_expired", "Relay-blind provider session or key expired")
		return
	}
	quotaMetered := false
	if s.admission != nil {
		if !s.admission.TryReserveRequest(provider) {
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_provider_unsupported", s.now())
			writeRelayBlindError(w, "relay_blind_provider_unsupported", "Relay-blind provider quota is unavailable")
			return
		}
		quotaMetered = s.admission.RequestQuotaMetered(provider)
	}
	reservation, err = s.relayBlind.store.ArmDispatchWithRequestID(r.Context(), account.ID(), walletSession, authorization, internalRequestID, s.now())
	if err != nil {
		if quotaMetered {
			s.admission.RefundRequest(provider)
		}
		writeRelayBlindError(w, "relay_blind_replay", "Relay-blind authorization has already been used")
		return
	}
	rec.setModel(reservation.Model)
	rec.setStream(reservation.Stream)
	rec.setPromptTokenUpperBound(reservation.InputTokenUpperBound)
	rec.setRelayBlindAudit(relayBlindAuditFields{Outcome: "relay_blind_unavailable", EnvelopeDigest: reservation.EnvelopeDigest,
		KeyRecordDigest: reservation.KeyRecordDigest, KID: reservation.KID, ProviderBindingDigest: relayblind.BindingDigest(reservation.ProviderBinding),
		InputTokenUpperBound: reservation.InputTokenUpperBound, MaxOutputTokens: reservation.MaxOutputTokens})
	rec.markProviderDispatched()
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()
	relayContext := providerws.RelayBlindDispatchContext{
		ExecutionAuthDigest: reservation.ExecutionAuthDigest, EnvelopeDigest: reservation.EnvelopeDigest, KID: reservation.KID,
		ProviderBindingDigest: relayblind.BindingDigest(reservation.ProviderBinding), BuyerBindingDigest: relayblind.BindingDigest(reservation.BuyerBinding),
		AssignedSession: reservation.AssignedSession, RequestID: reservation.RequestID,
		InputTokenUpperBound: reservation.InputTokenUpperBound, MaxOutputTokens: reservation.MaxOutputTokens,
	}
	relay, err := s.relayBlind.relay(ctx, provider, envelope.RequestID, body, envelope.Stream, relayContext)
	if err != nil {
		_ = s.relayBlind.store.RejectArmedPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_provider_unsupported", s.now())
		if quotaMetered {
			s.admission.RefundRequest(provider)
		}
		_ = rec.logProviderRowWithEstimateAndOutput(provider, http.StatusServiceUnavailable, nil, nil, err.Error(), "relay_blind_provider_unsupported", 0, nil, nil)
		writeRelayBlindError(w, "relay_blind_provider_unsupported", "Relay-blind provider dispatch was unavailable")
		return
	}
	var validation providerws.RelayBlindValidation
	select {
	case validation = <-relay.Validations:
	case err = <-relay.Errors:
		_ = err
		_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
		s.recordRelayBlindUnknown(rec, provider, nil, nil, http.StatusInternalServerError, "Provider validation evidence was not accepted")
		writeRelayBlindError(w, "relay_blind_committed_failed", "Provider validation evidence was not accepted")
		return
	case <-ctx.Done():
		_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
		s.recordRelayBlindUnknown(rec, provider, nil, nil, http.StatusInternalServerError, "Provider validation evidence timed out")
		writeRelayBlindError(w, "relay_blind_committed_failed", "Provider validation evidence timed out")
		return
	}
	evidence := relayBlindEvidence(validation)
	if _, err := s.relayBlind.store.PersistEvidence(r.Context(), provider.ProviderID, provider.AssignedID, evidence, "", s.now()); err != nil {
		_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
		s.recordRelayBlindUnknown(rec, provider, nil, nil, http.StatusInternalServerError, "Provider validation evidence was not accepted")
		writeRelayBlindError(w, "relay_blind_committed_failed", "Provider validation evidence was not accepted")
		return
	}
	if validation.State == "rejected" {
		if quotaMetered {
			s.admission.RefundRequest(provider)
		}
		status := relayBlindErrors[validation.ErrorCode].Status
		zero := int64(0)
		_ = rec.logProviderRowWithEstimateAndOutput(provider, status, &zero, &zero, validation.ErrorCode, validation.ErrorCode, 0, nil, nil)
		writeRelayBlindError(w, validation.ErrorCode, "Provider rejected the relay-blind ciphertext before generation")
		return
	}
	rec.relayBlind.Outcome = "relay_blind_satisfied"
	w.Header().Set(relayBlindValidatedHeader, reservation.EnvelopeDigest)
	w.Header().Set(relayBlindInputTokensHeader, strconv.FormatInt(validation.InputTokens, 10))
	if envelope.Stream {
		s.forwardRelayBlindStreaming(w, r, rec, provider, reservation, relay, validation.InputTokens)
		return
	}
	s.forwardRelayBlindNonStreaming(w, r, rec, provider, reservation, relay, validation.InputTokens)
}

func relayBlindEvidence(value providerws.RelayBlindValidation) relayblind.Evidence {
	return relayblind.Evidence{ExecutionAuthDigest: value.ExecutionAuthDigest, EnvelopeDigest: value.EnvelopeDigest, KID: value.KID,
		ProviderBindingDigest: value.ProviderBindingDigest, BuyerBindingDigest: value.BuyerBindingDigest, AssignedSession: value.AssignedSession,
		RequestID: value.RequestID, State: value.State, InputTokens: value.InputTokens, InputTokenUpperBound: value.InputTokenUpperBound, MaxOutputTokens: value.MaxOutputTokens,
		ErrorCode: value.ErrorCode}
}

func (s *Server) forwardRelayBlindNonStreaming(w http.ResponseWriter, r *http.Request, rec *billingRecorder, provider pool.Provider, reservation relayblind.Reservation, relay *providerws.RelayStream, inputTokens int64) {
	var output bytes.Buffer
	for {
		select {
		case chunk, ok := <-relay.Chunks:
			if ok {
				if output.Len()+len(chunk.Data) > int(maxUpstreamResponseBodyBytes) {
					_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
					writeRelayBlindError(w, "relay_blind_committed_failed", "Provider response exceeded coordinator limit")
					return
				}
				output.WriteString(chunk.Data)
			}
		case end := <-relay.Done:
			if end.RelayBlindValidation == nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Terminal provider evidence was missing")
				writeRelayBlindError(w, "relay_blind_committed_failed", "Terminal provider evidence was missing")
				return
			}
			completion, valid := boundedRelayBlindCompletion(end.Usage, reservation.MaxOutputTokens)
			if !valid {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Terminal provider usage was invalid")
				writeRelayBlindError(w, "relay_blind_committed_failed", "Terminal provider usage was invalid")
				return
			}
			terminal := relayBlindEvidence(*end.RelayBlindValidation)
			terminal.CompletionTokens = completion
			code := ""
			status := http.StatusOK
			if end.Status != "complete" {
				code = "relay_blind_committed_failed"
				status = relayBlindErrors[code].Status
			}
			if _, err := s.relayBlind.store.PersistEvidence(r.Context(), provider.ProviderID, provider.AssignedID, terminal, code, s.now()); err != nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Terminal provider evidence was not accepted")
				writeRelayBlindError(w, "relay_blind_committed_failed", "Terminal provider evidence was not accepted")
				return
			}
			prompt, complete := inputTokens, completion
			settlementOutput, validOutput := settlementOutputFromChatResponseAt(output.Bytes(), terminalStateFromAttempt(status, end.Error, code), s.now().UnixMilli())
			if !validOutput {
				settlementOutput = settlementOutputUnavailableFor(terminalStateFromAttempt(status, end.Error, code))
			}
			if err := rec.logProviderRowWithEstimateAndOutput(provider, status, &prompt, &complete, end.Error, code, 0, nil, settlementOutput); err != nil {
				writeRelayBlindError(w, "relay_blind_committed_failed", "Could not durably record relay-blind execution")
				return
			}
			if status != http.StatusOK {
				writeRelayBlindError(w, code, "Provider relay-blind execution failed after commit")
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(output.Bytes())
			return
		case <-relay.Errors:
			_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Provider relay failed after commit")
			writeRelayBlindError(w, "relay_blind_committed_failed", "Provider relay failed after commit")
			return
		case <-r.Context().Done():
			_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Buyer disconnected during request")
			return
		}
	}
}

func (s *Server) forwardRelayBlindStreaming(w http.ResponseWriter, r *http.Request, rec *billingRecorder, provider pool.Provider, reservation relayblind.Reservation, relay *providerws.RelayStream, inputTokens int64) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	tracker := newSettlementStreamOutputTracker()
	var streamedBytes int64
	for {
		select {
		case chunk, ok := <-relay.Chunks:
			if ok {
				streamedBytes += int64(len(chunk.Data))
				if streamedBytes > maxUpstreamResponseBodyBytes {
					relay.Cancel("response_byte_cap_exceeded")
					_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
					s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Provider response exceeded coordinator limit")
					return
				}
				n, writeErr := io.WriteString(w, chunk.Data)
				if n > 0 {
					_ = tracker.observeBlock([]byte(chunk.Data[:n]))
				}
				if writeErr != nil {
					relay.Cancel("buyer_disconnected")
					_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
					s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateBuyerCancel), http.StatusOK, "Buyer disconnected during streaming")
					return
				}
				if flusher != nil {
					flusher.Flush()
				}
			}
		case end := <-relay.Done:
			if end.RelayBlindValidation == nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Terminal provider evidence was missing")
				return
			}
			completion, valid := boundedRelayBlindCompletion(end.Usage, reservation.MaxOutputTokens)
			if !valid {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Terminal provider usage was invalid")
				return
			}
			terminal := relayBlindEvidence(*end.RelayBlindValidation)
			terminal.CompletionTokens = completion
			code := ""
			status := http.StatusOK
			if end.Status != "complete" {
				code, status = "relay_blind_committed_failed", http.StatusInternalServerError
			}
			if _, err := s.relayBlind.store.PersistEvidence(context.Background(), provider.ProviderID, provider.AssignedID, terminal, code, s.now()); err != nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Terminal provider evidence was not accepted")
				return
			}
			prompt, complete := inputTokens, completion
			_ = rec.logProviderRowWithEstimateAndOutput(provider, status, &prompt, &complete, end.Error, code, 0, nil, tracker.output(terminalStateFromAttempt(status, end.Error, code)))
			return
		case <-relay.Errors:
			_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Provider relay failed after commit")
			return
		case <-r.Context().Done():
			relay.Cancel("buyer_disconnected")
			_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateBuyerCancel), http.StatusOK, "Buyer disconnected during streaming")
			return
		}
	}
}

func (s *Server) recordRelayBlindUnknown(rec *billingRecorder, provider pool.Provider, inputTokens *int64, output *billing.SettlementOutput, status int, message string) {
	var estimate *int64
	if output != nil && output.Available {
		delivered := output.OutputPrefixEndByte - output.OutputPrefixStartByte
		estimate = s.estimatedCompletionTokensFromBytes(int(delivered))
		if estimate != nil && rec != nil && rec.relayBlind != nil && *estimate > rec.relayBlind.MaxOutputTokens {
			bounded := rec.relayBlind.MaxOutputTokens
			estimate = &bounded
		}
	}
	_ = rec.logProviderRowWithEstimateAndOutput(provider, status, inputTokens, nil, message, "relay_blind_committed_failed", 0, estimate, output)
}

func boundedRelayBlindCompletion(raw json.RawMessage, max int64) (int64, bool) {
	_, _, value := tokenPointersFromUsageObject(raw)
	if value == nil || *value < 0 || *value > max {
		return 0, false
	}
	return *value, true
}

func (s *Server) handleRelayBlindStatus(w http.ResponseWriter, r *http.Request) {
	setRelayBlindNoStore(w)
	account, ok := authenticatedAccountFromContext(r.Context())
	walletSession, validSession := relayBlindWalletSession(r)
	if !ok || !validSession || s.relayBlind == nil || s.relayBlind.store == nil {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind status is unavailable")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, 1025))
	if err != nil || len(body) > 1024 {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Invalid relay-blind status request")
		return
	}
	request, err := relayblind.ParseStatusRequest(body)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Invalid relay-blind status request")
		return
	}
	reservation, err := s.relayBlind.store.LookupStatus(r.Context(), account.ID(), walletSession, request.ProviderBindingDigest, request.EnvelopeDigest, s.now())
	if err != nil {
		writeRelayBlindError(w, "relay_blind_route_reservation_invalid", "Relay-blind status was not found")
		return
	}
	response := relayblind.StatusResponse{Version: relayblind.StatusVersion, State: reservation.State, InternalRequestID: reservation.InternalRequestID,
		Validated: reservation.ValidatedInputTokens != nil, InputTokens: reservation.ValidatedInputTokens, CompletionTokens: reservation.CompletionTokens,
		EffectivePrivacyOutcome: reservation.EffectivePrivacyOutcome, RetryAction: relayblind.RetryDoNotResubmit}
	if err := response.Validate(); err != nil {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind status is unavailable")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(response)
}

func (s *Server) handleRelayBlindCapabilities(w http.ResponseWriter, r *http.Request) {
	setRelayBlindNoStore(w)
	if !s.relayBlindAvailable() {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind capabilities are unavailable")
		return
	}
	active, err := s.relayBlind.store.ActiveKeyModels(r.Context(), s.now())
	if err != nil {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind capabilities are unavailable")
		return
	}
	type counts struct {
		CapableProviderCount   int `json:"capable_provider_count"`
		IncapableProviderCount int `json:"incapable_provider_count"`
	}
	models := make(map[string]counts)
	for _, provider := range s.pool.Snapshot() {
		if !provider.ServingCapable() || !provider.IsWSTunneled() {
			continue
		}
		value := models[provider.ModelID]
		if providerSessions := active[provider.ProviderID]; providerSessions != nil {
			providerModels := providerSessions[provider.AssignedID]
			if _, ok := providerModels[provider.ModelID]; ok {
				value.CapableProviderCount++
			} else {
				value.IncapableProviderCount++
			}
		} else {
			value.IncapableProviderCount++
		}
		models[provider.ModelID] = value
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"version": "relay-blind-capabilities-v1", "models": models})
}
