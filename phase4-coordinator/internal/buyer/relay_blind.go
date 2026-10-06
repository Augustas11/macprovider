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
	// dispatchClaims holds one in-process claim per provider binding while a
	// consumed authorization waits for a slot, so a concurrent duplicate is
	// a replay and never takes a second slot-queue position.
	dispatchClaims sync.Map
}

// relayBlindCleanupTimeout bounds terminal rejection writes that must land
// even after the buyer request context is canceled.
const relayBlindCleanupTimeout = 5 * time.Second

func relayBlindCleanupContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), relayBlindCleanupTimeout)
}

func WithRelayBlind(cfg config.RelayBlindConfig, store *relayblind.Store, relay RelayBlindRelayFunc) Option {
	return func(s *Server) {
		s.relayBlind = &relayBlindService{cfg: cfg, store: store, relay: relay, windows: make(map[string][]time.Time)}
	}
}

// WithPrivacyAuthority stores the SPEC-049 posture authority for the buyer
// routing gate. Nil leaves privacy-class routing unchanged.
func WithPrivacyAuthority(authority *relayblind.PrivacyAuthority) Option {
	return func(s *Server) {
		s.privacyAuthority = authority
	}
}

// relayBlindAvailable is SPEC-041 availability. Under SPEC-022 enforce the
// lane is open only with the R-14 settlement profile configured (R-1.3).
func (s *Server) relayBlindAvailable() bool {
	return s != nil && s.relayBlind != nil && s.relayBlind.cfg.Enabled && s.relayBlind.store != nil && s.relayBlind.relay != nil &&
		(!s.settlementEnforceMode() || s.relayBlindSettlementProfileConfigured())
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
	"unsupported_sampling_penalty":          {http.StatusBadRequest, false, "none"},
	privacyClassDisabled:                    {http.StatusServiceUnavailable, false, "none"},
	privacyClassUnavailable:                 {http.StatusServiceUnavailable, false, "none"},
	privacyClassDowngrade:                   {http.StatusBadRequest, false, "none"},
	privacyClassStale:                       {http.StatusServiceUnavailable, true, "new_reservation_and_envelope"},
	privacyClassUnconfirmed:                 {http.StatusInternalServerError, false, "do_not_resubmit"},
}

