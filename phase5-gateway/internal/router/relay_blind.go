package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

const relayBlindEnvelopeVersionV1 = "relay-blind-request-v1"

const (
	relayBlindIDMaxBytes          = 128
	relayBlindOpaqueMaxBytes      = 256
	relayBlindCiphertextMaxBytes  = 1 << 20
	relayBlindTagMaxBytes         = 256
	relayBlindAuditDigestHexBytes = sha256.Size * 2
)

type relayBlindEnvelopeProbe struct {
	Version string `json:"version"`
	Mode    string `json:"mode"`
}

type relayBlindRequestEnvelope struct {
	Version                 string `json:"version"`
	Mode                    string `json:"mode"`
	EndpointFamily          string `json:"endpoint_family"`
	Model                   string `json:"model"`
	ProviderModel           string `json:"provider_model"`
	Stream                  *bool  `json:"stream"`
	RequestID               string `json:"request_id"`
	MaxOutputTokens         int64  `json:"max_output_tokens"`
	InputTokenUpperBound    int64  `json:"input_token_upper_bound"`
	ReservationTokenCap     int64  `json:"reservation_token_cap"`
	ProviderBinding         string `json:"provider_binding"`
	KeyRecordDigest         string `json:"key_record_digest"`
	KID                     string `json:"kid"`
	BuyerEphemeralPublicKey string `json:"buyer_ephemeral_public_key"`
	RequestReplayNonce      string `json:"request_replay_nonce"`
	IssuedAtUnix            int64  `json:"issued_at_unix"`
	Algorithm               string `json:"algorithm"`
	Ciphertext              string `json:"ciphertext"`
	Tag                     string `json:"tag"`
}

type relayBlindRouteReservationRequest struct {
	EndpointFamily        string `json:"endpoint_family"`
	Model                 string `json:"model"`
	Stream                *bool  `json:"stream"`
	MaxOutputTokens       int64  `json:"max_output_tokens"`
	InputTokenUpperBound  int64  `json:"input_token_upper_bound"`
	EncryptedRequestBytes int64  `json:"encrypted_request_bytes"`
}

func (s *Server) handleRelayBlindRouteReservations(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w.Header())
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	authn, ok := s.authenticateAny(w, r)
	if !ok {
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, s.cfg.Limits.RequestBodyBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return
	}
	if int64(len(body)) > s.cfg.Limits.RequestBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
		return
	}
	if authn.WalletSession != nil {
		if _, ok := s.requireWalletSessionSignature(w, r, walletCanonicalRouteForRequest(r), body); !ok {
			return
		}
	}
	if !contentEncodingSupported(r.Header.Values("Content-Encoding")) {
		writeSpec019PreflightError(w, http.StatusUnsupportedMediaType, "request_content_encoding_unsupported", "v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding` header; compressed request bodies are deferred to v0.2 per §10.", "Content-Encoding")
		return
	}
	if authn.WalletSession != nil && !s.admitRelayBlindWalletMetadata(w, r, authn.WalletSession, body) {
		return
	}
	req, err := decodeRelayBlindRouteReservation(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_route_reservation_invalid", err.Error())
		return
	}
	if s.cfg.Features.RelayBlindRequests.Enabled && req.EncryptedRequestBytes > s.cfg.Features.RelayBlindRequests.MaxEncryptedRequestBytes {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_route_reservation_invalid", "Relay-blind encrypted request exceeds configured size limit")
		return
	}
	if req.EndpointFamily != "chat_completions" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_endpoint_unsupported", "Relay-blind request encryption v0.1 supports chat_completions only")
		return
	}
	if !relayBlindModelIDValid(req.Model) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_route_reservation_invalid", "Invalid relay-blind route reservation")
		return
	}
	routeReservationCap, ok := relayBlindRouteReservationTokenCap(req.InputTokenUpperBound, req.MaxOutputTokens)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_route_reservation_invalid", "Invalid relay-blind route reservation")
		return
	}
	if authn.WalletSession != nil {
		if !writeRelayBlindWalletSessionPrecheck(w, authn.WalletSession.Session, req.Model, req.InputTokenUpperBound, req.MaxOutputTokens, routeReservationCap) {
			return
		}
	} else if relayBlindTokenBoundsInvalid(req.InputTokenUpperBound, req.MaxOutputTokens, routeReservationCap, relayBlindMaxOutputTokensForAuth(s, authn)) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_route_reservation_invalid", "Invalid relay-blind route reservation")
		return
	}
	// SPEC-041 v0.1 gateway slice has no provider-signed relay-blind key
	// evidence ingestion. Required mode therefore fails closed before quota
	// reservation or coordinator dispatch.
	if !s.cfg.Features.RelayBlindRequests.Enabled {
		writeError(w, http.StatusServiceUnavailable, "api_error", "relay_blind_disabled", "Relay-blind request encryption is disabled")
		return
	}
	writeError(w, http.StatusServiceUnavailable, "api_error", "relay_blind_required_unavailable", "Relay-blind route reservation is unavailable for this model; no reservation was created")
}

