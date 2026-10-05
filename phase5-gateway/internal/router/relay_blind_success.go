package router

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-gateway/internal/relayblind"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

const relayBlindValidatedHeader = "X-MacProvider-Relay-Blind-Validated"
const relayBlindExecutionHeader = "X-MacProvider-Relay-Blind-Execution-Authorization"
const relayBlindRequestedHeader = "X-MacProvider-Requested-Privacy-Mode"
const relayBlindEffectiveHeader = "X-MacProvider-Effective-Privacy-Outcome"
const relayBlindScope = "request_content_hidden_from_relays; provider_reads_request; responses_visible_to_relays"

type relayBlindContextKey struct{}
type relayBlindExecution struct {
	Metadata storage.RelayBlindMetadata
	Privacy  *privacyUsageContext
}

func relayBlindExecutionFor(r *http.Request) *relayBlindExecution {
	v, _ := r.Context().Value(relayBlindContextKey{}).(*relayBlindExecution)
	return v
}
func relayBlindMetadataFor(r *http.Request) *storage.RelayBlindMetadata {
	if v := relayBlindExecutionFor(r); v != nil {
		m := v.Metadata
		return &m
	}
	return nil
}
func relayBlindHeaders(h http.Header, satisfied bool) {
	h.Set(relayBlindRequestedHeader, "relay_blind_required")
	outcome := "relay_blind_unavailable"
	if satisfied {
		outcome = "relay_blind_satisfied"
	}
	h.Set(relayBlindEffectiveHeader, outcome)
	h.Set("X-MacProvider-Request-Encryption-Scope", relayBlindScope)
	h.Del("X-Provider-Id")
	h.Del("X-MacProvider-Receipt")
}
func relayBlindOutcomeMetadata(h http.Header, code string) map[string]any {
	if h.Get(relayBlindRequestedHeader) != "relay_blind_required" {
		return nil
	}
	return map[string]any{"requested_privacy_mode": "relay_blind_required", "effective_privacy_outcome": h.Get(relayBlindEffectiveHeader), "scope": relayBlindScope, "retry_action": relayBlindRetryAction(h, code), "settlement": relayBlindDisclosureUnavailable().Settlement}
}
func relayBlindRetryAction(h http.Header, code string) string {
	switch code {
	case "relay_blind_replay", "relay_blind_committed_failed", privacyClassUnconfirmed:
		return "do_not_resubmit"
	case privacyClassStale:
		return "new_reservation_and_envelope"
	case privacyClassDisabled, privacyClassUnavailable, privacyClassDowngrade:
		return "none"
	}
	if code != "" && (gatewayRetryable(code) || h.Get("X-MacProvider-Relay-Blind-Retry-Action") == "new_reservation_and_envelope") {
		return "new_reservation_and_envelope"
	}
	return "none"
}
func relayBlindPoolSelected(r *http.Request) bool {
	// An engine selector is a routing control too (SPEC-006-R016 rule 6).
	for _, name := range []string{poolSelectHeader, poolEmitHeader, engineSelectHeader} {
		for _, v := range r.Header.Values(name) {
			if strings.TrimSpace(v) != "" {
				return true
			}
		}
	}
	return false
}