func writeRelayBlindError(w http.ResponseWriter, code, message string) {
	status, body := relayBlindErrorBody(w, code, message)
	w.Header().Del(privacyClassHeader)
	w.Header().Del(privacyPostureVerifiedAtHeader)
	setRelayBlindNoStore(w)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

// writeRelayBlindStreamError ends a relay-blind stream whose 200 headers are
// already sent with the same typed error envelope, followed by [DONE].
func writeRelayBlindStreamError(w http.ResponseWriter, code, message string) {
	_, body := relayBlindErrorBody(w, code, message)
	raw, _ := json.Marshal(body)
	_, _ = io.WriteString(w, "data: "+string(raw)+"\n\ndata: [DONE]\n\n")
	if flusher, ok := w.(http.Flusher); ok {
		flusher.Flush()
	}
}

func relayBlindErrorBody(w http.ResponseWriter, code, message string) (int, map[string]any) {
	shape, ok := relayBlindErrors[code]
	if !ok {
		shape = relayBlindErrors["relay_blind_required_unavailable"]
		code = "relay_blind_required_unavailable"
	}
	effectiveOutcome := "relay_blind_unavailable"
	if strings.TrimSpace(w.Header().Get(relayBlindValidatedHeader)) != "" {
		effectiveOutcome = "relay_blind_satisfied"
	}
	return shape.Status, map[string]any{"error": map[string]any{
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
	}}
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
	present, valid := privacyRequested(r)
	if !ok || !validSession {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind requests require the global pool and trusted account context")
		return
	}
	if present && relayBlindPoolIntent(r) {
		writePrivacyClassError(w, privacyClassDowngrade, "Privacy class does not accept pool-scoped requests")
		return
	}
	if relayBlindPoolIntent(r) {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind requests require the global pool and trusted account context")
		return
	}
	if present && !valid {
		writePrivacyClassError(w, privacyClassDowngrade, "")
		return
	}
	if present {
		s.handlePrivacyClassReservation(w, r, account.ID(), walletSession)
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
	provider, key, found := s.selectRelayBlindProvider(r.Context(), request.Model, request.EncryptedRequestBytes, false, relayblind.KeyClassRelayBlind)
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

// relayBlindBindable reports a session a relay-blind or privacy reservation
// may bind or consume against. A session still waiting for its handshake
// ack is excluded: its relay-blind keys are accepted at registration, before
// the ack. ServingCapable itself is left untouched because its body is
// bound by SPEC-032-R001 conformant commit evidence.
func relayBlindBindable(p pool.Provider) bool {
	return p.ServingCapable() && !p.HandshakeAckPending
}

// relayBlindSessionUsable is the session half of RoutingEligible for a
// pinned relay-blind dispatch: everything except free-slot capacity, which
// awaitRelayBlindSlot acquires separately.
func relayBlindSessionUsable(p pool.Provider) bool {
	return relayBlindBindable(p) && !p.CatalogRecheckPending
}

func relayBlindSessionLostCode(privacy bool) (string, bool) {
	if privacy {
		return privacyClassStale, true
	}
	return "relay_blind_key_expired", false
}

// relayBlindPredispatchFailure re-runs the non-capacity predispatch checks
// for a reservation whose slot wait failed. It returns "" when only
// capacity is missing. The bool reports a privacy-class error code.
func (s *Server) relayBlindPredispatchFailure(ctx context.Context, reservation relayblind.Reservation) (string, bool) {
	provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
	_, keyErr := s.relayBlind.store.LookupKeyRecord(ctx, reservation.ProviderID, reservation.AssignedSession, reservation.KID, reservation.KeyRecordDigest, s.now())
	sessionLost := !live || provider.AssignedID != reservation.AssignedSession || !relayBlindSessionUsable(provider) || !provider.IsWSTunneled() || keyErr != nil || s.relayBlindSettlementPrerequisite(provider) != ""
	if reservation.PrivacyClass {
		if s.privacyDisabledNow(ctx) {
			return privacyClassDisabled, true
		}
		if !s.relayBlindAvailable() || sessionLost {
			return privacyClassStale, true
		}
		if _, code := s.privacyGate(ctx, provider, reservation.KeyRecordDigest); code != "" {
			return privacyObservedCode(code, false), true
		}
		return "", false
	}
	if !s.relayBlind.cfg.Enabled {
		return "relay_blind_disabled", false
	}
	if !s.relayBlindAvailable() {
		return "relay_blind_required_unavailable", false
	}
	if sessionLost {
		return "relay_blind_key_expired", false
	}
	return "", false
}

type relayBlindSlotOutcome int

const (
	relayBlindSlotAcquired relayBlindSlotOutcome = iota
	relayBlindSlotSessionLost
	relayBlindSlotUnavailable
)

// awaitRelayBlindSlot takes a coordinator slot lease on the reserved session.
// It waits in that session's slot queue, bounded by the slot-queue deadline
// and the reservation expiry. On success the lease is recorded in state for
// noteProviderAcceptedRequest and releaseQueuedSlotReservation.
func (s *Server) awaitRelayBlindSlot(ctx context.Context, reservation relayblind.Reservation, state *forwardState) (pool.Provider, relayBlindSlotOutcome) {
	resolve := func() (pool.Provider, bool) {
		provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
		return provider, live && provider.AssignedID == reservation.AssignedSession && relayBlindSessionUsable(provider) && provider.IsWSTunneled()
	}
	acquired := func(provider pool.Provider) (pool.Provider, relayBlindSlotOutcome) {
		state.provider = provider
		state.queuedSlotProviderID = provider.ProviderID
		return provider, relayBlindSlotAcquired
	}
	provider, usable := resolve()
	if !usable {
		return pool.Provider{}, relayBlindSlotSessionLost
	}
	if s.slotQueue == nil {
		if provider.RoutingEligible() {
			state.provider = provider
			return provider, relayBlindSlotAcquired
		}
		return pool.Provider{}, relayBlindSlotUnavailable
	}
	if provider.RoutingEligible() && s.slotQueue.reserveProvider(provider.ProviderID, provider.SlotsFree) {
		return acquired(provider)
	}
	deadline := s.slotQueueDeadline
	if deadline <= 0 {
		deadline = slotQueueDefaultDeadline
	}
	if untilExpiry := time.Unix(reservation.ExpiresAtUnix, 0).Sub(s.now()); untilExpiry < deadline {
		deadline = untilExpiry
	}
	if deadline <= 0 {
		return pool.Provider{}, relayBlindSlotUnavailable
	}
	pollInterval := s.slotQueuePollInterval
	if pollInterval <= 0 {
		pollInterval = slotQueueDefaultPollInterval
	}
	waiter, ok := s.slotQueue.enter(provider.ProviderID)
	if !ok {
		return pool.Provider{}, relayBlindSlotUnavailable
	}
	defer s.slotQueue.leave(waiter)
	waitCtx, cancel := context.WithTimeout(ctx, deadline)
	defer cancel()
	ticker := time.NewTicker(pollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-waitCtx.Done():
			return pool.Provider{}, relayBlindSlotUnavailable
		case <-ticker.C:
		}
		provider, usable = resolve()
		if !usable {
			return pool.Provider{}, relayBlindSlotSessionLost
		}
		if provider.RoutingEligible() && s.slotQueue.reserveHead(waiter, provider.SlotsFree) {
			return acquired(provider)
		}
	}
}

func (s *Server) selectRelayBlindProvider(ctx context.Context, model string, encryptedBytes int64, requireFree bool, class string) (pool.Provider, relayblind.KeyRecord, bool) {
	providers := s.pool.Snapshot()
	sort.Slice(providers, func(i, j int) bool { return providers[i].AssignedID < providers[j].AssignedID })
	for _, provider := range providers {
		eligible := relayBlindBindable(provider)
		if requireFree {
			eligible = provider.RoutingEligible()
		}
		if !eligible || !provider.IsWSTunneled() || !modelIDEqual(provider.ModelID, model) {
			continue
		}
		// SPEC-047-R011: a session bound to a pool model entry serves only
		// that pool's pool-model route; relay-blind is global-pool only.
		if provider.ModelAdmissionPoolModelID != "" {
			continue
		}
		if s.relayBlindSettlementPrerequisite(provider) != "" {
			continue
		}
		records, err := s.relayBlind.store.FreshKeyRecords(ctx, provider.ProviderID, provider.AssignedID, model, encryptedBytes, s.now(), class)
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
	present, valid := privacyRequested(r)
	if !ok || !validSession {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind requests require trusted global-pool context")
		return
	}
	if present && relayBlindPoolIntent(r) {
		writePrivacyClassError(w, privacyClassDowngrade, "Privacy class does not accept pool-scoped requests")
		return
	}
	if relayBlindPoolIntent(r) {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind requests require trusted global-pool context")
		return
	}
	if s.relayBlind == nil || s.relayBlind.store == nil {
		if present {
			if !valid {
				writePrivacyClassError(w, privacyClassDowngrade, "")
				return
			}
			writePrivacyClassError(w, privacyClassDisabled, "")
			return
		}
		writeRelayBlindError(w, "relay_blind_disabled", "Relay-blind requests are disabled")
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxRelayBlindEnvelopeBodyBytes+1))
	if err != nil || len(body) > maxRelayBlindEnvelopeBodyBytes {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	envelope, err := relayblind.ParseEnvelope(body)
	envelopeValid := err == nil && envelope.Validate(s.now(), time.Duration(s.relayBlind.cfg.MaxClockSkewSeconds)*time.Second) == nil
	// SPEC-049 §4.2/R012: classify the privacy marker before the envelope
	// error. A privacy header on a body outside the relay-blind envelope
	// namespace, or an invalid header on a body that is not a valid
	// envelope, is a downgrade. An invalid header on a valid envelope still
	// reaches privacyClassConflict below, which also burns the reservation.
	if present && !relayBlindEnvelopeNamespace(body) {
		writePrivacyClassError(w, privacyClassDowngrade, "Privacy class marker is not valid for a plaintext request")
		return
	}
	if present && !valid && !envelopeValid {
		writePrivacyClassError(w, privacyClassDowngrade, "")
		return
	}
	if !envelopeValid {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	digest, err := relayblind.DigestEnvelopeBytes(body)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	held, heldErr := s.relayBlind.store.LookupReservation(r.Context(), envelope.ProviderBinding)
	if code, reject := s.privacyClassConflict(r.Context(), held, heldErr == nil, present, valid); code != "" {
		if reject {
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), held.ProviderBinding, code, s.now())
		}
		writePrivacyClassError(w, code, "")
		return
	}
	response, err := s.relayBlind.store.Consume(r.Context(), relayblind.ConsumeInput{AccountID: account.ID(), WalletSession: walletSession, Envelope: envelope, EnvelopeDigest: digest, Now: s.now()})
	if err != nil {
		if errors.Is(err, relayblind.ErrReplay) && heldErr == nil && held.AccountID == account.ID() && held.WalletSession == walletSession {
			if code := privacyInvalidatedCode(held, s.now()); code != "" {
				writePrivacyClassError(w, code, "")
				return
			}
		}
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
	reservation, err := s.relayBlind.store.LookupReservation(r.Context(), envelope.ProviderBinding)
	if err != nil {
		writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind state is unavailable")
		return
	}
	if reservation.PrivacyClass {
		provider, _ := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
		if _, code := s.privacyGate(r.Context(), provider, reservation.KeyRecordDigest); code != "" {
			observed := privacyObservedCode(code, false)
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, observed, s.now())
			writePrivacyClassError(w, observed, "")
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(response)
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
	provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
	_, keyErr := s.relayBlind.store.LookupKeyRecord(r.Context(), reservation.ProviderID, reservation.AssignedSession, reservation.KID, reservation.KeyRecordDigest, s.now())
	if !live || !relayBlindBindable(provider) || !provider.IsWSTunneled() || keyErr != nil || s.relayBlindSettlementPrerequisite(provider) != "" {
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
	present, valid := privacyRequested(r)
	if !ok || !validSession || authorization == "" {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind execution requires trusted global-pool context")
		return
	}
	if present && relayBlindPoolIntent(r) {
		writePrivacyClassError(w, privacyClassDowngrade, "Privacy class does not accept pool-scoped requests")
		return
	}
	if relayBlindPoolIntent(r) {
		writeRelayBlindError(w, "relay_blind_downgrade_rejected", "Relay-blind execution requires trusted global-pool context")
		return
	}
	if s.relayBlind == nil || s.relayBlind.store == nil {
		if present {
			if !valid {
				writePrivacyClassError(w, privacyClassDowngrade, "")
				return
			}
			writePrivacyClassError(w, privacyClassDisabled, "")
			return
		}
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
	// SPEC-049 §4.2/R012: an invalid privacy header, or a privacy header on a
	// body outside the relay-blind envelope namespace, is a downgrade. A
	// genuine envelope that fails Validate stays relay_blind_envelope_invalid.
	if present && !valid {
		writePrivacyClassError(w, privacyClassDowngrade, "")
		return
	}
	if present && !relayBlindEnvelopeNamespace(body) {
		writePrivacyClassError(w, privacyClassDowngrade, "Privacy class marker is not valid for a plaintext request")
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
	held, heldErr := s.relayBlind.store.LookupReservation(r.Context(), envelope.ProviderBinding)
	if code, reject := s.privacyClassConflict(r.Context(), held, heldErr == nil, present, valid); code != "" {
		if reject {
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), held.ProviderBinding, code, s.now())
		}
		writePrivacyClassError(w, code, "")
		return
	}
	reservation, err := s.relayBlind.store.LookupConsumedAuthorization(r.Context(), account.ID(), walletSession, authorization, s.now())
	if err != nil || subtle.ConstantTimeCompare([]byte(reservation.EnvelopeDigest), []byte(digest)) != 1 || reservation.RequestID != envelope.RequestID {
		if errors.Is(err, relayblind.ErrReplay) {
			if peeked, peekErr := s.relayBlind.store.PeekAuthorization(r.Context(), account.ID(), walletSession, authorization); peekErr == nil && peeked.PrivacyClass && s.privacyDisabledNow(r.Context()) {
				writePrivacyClassError(w, privacyClassDisabled, "")
				return
			}
			if code := s.privacyInvalidatedAuthorization(r.Context(), account.ID(), walletSession, authorization); code != "" {
				writePrivacyClassError(w, code, "")
				return
			}
		}
		code := "relay_blind_route_reservation_invalid"
		if errors.Is(err, relayblind.ErrReplay) {
			code = "relay_blind_replay"
		}
		writeRelayBlindError(w, code, "Relay-blind execution authorization is invalid")
		return
	}
	provider, live := s.pool.Resolve(reservation.ProviderID, reservation.AssignedSession)
	_, keyErr := s.relayBlind.store.LookupKeyRecord(r.Context(), reservation.ProviderID, reservation.AssignedSession, reservation.KID, reservation.KeyRecordDigest, s.now())
	if reservation.PrivacyClass {
		if s.privacyDisabledNow(r.Context()) {
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, privacyClassDisabled, s.now())
			writePrivacyClassError(w, privacyClassDisabled, "")
			return
		}
		if !s.relayBlindAvailable() || !live || !relayBlindSessionUsable(provider) || !provider.IsWSTunneled() || keyErr != nil || s.relayBlindSettlementPrerequisite(provider) != "" {
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, privacyClassStale, s.now())
			writePrivacyClassError(w, privacyClassStale, "")
			return
		}
	} else {
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
		if !live || !relayBlindSessionUsable(provider) || !provider.IsWSTunneled() || keyErr != nil || s.relayBlindSettlementPrerequisite(provider) != "" {
			_ = s.relayBlind.store.RejectPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_key_expired", s.now())
			writeRelayBlindError(w, "relay_blind_key_expired", "Relay-blind provider session or key expired")
			return
		}
	}
	// SPEC-041-R004 / SPEC-002: provider capacity is acquired at dispatch. A
	// session with no free slot is a capacity condition, not a lost session,
	// a stale posture, or an expired key. Wait on the pinned session's slot
	// queue like plaintext routing; never move to another provider.
	if _, claimed := s.relayBlind.dispatchClaims.LoadOrStore(reservation.ProviderBinding, struct{}{}); claimed {
		writeRelayBlindError(w, "relay_blind_replay", "Relay-blind authorization has already been used")
		return
	}
	defer s.relayBlind.dispatchClaims.Delete(reservation.ProviderBinding)
	slotState := &forwardState{}
	defer s.releaseQueuedSlotReservation(slotState)
	defer s.restoreConsumedForwardedSlot(slotState)
	provider, slotOutcome := s.awaitRelayBlindSlot(r.Context(), reservation, slotState)
	if slotOutcome != relayBlindSlotAcquired {
		// A wait can outlive the posture, the kill switch, or the key. Those
		// keep their own codes; only a pure capacity miss is a capacity code.
		cleanupCtx, cancelCleanup := relayBlindCleanupContext()
		defer cancelCleanup()
		code, privacyCode := s.relayBlindPredispatchFailure(cleanupCtx, reservation)
		if code == "" {
			code, privacyCode = "relay_blind_provider_unsupported", false
			if slotOutcome == relayBlindSlotSessionLost {
				code, privacyCode = relayBlindSessionLostCode(reservation.PrivacyClass)
			}
		}
		_ = s.relayBlind.store.RejectPredispatch(cleanupCtx, reservation.ProviderBinding, code, s.now())
		if privacyCode {
			writePrivacyClassError(w, code, "")
			return
		}
		message := "Relay-blind provider session or key expired"
		switch code {
		case "relay_blind_provider_unsupported":
			message = "Relay-blind provider capacity is unavailable"
		case "relay_blind_disabled":
			message = "Relay-blind execution is disabled"
		case "relay_blind_required_unavailable":
			message = "Relay-blind execution is unavailable"
		}
		writeRelayBlindError(w, code, message)
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
	// ArmDispatchWithRequestID returns a zero Reservation on error.
	heldBinding, heldPrivacy := reservation.ProviderBinding, reservation.PrivacyClass
	reservation, err = s.relayBlind.store.ArmDispatchWithRequestID(r.Context(), account.ID(), walletSession, authorization, internalRequestID, s.now())
	if err != nil {
		if quotaMetered {
			s.admission.RefundRequest(provider)
		}
		if errors.Is(err, relayblind.ErrReplay) {
			if code := s.privacyInvalidatedAuthorization(r.Context(), account.ID(), walletSession, authorization); code != "" {
				writePrivacyClassError(w, code, "")
				return
			}
		}
		// A slot wait can end after the reservation expired or its key or
		// session was invalidated. Those are retryable predispatch failures,
		// not replays, and the consumed row is burned.
		if errors.Is(err, relayblind.ErrReservationExpired) || errors.Is(err, relayblind.ErrKeyRevoked) || errors.Is(err, relayblind.ErrStaleSession) {
			code, privacyCode := relayBlindSessionLostCode(heldPrivacy)
			cleanupCtx, cancelCleanup := relayBlindCleanupContext()
			_ = s.relayBlind.store.RejectPredispatch(cleanupCtx, heldBinding, code, s.now())
			cancelCleanup()
			if privacyCode {
				writePrivacyClassError(w, code, "")
				return
			}
			writeRelayBlindError(w, code, "Relay-blind provider session or key expired")
			return
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
	// SPEC-022 R-14.3: under enforce the relay-blind route snapshot commits
	// before dispatch, and the dispatch carries its settlement metadata.
	var settlement *providerws.RelayBlindSettlementMetadata
	if s.settlementEnforceMode() {
		settlement, err = rec.recordRelayBlindRouteSnapshot(r.Context(), provider, reservation)
		if err != nil {
			s.log.Warn().Err(err).Str("request_id", rec.requestID).Str("provider_id", provider.ProviderID).Msg("relay-blind route snapshot failed before dispatch")
			_ = s.relayBlind.store.RejectArmedPredispatch(r.Context(), reservation.ProviderBinding, "relay_blind_required_unavailable", s.now())
			if quotaMetered {
				s.admission.RefundRequest(provider)
			}
			if reservation.PrivacyClass {
				writePrivacyClassError(w, privacyClassStale, "")
				return
			}
			writeRelayBlindError(w, "relay_blind_required_unavailable", "Relay-blind settlement could not be recorded before dispatch")
			return
		}
		// The gateway binds its settlement hold to this coordinator id. The
		// coverage marker is set only after the R-14 snapshot committed; the
		// gateway keeps it as a hint, and coordinator finality stays the
		// authority for recovery.
		w.Header().Set(internalRequestIDHeader, rec.requestID)
		w.Header().Set(relayBlindSettlementCoverageHeader, billing.RelayBlindCoverageEnforce)
	}
	rec.markProviderDispatched()
	ctx, cancel := context.WithTimeout(r.Context(), s.requestTimeout)
	defer cancel()
	relayContext := providerws.RelayBlindDispatchContext{
		ExecutionAuthDigest: reservation.ExecutionAuthDigest, EnvelopeDigest: reservation.EnvelopeDigest, KID: reservation.KID,
		ProviderBindingDigest: relayblind.BindingDigest(reservation.ProviderBinding), BuyerBindingDigest: relayblind.BindingDigest(reservation.BuyerBinding),
		AssignedSession: reservation.AssignedSession, RequestID: reservation.RequestID,
		InputTokenUpperBound: reservation.InputTokenUpperBound, MaxOutputTokens: reservation.MaxOutputTokens,
		Settlement: settlement,
	}
	var privacyVerifiedAt time.Time
	if reservation.PrivacyClass {
		relayContext.PrivacyClass = relayblind.PrivacyClassV1
		verifiedAt, code := s.privacyGate(r.Context(), provider, reservation.KeyRecordDigest)
		if code != "" {
			observed := privacyObservedCode(code, false)
			_ = s.relayBlind.store.RejectArmedPredispatch(r.Context(), reservation.ProviderBinding, observed, s.now())
			if quotaMetered {
				s.admission.RefundRequest(provider)
			}
			writePrivacyClassError(w, observed, "")
			return
		}
		privacyVerifiedAt = verifiedAt
	}
	relay, err := s.relayBlind.relay(ctx, provider, envelope.RequestID, body, envelope.Stream, relayContext)
	if err == nil {
		s.noteProviderAcceptedRequest(slotState)
	}
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
		s.recordRelayBlindUnknown(rec, provider, nil, nil, http.StatusInternalServerError, "Provider validation evidence was not accepted", reservation.PrivacyClass)
		writeRelayBlindError(w, "relay_blind_committed_failed", "Provider validation evidence was not accepted")
		return
	case <-ctx.Done():
		_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
		s.recordRelayBlindUnknown(rec, provider, nil, nil, http.StatusInternalServerError, "Provider validation evidence timed out", reservation.PrivacyClass)
		writeRelayBlindError(w, "relay_blind_committed_failed", "Provider validation evidence timed out")
		return
	}
	evidence := relayBlindEvidence(validation)
	if _, err := s.relayBlind.store.PersistEvidence(r.Context(), provider.ProviderID, provider.AssignedID, evidence, "", s.now()); err != nil {
		_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
		s.recordRelayBlindUnknown(rec, provider, nil, nil, http.StatusInternalServerError, "Provider validation evidence was not accepted", reservation.PrivacyClass)
		writeRelayBlindError(w, "relay_blind_committed_failed", "Provider validation evidence was not accepted")
		return
	}
	if validation.State == "rejected" {
		if quotaMetered {
			s.admission.RefundRequest(provider)
		}
		code, status := relayBlindRejectionStatus(validation.ErrorCode)
		zero := int64(0)
		_ = rec.logProviderRowWithEstimateAndOutput(provider, status, &zero, &zero, code, code, 0, nil, nil)
		if code == privacyClassDowngrade || code == privacyClassStale {
			writePrivacyClassError(w, code, "")
			return
		}
		writeRelayBlindError(w, code, "Provider rejected the relay-blind ciphertext before generation")
		return
	}
	rec.relayBlind.Outcome = "relay_blind_satisfied"
	w.Header().Set(relayBlindValidatedHeader, reservation.EnvelopeDigest)
	w.Header().Set(relayBlindInputTokensHeader, strconv.FormatInt(validation.InputTokens, 10))
	if reservation.PrivacyClass {
		// Gateway instances do not share memory. This dispatch-time
		// verification time is coordinator-to-gateway only.
		w.Header().Set(privacyClassHeader, relayblind.PrivacyClassV1)
		w.Header().Set(privacyPostureVerifiedAtHeader, strconv.FormatInt(privacyVerifiedAt.Unix(), 10))
	}
	if envelope.Stream {
		s.forwardRelayBlindStreaming(w, r, rec, provider, reservation, relay, validation.InputTokens)
		return
	}
	s.forwardRelayBlindNonStreaming(w, r, rec, provider, reservation, relay, validation.InputTokens)
}

func relayBlindRejectionStatus(code string) (string, int) {
	shape, ok := relayBlindErrors[code]
	if !ok || shape.Status == 0 {
		fallback := relayBlindErrors["relay_blind_required_unavailable"]
		return "relay_blind_required_unavailable", fallback.Status
	}
	return code, shape.Status
}

func relayBlindEvidence(value providerws.RelayBlindValidation) relayblind.Evidence {
	return relayblind.Evidence{ExecutionAuthDigest: value.ExecutionAuthDigest, EnvelopeDigest: value.EnvelopeDigest, KID: value.KID,
		ProviderBindingDigest: value.ProviderBindingDigest, BuyerBindingDigest: value.BuyerBindingDigest, AssignedSession: value.AssignedSession,
		RequestID: value.RequestID, State: value.State, InputTokens: value.InputTokens, InputTokenUpperBound: value.InputTokenUpperBound, MaxOutputTokens: value.MaxOutputTokens,
		ErrorCode: value.ErrorCode}
}

func (s *Server) forwardRelayBlindNonStreaming(w http.ResponseWriter, r *http.Request, rec *billingRecorder, provider pool.Provider, reservation relayblind.Reservation, relay *providerws.RelayStream, inputTokens int64) {
	var output bytes.Buffer
	responseDigest := newRelayBlindResponseDigest()
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
				responseDigest.write(chunk.Data)
			}
		case end := <-relay.Done:
			if end.RelayBlindValidation == nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Terminal provider evidence was missing", reservation.PrivacyClass)
				writeRelayBlindError(w, "relay_blind_committed_failed", "Terminal provider evidence was missing")
				return
			}
			completion, valid := boundedRelayBlindCompletion(end.Usage, reservation.MaxOutputTokens)
			if !valid {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Terminal provider usage was invalid", reservation.PrivacyClass)
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
			// SPEC-049 §4.8/R015: a privacy body is only the closed
			// privacy-response-v1 envelope. Clear content is never relayed.
			if reservation.PrivacyClass && status == http.StatusOK && relayblind.ValidatePrivacyResponseBody(output.Bytes()) != nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, privacyClassUnconfirmed, s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Privacy response shape was not accepted", true)
				writePrivacyClassError(w, privacyClassUnconfirmed, "")
				return
			}
			if _, err := s.relayBlind.store.PersistEvidence(r.Context(), provider.ProviderID, provider.AssignedID, terminal, code, s.now()); err != nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(r.Context(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Terminal provider evidence was not accepted", reservation.PrivacyClass)
				writeRelayBlindError(w, "relay_blind_committed_failed", "Terminal provider evidence was not accepted")
				return
			}
			prompt, complete := inputTokens, completion
			var settlementOutput *billing.SettlementOutput
			if rec.relayBlindSettlement != nil {
				// SPEC-022 R-3.5: the response-body digest, never a
				// plaintext output hash, for an R-14 attempt.
				settlementOutput = responseDigest.output(relayBlindTerminalState(end.Status), rec.relayBlindTerminalTimestamp(end))
			} else if reservation.PrivacyClass {
				settlementOutput = settlementOutputUnavailableFor(terminalStateFromAttempt(status, end.Error, code))
			} else {
				var validOutput bool
				settlementOutput, validOutput = settlementOutputFromChatResponseAt(output.Bytes(), terminalStateFromAttempt(status, end.Error, code), s.now().UnixMilli())
				if !validOutput {
					settlementOutput = settlementOutputUnavailableFor(terminalStateFromAttempt(status, end.Error, code))
				}
			}
			if err := rec.logProviderRowWithEstimateAndOutput(provider, status, &prompt, &complete, end.Error, code, 0, nil, settlementOutput); err != nil {
				writeRelayBlindError(w, "relay_blind_committed_failed", "Could not durably record relay-blind execution")
				return
			}
			if rec.relayBlindSettlement != nil {
				s.finishRelayBlindSettlement(w.Header(), rec, provider, reservation.ProviderBinding, end.RelayBlindSettlementReceipt)
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
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Provider relay failed after commit", reservation.PrivacyClass)
			writeRelayBlindError(w, "relay_blind_committed_failed", "Provider relay failed after commit")
			return
		case <-r.Context().Done():
			_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, nil, http.StatusInternalServerError, "Buyer disconnected during request", reservation.PrivacyClass)
			return
		}
	}
}

func (s *Server) forwardRelayBlindStreaming(w http.ResponseWriter, r *http.Request, rec *billingRecorder, provider pool.Provider, reservation relayblind.Reservation, relay *providerws.RelayStream, inputTokens int64) {
	w.Header().Set("Content-Type", "text/event-stream")
	responseDigest := newRelayBlindResponseDigest()
	if rec.relayBlindSettlement != nil {
		// The R-14 verdict is known only after the terminal frame, so it
		// travels as trailers (MAC'd for a negotiating gateway).
		if negotiatedSettlementFinality(rec) {
			declareNonStreamingSettlementTrailers(w.Header(), rec)
		} else {
			declareInternalSettlementOutcomeTrailers(w.Header(), rec)
		}
	}
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	tracker := newSettlementStreamOutputTracker()
	var streamedBytes int64
	var privacyStream *privacyStreamRelay
	if reservation.PrivacyClass {
		privacyStream = &privacyStreamRelay{gate: relayblind.PrivacyStreamGate{Model: reservation.Model}}
	}
	refusePrivacyStream := func() {
		relay.Cancel("privacy_response_invalid")
		_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, privacyClassUnconfirmed, s.now())
		s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Privacy response shape was not accepted", true)
		writeRelayBlindStreamError(w, privacyClassUnconfirmed, privacyErrorMessage(privacyClassUnconfirmed))
	}
	for {
		select {
		case chunk, ok := <-relay.Chunks:
			if ok {
				streamedBytes += int64(len(chunk.Data))
				responseDigest.write(chunk.Data)
				if streamedBytes > maxUpstreamResponseBodyBytes {
					relay.Cancel("response_byte_cap_exceeded")
					_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
					s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Provider response exceeded coordinator limit", reservation.PrivacyClass)
					return
				}
				data := chunk.Data
				if privacyStream != nil {
					accepted, err := privacyStream.accept(chunk.Data)
					if err != nil {
						refusePrivacyStream()
						return
					}
					data = accepted
				}
				n, writeErr := io.WriteString(w, data)
				if n > 0 && !reservation.PrivacyClass {
					_ = tracker.observeBlock([]byte(data[:n]))
				}
				if writeErr != nil {
					relay.Cancel("buyer_disconnected")
					_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
					s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateBuyerCancel), http.StatusOK, "Buyer disconnected during streaming", reservation.PrivacyClass)
					return
				}
				if flusher != nil {
					flusher.Flush()
				}
			}
		case end := <-relay.Done:
			if end.RelayBlindValidation == nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Terminal provider evidence was missing", reservation.PrivacyClass)
				return
			}
			completion, valid := boundedRelayBlindCompletion(end.Usage, reservation.MaxOutputTokens)
			if !valid {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_committed_failed", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Terminal provider usage was invalid", reservation.PrivacyClass)
				return
			}
			terminal := relayBlindEvidence(*end.RelayBlindValidation)
			terminal.CompletionTokens = completion
			code := ""
			status := http.StatusOK
			if end.Status != "complete" {
				code, status = "relay_blind_committed_failed", http.StatusInternalServerError
			}
			if privacyStream != nil && privacyStream.complete() != nil {
				refusePrivacyStream()
				return
			}
			if _, err := s.relayBlind.store.PersistEvidence(context.Background(), provider.ProviderID, provider.AssignedID, terminal, code, s.now()); err != nil {
				_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
				s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Terminal provider evidence was not accepted", reservation.PrivacyClass)
				return
			}
			prompt, complete := inputTokens, completion
			settlementOutput := tracker.output(terminalStateFromAttempt(status, end.Error, code))
			if rec.relayBlindSettlement != nil {
				settlementOutput = responseDigest.output(relayBlindTerminalState(end.Status), rec.relayBlindTerminalTimestamp(end))
			} else if reservation.PrivacyClass {
				settlementOutput = settlementOutputUnavailableFor(terminalStateFromAttempt(status, end.Error, code))
			}
			if err := rec.logProviderRowWithEstimateAndOutput(provider, status, &prompt, &complete, end.Error, code, 0, nil, settlementOutput); err == nil && rec.relayBlindSettlement != nil {
				s.finishRelayBlindSettlement(w.Header(), rec, provider, reservation.ProviderBinding, end.RelayBlindSettlementReceipt)
			}
			return
		case <-relay.Errors:
			_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateProviderError), http.StatusOK, "Provider relay failed after commit", reservation.PrivacyClass)
			return
		case <-r.Context().Done():
			relay.Cancel("buyer_disconnected")
			_ = s.relayBlind.store.MarkUnknownPostdispatch(context.Background(), reservation.ProviderBinding, "relay_blind_execution_uncertain", s.now())
			s.recordRelayBlindUnknown(rec, provider, &inputTokens, tracker.output(billing.TerminalStateBuyerCancel), http.StatusOK, "Buyer disconnected during streaming", reservation.PrivacyClass)
			return
		}
	}
}

