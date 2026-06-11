package router

import (
	"bufio"
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

type chatRequest struct {
	Model     string            `json:"model"`
	Messages  []json.RawMessage `json:"messages"`
	MaxTokens *int64            `json:"max_tokens"`
	N         *int              `json:"n"`
	Stream    bool              `json:"stream"`
}

type tokenUsage struct {
	PromptTokens     int64 `json:"prompt_tokens"`
	CompletionTokens int64 `json:"completion_tokens"`
	TotalTokens      int64 `json:"total_tokens"`
}

type authResult struct {
	Bearer      *storage.KeyValidation
	Demo        bool
	DemoPayload auth.DemoPayload
	DemoToken   string
}

type usageSubject struct {
	AccountID     string
	DemoIdentity  string
	DemoTokenHash string
}

func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	// G3: capture per-request observability. status, wall_ms, model, stream
	// mode, and account_id are logged on every chat completion regardless of
	// outcome, so the flaky-provider failure mode can be diagnosed without
	// re-instrumenting the binary.
	start := s.now()
	sw := &statusWriter{ResponseWriter: w, statusCode: 0}
	w = sw
	var accountID, model string
	var streamMode bool
	defer func() {
		slog.Info("chat completion",
			"request_id", requestID(r),
			"account_id", accountID,
			"model", model,
			"stream", streamMode,
			"wall_ms", s.now().Sub(start).Milliseconds(),
			"status", sw.statusCode,
		)
	}()

	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	authn, ok := s.authenticateAny(w, r)
	if !ok {
		return
	}
	subject := usageSubject{}
	dailyQuota := s.effectiveAccountDailyQuota(r.Context())
	maxAllowed := s.cfg.Limits.MaxTokensPerRequest
	if authn.Demo {
		subject = usageSubject{
			AccountID:     "demo:" + authn.DemoPayload.IP,
			DemoIdentity:  authn.DemoPayload.IP,
			DemoTokenHash: demoTokenHash(authn.DemoToken),
		}
		dailyQuota = s.cfg.Quotas.DemoDailyTokensPerIP
		maxAllowed = s.cfg.Limits.DemoMaxTokensPerRequest
	} else {
		subject = usageSubject{AccountID: authn.Bearer.AccountID}
	}
	accountID = subject.AccountID
	body, err := io.ReadAll(io.LimitReader(r.Body, s.cfg.Limits.RequestBodyBytes+1))
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request_body", "Could not read request body")
		return
	}
	if int64(len(body)) > s.cfg.Limits.RequestBodyBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "invalid_request_error", "request_too_large", "Request body too large")
		return
	}
	chat, err := parseChatRequest(body)
	if err != nil {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_request", err.Error())
		return
	}
	model = chat.Model
	streamMode = chat.Stream
	if chat.N != nil && *chat.N != 1 {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "n_must_be_1", "n must be 1")
		return
	}
	maxTokens := maxAllowed
	if chat.MaxTokens != nil {
		maxTokens = *chat.MaxTokens
	}
	if maxTokens <= 0 || maxTokens > maxAllowed {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "max_tokens_exceeded", "max_tokens exceeds configured limit")
		return
	}
	window := s.now().UTC().Format("2006-01-02")
	reservationMaxAge := time.Duration(s.cfg.Quotas.ReservationMaxAgeHours) * time.Hour
	decision, err := s.store.ReserveQuota(r.Context(), storage.ReservationRequest{
		AccountID: subject.AccountID, RequestID: requestID(r), WindowDate: window,
		RequestedTokens: maxTokens, DailyQuota: dailyQuota,
		CreatedAt: s.now(), ExpiresAt: s.now().Add(reservationMaxAge),
	})
	if errors.Is(err, storage.ErrQuotaExceeded) {
		setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
		return
	}
	if err != nil && decision.Admitted {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	}
	// Belt-and-suspenders: if the store returned an unexpected error but the
	// decision already shows quota exceeded, surface 429 rather than 500.
	if err != nil && !decision.Admitted && decision.RemainingTokens == 0 && decision.LimitTokens > 0 {
		setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "quota_exhausted", "Quota exhausted")
		return
	}
	if err != nil {
		// Defensive cleanup: if the reservation INSERT committed before the
		// context was cancelled (commit-boundary race), this unwinds it.
		// If no row was written, RefundReservation is a safe no-op
		// (returns ErrReservationNotFound which we ignore here).
		if !decision.Admitted {
			_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		}
		// If the error is a client disconnect, avoid writing a response to a
		// dead connection — the buyer already gave up.
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "quota_reservation_failed", "Could not reserve quota")
		return
	}
	setRateLimitHeaders(w, decision.LimitTokens, decision.RemainingTokens, decision.ResetUnix)
	// M1-8 / PERF-6: demo subjects must also acquire concurrency. Pre-fix,
	// only paying accounts went through AcquireConcurrency. 3+ parallel demo
	// requests from a single demo identity (keyed on IP/64 via the demo
	// AccountID) saturated the MLX-serialized provider pool for up to
	// CoordinatorTimeout, an accidental DoS against paying buyers.
	// subject.AccountID is already "demo:<ip>" with IPv6 normalized to /64
	// (see auth.normalizeDemoIP), so the existing per-AccountID reservation
	// machinery keys correctly without further per-IP tracking.
	concurrencyLimit := s.cfg.Quotas.AccountConcurrency
	concurrencyErrCode := "account_concurrency_exceeded"
	concurrencyErrMsg := "Account concurrency limit exceeded"
	if authn.Demo {
		concurrencyLimit = s.cfg.Quotas.DemoConcurrency
		concurrencyErrCode = "demo_concurrency_exceeded"
		concurrencyErrMsg = "Demo concurrency limit exceeded"
	}
	if _, err := s.store.AcquireConcurrency(r.Context(), storage.ConcurrencyRequest{
		AccountID: subject.AccountID, RequestID: requestID(r), Limit: concurrencyLimit,
		CreatedAt: s.now(), ExpiresAt: s.now().Add(s.cfg.CoordinatorTimeout() + time.Minute),
	}); errors.Is(err, storage.ErrQuotaExceeded) {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", concurrencyErrCode, concurrencyErrMsg)
		return
	} else if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "concurrency_reservation_failed", "Could not reserve concurrency")
		return
	}
	defer func() {
		_ = s.store.ReleaseConcurrency(context.Background(), subject.AccountID, requestID(r), s.now())
	}()

	upCtx, cancelUpstream := context.WithTimeout(r.Context(), s.cfg.CoordinatorTimeout())
	defer cancelUpstream()
	upReq, err := http.NewRequestWithContext(upCtx, http.MethodPost, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	copyForwardHeaders(upReq.Header, r.Header)
	upReq.Header.Set("Content-Type", "application/json")
	upReq.Header.Set("X-Request-ID", newUUID())
	if s.cfg.Routing.StickyEnabled && !authn.Demo {
		if tag := strings.TrimSpace(r.Header.Get("X-MacProvider-Conversation")); tag != "" {
			if !validConversationTag(tag) {
				_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
				writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_conversation_tag", "Invalid conversation tag")
				return
			}
			if metadata, ok := s.coordinatorRoutingMetadata(upCtx); ok && metadata.Sticky.Enabled && metadata.Sticky.TTLSeconds == s.cfg.Routing.StickyTTLS {
				upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.OperatorKey)
				upReq.Header.Set("X-MacProvider-Account", subject.AccountID)
				upReq.Header.Set("X-MacProvider-Internal-Conv", s.deriveConversationKey(subject.AccountID, tag))
			}
		}
	}
	resp, err := s.client.Do(upReq)
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()

	promptEstimate := estimatePromptTokens(body)
	maxUsageTokens := promptEstimate + maxTokens
	if chat.Stream {
		s.forwardStreamingChat(w, r, resp, subject, promptEstimate, maxUsageTokens, cancelUpstream)
		return
	}
	s.forwardNonStreamingChat(w, r, resp, subject, promptEstimate, maxUsageTokens)
}

