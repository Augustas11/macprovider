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
	"fmt"
	"io"
	"log/slog"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

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
				// M3-2 / SECU-4: prefer ServiceToken when set; falls back to
				// OperatorKey so a not-yet-upgraded coordinator keeps
				// accepting us on the hot sticky-routing path.
				upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
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
		if isNullUsageProviderError(body) {
			s.passThroughReceiptEligibleProviderError(w, r, resp, subject, body)
			return
		}
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
		if isNullUsageProviderError(body) {
			s.passThroughReceiptEligibleProviderError(w, r, resp, subject, body)
			return
		}
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
	copyReceiptEligibleHeaders(w.Header(), resp.Header)
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
	reader := bufio.NewReaderSize(resp.Body, maxStreamingLineBytes)
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
	settleTruncated := func() {
		if reported != nil {
			s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "stream_truncated")
			return
		}
		s.settleAfterCommit(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, promptEstimate, maxUsageTokens), maxUsageTokens, "gateway_estimated", "stream_truncated")
	}
	forwardLine := func(line []byte) bool {
		select {
		case <-r.Context().Done():
			if reported != nil {
				s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "client_disconnect")
				return false
			}
			s.settleCancelledStream(r, subject, promptEstimate, emitted, maxUsageTokens, cancelCoordinator)
			return false
		default:
		}
		text := strings.TrimRight(string(line), "\r\n")
		if data, ok := sseDataValue(text); ok {
			if data != "[DONE]" {
				deltaBytes, parseOK := streamingCompletionDeltaBytes(data)
				if !parseOK {
					slog.Warn("streaming gateway estimate saw malformed chunk; truncating stream", "request_id", requestID(r))
					writeSSEError(w, "Upstream stream returned malformed data", "stream_malformed")
					if flusher != nil {
						flusher.Flush()
					}
					cancelCoordinator()
					completion := estimateStreamingCompletionTokens(emitted, promptEstimate, maxUsageTokens)
					s.settleAfterCommit(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "stream_malformed")
					return false
				}
				if deltaBytes > 0 {
					projectedCompletion := estimateTokensFromBytes(emitted + deltaBytes)
					maxCompletion := maxStreamingCompletionTokens(promptEstimate, maxUsageTokens)
					if projectedCompletion > maxCompletion {
						slog.Warn("streaming gateway estimate exceeded request maximum; truncating stream", "request_id", requestID(r), "estimated_completion_tokens", projectedCompletion, "max_completion_tokens", maxCompletion)
						writeSSEError(w, "Upstream stream exceeded requested max_tokens", "stream_output_exceeded")
						if flusher != nil {
							flusher.Flush()
						}
						cancelCoordinator()
						s.settleAfterCommit(r, subject, promptEstimate, maxCompletion, maxUsageTokens, "gateway_estimated", "stream_output_exceeded")
						return false
					}
					emitted += deltaBytes
				}
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
		if _, err := w.Write(line); err != nil {
			slog.Warn("streaming buyer write failed", "request_id", requestID(r), "error", err)
			if reported != nil {
				s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "client_disconnect")
				return false
			}
			s.settleCancelledStream(r, subject, promptEstimate, emitted, maxUsageTokens, cancelCoordinator)
			return false
		}
		if flusher != nil {
			flusher.Flush()
		}
		return true
	}
	for {
		line, err := reader.ReadSlice('\n')
		if errors.Is(err, bufio.ErrBufferFull) {
			slog.Error("streaming coordinator line exceeded limit", "request_id", requestID(r), "max_line_bytes", maxStreamingLineBytes)
			writeSSEError(w, "Upstream stream failed", "stream_truncated")
			if flusher != nil {
				flusher.Flush()
			}
			settleTruncated()
			return
		}
		if len(line) > 0 {
			if !forwardLine(line) {
				return
			}
		}
		if err == nil {
			continue
		}
		if err == io.EOF {
			break
		}
		if errors.Is(r.Context().Err(), context.Canceled) {
			if reported != nil {
				s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "client_disconnect")
				return
			}
			s.settleCancelledStream(r, subject, promptEstimate, emitted, maxUsageTokens, cancelCoordinator)
			return
		}
		slog.Error("streaming coordinator read failed", "request_id", requestID(r), "error", err)
		writeSSEError(w, "Upstream stream failed", "stream_truncated")
		if flusher != nil {
			flusher.Flush()
		}
		settleTruncated()
		return
	}
	if errors.Is(r.Context().Err(), context.Canceled) {
		if reported != nil {
			s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "client_disconnect")
			return
		}
		s.settleCancelledStream(r, subject, promptEstimate, emitted, maxUsageTokens, cancelCoordinator)
		return
	}
	if reported != nil && !invalidReportedUsage {
		s.settleAfterCommit(r, subject, reported.PromptTokens, reported.CompletionTokens, maxUsageTokens, "provider_reported", "ok")
		return
	}
	s.settleAfterCommit(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, promptEstimate, maxUsageTokens), maxUsageTokens, "gateway_estimated", "ok")
}