func (s *Server) recordRelayBlindUnknown(rec *billingRecorder, provider pool.Provider, inputTokens *int64, output *billing.SettlementOutput, status int, message string, privacy bool) {
	var estimate *int64
	if privacy {
		// Privacy ciphertext is not a completion estimate. Bill the known
		// input and record a delivered-output estimate of zero.
		zero := int64(0)
		estimate = &zero
		terminal := billing.TerminalStateProviderError
		if output != nil && output.TerminalState != "" {
			terminal = output.TerminalState
		}
		output = settlementOutputUnavailableFor(terminal)
	} else if output != nil && output.Available {
		delivered := output.OutputPrefixEndByte - output.OutputPrefixStartByte
		estimate = s.estimatedCompletionTokensFromBytes(int(delivered))
		if estimate != nil && rec != nil && rec.relayBlind != nil && *estimate > rec.relayBlind.MaxOutputTokens {
			bounded := rec.relayBlind.MaxOutputTokens
			estimate = &bounded
		}
	}
	if rec != nil && rec.relayBlindSettlement != nil {
		// SPEC-022 R-3.5 / R-14.6: an R-14 attempt never persists a plaintext
		// output hash; without its terminal receipt it can only quarantine.
		terminal := billing.TerminalStateProviderError
		if output != nil && output.TerminalState != "" {
			terminal = output.TerminalState
		}
		output = settlementOutputUnavailableFor(terminal)
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
	enabled, privacyModels := s.privacyCapabilityModels(r.Context())
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{
		"version": "relay-blind-capabilities-v1",
		"models":  models,
		"privacy_class": map[string]any{
			"enabled": enabled,
			"models":  privacyModels,
		},
	})
}