func (s *Server) forwardNonStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate, maxUsageTokens int64) {
	body, err := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	if resp.StatusCode == http.StatusServiceUnavailable {
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "provider_unavailable", "No provider available")
		return
	}
	if resp.StatusCode == http.StatusGatewayTimeout {
		if !s.settleBeforeResponse(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "provider_timeout") {
			return
		}
		writeError(w, http.StatusGatewayTimeout, "api_error", "provider_timeout", "Provider timed out")
		return
	}
	// Coordinator-issued 404 means the request was structurally rejected
	// (e.g. model_not_found — no provider has advertised the requested model).
	// No provider was reached → no prompt-token settlement; refund the
	// reservation and pass the OpenAI-shaped error body through verbatim so
	// the buyer sees an actionable 404 instead of an opaque 502.
	if resp.StatusCode == http.StatusNotFound {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
		return
	}
	if coordinatorTier2PolicyError(resp.StatusCode, body) {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
		return
	}
	if resp.StatusCode != http.StatusOK {
		completion := completionFromHeader(resp.Header)
		if !s.settleBeforeResponse(w, r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "upstream_error") {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	usage, ok, usageErr := usageFromJSON(body, maxUsageTokens)
	tokenSource := "gateway_estimated"
	if !ok {
		usage = tokenUsage{PromptTokens: promptEstimate, CompletionTokens: 0, TotalTokens: promptEstimate}
	} else if usageErr != nil {
		if !s.settleBeforeResponse(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "invalid_provider_usage") {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "invalid_provider_usage", "Upstream provider returned invalid usage")
		return
	} else {
		tokenSource = "provider_reported"
	}
	if !s.settleBeforeResponse(w, r, subject, usage.PromptTokens, usage.CompletionTokens, maxUsageTokens, tokenSource, "ok") {
		return
	}
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (s *Server) forwardStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate, maxUsageTokens int64, cancelUpstream func()) {
	if resp.StatusCode == http.StatusServiceUnavailable {
		body, _ := io.ReadAll(resp.Body)
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "provider_unavailable", "No provider available")
		return
	}
	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusGatewayTimeout {
			if !s.settleBeforeResponse(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "provider_timeout") {
				return
			}
			writeError(w, http.StatusGatewayTimeout, "api_error", "provider_timeout", "Provider timed out")
			return
		}
		// Coordinator 404 = structural rejection (model_not_found, etc.);
		// no provider reached, no charge. Pass through the OpenAI-shaped body
		// verbatim so the buyer sees a clean 404 instead of an opaque 502.
		// See forwardNonStreamingChat for the matching non-stream branch.
		if resp.StatusCode == http.StatusNotFound {
			body, _ := io.ReadAll(resp.Body)
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		body, _ := io.ReadAll(resp.Body)
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		if !s.settleBeforeResponse(w, r, subject, promptEstimate, completionFromHeader(resp.Header), maxUsageTokens, "gateway_estimated", "upstream_error") {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	w.WriteHeader(http.StatusOK)
	flusher, _ := w.(http.Flusher)
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	var cancelOnce sync.Once
	cancelCoordinator := func() {
		cancelOnce.Do(cancelUpstream)
	}
	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-r.Context().Done():
			cancelCoordinator()
		case <-done:
		}
	}()
	var emitted int64
	var reported *tokenUsage
	invalidReportedUsage := false
	for scanner.Scan() {
		select {
		case <-r.Context().Done():
			if reported != nil {
				s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "client_disconnect")
				return
			}
			s.settleCancelledStream(r, subject, promptEstimate, emitted, maxUsageTokens, cancelCoordinator)
			return
		default:
		}
		line := scanner.Text()
		if strings.HasPrefix(line, "data: ") {
			data := strings.TrimPrefix(line, "data: ")
			if data != "[DONE]" {
				emitted += int64(len(data))
				if usage, ok, err := usageFromJSON([]byte(data), maxUsageTokens); ok {
					if err != nil {
						invalidReportedUsage = true
						reported = nil
						slog.Warn("invalid provider usage in stream; falling back to gateway estimate", "request_id", requestID(r), "error", err)
					} else if !invalidReportedUsage {
						reported = &usage
					}
				}
			}
		}
		_, _ = w.Write([]byte(line + "\n"))
		if flusher != nil {
			flusher.Flush()
		}
	}
	if errors.Is(r.Context().Err(), context.Canceled) {
		if reported != nil {
			s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "client_disconnect")
			return
		}
		s.settleCancelledStream(r, subject, promptEstimate, emitted, maxUsageTokens, cancelCoordinator)
		return
	}
	if err := scanner.Err(); err != nil {
		slog.Error("streaming coordinator read failed", "request_id", requestID(r), "error", err)
		writeSSEError(w, "Upstream stream failed", "stream_truncated")
		if flusher != nil {
			flusher.Flush()
		}
		if reported != nil {
			s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "stream_truncated")
			return
		}
		s.settleAfterCommit(r, subject, promptEstimate, int64(math.Ceil(float64(emitted)/4.0)), maxUsageTokens, "gateway_estimated", "stream_truncated")
		return
	}
	if reported != nil && !invalidReportedUsage {
		s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "ok")
		return
	}
	s.settleAfterCommit(r, subject, promptEstimate, int64(math.Ceil(float64(emitted)/4.0)), maxUsageTokens, "gateway_estimated", "ok")
}