func decodeRelayBlindRouteReservation(body []byte) (relayBlindRouteReservationRequest, error) {
	var req relayBlindRouteReservationRequest
	if anthropicRawHasDuplicateKeys(body) {
		return req, errors.New("Invalid relay-blind route reservation: duplicate keys")
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&req); err != nil {
		return req, fmt.Errorf("Invalid relay-blind route reservation: %w", err)
	}
	if err := ensureSingleJSONValue(dec, "relay-blind route reservation"); err != nil {
		return req, err
	}
	if req.EndpointFamily == "" || strings.TrimSpace(req.Model) == "" || req.Stream == nil || req.MaxOutputTokens <= 0 || req.InputTokenUpperBound <= 0 || req.EncryptedRequestBytes <= 0 {
		return req, errors.New("Invalid relay-blind route reservation")
	}
	return req, nil
}

func (s *Server) rejectRelayBlindEnvelopeIfRequired(w http.ResponseWriter, r *http.Request, body []byte, accountID string, walletSession *walletSessionAuth) bool {
	probe, ok, malformed := parseRelayBlindEnvelopeProbe(body)
	if !ok {
		if malformed {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope is malformed")
			return true
		}
		return false
	}
	if walletSession != nil && !s.admitRelayBlindWalletMetadata(w, r, walletSession, body) {
		return true
	}
	if malformed || probe.Mode == "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope is malformed")
		return true
	}
	if probe.Mode != "required" {
		if walletSession == nil && !s.admitRelayBlindMetadataWrite(w, r, accountID) {
			return true
		}
		if err := s.recordRelayBlindAudit(r, accountID, relayBlindEndpointFamilyFromRequest(r), probe.Mode, "relay_blind_downgrade_rejected"); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind downgrade audit")
			return true
		}
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_downgrade_rejected", "Relay-blind request encryption v0.1 does not support opportunistic plaintext fallback")
		return true
	}
	endpointFamily := relayBlindEndpointFamilyFromRequest(r)
	enforceEncryptedSizeLimit := s.cfg.Features.RelayBlindRequests.Enabled
	env, err := s.validateRelayBlindRequestEnvelope(body, endpointFamily, enforceEncryptedSizeLimit)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", err.Error())
		return true
	}
	if walletSession != nil && !writeRelayBlindWalletSessionPrecheck(w, walletSession.Session, env.Model, env.InputTokenUpperBound, env.MaxOutputTokens, env.ReservationTokenCap) {
		return true
	}
	if walletSession == nil && relayBlindTokenBoundsInvalid(env.InputTokenUpperBound, env.MaxOutputTokens, env.ReservationTokenCap, relayBlindMaxOutputTokensForRequest(s, r)) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Invalid relay-blind request envelope")
		return true
	}
	if !s.relayBlindEnvelopeFresh(env) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope timestamp is outside the accepted freshness window")
		return true
	}
	walletSessionID := ""
	if walletSession != nil {
		walletSessionID = walletSession.Session.SessionID
	}
	replay := s.relayBlindReplayMaterial(accountID, walletSessionID, env, body)
	if s.rejectRelayBlindReplayIfSeen(w, r, replay) {
		return true
	}
	if walletSession == nil && !s.admitRelayBlindMetadataWrite(w, r, accountID) {
		return true
	}
	if !s.recordRelayBlindReplay(w, r, replay) {
		return true
	}
	if !s.cfg.Features.RelayBlindRequests.Enabled {
		if err := s.recordRelayBlindRequiredAudit(r, accountID, walletSessionID, endpointFamily, env, body, "relay_blind_disabled"); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind required-mode audit")
			return true
		}
		writeError(w, http.StatusServiceUnavailable, "api_error", "relay_blind_disabled", "Relay-blind request encryption is disabled")
		return true
	}
	if env.EndpointFamily != "chat_completions" {
		if err := s.recordRelayBlindRequiredAudit(r, accountID, walletSessionID, endpointFamily, env, body, "relay_blind_endpoint_unsupported"); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind required-mode audit")
			return true
		}
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_endpoint_unsupported", "Relay-blind request encryption v0.1 supports chat_completions only")
		return true
	}
	if err := s.recordRelayBlindRequiredAudit(r, accountID, walletSessionID, endpointFamily, env, body, "relay_blind_required_unavailable"); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind required-mode audit")
		return true
	}
	writeError(w, http.StatusServiceUnavailable, "api_error", "relay_blind_required_unavailable", "Relay-blind request encryption is unavailable for this model; any later attempt requires a fresh route reservation and envelope")
	return true
}

func (s *Server) handleRelayBlindResponsesDisabled(w http.ResponseWriter, r *http.Request) {
	s.handleRelayBlindEndpointDisabled(w, r, "responses")
}