func (s *Server) passThroughNoProviderCoordinatorError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte) {
	_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func (s *Server) passThroughReceiptEligibleProviderError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte) {
	_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	copyReceiptEligibleHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func isNullUsageProviderError(body []byte) bool {
	switch openAIErrorCode(body) {
	case "error_model_not_loaded", "error_context_exceeded", "error_queue_full", "error_internal":
		return true
	default:
		return false
	}
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
	s.settleAfterCommit(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, promptEstimate, maxUsageTokens), maxUsageTokens, "gateway_estimated", "client_disconnect")
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

func estimateStreamingCompletionTokens(emitted, promptEstimate, maxUsageTokens int64) int64 {
	completion := estimateTokensFromBytes(emitted)
	maxCompletion := maxStreamingCompletionTokens(promptEstimate, maxUsageTokens)
	if completion > maxCompletion {
		return maxCompletion
	}
	return completion
}

func maxStreamingCompletionTokens(promptEstimate, maxUsageTokens int64) int64 {
	maxCompletion := maxUsageTokens - promptEstimate
	if maxCompletion < 0 {
		return 0
	}
	return maxCompletion
}

func estimateTokensFromBytes(n int64) int64 {
	return int64(math.Ceil(float64(n) / 4.0))
}

func streamingCompletionDeltaBytes(data string) (int64, bool) {
	var envelope struct {
		Choices []struct {
			Delta json.RawMessage `json:"delta"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(data), &envelope); err != nil {
		return 0, false
	}
	var n int64
	for _, choice := range envelope.Choices {
		if len(choice.Delta) == 0 || bytes.Equal(choice.Delta, []byte("null")) {
			continue
		}
		deltaBytes, ok := generatedDeltaStringBytes(choice.Delta)
		if !ok {
			return 0, false
		}
		n += deltaBytes
	}
	return n, true
}

func generatedDeltaStringBytes(raw json.RawMessage) (int64, bool) {
	var delta any
	if err := json.Unmarshal(raw, &delta); err != nil {
		return 0, false
	}
	if _, ok := delta.(map[string]any); !ok {
		return 0, false
	}
	return countGeneratedDeltaStrings("", delta), true
}

func countGeneratedDeltaStrings(key string, value any) int64 {
	switch v := value.(type) {
	case map[string]any:
		var n int64
		for childKey, childValue := range v {
			n += countGeneratedDeltaStrings(childKey, childValue)
		}
		return n
	case []any:
		var n int64
		for _, childValue := range v {
			n += countGeneratedDeltaStrings(key, childValue)
		}
		return n
	case string:
		if !countDeltaStringKey(key) {
			return 0
		}
		return int64(len(v))
	default:
		return 0
	}
}

func countDeltaStringKey(key string) bool {
	switch strings.ToLower(key) {
	case "", "role", "id", "type", "name":
		return false
	default:
		return true
	}
}

func sseDataValue(line string) (string, bool) {
	if !strings.HasPrefix(line, "data:") {
		return "", false
	}
	value := strings.TrimPrefix(line, "data:")
	if strings.HasPrefix(value, " ") {
		value = strings.TrimPrefix(value, " ")
	}
	return value, true
}

func demoTokenHash(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}

// ============================================================
// Chat-only helpers migrated from server.go (M3-9 CODE-8 cleanup)
// ============================================================

const maxUpstreamResponseBodyBytes = int64(16 << 20)
const maxStreamingLineBytes = 1024 * 1024

func readLimitedBody(r io.Reader, maxBytes int64) ([]byte, error) {
	if maxBytes < 0 {
		maxBytes = 0
	}
	lr := &io.LimitedReader{R: r, N: maxBytes + 1}
	body, err := io.ReadAll(lr)
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > maxBytes {
		return nil, fmt.Errorf("upstream response body exceeds %d bytes", maxBytes)
	}
	return body, nil
}

// statusWriter wraps http.ResponseWriter to capture the HTTP status code that
// was written. handleChatCompletions uses it for an end-of-request log line
// (G3 — operator observability for the flaky-provider failure mode).
type statusWriter struct {
	http.ResponseWriter
	statusCode int
	flushed    bool
}

func (sw *statusWriter) WriteHeader(code int) {
	if !sw.flushed {
		sw.statusCode = code
		sw.flushed = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *statusWriter) Write(b []byte) (int, error) {
	if !sw.flushed {
		sw.statusCode = http.StatusOK
		sw.flushed = true
	}
	return sw.ResponseWriter.Write(b)
}

// Flush satisfies http.Flusher so SSE streaming through this wrapper still
// flushes chunks to the buyer in real time.
func (sw *statusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func writeSSEError(w http.ResponseWriter, message, code string) {
	payload, _ := json.Marshal(map[string]any{"error": map[string]any{"message": message, "type": "api_error", "code": code}})
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(payload)
	_, _ = w.Write([]byte("\n\ndata: [DONE]\n\n"))
}

func parseChatRequest(body []byte) (chatRequest, error) {
	var req chatRequest
	if err := json.Unmarshal(body, &req); err != nil {
		return chatRequest{}, errors.New("Malformed JSON")
	}
	if strings.TrimSpace(req.Model) == "" {
		return chatRequest{}, errors.New("model is required")
	}
	if len(req.Messages) == 0 {
		return chatRequest{}, errors.New("messages is required")
	}
	return req, nil
}

func usageFromJSON(body []byte, maxUsageTokens int64) (tokenUsage, bool, error) {
	var envelope struct {
		Usage json.RawMessage `json:"usage"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil || envelope.Usage == nil {
		return tokenUsage{}, false, nil
	}
	if bytes.Equal(bytes.TrimSpace(envelope.Usage), []byte("null")) {
		return tokenUsage{}, false, nil
	}
	var rawUsage struct {
		PromptTokens     *int64 `json:"prompt_tokens"`
		CompletionTokens *int64 `json:"completion_tokens"`
		TotalTokens      *int64 `json:"total_tokens"`
	}
	if err := json.Unmarshal(envelope.Usage, &rawUsage); err != nil {
		return tokenUsage{}, true, fmt.Errorf("usage object is malformed")
	}
	if rawUsage.PromptTokens == nil || rawUsage.CompletionTokens == nil {
		return tokenUsage{}, true, fmt.Errorf("usage prompt_tokens and completion_tokens are required")
	}
	usage := tokenUsage{}
	usage.PromptTokens = *rawUsage.PromptTokens
	usage.CompletionTokens = *rawUsage.CompletionTokens
	if rawUsage.TotalTokens != nil {
		usage.TotalTokens = *rawUsage.TotalTokens
	}
	if usage.PromptTokens < 0 || usage.CompletionTokens < 0 || usage.TotalTokens < 0 {
		return tokenUsage{}, true, fmt.Errorf("usage tokens must be non-negative")
	}
	if usage.PromptTokens > math.MaxInt64-usage.CompletionTokens {
		return tokenUsage{}, true, fmt.Errorf("usage token total overflows int64")
	}
	sum := usage.PromptTokens + usage.CompletionTokens
	if sum > maxUsageTokens {
		return tokenUsage{}, true, fmt.Errorf("usage token total exceeds request maximum")
	}
	if rawUsage.TotalTokens != nil && usage.TotalTokens != sum {
		return tokenUsage{}, true, fmt.Errorf("usage total_tokens does not match prompt_tokens plus completion_tokens")
	}
	usage.TotalTokens = sum
	return usage, true, nil
}

func completionFromHeader(header http.Header) int64 {
	raw := header.Get("X-MacProvider-Completion-Tokens")
	if raw == "" {
		return 0
	}
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func estimatePromptTokens(body []byte) int64 {
	if len(body) == 0 {
		return 0
	}
	return int64(math.Ceil(float64(len(body)) / 4.0))
}

func copyForwardHeaders(dst, src http.Header) {
	if accept := strings.TrimSpace(src.Get("Accept")); accept != "" {
		dst.Set("Accept", accept)
	}
	if retry := strings.TrimSpace(src.Get("X-MacProvider-Retry")); retry != "" {
		dst.Set("X-MacProvider-Retry", retry)
	}
	if idempotencyKey := strings.TrimSpace(src.Get("Idempotency-Key")); idempotencyKey != "" {
		dst.Set("Idempotency-Key", idempotencyKey)
	}
}

func contentTypeOrJSON(header http.Header) string {
	if ct := header.Get("Content-Type"); ct != "" {
		return ct
	}
	return "application/json"
}