func (s *Server) passThroughNoProviderCoordinatorError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte) {
	_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func coordinatorTier2PolicyError(status int, body []byte) bool {
	code := openAIErrorCode(body)
	switch code {
	case "tier2_hash_verified_required", "tier2_hash_mismatch", "tier2_encrypted_leg_required", "tier2_attestation_required":
		return status == http.StatusServiceUnavailable
	case "tier2_hard_pin_predicate_failed":
		return status == http.StatusBadRequest
	default:
		return false
	}
}

func openAIErrorCode(body []byte) string {
	var envelope struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return ""
	}
	return strings.TrimSpace(envelope.Error.Code)
}

func (s *Server) settleCancelledStream(r *http.Request, subject usageSubject, promptEstimate, emitted, maxUsageTokens int64, cancelCoordinator func()) {
	cancelCoordinator()
	s.settleAfterCommit(r, subject, promptEstimate, int64(math.Ceil(float64(emitted)/4.0)), maxUsageTokens, "gateway_estimated", "client_disconnect")
}

func (s *Server) settleBeforeResponse(w http.ResponseWriter, r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string) bool {
	if err := s.settleRequest(r, subject, prompt, completion, maxTotal, source, outcome); err != nil {
		slog.Error("gateway settlement failed before response", "request_id", requestID(r), "account_id", subject.AccountID, "source", source, "outcome", outcome, "error", err)
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
		return false
	}
	return true
}