func (s *Server) handleRelayBlindMessagesDisabled(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		s.handleNotFound(w, r)
		return
	}
	body, nonRelayTooLarge, err := readRelayBlindDisabledProbeBody(r, s.cfg.Limits.RequestBodyBytes)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return
	}
	probe, ok, malformed := parseRelayBlindEnvelopeProbe(body)
	if nonRelayTooLarge || (!ok && !malformed) {
		s.handleNotFound(w, r)
		return
	}
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		setNoStoreHeaders(w.Header())
		w.Header().Add("Vary", "Authorization")
		w.Header().Add("Vary", "X-Api-Key")
		w.Header().Add("Vary", "X-Demo-Token")
		writeAnthropicMessagesError(w, http.StatusUnauthorized, "authentication_error", "invalid_demo_token", "X-Demo-Token is not supported for /v1/messages")
		return
	}
	if strings.TrimSpace(r.Header.Get("Authorization")) == "" {
		if key := strings.TrimSpace(r.Header.Get("X-Api-Key")); key != "" {
			r = r.Clone(r.Context())
			r.Header.Set("Authorization", "Bearer "+key)
		}
	}
	adapter := newAnthropicMessagesAdapter(w, requestID(r), s.now)
	ctx := context.WithValue(r.Context(), anthropicMessagesAdapterContextKey{}, adapter)
	r = r.WithContext(ctx)
	r.Body = io.NopCloser(bytes.NewReader(body))
	s.handleRelayBlindEndpointDisabledBody(adapter, r, "messages", body, nonRelayTooLarge, probe, ok, malformed)
	adapter.finish()
}

func (s *Server) handleRelayBlindEndpointDisabled(w http.ResponseWriter, r *http.Request, endpointFamily string) {
	if r.Method != http.MethodPost {
		s.handleNotFound(w, r)
		return
	}
	body, nonRelayTooLarge, err := readRelayBlindDisabledProbeBody(r, s.cfg.Limits.RequestBodyBytes)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return
	}
	if nonRelayTooLarge {
		s.handleNotFound(w, r)
		return
	}
	probe, ok, malformed := parseRelayBlindEnvelopeProbe(body)
	s.handleRelayBlindEndpointDisabledBody(w, r, endpointFamily, body, nonRelayTooLarge, probe, ok, malformed)
}

func (s *Server) handleRelayBlindEndpointDisabledBody(w http.ResponseWriter, r *http.Request, endpointFamily string, body []byte, nonRelayTooLarge bool, probe relayBlindEnvelopeProbe, ok, malformed bool) {
	if nonRelayTooLarge {
		s.handleNotFound(w, r)
		return
	}
	if !ok {
		if malformed {
			authn, ok := s.authenticateRelayBlindEndpointDisabled(w, r, body)
			if !ok {
				return
			}
			if authn.WalletSession != nil && !s.admitRelayBlindWalletMetadata(w, r, authn.WalletSession, body) {
				return
			}
			writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope is malformed")
			return
		}
		s.handleNotFound(w, r)
		return
	}
	if int64(len(body)) > s.cfg.Limits.RequestBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
		return
	}
	if malformed || probe.Mode == "" {
		authn, ok := s.authenticateRelayBlindEndpointDisabled(w, r, body)
		if !ok {
			return
		}
		if authn.WalletSession != nil && !s.admitRelayBlindWalletMetadata(w, r, authn.WalletSession, body) {
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope is malformed")
		return
	}
	authn, authed := s.authenticateAny(w, r)
	if !authed {
		return
	}
	if authn.WalletSession != nil {
		if _, ok := s.requireWalletSessionSignature(w, r, walletCanonicalRouteForRequest(r), body); !ok {
			return
		}
	}
	if !contentEncodingSupported(r.Header.Values("Content-Encoding")) {
		writeSpec019PreflightError(w, http.StatusUnsupportedMediaType, "request_content_encoding_unsupported", "v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding` header; compressed request bodies are deferred to v0.2 per §10.", "Content-Encoding")
		return
	}
	if authn.WalletSession != nil && !s.admitRelayBlindWalletMetadata(w, r, authn.WalletSession, body) {
		return
	}
	if probe.Mode != "required" {
		if probe.Mode == "" || malformed {
			writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope is malformed")
			return
		}
		if authn.WalletSession == nil && !s.admitRelayBlindMetadataWrite(w, r, relayBlindAccountID(authn)) {
			return
		}
		if err := s.recordRelayBlindAudit(r, relayBlindAccountID(authn), endpointFamily, probe.Mode, "relay_blind_downgrade_rejected"); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind downgrade audit")
			return
		}
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_downgrade_rejected", "Relay-blind request encryption v0.1 does not support opportunistic plaintext fallback")
		return
	}
	env, err := s.validateRelayBlindRequestEnvelope(body, endpointFamily, s.cfg.Features.RelayBlindRequests.Enabled)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", err.Error())
		return
	}
	if authn.WalletSession != nil && !writeRelayBlindWalletSessionPrecheck(w, authn.WalletSession.Session, env.Model, env.InputTokenUpperBound, env.MaxOutputTokens, env.ReservationTokenCap) {
		return
	}
	if authn.WalletSession == nil && relayBlindTokenBoundsInvalid(env.InputTokenUpperBound, env.MaxOutputTokens, env.ReservationTokenCap, relayBlindMaxOutputTokensForAuth(s, authn)) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Invalid relay-blind request envelope")
		return
	}
	if !s.relayBlindEnvelopeFresh(env) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_envelope_invalid", "Relay-blind request envelope timestamp is outside the accepted freshness window")
		return
	}
	walletSessionID := ""
	if authn.WalletSession != nil {
		walletSessionID = authn.WalletSession.Session.SessionID
	}
	replay := s.relayBlindReplayMaterial(relayBlindAccountID(authn), walletSessionID, env, body)
	if s.rejectRelayBlindReplayIfSeen(w, r, replay) {
		return
	}
	if authn.WalletSession == nil && !s.admitRelayBlindMetadataWrite(w, r, relayBlindAccountID(authn)) {
		return
	}
	if !s.recordRelayBlindReplay(w, r, replay) {
		return
	}
	if !s.cfg.Features.RelayBlindRequests.Enabled {
		if err := s.recordRelayBlindRequiredAudit(r, relayBlindAccountID(authn), walletSessionID, endpointFamily, env, body, "relay_blind_disabled"); err != nil {
			writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind required-mode audit")
			return
		}
		writeError(w, http.StatusServiceUnavailable, "api_error", "relay_blind_disabled", "Relay-blind request encryption is disabled")
		return
	}
	if err := s.recordRelayBlindRequiredAudit(r, relayBlindAccountID(authn), walletSessionID, endpointFamily, env, body, "relay_blind_endpoint_unsupported"); err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind required-mode audit")
		return
	}
	writeError(w, http.StatusBadRequest, "invalid_request_error", "relay_blind_endpoint_unsupported", "Relay-blind request encryption v0.1 supports chat_completions only")
}