// Internal requests are built from an empty header set: browser-supplied routing,
// wallet identity, execution authority, and credentials cannot cross this boundary.
func (s *Server) relayBlindUpstream(r *http.Request, method, path, account, session string, body []byte, privacy bool) (*http.Response, error) {
	req, err := http.NewRequestWithContext(r.Context(), method, strings.TrimRight(s.coordinatorBuyerURL(), "/")+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
	req.Header.Set("X-MacProvider-Account", account)
	req.Header.Set("X-Request-ID", requestID(r))
	if session != "" {
		req.Header.Set("X-MacProvider-Wallet-Session", session)
	}
	if privacy {
		req.Header.Set(privacyClassHeader, privacyClassV1)
	}
	client := *s.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	return client.Do(req)
}
func readRelayBlindUpstream(resp *http.Response) ([]byte, error) {
	defer resp.Body.Close()
	b, e := io.ReadAll(io.LimitReader(resp.Body, 64<<10+1))
	if e != nil || len(b) > 64<<10 {
		return nil, errors.New("invalid relay metadata response")
	}
	return b, nil
}
func writeRelayBlindUpstreamError(w http.ResponseWriter, resp *http.Response, body []byte) {
	var wire struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if json.Unmarshal(body, &wire) == nil && privacyClassKnown(wire.Error.Code) {
		writePrivacyClassError(w, wire.Error.Code, "")
		return
	}
	if json.Unmarshal(body, &wire) == nil && strings.HasPrefix(wire.Error.Code, "relay_blind_") {
		_, retryableCode := gatewayRetryableByCode[wire.Error.Code]
		_, permanentCode := gatewayPermanentCodes[wire.Error.Code]
		if retryableCode || permanentCode {
			writeError(w, resp.StatusCode, "api_error", wire.Error.Code, "Relay-blind transaction rejected; do not reuse its envelope")
			return
		}
	}
	writeError(w, http.StatusServiceUnavailable, "api_error", "relay_blind_required_unavailable", "Relay-blind transaction is unavailable")
}
func (s *Server) reserveRelayBlindRoute(w http.ResponseWriter, r *http.Request, authn authResult, req relayBlindRouteReservationRequest, privacy bool) {
	accountID := relayBlindAccountID(authn)
	if privacy && privacyBuyerIntentDenied(r, accountID, authn.Demo) {
		writePrivacyClassError(w, privacyClassDowngrade, privacyIntentDowngradeMessage(r, accountID, authn.Demo))
		return
	}
	if authn.Demo || relayBlindPoolSelected(r) {
		writeError(w, 400, "invalid_request_error", "relay_blind_downgrade_rejected", "Relay-blind pilot requires an authenticated global route")
		return
	}
	if authn.WalletSession == nil && !s.admitRelayBlindMetadataWrite(w, r, relayBlindAccountID(authn)) {
		return
	}
	body, _ := json.Marshal(req)
	session := ""
	if authn.WalletSession != nil {
		session = authn.WalletSession.Session.SessionID
	}
	resp, err := s.relayBlindUpstream(r, http.MethodPost, "/v1/relay-blind/route-reservations", relayBlindAccountID(authn), session, body, privacy)
	if err != nil {
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind route reservation is unavailable")
		return
	}
	data, err := readRelayBlindUpstream(resp)
	if err != nil {
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind route reservation is unavailable")
		return
	}
	if resp.StatusCode != 200 {
		writeRelayBlindUpstreamError(w, resp, data)
		return
	}
	reservation, err := relayblind.ParseReservationResponse(data)
	if err != nil || reservation.Model != req.Model || reservation.Stream != *req.Stream || reservation.MaxOutputTokens != req.MaxOutputTokens || reservation.InputTokenUpperBound != req.InputTokenUpperBound || reservation.ExpiresAtUnix <= s.now().Unix() || reservation.ExpiresAtUnix > s.now().Add(30*time.Second).Unix() || reservation.MaxEncryptedRequestBytes < uint64(req.EncryptedRequestBytes) {
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind reservation evidence is invalid")
		return
	}
	if privacy != (reservation.Version == relayblind.PrivacyReservationVersion) {
		writePrivacyClassError(w, privacyClassUnavailable, "")
		return
	}
	// Re-encoding the closed type guarantees no extra internal response fields leak.
	writeJSON(w, 200, reservation)
}

// dispatchRelayBlindChat joins the ordinary quota/concurrency and response
// settlement owners, without passing ciphertext through the plaintext parser,
// prompt estimator, id-less dedupe, model rewriter, or retry loop.
func (s *Server) dispatchRelayBlindChat(w http.ResponseWriter, r *http.Request, raw []byte, account string, sessionAuth *walletSessionAuth) {
	present, valid := privacyRequested(r)
	if present && privacyBuyerIntentDenied(r, account, false) {
		writePrivacyClassError(w, privacyClassDowngrade, privacyIntentDowngradeMessage(r, account, false))
		return
	}
	if present && !valid {
		writePrivacyClassError(w, privacyClassDowngrade, "")
		return
	}
	if present && !s.privacyClassEnabled() {
		writePrivacyClassError(w, privacyClassDisabled, "")
		return
	}
	privacy := present
	env, err := relayblind.ParseEnvelope(raw)
	if err != nil {
		writeError(w, 400, "invalid_request_error", "relay_blind_envelope_invalid", "Invalid relay-blind envelope")
		return
	}
	if !privacy && (relayBlindPoolSelected(r) || strings.HasPrefix(account, "demo:")) {
		writeError(w, 400, "invalid_request_error", "relay_blind_downgrade_rejected", "Relay-blind pilot requires an authenticated global route")
		return
	}
	if env.RequestID != requestID(r) {
		writeError(w, 400, "invalid_request_error", "relay_blind_envelope_invalid", "Envelope request ID must match X-Request-ID")
		return
	}
	session := ""
	if sessionAuth != nil {
		session = sessionAuth.Session.SessionID
	}
	w.Header().Set("X-MacProvider-Relay-Blind-Retry-Action", "new_reservation_and_envelope")
	resp, err := s.relayBlindUpstream(r, http.MethodPost, "/v1/relay-blind/consume", account, session, raw, privacy)
	if err != nil {
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind consumption is unavailable; do not reuse the envelope")
		return
	}
	data, err := readRelayBlindUpstream(resp)
	if err != nil {
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind consumption is unavailable")
		return
	}
	if resp.StatusCode != 200 {
		writeRelayBlindUpstreamError(w, resp, data)
		return
	}
	consumed, err := relayblind.ParseConsumeResponse(data)
	digest := sha256.Sum256(raw)
	digestText := base64.RawURLEncoding.EncodeToString(digest[:])
	if err != nil || consumed.ProviderBinding != env.ProviderBinding || consumed.BuyerBinding != env.BuyerBinding || consumed.EnvelopeDigest != digestText || consumed.ExpiresAtUnix <= s.now().Unix() {
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind consumption evidence is invalid")
		return
	}
	bindingDigest := sha256.Sum256([]byte(env.ProviderBinding))
	execution := &relayBlindExecution{Metadata: storage.RelayBlindMetadata{RequestedPrivacyMode: "relay_blind_required", EffectivePrivacyOutcome: "relay_blind_unavailable", EnvelopeDigest: digestText, KeyRecordDigest: env.KeyRecordDigest, KID: env.KID, ProviderBindingDigest: base64.RawURLEncoding.EncodeToString(bindingDigest[:]), InputTokenUpperBound: env.InputTokenUpperBound, MaxOutputTokens: env.MaxOutputTokens}}
	r = r.WithContext(context.WithValue(r.Context(), relayBlindContextKey{}, execution))
	if !s.admitChatStart(w, r, account) {
		return
	}
	now := s.now().UTC()
	window := now.Format("2006-01-02")
	subject := usageSubject{AccountID: account, WalletSessionID: session, ReservationCreatedAt: now}
	daily := s.effectiveAccountDailyQuota(r.Context())
	var decision storage.QuotaDecision
	var walletDecision storage.WalletSessionAdmissionDecision
	if sessionAuth != nil {
		walletDecision, err = s.admitWalletSessionInference(r, sessionAuth, raw, env.Model, env.ReservationTokenCap, daily, window, now, now.Add(time.Duration(s.cfg.Quotas.ReservationMaxAgeHours)*time.Hour))
		decision = walletDecision.AccountQuota
	} else {
		decision, err = s.store.ReserveQuota(r.Context(), storage.ReservationRequest{AccountID: account, RequestID: requestID(r), WindowDate: window, RequestedTokens: env.ReservationTokenCap, DailyQuota: daily, CreatedAt: now, ExpiresAt: now.Add(time.Duration(s.cfg.Quotas.ReservationMaxAgeHours) * time.Hour), RelayBlind: relayBlindMetadataFor(r)})
	}
	if err != nil {
		if decision.Admitted {
			_ = s.refundWalletAwareReservation(subject, requestID(r))
		}
		if sessionAuth != nil {
			s.writeWalletAdmissionError(w, err, walletDecision)
		} else if errors.Is(err, storage.ErrQuotaExceeded) {
			writeError(w, 429, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
		} else {
			writeError(w, 409, "invalid_request_error", "duplicate_request_id", "Request cannot reserve quota")
		}
		return
	}
	setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
	deadlines := newRequestDeadlines(r.Context())
	defer deadlines.Stop()
	bound := s.cfg.NonStreamRequestTimeout()
	if env.Stream {
		bound = s.effectiveStreamCeiling(env.MaxOutputTokens, false)
		deadlines.armCeiling(bound)
	} else {
		deadlines.armPhaseFromStart(deadlinePhaseNonStreamWall, bound)
	}
	if _, err = s.store.AcquireConcurrency(r.Context(), storage.ConcurrencyRequest{AccountID: account, RequestID: requestID(r), Limit: s.cfg.Quotas.AccountConcurrency, CreatedAt: now, ExpiresAt: now.Add(bound + time.Minute)}); err != nil {
		_ = s.refundWalletAwareReservation(subject, requestID(r))
		writeError(w, 429, "rate_limit_exceeded", "account_concurrency_exceeded", "Account concurrency exceeded")
		return
	}
	defer s.store.ReleaseConcurrency(context.Background(), account, requestID(r), s.now())
	if sessionAuth != nil {
		if err = s.store.ArmWalletSessionDispatch(r.Context(), storage.WalletSessionDispatchArm{SessionID: session, AccountID: account, RequestID: requestID(r), CanonicalRoute: walletCanonicalRouteForRequest(r), ArmedAt: s.now().UTC()}); err != nil {
			_ = s.refundWalletAwareReservation(subject, requestID(r))
			s.writeWalletAdmissionError(w, err, walletDecision)
			return
		}
	}
	up, err := http.NewRequestWithContext(deadlines.Context(), http.MethodPost, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/chat/completions", bytes.NewReader(raw))
	if err != nil {
		_ = s.refundWalletAwareReservation(subject, requestID(r))
		writeError(w, 503, "api_error", "relay_blind_required_unavailable", "Relay-blind dispatch unavailable")
		return
	}
	up.Header.Set("Content-Type", "application/json")
	// SPEC-022 R-12.8: bearer, account, request id and the signed-finality
	// capability, set together; subject.AccountID is account.
	s.setCoordinatorChatContext(up.Header, r, subject.AccountID)
	up.Header.Set(relayBlindExecutionHeader, consumed.ExecutionAuthorization)
	// Chat is not built by relayBlindUpstream. Stamp the trusted marker on
	// this empty header set; buyer-supplied copies never reach it.
	if privacy {
		up.Header.Set(privacyClassHeader, privacyClassV1)
	}
	if session != "" {
		up.Header.Set("X-MacProvider-Wallet-Session", session)
	}
	// A crash after sending must leave a durable row in the existing recovery
	// scan. Arming before the network side effect also covers API-key buyers.
	if sessionAuth == nil {
		armCtx, armCancel := context.WithTimeout(context.Background(), 5*time.Second)
		armErr := s.store.MarkReservationSettlementHold(armCtx, subject.AccountID, requestID(r))
		armCancel()
		if armErr != nil {
			_ = s.refundWalletAwareReservation(subject, requestID(r))
			writeError(w, 500, "server_error", "settlement_failed", "Could not arm relay-blind recovery")
			return
		}
	}
	w.Header().Del("X-MacProvider-Relay-Blind-Retry-Action")
	timing := newGatewayPhaseTiming(now)
	timing.markCoordinatorStart(s.now())
	client := *s.client
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	resp, err = client.Do(up)
	if err != nil {
		// Dispatch may have reached the provider. Existing held reservations carry
		// the durable envelope identity for read-only status reconciliation.
		// The durable recovery hold was armed before dispatch.
		writeError(w, 500, "api_error", "relay_blind_committed_failed", "Relay-blind execution status is uncertain; do not resubmit")
		return
	}
	defer resp.Body.Close()
	validationValues := nonemptyHeaderValues(resp.Header.Values(relayBlindValidatedHeader))
	inputValues := nonemptyHeaderValues(resp.Header.Values("X-MacProvider-Relay-Blind-Input-Tokens"))
	validatedInput := int64(0)
	validationAccepted := len(validationValues) == 1 && validationValues[0] == digestText
	validationInvalid := len(validationValues) > 0 && !validationAccepted
	if len(inputValues) > 0 {
		inputText := inputValues[0]
		parsed, parseErr := strconv.ParseInt(inputText, 10, 64)
		if len(inputValues) != 1 || parseErr != nil || parsed < 0 || strconv.FormatInt(parsed, 10) != inputText || parsed > env.InputTokenUpperBound || !validationAccepted {
			validationInvalid = true
		} else {
			validatedInput = parsed
		}
	}
	if validationInvalid {
		// A non-empty validation claim is post-dispatch evidence. Malformed or
		// contradictory evidence cannot safely authorize a refund or resubmission.
		writeError(w, 500, "api_error", "relay_blind_committed_failed", "Provider validation evidence is invalid; do not resubmit")
		return
	}
	if validationAccepted {
		execution.Metadata.EffectivePrivacyOutcome = "relay_blind_satisfied"
		relayBlindHeaders(w.Header(), true)
	}
	if resp.StatusCode != 200 && !validationAccepted && resp.Header.Get(settlementNoPriorDispatchHeader) == "1" {
		_ = s.refundWalletAwareReservation(subject, requestID(r))
		b, e := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		if e != nil {
			b = nil
		}
		writeRelayBlindUpstreamError(w, resp, b)
		return
	}
	if sessionAuth != nil {
		if err = s.store.MarkWalletSessionDispatched(context.Background(), session, requestID(r), s.now().UTC()); err != nil {
			// The durable recovery hold was armed before dispatch.
			writeError(w, 500, "api_error", "relay_blind_committed_failed", "Relay-blind dispatch state could not be recorded")
			return
		}
	}
	if resp.StatusCode != 200 {
		b, e := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		if e != nil {
			b = nil
		}
		if validationAccepted {
			writeError(w, 500, "api_error", "relay_blind_committed_failed", "Relay-blind execution failed after provider validation; do not resubmit")
			return
		}
		writeRelayBlindUpstreamError(w, resp, b)
		return
	}
	if !validationAccepted {
		// The durable recovery hold was armed before dispatch.
		writeError(w, 500, "api_error", "relay_blind_committed_failed", "Provider validation evidence is unavailable; do not resubmit")
		return
	}
	if privacy {
		// A 200 without both coordinator echoes can be plaintext, or a chat
		// that landed on a different gateway than the reservation. Do not
		// read or forward the body.
		verifiedAt, postureOK := privacyPostureVerifiedAt(resp.Header)
		if !privacyEchoConfirmed(resp.Header) || !postureOK {
			writePrivacyClassError(w, privacyClassUnconfirmed, "")
			return
		}
		// Consume bound env.Model to the reservation's canonical model.
		execution.Privacy = &privacyUsageContext{PostureVerifiedAtUnix: verifiedAt, Model: env.Model}
	}
	// Keep ordinary provider-leg encryption disclosure separate; never publish
	// stable peer attribution, a plaintext receipt, or the internal posture
	// timestamp. The buyer sees that timestamp only inside usage metadata.
	resp.Header.Del("X-MacProvider-Provider")
	resp.Header.Del("X-Provider-Id")
	resp.Header.Del("X-MacProvider-Receipt")
	resp.Header.Del(privacyPostureVerifiedAtHeader)
	timing.observeCoordinatorResponse(resp.Header, s.now())
	if env.Stream {
		s.forwardStreamingChat(w, r, resp, subject, validatedInput, env.ReservationTokenCap, env.MaxOutputTokens, env.Model, false, true, deadlines, false, window, timing)
	} else {
		s.forwardNonStreamingChat(w, r, resp, subject, validatedInput, env.ReservationTokenCap, env.MaxOutputTokens, false, true, window)
	}
}

func nonemptyHeaderValues(values []string) []string {
	nonempty := make([]string, 0, len(values))
	for _, value := range values {
		if value != "" {
			nonempty = append(nonempty, value)
		}
	}
	return nonempty
}

// Keep provider-visible counts intact. Only already-validated settlement values
// are bounded; malformed original totals remain errors in the common parser.
func relayBlindBoundSettlementUsage(r *http.Request, usage tokenUsage) tokenUsage {
	execution := relayBlindExecutionFor(r)
	if execution == nil {
		return usage
	}
	if usage.PromptTokens > execution.Metadata.InputTokenUpperBound || usage.CompletionTokens > execution.Metadata.MaxOutputTokens {
		slog.Warn("relay-blind provider usage exceeded clear caps", "request_id", requestID(r), "audit", "relay_blind_usage_overreport")
	}
	usage.PromptTokens = min(usage.PromptTokens, execution.Metadata.InputTokenUpperBound)
	usage.CompletionTokens = min(usage.CompletionTokens, execution.Metadata.MaxOutputTokens)
	usage.CachedPromptTokens = min(usage.CachedPromptTokens, usage.PromptTokens)
	usage.PromptTokensDetails.CachedTokens = min(usage.PromptTokensDetails.CachedTokens, usage.PromptTokens)
	usage.TotalTokens = usage.PromptTokens + usage.CompletionTokens
	return usage
}

func relayBlindUsageMetadataBody(r *http.Request, body []byte) []byte {
	execution := relayBlindExecutionFor(r)
	if execution == nil {
		return body
	}
	var root map[string]json.RawMessage
	if json.Unmarshal(body, &root) != nil {
		return body
	}
	var usage map[string]json.RawMessage
	if json.Unmarshal(root["usage"], &usage) != nil || usage == nil {
		return body
	}
	h := http.Header{}
	relayBlindHeaders(h, execution.Metadata.EffectivePrivacyOutcome == "relay_blind_satisfied")
	meta := relayBlindOutcomeMetadata(h, "")
	if execution.Privacy != nil && meta != nil {
		meta["privacy"] = privacyUsageMetadata(execution.Privacy.PostureVerifiedAtUnix)
	}
	usage["macprovider"], _ = json.Marshal(meta)
	root["usage"], _ = json.Marshal(usage)
	out, err := json.Marshal(root)
	if err != nil {
		return body
	}
	return out
}

func (s *Server) isRelayBlindPilotCandidate(r *http.Request, body []byte) bool {
	if !s.cfg.Features.RelayBlindRequests.Enabled || relayBlindEndpointFamilyFromRequest(r) != "chat_completions" {
		return false
	}
	_, err := relayblind.ParseEnvelope(body)
	return err == nil
}

// This is a read-only recovery of a previously dispatched transaction. It never
// sends ciphertext or creates new provider work, even when feature flags roll back.
func (s *Server) reconcileRelayBlindReservation(ctx context.Context, reservation storage.ActiveReservation) (string, error) {
	meta := reservation.RelayBlind
	body, _ := json.Marshal(map[string]string{"provider_binding_digest": meta.ProviderBindingDigest, "envelope_digest": meta.EnvelopeDigest})
	r, _ := http.NewRequestWithContext(context.WithValue(ctx, requestIDKey{}, reservation.RequestID), http.MethodPost, "http://localhost/", nil)
	resp, err := s.relayBlindUpstream(r, http.MethodPost, "/v1/relay-blind/status", reservation.AccountID, reservation.WalletSessionID, body, false)
	if err != nil {
		return "held", nil
	}
	raw, err := readRelayBlindUpstream(resp)
	if err != nil || resp.StatusCode != 200 {
		return "held", nil
	}
	status, err := relayblind.ParseStatusResponse(raw)
	if err != nil {
		return "held", nil
	}
	if status.State == "rejected" {
		subject := usageSubject{AccountID: reservation.AccountID, WalletSessionID: reservation.WalletSessionID}
		return "refunded", s.refundWalletAwareReservation(subject, reservation.RequestID)
	}
	if status.State != "terminal" && status.State != "unknown_postdispatch" {
		return "held", nil
	}
	// SPEC-022 R-13.6 / R-8.1: under enforce the coordinator's finality, not
	// the status row, decides money for a relay-blind execution.
	if result, handled, err := s.reconcileRelayBlindEnforceFinality(ctx, reservation, status.InternalRequestID); handled {
		return result, err
	}
	recovered := *meta
	prompt := int64(0)
	if status.EffectivePrivacyOutcome == "relay_blind_satisfied" {
		recovered.EffectivePrivacyOutcome = "relay_blind_satisfied"
	}
	if status.Validated {
		prompt = *status.InputTokens
		if prompt > meta.InputTokenUpperBound {
			prompt = meta.InputTokenUpperBound
		}
	}
	// A hold created before any response bytes has no delivered completion. If a
	// partial stream was delivered, its existing journal/fallback candidate owns
	// those counts; never replace them with provider-generated output totals.
	completion := int64(0)
	if candidate, e := s.store.LookupSettlementFallbackCandidate(ctx, reservation); e == nil && candidate.RelayBlind != nil && candidate.RelayBlind.EnvelopeDigest == meta.EnvelopeDigest {
		completion = candidate.CompletionTokens
		if completion > meta.MaxOutputTokens {
			completion = meta.MaxOutputTokens
		}
	}
	settlement := storage.ReservationSettlement{RelayBlind: &recovered, ExpectedReservationCreatedAt: reservation.CreatedAt, AccountID: reservation.AccountID, RequestID: reservation.RequestID, PromptTokens: prompt, CompletionTokens: completion, MaxTotalTokens: reservation.ReservedTokens, TokenSource: "coordinator_observed", Outcome: "relay_blind_recovered", SettledAt: s.now()}
	if reservation.WalletSessionID != "" {
		err = s.store.FinalizeWalletSessionReservation(ctx, storage.WalletSessionReservationSettlement{RelayBlind: &recovered, ExpectedReservationCreatedAt: reservation.CreatedAt, AccountID: reservation.AccountID, SessionID: reservation.WalletSessionID, RequestID: reservation.RequestID, PromptTokens: prompt, CompletionTokens: completion, MaxTotalTokens: reservation.ReservedTokens, TokenSource: settlement.TokenSource, Outcome: settlement.Outcome, SettledAt: settlement.SettledAt})
	} else {
		err = s.store.SettleReservation(ctx, settlement)
	}
	if errors.Is(err, storage.ErrReservationTerminal) || errors.Is(err, storage.ErrReservationNotFound) {
		return "already_terminal", nil
	}
	return "observed", err
}

// reconcileRelayBlindEnforceFinality settles a relay-blind hold from the
// coordinator's request finality when that finality is in enforce mode: a
// relay_blind_settled tuple debits the coordinator's usage, a refund tuple
// refunds, and anything else holds. It reports handled=false when the
// coordinator has no enforce finality for the request, which keeps the
// observe and off recovery unchanged.
func (s *Server) reconcileRelayBlindEnforceFinality(ctx context.Context, reservation storage.ActiveReservation, internalRequestID string) (string, bool, error) {
	if strings.TrimSpace(internalRequestID) == "" || strings.TrimSpace(s.cfg.Coordinator.OperatorURL) == "" {
		return "", false, nil
	}
	finality, found, _, err := s.fetchCoordinatorRequestSettlementFinalityDetail(ctx, reservation, internalRequestID)
	if err != nil {
		// The mode is unknown; never debit from the status row on a guess.
		result, recordErr := s.recordSettlementHeldResult(ctx, reservation, "held")
		return result, true, recordErr
	}
	if !found || finality.Mode != "enforce" {
		return "", false, nil
	}
	candidate, candidateErr := s.store.LookupSettlementFallbackCandidate(ctx, reservation)
	if candidateErr != nil && !errors.Is(candidateErr, storage.ErrNotFound) {
		return "", true, candidateErr
	}
	switch coordinatorSettlementFinalityForRequest(finalityHeaders(finality), true).Action {
	case settlementFinalityDebit:
		if err := s.settleVerifiedReservation(ctx, reservation, candidate, finality); err != nil {
			if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
				return "already_terminal", true, nil
			}
			return "", true, err
		}
		return relayBlindSettledOutcome, true, nil
	case settlementFinalityRefund:
		if err := s.refundHeldReservation(ctx, reservation, candidate); err != nil {
			if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
				return "already_terminal", true, nil
			}
			return "", true, err
		}
		return "refunded", true, nil
	default:
		result, err := s.recordSettlementHeldResult(ctx, reservation, "held")
		return result, true, err
	}
}

func (s *Server) applyRelayBlindModelsDisclosure(ctx context.Context, body map[string]any, disclosure *tier1Disclosure) {
	if !s.cfg.Features.RelayBlindRequests.Enabled {
		return
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	r, _ := http.NewRequestWithContext(ctx, http.MethodGet, "http://localhost/", nil)
	resp, err := s.relayBlindUpstream(r, http.MethodGet, "/v1/relay-blind/capabilities", "", "", nil, false)
	if err != nil {
		return
	}
	raw, err := readRelayBlindUpstream(resp)
	if err != nil || resp.StatusCode != 200 {
		return
	}
	type counts struct {
		Capable   int `json:"capable_provider_count"`
		Incapable int `json:"incapable_provider_count"`
	}
	var capability struct {
		Version      string            `json:"version"`
		Models       map[string]counts `json:"models"`
		PrivacyClass *struct {
			Enabled bool                             `json:"enabled"`
			Models  map[string]privacyProviderCounts `json:"models"`
		} `json:"privacy_class"`
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if dec.Decode(&capability) != nil || dec.Decode(new(any)) != io.EOF || capability.Version != "relay-blind-capabilities-v1" {
		return
	}
	rows, _ := body["data"].([]any)
	available := false
	incapable := false
	buyerModelIDs := make([]string, 0, len(rows))
	for _, row := range rows {
		model, ok := row.(map[string]any)
		if !ok {
			continue
		}
		id, _ := model["id"].(string)
		if id != "" {
			buyerModelIDs = append(buyerModelIDs, id)
		}
		c, found := capability.Models[id]
		if !found || c.Capable < 0 || c.Incapable < 0 || c.Capable > 100000 || c.Incapable > 100000 {
			continue
		}
		incapable = incapable || c.Incapable > 0
		d := relayBlindDisclosureUnavailable()
		d.Scope = relayBlindScope
		endpoint := d.EndpointFamilies["chat_completions"]
		endpoint.CapableProviderCount = &c.Capable
		endpoint.IncapableProviderCount = &c.Incapable
		if c.Capable > 0 {
			available = true
			endpoint.RequiredMode = "available"
			endpoint.PoolComposition = "all_relay_blind_capable"
			if c.Incapable > 0 {
				endpoint.PoolComposition = "mixed"
			}
		}
		d.EndpointFamilies["chat_completions"] = endpoint
		model["relay_blind_request_encryption"] = d
	}
	if available {
		d := disclosure.RelayBlindRequestEncryption
		d.Scope = relayBlindScope
		endpoint := d.EndpointFamilies["chat_completions"]
		endpoint.RequiredMode = "available"
		endpoint.PoolComposition = "all_relay_blind_capable"
		if incapable {
			endpoint.PoolComposition = "mixed"
		}
		d.EndpointFamilies["chat_completions"] = endpoint
		d.Description = "Relay-blind request encryption is available only for models with fresh capable-provider evidence. Providers read decrypted requests; relays see responses, including echoed request content."
	}
	if s.privacyClassEnabled() && capability.PrivacyClass != nil && capability.PrivacyClass.Enabled {
		disclosure.OperatorConstrainedPrivacy = newOperatorConstrainedPrivacyDisclosure(capability.PrivacyClass.Models, buyerModelIDs)
	}
}

func relayBlindDecodedCiphertextBytes(ciphertext string) int64 {
	b, err := base64.RawURLEncoding.DecodeString(ciphertext)
	if err != nil {
		return 1 << 62
	}
	return int64(len(b))
}