func (s *Server) settleAfterCommit(r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string) {
	if err := s.settleRequest(r, subject, prompt, completion, maxTotal, source, outcome); err != nil {
		slog.Error("gateway settlement failed after response commit", "request_id", requestID(r), "account_id", subject.AccountID, "source", source, "outcome", outcome, "error", err)
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	}
}

func validConversationTag(tag string) bool {
	if len(tag) < 1 || len(tag) > 128 || strings.TrimSpace(tag) != tag {
		return false
	}
	for _, r := range tag {
		if r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9' {
			continue
		}
		switch r {
		case '.', '_', ':', '-':
			continue
		default:
			return false
		}
	}
	return true
}

func (s *Server) deriveConversationKey(accountID, tag string) string {
	const scope = "spec006-v0.8-sticky-conversation-v1"
	mac := hmac.New(sha256.New, []byte(s.cfg.Auth.KeyHashSecret))
	_, _ = mac.Write([]byte(scope))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(accountID))
	_, _ = mac.Write([]byte("\n"))
	_, _ = mac.Write([]byte(tag))
	return "conv:" + base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func (s *Server) settleRequest(r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string) error {
	settlement := storage.ReservationSettlement{
		AccountID: subject.AccountID, RequestID: requestID(r), PromptTokens: prompt, CompletionTokens: completion,
		MaxTotalTokens: maxTotal, TokenSource: source, Outcome: outcome, SettledAt: s.now(),
	}
	if subject.DemoIdentity != "" {
		return s.store.SettleDemoReservation(context.Background(), settlement, storage.DemoUsageEvent{
			RequestID: requestID(r), ClientIP: subject.DemoIdentity, DemoTokenHash: subject.DemoTokenHash, CreatedAt: s.now(),
		})
	}
	return s.store.SettleReservation(context.Background(), settlement)
}

func demoTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