func readRelayBlindDisabledProbeBody(r *http.Request, limit int64) ([]byte, bool, error) {
	if limit < 0 {
		limit = 0
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, limit+1))
	if err != nil {
		return nil, false, err
	}
	if int64(len(body)) <= limit || relayBlindDisabledProbeBodyRelayShaped(body) {
		return body, false, nil
	}
	return body, true, nil
}

func relayBlindDisabledProbeBodyRelayShaped(body []byte) bool {
	return bytes.Contains(body, []byte(`"version"`)) || bytes.Contains(body, []byte(`"mode"`)) ||
		bytes.Contains(body, []byte(relayBlindEnvelopeVersionV1)) || bytes.Contains(body, []byte(`relay-blind-request-`))
}

func parseRelayBlindEnvelopeProbe(body []byte) (relayBlindEnvelopeProbe, bool, bool) {
	trimmed := bytes.TrimSpace(body)
	if len(trimmed) == 0 || trimmed[0] != '{' {
		if relayBlindRawSentinelPresent(trimmed) {
			return relayBlindEnvelopeProbe{}, true, true
		}
		return relayBlindEnvelopeProbe{}, false, false
	}

	probe, sawRelayVersion, sawRequiredMode, duplicateSentinel, malformedSentinel := scanRelayBlindSentinels(trimmed)
	if !sawRelayVersion {
		if sawRequiredMode {
			return probe, true, true
		}
		return relayBlindEnvelopeProbe{}, false, false
	}
	if malformedSentinel || duplicateSentinel {
		return relayBlindEnvelopeProbe{}, true, true
	}
	return probe, true, false
}

func scanRelayBlindSentinels(body []byte) (relayBlindEnvelopeProbe, bool, bool, bool, bool) {
	var probe relayBlindEnvelopeProbe
	dec := json.NewDecoder(bytes.NewReader(body))
	tok, err := dec.Token()
	if err != nil {
		return probe, false, false, false, false
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return probe, false, false, false, false
	}

	var versionCount, modeCount int
	var sawRelayVersion, sawRequiredMode, malformedSentinel bool
	rawRelayVersion := bytes.Contains(body, []byte(`relay-blind-request-`))
	rawRequiredMode := relayBlindRawRequiredModePresent(body)
	failMalformedIfRelayObserved := func() (relayBlindEnvelopeProbe, bool, bool, bool, bool) {
		relayObserved := sawRelayVersion || sawRequiredMode || rawRelayVersion || rawRequiredMode
		return probe, sawRelayVersion || rawRelayVersion, sawRequiredMode || rawRequiredMode, false, relayObserved
	}
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return failMalformedIfRelayObserved()
		}
		key, ok := keyTok.(string)
		if !ok {
			return failMalformedIfRelayObserved()
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return failMalformedIfRelayObserved()
		}
		switch key {
		case "version":
			versionCount++
			var version string
			if err := json.Unmarshal(raw, &version); err != nil {
				malformedSentinel = true
				continue
			}
			if strings.HasPrefix(version, "relay-blind-request-") {
				sawRelayVersion = true
				probe.Version = version
				if version != relayBlindEnvelopeVersionV1 {
					malformedSentinel = true
				}
			} else if probe.Version == "" {
				probe.Version = version
			}
		case "mode":
			modeCount++
			var mode string
			if err := json.Unmarshal(raw, &mode); err != nil {
				malformedSentinel = true
				continue
			}
			if mode == "required" {
				sawRequiredMode = true
				probe.Mode = mode
			} else if probe.Mode == "" {
				probe.Mode = mode
			}
		}
	}
	if _, err := dec.Token(); err != nil {
		return failMalformedIfRelayObserved()
	}
	if _, err := dec.Token(); err != io.EOF {
		return failMalformedIfRelayObserved()
	}
	duplicateSentinel := (versionCount > 1 || modeCount > 1) && (sawRelayVersion || sawRequiredMode)
	malformedSentinel = malformedSentinel && (sawRelayVersion || sawRequiredMode)
	return probe, sawRelayVersion, sawRequiredMode, duplicateSentinel, malformedSentinel
}

func relayBlindRawSentinelPresent(body []byte) bool {
	return bytes.Contains(body, []byte(`relay-blind-request-`)) || relayBlindRawRequiredModePresent(body)
}

func relayBlindRawRequiredModePresent(body []byte) bool {
	return bytes.Contains(body, []byte(`"mode"`)) && bytes.Contains(body, []byte(`required`))
}

func relayBlindEndpointFamilyFromRequest(r *http.Request) string {
	if responsesAdapterFromContext(r.Context()) != nil {
		return "responses"
	}
	if anthropicMessagesAdapterFromContext(r.Context()) != nil {
		return "messages"
	}
	return "chat_completions"
}

func relayBlindAccountID(authn authResult) string {
	if authn.Demo {
		return "demo:" + authn.DemoPayload.IP
	}
	if authn.WalletSession != nil {
		return authn.WalletSession.Session.AccountID
	}
	if authn.Bearer != nil {
		return authn.Bearer.AccountID
	}
	return ""
}

func (s *Server) authenticateRelayBlindEndpointDisabled(w http.ResponseWriter, r *http.Request, body []byte) (authResult, bool) {
	authn, ok := s.authenticateAny(w, r)
	if !ok {
		return authResult{}, false
	}
	if authn.WalletSession != nil {
		if _, ok := s.requireWalletSessionSignature(w, r, walletCanonicalRouteForRequest(r), body); !ok {
			return authResult{}, false
		}
	}
	return authn, true
}

func (s *Server) admitRelayBlindWalletMetadata(w http.ResponseWriter, r *http.Request, sessionAuth *walletSessionAuth, rawBody []byte) bool {
	bodyHash := sha256.Sum256(rawBody)
	headersHash, err := auth.SemanticHeadersSHA256Base64URL(walletCanonicalRouteForRequest(r), r.Header)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_invalid", "Wallet-session signature is invalid")
		return false
	}
	headersHashBytes, err := auth.DecodeBase64URLFixed(headersHash, sha256.Size)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "authentication_error", "wallet_session_signature_invalid", "Wallet-session signature is invalid")
		return false
	}
	err = s.store.AdmitWalletSessionMetadata(r.Context(), storage.WalletSessionMetadataAdmissionRequest{
		SessionID: sessionAuth.Session.SessionID,
		AccountID: sessionAuth.Session.AccountID,
		Replay: storage.WalletSessionReplayMaterial{
			SessionID:           sessionAuth.Session.SessionID,
			RequestID:           requestID(r),
			Method:              r.Method,
			CanonicalRoute:      walletCanonicalRouteForRequest(r),
			SemanticHeadersHash: headersHashBytes,
			RawBodyHash:         bodyHash[:],
			BodyBytes:           int64(len(rawBody)),
			MetadataClientIP:    s.clientIP(r),
		},
		WindowStart:    s.now().UTC().Add(-time.Minute),
		RateLimit:      s.cfg.Auth.WalletSessions.MetadataRequestsPerMinute,
		MaxReplayRows:  s.cfg.Auth.WalletSessions.ReplayMaxRowsPerSession,
		MaxReplayBytes: s.cfg.Auth.WalletSessions.ReplayMaxBytesPerSession,
		CreatedAt:      s.now().UTC(),
	})
	if err == nil {
		return true
	}
	s.recordWalletSessionAudit(r.Context(), sessionAuth.Session.AccountID, sessionAuth.Session.SessionID, "wallet_session_rejected", "gateway", map[string]any{
		"request_id":      requestID(r),
		"canonical_route": walletCanonicalRouteForRequest(r),
		"reason":          walletSessionAdmissionAuditReason(err),
	})
	s.writeWalletAdmissionError(w, err, storage.WalletSessionAdmissionDecision{})
	return false
}

func (s *Server) admitRelayBlindMetadataWrite(w http.ResponseWriter, r *http.Request, accountID string) bool {
	limit := s.relayBlindMetadataRequestsPerMinute()
	decision := s.relayBlindMetadataLimits.allow(accountID, limit, s.now())
	if decision.Admitted {
		return true
	}
	setConcurrencyRateLimitHeaders(w, decision.Limit, decision.Remaining, decision.RetryAfterSeconds, s.now())
	writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "relay_blind_metadata_rate_limited", "Relay-blind request metadata rate limit exceeded")
	return false
}

func (s *Server) relayBlindEnvelopeFresh(env relayBlindRequestEnvelope) bool {
	maxSkew := s.relayBlindTimestampMaxSkewSeconds()
	issuedAt := time.Unix(env.IssuedAtUnix, 0).UTC()
	now := s.now().UTC()
	skew := time.Duration(maxSkew) * time.Second
	return !issuedAt.Before(now.Add(-skew)) && !issuedAt.After(now.Add(skew))
}

func (s *Server) relayBlindReplayMaterial(accountID, walletSessionID string, env relayBlindRequestEnvelope, body []byte) storage.RelayBlindReplayMaterial {
	digest := sha256.Sum256(body)
	nonceDigest := relayBlindMetadataDigest(env.RequestReplayNonce)
	buyerKeyDigest := relayBlindMetadataDigest(env.BuyerEphemeralPublicKey)
	providerBindingDigest := relayBlindMetadataDigest(env.ProviderBinding)
	kidDigest := relayBlindMetadataDigest(env.KID)
	now := s.now().UTC()
	return storage.RelayBlindReplayMaterial{
		AccountID:                     accountID,
		WalletSessionID:               walletSessionID,
		RequestID:                     env.RequestID,
		RequestReplayNonceDigest:      nonceDigest[:],
		BuyerEphemeralPublicKeyDigest: buyerKeyDigest[:],
		ProviderBindingDigest:         providerBindingDigest[:],
		KIDDigest:                     kidDigest[:],
		EnvelopeDigest:                digest[:],
		EnvelopeBytes:                 int64(len(body)),
		RetentionExpiresAt:            now.Add(time.Duration(s.relayBlindReplayRetentionSeconds()) * time.Second),
		MaxReplayRows:                 s.relayBlindReplayMaxRowsPerAccount(),
		MaxReplayBytes:                s.relayBlindReplayMaxBytesPerAccount(),
		CreatedAt:                     now,
	}
}

func (s *Server) rejectRelayBlindReplayIfSeen(w http.ResponseWriter, r *http.Request, replay storage.RelayBlindReplayMaterial) bool {
	seen, err := s.store.RelayBlindReplaySeen(r.Context(), replay)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not read relay-blind replay state")
		return true
	}
	if seen {
		writeError(w, http.StatusConflict, "invalid_request_error", "relay_blind_replay", "Relay-blind request envelope was already seen in the replay retention window")
		return true
	}
	return false
}

func (s *Server) recordRelayBlindReplay(w http.ResponseWriter, r *http.Request, replay storage.RelayBlindReplayMaterial) bool {
	err := s.store.RecordRelayBlindReplay(r.Context(), replay)
	if err == nil {
		return true
	}
	if errors.Is(err, storage.ErrRelayBlindReplay) {
		writeError(w, http.StatusConflict, "invalid_request_error", "relay_blind_replay", "Relay-blind request envelope was already seen in the replay retention window")
		return false
	}
	if errors.Is(err, storage.ErrRateLimit) {
		setConcurrencyRateLimitHeaders(w, s.relayBlindMetadataRequestsPerMinute(), 0, s.relayBlindReplayRetentionSeconds(), s.now())
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "relay_blind_metadata_rate_limited", "Relay-blind request metadata rate limit exceeded")
		return false
	}
	writeError(w, http.StatusInternalServerError, "server_error", "internal_error", "Could not record relay-blind replay state")
	return false
}

func (s *Server) recordRelayBlindAudit(r *http.Request, accountID, endpointFamily, _ string, reason string) error {
	payload, err := json.Marshal(map[string]any{
		"endpoint_family":        endpointFamily,
		"mode_class":             "non_required",
		"requested_privacy_mode": "relay_blind_required",
		"effective_outcome":      "relay_blind_unavailable",
		"reason":                 reason,
	})
	if err != nil {
		payload = []byte(`{"payload_error":"marshal_failed"}`)
	}
	return s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
		EventID:   mustID("audit"),
		RequestID: requestID(r),
		AccountID: accountID,
		Actor:     "gateway",
		Type:      reason,
		Payload:   string(payload),
		CreatedAt: s.now().UTC(),
	})
}

func (s *Server) recordRelayBlindRequiredAudit(r *http.Request, accountID, walletSessionID, endpointFamily string, env relayBlindRequestEnvelope, body []byte, reason string) error {
	envelopeDigest := sha256.Sum256(body)
	payload, err := json.Marshal(map[string]any{
		"endpoint_family":        endpointFamily,
		"mode_class":             "required",
		"requested_privacy_mode": "relay_blind_required",
		"effective_outcome":      "relay_blind_unavailable",
		"model":                  env.Model,
		"wallet_session_id":      walletSessionID,
		"provider_binding":       env.ProviderBinding,
		"kid":                    env.KID,
		"envelope_digest":        hex.EncodeToString(envelopeDigest[:]),
		"reason_code":            reason,
	})
	if err != nil {
		payload = []byte(`{"payload_error":"marshal_failed"}`)
	}
	return s.store.InsertAuditEvent(r.Context(), storage.AuditEvent{
		EventID:   mustID("audit"),
		RequestID: requestID(r),
		AccountID: accountID,
		Actor:     "gateway",
		Type:      "relay_blind_required_rejected",
		Payload:   string(payload),
		CreatedAt: s.now().UTC(),
	})
}

func writeRelayBlindWalletSessionPrecheck(w http.ResponseWriter, session storage.WalletSession, model string, inputTokenUpperBound, maxOutputTokens, reservationTokenCap int64) bool {
	if _, ok := walletModelAllowlist(session)[model]; !ok {
		writeError(w, http.StatusForbidden, "permission_error", "wallet_session_model_not_allowed", "Wallet session does not allow this model")
		return false
	}
	if relayBlindWalletSessionCapExceeded(session.PerRequestTokenCap, inputTokenUpperBound, maxOutputTokens, reservationTokenCap) {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "wallet_session_request_cap_exceeded", "Wallet-session per-request cap exceeded")
		return false
	}
	return true
}

func relayBlindWalletSessionCapExceeded(cap, inputTokenUpperBound, maxOutputTokens, reservationTokenCap int64) bool {
	if cap <= 0 || inputTokenUpperBound <= 0 || maxOutputTokens <= 0 || reservationTokenCap <= 0 {
		return true
	}
	if inputTokenUpperBound > cap || maxOutputTokens > cap-inputTokenUpperBound {
		return true
	}
	return reservationTokenCap > cap
}

func relayBlindRouteReservationTokenCap(inputTokenUpperBound, maxOutputTokens int64) (int64, bool) {
	if inputTokenUpperBound <= 0 || maxOutputTokens <= 0 || inputTokenUpperBound > math.MaxInt64-maxOutputTokens {
		return 0, false
	}
	return inputTokenUpperBound + maxOutputTokens, true
}

func relayBlindTokenBoundsInvalid(inputTokenUpperBound, maxOutputTokens, reservationTokenCap, maxOutputLimit int64) bool {
	if inputTokenUpperBound <= 0 || maxOutputTokens <= 0 || reservationTokenCap <= 0 || maxOutputLimit <= 0 {
		return true
	}
	if maxOutputTokens > maxOutputLimit || inputTokenUpperBound > math.MaxInt64-maxOutputTokens {
		return true
	}
	return reservationTokenCap < inputTokenUpperBound+maxOutputTokens
}

func relayBlindMaxOutputTokensForAuth(s *Server, authn authResult) int64 {
	if authn.Demo {
		return s.cfg.Limits.DemoMaxTokensPerRequest
	}
	return s.cfg.Limits.MaxTokensPerRequest
}

func relayBlindMaxOutputTokensForRequest(s *Server, r *http.Request) int64 {
	if strings.TrimSpace(r.Header.Get("X-Demo-Token")) != "" {
		return s.cfg.Limits.DemoMaxTokensPerRequest
	}
	return s.cfg.Limits.MaxTokensPerRequest
}

func (s *Server) relayBlindMetadataRequestsPerMinute() int {
	if s.cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute > 0 {
		return s.cfg.Features.RelayBlindRequests.MetadataRequestsPerMinute
	}
	return config.Default().Features.RelayBlindRequests.MetadataRequestsPerMinute
}

func (s *Server) relayBlindTimestampMaxSkewSeconds() int {
	if s.cfg.Features.RelayBlindRequests.TimestampMaxSkewSeconds > 0 {
		return s.cfg.Features.RelayBlindRequests.TimestampMaxSkewSeconds
	}
	return config.Default().Features.RelayBlindRequests.TimestampMaxSkewSeconds
}

func (s *Server) relayBlindReplayRetentionSeconds() int {
	if s.cfg.Features.RelayBlindRequests.ReplayRetentionSeconds > 0 {
		return s.cfg.Features.RelayBlindRequests.ReplayRetentionSeconds
	}
	return config.Default().Features.RelayBlindRequests.ReplayRetentionSeconds
}

func (s *Server) relayBlindReplayMaxRowsPerAccount() int {
	if s.cfg.Features.RelayBlindRequests.ReplayMaxRowsPerAccount > 0 {
		return s.cfg.Features.RelayBlindRequests.ReplayMaxRowsPerAccount
	}
	return config.Default().Features.RelayBlindRequests.ReplayMaxRowsPerAccount
}

func (s *Server) relayBlindReplayMaxBytesPerAccount() int64 {
	if s.cfg.Features.RelayBlindRequests.ReplayMaxBytesPerAccount > 0 {
		return s.cfg.Features.RelayBlindRequests.ReplayMaxBytesPerAccount
	}
	return config.Default().Features.RelayBlindRequests.ReplayMaxBytesPerAccount
}

func relayBlindModelIDValid(value string) bool {
	if value == "" || value != strings.TrimSpace(value) || len(value) > relayBlindIDMaxBytes {
		return false
	}
	for _, ch := range value {
		if (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || (ch >= '0' && ch <= '9') ||
			ch == '_' || ch == '-' || ch == '.' || ch == '/' || ch == ':' {
			continue
		}
		return false
	}
	return true
}

func relayBlindMetadataDigest(value string) [sha256.Size]byte {
	return sha256.Sum256([]byte(value))
}

func relayBlindVisibleASCII(value string, maxBytes int) bool {
	if value == "" || value != strings.TrimSpace(value) || len(value) > maxBytes {
		return false
	}
	for _, ch := range value {
		if ch < 0x21 || ch > 0x7e {
			return false
		}
	}
	return true
}

func relayBlindEnvelopeMetadataValid(env relayBlindRequestEnvelope) bool {
	return relayBlindVisibleASCII(env.RequestID, relayBlindIDMaxBytes) &&
		relayBlindVisibleASCII(env.ProviderBinding, relayBlindOpaqueMaxBytes) &&
		relayBlindVisibleASCII(env.KeyRecordDigest, relayBlindOpaqueMaxBytes) &&
		relayBlindVisibleASCII(env.KID, relayBlindIDMaxBytes) &&
		relayBlindVisibleASCII(env.BuyerEphemeralPublicKey, relayBlindOpaqueMaxBytes) &&
		relayBlindVisibleASCII(env.RequestReplayNonce, relayBlindIDMaxBytes) &&
		relayBlindVisibleASCII(env.Ciphertext, relayBlindCiphertextMaxBytes) &&
		relayBlindVisibleASCII(env.Tag, relayBlindTagMaxBytes)
}

func (s *Server) validateRelayBlindRequestEnvelope(body []byte, routeEndpointFamily string, enforceEncryptedSizeLimit bool) (relayBlindRequestEnvelope, error) {
	var env relayBlindRequestEnvelope
	if anthropicRawHasDuplicateKeys(body) {
		return env, errors.New("Invalid relay-blind request envelope: duplicate keys")
	}
	dec := json.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&env); err != nil {
		return env, fmt.Errorf("Invalid relay-blind request envelope: %w", err)
	}
	if err := ensureSingleJSONValue(dec, "relay-blind request envelope"); err != nil {
		return env, err
	}
	if env.Version != relayBlindEnvelopeVersionV1 {
		return env, errors.New("Invalid relay-blind request envelope version")
	}
	if env.Mode != "required" {
		return env, errors.New("Invalid relay-blind request mode")
	}
	if env.EndpointFamily != routeEndpointFamily {
		return env, errors.New("Relay-blind request envelope is inconsistent with the request route")
	}
	if strings.TrimSpace(env.Model) == "" ||
		strings.TrimSpace(env.ProviderModel) == "" ||
		strings.TrimSpace(env.RequestID) == "" ||
		strings.TrimSpace(env.ProviderBinding) == "" ||
		strings.TrimSpace(env.KeyRecordDigest) == "" ||
		strings.TrimSpace(env.KID) == "" ||
		strings.TrimSpace(env.BuyerEphemeralPublicKey) == "" ||
		strings.TrimSpace(env.RequestReplayNonce) == "" ||
		strings.TrimSpace(env.Ciphertext) == "" ||
		strings.TrimSpace(env.Tag) == "" {
		return env, errors.New("Invalid relay-blind request envelope")
	}
	if !relayBlindModelIDValid(env.Model) || !relayBlindModelIDValid(env.ProviderModel) {
		return env, errors.New("Invalid relay-blind request envelope")
	}
	if !relayBlindEnvelopeMetadataValid(env) {
		return env, errors.New("Invalid relay-blind request envelope")
	}
	if env.Stream == nil || env.MaxOutputTokens <= 0 || env.InputTokenUpperBound <= 0 || env.ReservationTokenCap <= 0 || env.IssuedAtUnix <= 0 {
		return env, errors.New("Invalid relay-blind request envelope")
	}
	if env.InputTokenUpperBound > math.MaxInt64-env.MaxOutputTokens || env.ReservationTokenCap < env.InputTokenUpperBound+env.MaxOutputTokens {
		return env, errors.New("Invalid relay-blind request envelope")
	}
	if env.Algorithm != "x25519-hkdf-sha256-a256gcm-v1" {
		return env, errors.New("Unsupported relay-blind request algorithm")
	}
	if enforceEncryptedSizeLimit && int64(len(env.Ciphertext)+len(env.Tag)) > s.cfg.Features.RelayBlindRequests.MaxEncryptedRequestBytes {
		return env, errors.New("Relay-blind encrypted request exceeds configured size limit")
	}
	return env, nil
}

func ensureSingleJSONValue(dec *json.Decoder, artifact string) error {
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		if err == nil {
			return fmt.Errorf("Invalid %s: multiple JSON values", artifact)
		}
		return fmt.Errorf("Invalid %s: %w", artifact, err)
	}
	return nil
}
