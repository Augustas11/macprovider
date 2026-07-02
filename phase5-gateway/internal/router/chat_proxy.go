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
	Model          string            `json:"model"`
	Messages       []json.RawMessage `json:"messages"`
	MaxTokens      *int64            `json:"max_tokens"`
	N              *int              `json:"n"`
	Stream         bool              `json:"stream"`
	ResponseFormat json.RawMessage   `json:"response_format"`
}

type tokenUsage struct {
	PromptTokens       int64 `json:"prompt_tokens"`
	CachedPromptTokens int64 `json:"cached_prompt_tokens"`
	CompletionTokens   int64 `json:"completion_tokens"`
	TotalTokens        int64 `json:"total_tokens"`
}

type usageSubject struct {
	AccountID     string
	DemoIdentity  string
	DemoTokenHash string
}

const (
	settlementOutcomeHeader       = "X-MacProvider-Settlement-Outcome"
	settlementReceiptResultHeader = "X-MacProvider-Settlement-Receipt-Result"
	settlementReasonHeader        = "X-MacProvider-Settlement-Reason"
	settlementClosedHeader        = "X-MacProvider-Settlement-Closed"
	settlementModeHeader          = "X-MacProvider-Settlement-Mode"
	settlementPolicyVersionHeader = "X-MacProvider-Settlement-Policy-Version"
	settlementPendingUntilHeader  = "X-MacProvider-Settlement-Pending-Deadline-Unix-Ms"
	settlementPolicyVersion       = "spec022-prereq-v0"
	settlementHoldFallbackTTL     = 5 * time.Minute
)

type settlementFinalityAction int

const (
	settlementFinalityLegacy settlementFinalityAction = iota
	settlementFinalityDebit
	settlementFinalityRefund
	settlementFinalityHold
)

type coordinatorSettlementFinality struct {
	Action                settlementFinalityAction
	Outcome               string
	Reason                string
	PendingDeadlineUnixMS int64
}

func (c chatRequest) hasStructuredOutput() bool {
	if len(c.ResponseFormat) == 0 || bytes.Equal(bytes.TrimSpace(c.ResponseFormat), []byte("null")) {
		return false
	}
	var rf struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(c.ResponseFormat, &rf); err != nil {
		return false
	}
	return rf.Type == "json_schema" || rf.Type == "json_object"
}

func (s *Server) handleChatCompletions(w http.ResponseWriter, r *http.Request) {
	// G3: capture per-request observability. status, wall_ms, model, stream
	// mode, and account_id are logged on every chat completion regardless of
	// outcome, so the flaky-provider failure mode can be diagnosed without
	// re-instrumenting the binary.
	start := s.now()
	// AC-V2-9: gateway-side first-byte-of-request is the SPEC-019 v0.2
	// wall-clock zero-point. The 300s budget (`coordinator_request_seconds`
	// by convention) measures from this point to provider terminal SSE frame
	// emission. Pre-upstream gateway time counts against the budget.
	upCtx, cancelUpstream := context.WithTimeout(r.Context(), s.cfg.CoordinatorTimeout())
	defer cancelUpstream()
	sw := &statusWriter{ResponseWriter: w, statusCode: 0}
	w = sw
	// Issue #190 R1 security HIGH: chat-completion responses now
	// carry per-tenant headers (X-RateLimit-Remaining-Requests).
	// Forbid intermediary caching unconditionally so a misconfigured
	// CDN/proxy cannot serve another buyer's rate-limit state via
	// a shared cache. Vary covers both auth modes (bearer + demo
	// token) so any proxy that does cache will at least key
	// correctly per-tenant.
	setNoStoreHeaders(w.Header())
	// Use Add (not Set) so an existing CORS-supplied Vary: Origin
	// is preserved alongside the auth-mode signals we add here.
	w.Header().Add("Vary", "Authorization")
	w.Header().Add("Vary", "X-Demo-Token")
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
	if !contentEncodingSupported(r.Header.Values("Content-Encoding")) {
		writeSpec019PreflightError(
			w,
			http.StatusUnsupportedMediaType,
			"request_content_encoding_unsupported",
			"v0.1.0 accepts `Content-Encoding: identity` or no `Content-Encoding` header; compressed request bodies are deferred to v0.2 per §10.",
			"Content-Encoding",
		)
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
	concurrencyDecision, concurrencyErr := s.store.AcquireConcurrency(r.Context(), storage.ConcurrencyRequest{
		AccountID: subject.AccountID, RequestID: requestID(r), Limit: concurrencyLimit,
		CreatedAt: s.now(), ExpiresAt: s.now().Add(s.cfg.CoordinatorTimeout() + time.Minute),
	})
	if errors.Is(concurrencyErr, storage.ErrQuotaExceeded) {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		// Issue #190: surface OpenAI-compatible concurrency
		// rate-limit headers so client SDKs can self-pace
		// instead of retrying blindly until 429.
		setConcurrencyRateLimitHeaders(w, concurrencyLimit, 0, concurrencyRetryAfterSeconds, s.now())
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", concurrencyErrCode, concurrencyErrMsg)
		return
	} else if concurrencyErr != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		if errors.Is(concurrencyErr, context.Canceled) || errors.Is(concurrencyErr, context.DeadlineExceeded) {
			return
		}
		writeError(w, http.StatusInternalServerError, "server_error", "concurrency_reservation_failed", "Could not reserve concurrency")
		return
	}
	// Issue #190: emit concurrency headers on admitted requests too
	// so OpenAI-compatible SDKs can pre-emptively throttle before
	// they hit the cap. Remaining is derived from the decision's
	// post-acquire Active count (already includes this request).
	remainingRequests := concurrencyLimit - concurrencyDecision.Active
	setConcurrencyRateLimitHeaders(w, concurrencyLimit, remainingRequests, 0, s.now())
	defer func() {
		_ = s.store.ReleaseConcurrency(context.Background(), subject.AccountID, requestID(r), s.now())
	}()

	upReq, err := http.NewRequestWithContext(upCtx, http.MethodPost, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/chat/completions", bytes.NewReader(body))
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	copyForwardHeaders(upReq.Header, r.Header)
	upReq.Header.Set("Content-Type", "application/json")
	// SPEC-002 §11 + v1.4.2 R-2: forward the gateway-visible request id
	// (which itself was honored from the buyer's inbound X-Request-ID
	// when present, else minted by the gateway middleware) so the
	// coordinator can store it in request_log.external_request_id and
	// out-of-process auditors can join gateway usage_events with
	// coordinator request_log on this shared id. Earlier code minted a
	// fresh UUID here, breaking that join.
	upReq.Header.Set("X-Request-ID", requestID(r))
	upReq.Header.Set("X-MacProvider-Gateway-FirstByte-Unix-Ms", strconv.FormatInt(start.UnixMilli(), 10))
	// SPEC-006 v0.9.1 / SPEC-002 v1.5.0 / issue #211: forward the
	// gateway's authenticated account id on EVERY forwarded buyer
	// request — bearer-authenticated and demo subjects alike, both on
	// the sticky and non-sticky paths. The coordinator persists this
	// into request_log.account_id; the composite
	// (account_id, external_request_id) is the reconciliation key
	// joining gateway usage_events to coordinator request_log (the
	// composite-PK addendum from #196). Earlier code emitted this
	// header only inside the sticky-routing conditional below, leaving
	// the non-sticky hot path account-blind and reopening the
	// cross-account request_id-collision class on the coordinator
	// audit-trail side.
	//
	// The coordinator treats X-MacProvider-Account as an internal-
	// routing header (see hasInternalRoutingHeader / selectProviderExcluding
	// in phase4-coordinator/internal/buyer/server.go) gated by the
	// gateway-service-token Authorization bearer. To avoid the
	// coordinator rejecting every non-sticky chat with 400
	// invalid_request, the upstream Authorization bearer is hoisted
	// alongside the account header — same pair the sticky path
	// already sends. M3-2 / SECU-4: prefer ServiceToken when set;
	// falls back to OperatorKey so a not-yet-upgraded coordinator
	// keeps accepting us. ISS-211 R1 security audit HIGH.
	if subject.AccountID != "" {
		upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
		upReq.Header.Set("X-MacProvider-Account", subject.AccountID)
	}
	if s.cfg.Routing.StickyEnabled && !authn.Demo {
		if tag := strings.TrimSpace(r.Header.Get("X-MacProvider-Conversation")); tag != "" {
			if !validConversationTag(tag) {
				_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
				writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_conversation_tag", "Invalid conversation tag")
				return
			}
			if metadata, ok := s.coordinatorRoutingMetadata(upCtx); ok && metadata.Sticky.Enabled && metadata.Sticky.TTLSeconds == s.cfg.Routing.StickyTTLS {
				// Authorization + X-MacProvider-Account already set
				// unconditionally above (SPEC-006 v0.9.1). The sticky
				// path's distinguishing header is X-MacProvider-Internal-Conv.
				upReq.Header.Set("X-MacProvider-Internal-Conv", s.deriveConversationKey(subject.AccountID, tag))
			}
		}
	}
	promptEstimate := estimatePromptTokens(body)
	// Validation cap uses promptCapTokens (with chat-template headroom)
	// — generous enough to admit valid provider tokenization. Billed
	// quantities (settle paths below) keep using the bare
	// promptEstimate so error-path settlement does not over-charge.
	maxUsageTokens := promptCapTokens(body) + maxTokens
	structuredStreaming := chat.Stream && chat.hasStructuredOutput()
	resp, err := s.client.Do(upReq)
	if err != nil {
		if structuredStreaming && errors.Is(upCtx.Err(), context.DeadlineExceeded) {
			if !s.settleBeforeResponse(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "provider_timeout") {
				return
			}
			writeStructuredOutputTimeoutSSE(w, requestID(r))
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "coordinator_unavailable", "Coordinator unavailable")
		return
	}
	defer resp.Body.Close()

	if chat.Stream {
		// ISS-187 R1 architect/code MAJOR: thread the reservation
		// window through to forwardStreamingChat so the SPEC-006 §
		// 17.7 fallback usage_events insert in settleAfterCommit
		// uses the SAME window_date as the original reservation
		// (avoids drift for streams that cross UTC midnight).
		s.forwardStreamingChat(w, r, resp, subject, promptEstimate, maxUsageTokens, maxTokens, cancelUpstream, upCtx, structuredStreaming, window)
		return
	}
	s.forwardNonStreamingChat(w, r, resp, subject, promptEstimate, maxUsageTokens, maxTokens)
}

func (s *Server) forwardNonStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate, maxUsageTokens, maxTokens int64) {
	body, err := readLimitedBody(resp.Body, maxUpstreamResponseBodyBytes)
	if err != nil {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	if resp.StatusCode == http.StatusServiceUnavailable {
		if isNullUsageProviderError(body) {
			s.passThroughReceiptEligibleProviderError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, maxTokens)
			return
		}
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "no_provider_available", "No provider available")
		return
	}
	if resp.StatusCode == http.StatusGatewayTimeout {
		if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "provider_timeout", resp.Header) {
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
	if coordinatorIdempotencyError(resp.StatusCode, body) {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
		return
	}
	if resp.StatusCode != http.StatusOK {
		if isNullUsageProviderError(body) {
			s.passThroughReceiptEligibleProviderError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, maxTokens)
			return
		}
		completion := completionFromHeaderCapped(resp.Header, maxTokens)
		if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "upstream_error", resp.Header) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	usage, ok, usageErr := usageFromJSON(body, maxUsageTokens, maxTokens)
	tokenSource := "gateway_estimated"
	if !ok {
		usage = tokenUsage{PromptTokens: promptEstimate, CachedPromptTokens: 0, CompletionTokens: 0, TotalTokens: promptEstimate}
	} else if usageErr != nil {
		if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "invalid_provider_usage", resp.Header) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "invalid_provider_usage", "Upstream provider returned invalid usage")
		return
	} else {
		tokenSource = "provider_reported"
	}
	if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, usage.PromptTokens, usage.CompletionTokens, maxUsageTokens, tokenSource, "ok", resp.Header) {
		return
	}
	body = usageBodyWithTokenUsage(body, usage)
	emitProviderAttribution(w.Header(), resp.Header)
	copyReceiptEligibleHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

// emitProviderAttribution surfaces the provider peer id under a public
// buyer-facing header name (X-Provider-Id) on the gateway response.
//
// Required by harness B5/B6 verdicts (slot utilization, per-provider
// earnings) and any downstream buyer that wants per-request provider
// attribution. The internal `X-MacProvider-Provider` header carrying
// the peer id is stripped by copyCleanHeaders /
// copyReceiptEligibleHeaders via isMacProviderHeader, so this MUST
// run BEFORE the copy/strip — and emit under a different prefix so it
// survives the strip.
//
// Only the peer id is surfaced. The companion `X-MacProvider-Route`
// header on coord responses carries a session-assigned routing token
// (auth-shaped, not a pure identifier) and is deliberately NOT
// emitted to buyers.
//
// Empty source values produce no output header (avoids leaking
// "X-Provider-Id: " sentinels on coord paths that don't carry
// provider attribution — coordinator policy errors, cold-start 503s
// without a peer selected, etc.).
func emitProviderAttribution(dst, src http.Header) {
	if v := src.Get("X-MacProvider-Provider"); v != "" {
		dst.Set("X-Provider-Id", v)
	}
}

func (s *Server) forwardStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate, maxUsageTokens, maxTokens int64, cancelUpstream func(), upstreamCtx context.Context, structuredStreaming bool, reservationWindow string) {
	if resp.StatusCode == http.StatusServiceUnavailable {
		body, _ := io.ReadAll(resp.Body)
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "no_provider_available", "No provider available")
		return
	}
	if resp.StatusCode != http.StatusOK {
		if resp.StatusCode == http.StatusGatewayTimeout {
			if !s.settleBeforeStreamingResponseWithCoordinatorFinality(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "provider_timeout", resp.Header) {
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
		if coordinatorIdempotencyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body)
			return
		}
		if !s.settleBeforeStreamingResponseWithCoordinatorFinality(w, r, subject, promptEstimate, completionFromHeaderCapped(resp.Header, maxTokens), maxUsageTokens, "gateway_estimated", "upstream_error", resp.Header) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	emitProviderAttribution(w.Header(), resp.Header)
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("X-MacProvider-Gateway-FirstByte-Unix-Ms", strconv.FormatInt(s.now().UnixMilli(), 10))
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	// Issue #190 R2 security HIGH: keep no-store (set at handler
	// entry) on streaming responses too — the SSE body carries
	// per-tenant X-RateLimit-*-Requests headers and must never be
	// cacheable by an intermediary. no-cache + no-transform are
	// the existing SSE-specific guarantees; we prepend no-store.
	w.Header().Set("Cache-Control", "no-store, no-cache, no-transform")
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
	terminalStructuredErrorCode := ""
	refundTerminalStructuredError := func() {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	}
	settleReported := func(outcome string) {
		usage := *reported
		observedRawCompletion := estimateTokensFromBytes(emitted)
		observedCompletion := estimateStreamingCompletionTokens(emitted, maxTokens)
		maxCompletion := maxStreamingCompletionTokens(maxTokens)
		if usage.CompletionTokens > maxCompletion {
			outcome = "stream_output_exceeded"
			if observedRawCompletion < usage.CompletionTokens {
				slog.Warn("streaming provider usage reported over max_tokens without matching emitted output; falling back to gateway estimate",
					"request_id", requestID(r),
					"account_id", subject.AccountID,
					"reported", usage.CompletionTokens,
					"observed", observedRawCompletion,
					"max_completion_tokens", maxCompletion,
				)
				s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, observedCompletion, maxUsageTokens, "gateway_estimated", outcome, reservationWindow, resp)
				return
			}
		}
		if providerUsageImplausiblyUnderreports(observedCompletion, usage.CompletionTokens) {
			slog.Warn("streaming provider usage implausibly under-reported completion tokens; falling back to gateway estimate",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"reported", usage.CompletionTokens,
				"observed", observedCompletion,
				"outcome", outcome,
			)
			s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, observedCompletion, maxUsageTokens, "gateway_estimated", outcome, reservationWindow, resp)
			return
		}
		s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, usage.PromptTokens, usage.CompletionTokens, maxUsageTokens, "provider_reported", outcome, reservationWindow, resp)
	}
	settleTruncated := func() {
		if reported != nil {
			settleReported("stream_truncated")
			return
		}
		s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, maxTokens), maxUsageTokens, "gateway_estimated", "stream_truncated", reservationWindow, resp)
	}
	settleCancelled := func() {
		cancelCoordinator()
		s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, maxTokens), maxUsageTokens, "gateway_estimated", "client_disconnect", reservationWindow, resp)
	}
	forwardLine := func(line []byte) bool {
		select {
		case <-r.Context().Done():
			if reported != nil {
				settleReported("client_disconnect")
				return false
			}
			settleCancelled()
			return false
		default:
		}
		text := strings.TrimRight(string(line), "\r\n")
		if data, ok := sseDataValue(text); ok {
			if data == "[DONE]" {
				if terminalStructuredErrorCode != "" {
					if _, err := w.Write(line); err != nil {
						slog.Warn("streaming buyer write failed", "request_id", requestID(r), "error", err)
					}
					if flusher != nil {
						flusher.Flush()
					}
					refundTerminalStructuredError()
					return false
				}
			} else {
				// SPEC-006 §17.7.1 clause 3 (#295): once we've
				// dispatched a terminal error envelope, no further
				// content `data:` frames may cross the wire to the
				// buyer before `[DONE]`. A malicious or buggy provider
				// that keeps emitting content after the envelope
				// violates the "last frame before [DONE]" contract;
				// drop the line and continue reading so the terminator
				// still fires the refund path.
				if terminalStructuredErrorCode != "" {
					return true
				}
				if code := terminalSSEErrorCode(data); isSpec019TerminalSSEErrorCode(code) {
					terminalStructuredErrorCode = code
					if _, err := w.Write(line); err != nil {
						slog.Warn("streaming buyer write failed", "request_id", requestID(r), "error", err)
						refundTerminalStructuredError()
						return false
					}
					if flusher != nil {
						flusher.Flush()
					}
					return true
				}
				deltaBytes, hasChoices, parseOK := streamingCompletionDeltaBytes(data)
				if !parseOK {
					slog.Warn("streaming gateway estimate saw malformed chunk; truncating stream", "request_id", requestID(r))
					writeSSEError(w, "Upstream stream returned malformed data", "api_error", "stream_malformed")
					if flusher != nil {
						flusher.Flush()
					}
					cancelCoordinator()
					completion := estimateStreamingCompletionTokens(emitted, maxTokens)
					s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "stream_malformed", reservationWindow, resp)
					return false
				}
				if deltaBytes > 0 {
					projectedCompletion := estimateTokensFromBytes(emitted + deltaBytes)
					maxCompletion := maxStreamingCompletionTokens(maxTokens)
					hardByteCeiling := maxCompletion * 8
					if hardByteCeiling < 1 {
						hardByteCeiling = 1
					}
					if emitted+deltaBytes > hardByteCeiling {
						slog.Warn("streaming gateway estimate exceeded hard byte ceiling; truncating stream", "request_id", requestID(r), "estimated_completion_tokens", projectedCompletion, "max_completion_tokens", maxCompletion, "emitted_bytes", emitted+deltaBytes, "hard_byte_ceiling", hardByteCeiling)
						writeSSEError(w, "Upstream stream exceeded requested max_tokens", "api_error", "stream_output_exceeded")
						if flusher != nil {
							flusher.Flush()
						}
						cancelCoordinator()
						s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, maxCompletion, maxUsageTokens, "gateway_estimated", "stream_output_exceeded", reservationWindow, resp)
						return false
					}
					emitted += deltaBytes
				}
				if usage, ok, err := usageFromJSON([]byte(data), maxUsageTokens, maxTokens, true); ok {
					if err != nil {
						invalidReportedUsage = true
						reported = nil
						slog.Warn("invalid provider usage in stream; falling back to gateway estimate", "request_id", requestID(r), "error", err)
						line = nil
					} else if !invalidReportedUsage {
						reported = &usage
						line = sseDataLineWithCachedPromptTokens(line, usage.CachedPromptTokens)
					} else {
						line = nil
					}
				} else if !hasChoices {
					slog.Warn("streaming gateway estimate saw data chunk without choices or usage; truncating stream", "request_id", requestID(r))
					writeSSEError(w, "Upstream stream returned malformed data", "api_error", "stream_malformed")
					if flusher != nil {
						flusher.Flush()
					}
					cancelCoordinator()
					completion := estimateStreamingCompletionTokens(emitted, maxTokens)
					s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "stream_malformed", reservationWindow, resp)
					return false
				}
			}
		}
		if len(line) == 0 {
			return true
		}
		if _, err := w.Write(line); err != nil {
			slog.Warn("streaming buyer write failed", "request_id", requestID(r), "error", err)
			if reported != nil {
				settleReported("client_disconnect")
				return false
			}
			settleCancelled()
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
			// Gateway-side truncation due to oversized line — NOT a
			// provider disconnect. Keep the legacy stream_truncated /
			// api_error envelope; this is gateway protection, not
			// upstream failure.
			writeSSEError(w, "Upstream stream failed", "api_error", "stream_truncated")
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
				settleReported("client_disconnect")
				return
			}
			settleCancelled()
			return
		}
		slog.Error("streaming coordinator read failed", "request_id", requestID(r), "error", err)
		// SPEC-019 v0.2 AC-V2-3a: if the provider already sent a
		// terminal SPEC-019 SSE error frame (forwarded verbatim to
		// the buyer above), an upstream read failure here MUST NOT
		// emit a SECOND terminal frame on top. The buyer-visible
		// terminal state is already correct; refund and return.
		// Skipping this guard would double-write (provider_timeout
		// or provider_disconnected) over the already-forwarded
		// SPEC-019 error and emit a positive usage_events outcome.
		if terminalStructuredErrorCode != "" {
			refundTerminalStructuredError()
			return
		}
		// SPEC-002 § FR-B6 / issue #186: an unexpected read error on
		// the coordinator-side stream (not EOF, not buyer cancel) is
		// the mid-stream provider-disconnect surface. The buyer MUST
		// see the exact FR-B6 envelope so OpenAI-compatible SDKs
		// distinguish a truncated successful response from a provider
		// drop and react (retry / surface to caller). The internal
		// settlement outcome remains `stream_truncated` per the gateway
		// settlement convention + SPEC-006 § 17.7 quota-debit policy —
		// that maps to usage_events.outcome, a separate field from the
		// buyer-visible SSE error.code.
		//
		// NOTE: error.type=server_error signals OpenAI-compatible SDKs
		// that the request is retriable. Gateway-side Idempotency-Key
		// dedupe is the open follow-up tracked in issue #200 — until
		// that lands, a buyer retrying after this envelope MAY incur
		// a fresh reservation if the coordinator's idempotency-cache
		// response isn't refund-honored on the gateway side.
		if structuredStreaming && errors.Is(upstreamCtx.Err(), context.DeadlineExceeded) {
			writeStructuredOutputTimeoutSSE(w, requestID(r))
			if flusher != nil {
				flusher.Flush()
			}
			s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, maxTokens), maxUsageTokens, "gateway_estimated", "provider_timeout", reservationWindow, resp)
			return
		}
		writeProviderDisconnectedSSE(w)
		if flusher != nil {
			flusher.Flush()
		}
		settleTruncated()
		return
	}
	if errors.Is(r.Context().Err(), context.Canceled) {
		if reported != nil {
			settleReported("client_disconnect")
			return
		}
		settleCancelled()
		return
	}
	if terminalStructuredErrorCode != "" {
		refundTerminalStructuredError()
		return
	}
	if reported != nil && !invalidReportedUsage {
		settleReported("ok")
		return
	}
	completion := estimateStreamingCompletionTokens(emitted, maxTokens)
	outcome := "ok"
	if estimateTokensFromBytes(emitted) > maxStreamingCompletionTokens(maxTokens) {
		outcome = "stream_output_exceeded"
	}
	s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", outcome, reservationWindow, resp)
}

func (s *Server) passThroughNoProviderCoordinatorError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte) {
	_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func (s *Server) passThroughReceiptEligibleProviderError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte, promptEstimate, maxUsageTokens, maxTokens int64) {
	completion := completionFromHeaderCapped(resp.Header, maxTokens)
	finality := coordinatorSettlementFinalityFromHeaders(resp.Header)
	switch finality.Action {
	case settlementFinalityLegacy, settlementFinalityRefund:
		if err := s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
			slog.Error("gateway settlement refund failed before provider error response",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"error", err,
			)
			writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
			return
		}
	case settlementFinalityDebit:
		if !s.settleBeforeResponse(w, r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "upstream_error") {
			return
		}
	case settlementFinalityHold:
		holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if !s.boundStreamingSettlementHold(holdCtx, r, subject, finality) {
			writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
			return
		}
		slog.Info("gateway deferred buyer settlement pending coordinator receipt finality",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
		)
	}
	// PR #250 R1 code MEDIUM: this path serves provider-SELECTED
	// errors (null-usage 5xx, etc.) where the coord did pick a
	// provider before the failure (server.go:1886, :1909 set
	// X-MacProvider-Provider on selected-provider non-200 responses).
	// Without emitting attribution here, B5/B6 benchmark verdicts
	// would still mis-attribute provider-side failures as anonymous.
	// passThroughNoProviderCoordinatorError stays unchanged because
	// no provider was selected on its callers' paths.
	emitProviderAttribution(w.Header(), resp.Header)
	copyReceiptEligibleHeaders(w.Header(), resp.Header)
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func isNullUsageProviderError(body []byte) bool {
	switch openAIErrorCode(body) {
	case "error_model_not_loaded", "error_context_exceeded", "error_queue_full", "error_internal", "malformed_json_response", "json_schema_validation_failed":
		return true
	default:
		return false
	}
}

func contentEncodingSupported(values []string) bool {
	if len(values) == 0 {
		return true
	}
	normalized := strings.ToLower(strings.Join(values, ","))
	normalized = strings.Map(func(r rune) rune {
		if r == ' ' || r == '\t' || r == '\n' || r == '\r' {
			return -1
		}
		return r
	}, normalized)
	return normalized == "identity"
}

// coordinatorIdempotencyError detects coordinator-issued 409 responses
// that signal "no provider work happened, no charge due" — the two
// known cases for buyer-supplied Idempotency-Key:
//
//   - idempotency_key_replayed: same key + same body. The original
//     request already settled; the retry hit dedupe.
//   - idempotency_key_body_mismatch: same key + different body (buyer
//     error).
//
// In either case the gateway must refund the reservation it just
// made (the request never reached a provider) and pass the coord
// response through verbatim so the buyer sees the idempotency
// semantics, not an opaque 502. Closes #200.
func coordinatorIdempotencyError(status int, body []byte) bool {
	if status != http.StatusConflict {
		return false
	}
	switch openAIErrorCode(body) {
	case "idempotency_key_replayed", "idempotency_key_body_mismatch":
		return true
	}
	return false
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

func (s *Server) settleCancelledStream(r *http.Request, subject usageSubject, promptEstimate, emitted, maxUsageTokens, maxTokens int64, cancelCoordinator func(), reservationWindow string) {
	cancelCoordinator()
	s.settleAfterCommit(r, subject, promptEstimate, estimateStreamingCompletionTokens(emitted, maxTokens), maxUsageTokens, "gateway_estimated", "client_disconnect", reservationWindow)
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

func (s *Server) settleBeforeResponseWithCoordinatorFinality(w http.ResponseWriter, r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string, h http.Header) bool {
	return s.settleBeforeResponseWithCoordinatorFinalityPolicy(w, r, subject, prompt, completion, maxTotal, source, outcome, h, false)
}

func (s *Server) settleBeforeStreamingResponseWithCoordinatorFinality(w http.ResponseWriter, r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string, h http.Header) bool {
	return s.settleBeforeResponseWithCoordinatorFinalityPolicy(w, r, subject, prompt, completion, maxTotal, source, outcome, h, true)
}

func (s *Server) settleBeforeResponseWithCoordinatorFinalityPolicy(w http.ResponseWriter, r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string, h http.Header, boundHold bool) bool {
	finality := coordinatorSettlementFinalityFromHeaders(h)
	switch finality.Action {
	case settlementFinalityLegacy, settlementFinalityDebit:
		return s.settleBeforeResponse(w, r, subject, prompt, completion, maxTotal, source, outcome)
	case settlementFinalityRefund:
		if err := s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
			slog.Error("gateway settlement refund failed before response",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"error", err,
			)
			writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
			return false
		}
		return true
	case settlementFinalityHold:
		holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if !s.boundStreamingSettlementHold(holdCtx, r, subject, finality) {
			writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
			return false
		}
		slog.Info("gateway deferred buyer settlement pending coordinator receipt finality",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_hold_bound", boundHold,
		)
		return true
	default:
		return s.settleBeforeResponse(w, r, subject, prompt, completion, maxTotal, source, outcome)
	}
}

func (s *Server) settleStreamingAfterCommitWithCoordinatorFinality(r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome, reservationWindow string, resp *http.Response) {
	finality := coordinatorStreamingSettlementFinality(resp)
	switch finality.Action {
	case settlementFinalityLegacy:
		s.settleAfterCommit(r, subject, prompt, completion, maxTotal, source, outcome, reservationWindow)
	case settlementFinalityDebit:
		s.markStreamingSettlementHoldForReconciliation(r, subject, finality)
	case settlementFinalityRefund:
		if err := s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
			slog.Error("gateway streaming settlement refund failed after coordinator receipt finality",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"error", err,
			)
		}
	case settlementFinalityHold:
		holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if !s.boundStreamingSettlementHold(holdCtx, r, subject, finality) {
			slog.Error("gateway failed to persist streaming settlement hold after coordinator finality",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
			)
		}
	default:
		s.settleAfterCommit(r, subject, prompt, completion, maxTotal, source, outcome, reservationWindow)
	}
}

func (s *Server) markStreamingSettlementHoldForReconciliation(r *http.Request, subject usageSubject, finality coordinatorSettlementFinality) {
	holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := s.store.MarkReservationSettlementHold(holdCtx, subject.AccountID, requestID(r)); err != nil {
		if errors.Is(err, storage.ErrReservationNotFound) || errors.Is(err, storage.ErrReservationTerminal) {
			slog.Info("gateway skipped streaming settlement hold after coordinator finality because reservation is not active",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"error", err,
			)
			return
		}
		slog.Error("gateway failed to mark streaming settlement hold after coordinator finality",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"error", err,
		)
		refundCtx, refundCancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer refundCancel()
		if refundErr := s.store.RefundReservation(refundCtx, subject.AccountID, requestID(r), s.now().Unix()); refundErr != nil && !errors.Is(refundErr, storage.ErrReservationNotFound) && !errors.Is(refundErr, storage.ErrReservationTerminal) {
			slog.Error("gateway failed to refund streaming reservation after settlement hold marker failure",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"error", refundErr,
			)
		}
		return
	}
	slog.Info("gateway deferred verified streaming buyer settlement to SPEC-022 reconciler",
		"request_id", requestID(r),
		"account_id", subject.AccountID,
		"settlement_outcome", finality.Outcome,
		"settlement_reason", finality.Reason,
	)
}

func (s *Server) boundStreamingSettlementHold(ctx context.Context, r *http.Request, subject usageSubject, finality coordinatorSettlementFinality) bool {
	now := s.now()
	deadline := time.Time{}
	if finality.PendingDeadlineUnixMS > 0 {
		deadline = time.UnixMilli(finality.PendingDeadlineUnixMS).UTC()
	}
	if !deadline.IsZero() && !deadline.After(now) {
		if err := s.store.RefundReservation(ctx, subject.AccountID, requestID(r), now.Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
			slog.Error("gateway streaming settlement hold refund failed",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
				"error", err,
			)
			return false
		}
		slog.Info("gateway released streaming buyer reservation without trustworthy coordinator receipt deadline",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
		)
		return true
	}
	if deadline.IsZero() {
		if finality.Reason == "missing_settlement_finality_trailer" {
			if err := s.store.RefundReservation(ctx, subject.AccountID, requestID(r), now.Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
				slog.Error("gateway streaming settlement hold refund failed",
					"request_id", requestID(r),
					"account_id", subject.AccountID,
					"settlement_outcome", finality.Outcome,
					"settlement_reason", finality.Reason,
					"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
					"error", err,
				)
				return false
			}
			slog.Info("gateway released streaming buyer reservation without coordinator settlement finality",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"settlement_outcome", finality.Outcome,
				"settlement_reason", finality.Reason,
				"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
			)
			return true
		}
		deadline = now.Add(settlementHoldFallbackTTL).UTC()
		slog.Info("gateway bounded streaming settlement hold to local fallback deadline",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
			"settlement_fallback_deadline_unix_ms", deadline.UnixMilli(),
		)
	}
	if err := s.store.MarkReservationSettlementHold(ctx, subject.AccountID, requestID(r)); err != nil && !errors.Is(err, storage.ErrReservationNotFound) && !errors.Is(err, storage.ErrReservationTerminal) {
		slog.Error("gateway streaming settlement hold marker failed",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
			"error", err,
		)
		return false
	}
	if err := s.store.ClampReservationExpiry(ctx, subject.AccountID, requestID(r), deadline); err != nil && !errors.Is(err, storage.ErrReservationNotFound) && !errors.Is(err, storage.ErrReservationTerminal) {
		slog.Error("gateway streaming settlement hold deadline clamp failed",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
			"error", err,
		)
		return false
	}
	slog.Info("gateway bounded streaming buyer settlement hold to receipt deadline",
		"request_id", requestID(r),
		"account_id", subject.AccountID,
		"settlement_outcome", finality.Outcome,
		"settlement_reason", finality.Reason,
		"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
		"settlement_hold_deadline_unix_ms", deadline.UnixMilli(),
	)
	return true
}

func coordinatorStreamingSettlementFinality(resp *http.Response) coordinatorSettlementFinality {
	if resp == nil {
		return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
	}
	if hasAnySettlementFinalityHeader(resp.Trailer) {
		return coordinatorSettlementFinalityFromHeaders(resp.Trailer)
	}
	if hasSettlementFinalityTrailerDeclaration(resp) {
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: "missing_settlement_finality_trailer"}
	}
	return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
}

func coordinatorSettlementFinalityFromHeaders(h http.Header) coordinatorSettlementFinality {
	if !hasAnySettlementFinalityHeader(h) {
		return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
	}
	mode := strings.TrimSpace(h.Get(settlementModeHeader))
	if mode == "observe" {
		return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
	}
	if mode != "enforce" {
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: "invalid_settlement_mode"}
	}
	policyVersion := strings.TrimSpace(h.Get(settlementPolicyVersionHeader))
	if policyVersion != settlementPolicyVersion {
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: "invalid_settlement_policy_version"}
	}
	outcome := strings.TrimSpace(h.Get(settlementOutcomeHeader))
	if outcome == "" {
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: "missing_settlement_outcome"}
	}
	receiptResult := strings.TrimSpace(h.Get(settlementReceiptResultHeader))
	reason := strings.TrimSpace(h.Get(settlementReasonHeader))
	closed, closedOK := parseSettlementClosedHeader(h.Get(settlementClosedHeader))
	pendingDeadlineUnixMS := parseSettlementPendingDeadlineUnixMS(h.Get(settlementPendingUntilHeader))
	switch outcome {
	case "verified":
		if receiptResult == "valid" && closedOK && closed {
			return coordinatorSettlementFinality{Action: settlementFinalityDebit, Outcome: outcome, Reason: reason, PendingDeadlineUnixMS: pendingDeadlineUnixMS}
		}
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Outcome: outcome, Reason: "verified_receipt_not_final", PendingDeadlineUnixMS: pendingDeadlineUnixMS}
	case "quarantined", "zero_settled":
		if closedOK && closed && settlementRefundReceiptResultValid(outcome, receiptResult) {
			return coordinatorSettlementFinality{Action: settlementFinalityRefund, Outcome: outcome, Reason: reason, PendingDeadlineUnixMS: pendingDeadlineUnixMS}
		}
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Outcome: outcome, Reason: "settlement_refund_tuple_incomplete", PendingDeadlineUnixMS: pendingDeadlineUnixMS}
	case "pending":
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Outcome: outcome, Reason: reason, PendingDeadlineUnixMS: pendingDeadlineUnixMS}
	default:
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Outcome: outcome, Reason: "unrecognized_settlement_outcome", PendingDeadlineUnixMS: pendingDeadlineUnixMS}
	}
}

func hasAnySettlementFinalityHeader(h http.Header) bool {
	for _, header := range []string{
		settlementOutcomeHeader,
		settlementReceiptResultHeader,
		settlementReasonHeader,
		settlementClosedHeader,
		settlementModeHeader,
		settlementPolicyVersionHeader,
		settlementPendingUntilHeader,
	} {
		if strings.TrimSpace(h.Get(header)) != "" {
			return true
		}
	}
	return false
}

func hasSettlementFinalityTrailerDeclaration(resp *http.Response) bool {
	if resp == nil {
		return false
	}
	for _, value := range resp.Header.Values("Trailer") {
		for _, name := range strings.Split(value, ",") {
			if isSettlementFinalityHeader(strings.TrimSpace(name)) {
				return true
			}
		}
	}
	for name := range resp.Trailer {
		if isSettlementFinalityHeader(name) {
			return true
		}
	}
	return false
}

func isSettlementFinalityHeader(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case strings.ToLower(settlementOutcomeHeader),
		strings.ToLower(settlementReceiptResultHeader),
		strings.ToLower(settlementReasonHeader),
		strings.ToLower(settlementClosedHeader),
		strings.ToLower(settlementModeHeader),
		strings.ToLower(settlementPolicyVersionHeader),
		strings.ToLower(settlementPendingUntilHeader):
		return true
	default:
		return false
	}
}

func settlementRefundReceiptResultValid(outcome, receiptResult string) bool {
	switch outcome {
	case "zero_settled":
		return receiptResult == "valid"
	case "quarantined":
		return receiptResult == "invalid" || receiptResult == "inconclusive"
	default:
		return false
	}
}

func parseSettlementClosedHeader(raw string) (bool, bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return false, false
	}
	closed, err := strconv.ParseBool(raw)
	return closed, err == nil
}

func parseSettlementPendingDeadlineUnixMS(raw string) int64 {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 0
	}
	deadline, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || deadline <= 0 {
		return 0
	}
	return deadline
}

func (s *Server) settleAfterCommit(r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome, reservationWindow string) {
	if err := s.settleRequest(r, subject, prompt, completion, maxTotal, source, outcome); err != nil {
		slog.Error("gateway settlement failed after response commit",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"source", source,
			"outcome", outcome,
			"error", err,
		)
		// SPEC-006 § 17.7 / issue #187: response bytes already flowed
		// to the buyer. The buyer MUST be debited and the audit row
		// (gateway-side usage_events) MUST exist regardless of why
		// SettleReservation failed (missing reservation, status
		// drift, transient DB error). Pre-#187 behavior fell back to
		// RefundReservation, silently losing the audit row and
		// undercharging the buyer.
		//
		// SCOPE: this fallback restores the BUYER-SIDE billing
		// invariant. The provider-credit / mirror path lives on the
		// COORDINATOR (per SPEC-005 § 10.3, "SPEC-005 does NOT read
		// SPEC-006 usage tables"; provider credit composes from
		// coordinator request_log), so the SPEC-005 mirror is
		// unaffected by this fix.
		//
		// WINDOW: use the reservation window captured at admission
		// time (not s.now()) so a stream that crosses UTC midnight
		// settles against the SAME daily quota window the buyer's
		// reservation was made against. ISS-187 R1 architect+code
		// MAJOR.
		window := reservationWindow
		if window == "" {
			window = s.now().UTC().Format("2006-01-02")
		}
		ev := storage.UsageEvent{
			RequestID:        requestID(r),
			AccountID:        subject.AccountID,
			DemoIdentity:     subject.DemoIdentity,
			WindowDate:       window,
			PromptTokens:     prompt,
			CompletionTokens: completion,
			TotalTokens:      prompt + completion,
			TokenSource:      source,
			Outcome:          outcome,
			CreatedAt:        s.now(),
		}
		if fallbackErr := s.store.EnsureUsageEvent(context.Background(), ev); fallbackErr != nil {
			// Both the normal settle path and the idempotent fallback
			// failed. Could be a genuine DB pathology OR (per #196 PK
			// collision territory) a cross-account request_id
			// collision detected via row-mismatch verify inside
			// EnsureUsageEvent. Log loudly and release the
			// reservation hold so the buyer's quota is not held
			// forever. The audit row is lost; operators must
			// reconcile from coordinator-side request_log.
			slog.Error("gateway SPEC-006 § 17.7 fallback usage_events insert failed",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"source", source,
				"outcome", outcome,
				"settle_error", err.Error(),
				"fallback_error", fallbackErr.Error(),
			)
			_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
			return
		}
		// Fallback insert succeeded (or the row already existed via
		// race AND matches by full billing payload). The buyer is now
		// debited via usage_events.
		//
		// R3 architect MINOR: for demo-token requests, also write
		// the matching demo_usage_events row idempotently so the
		// demo-side audit trail required by SPEC-006 §4.5 / §14.3
		// stays consistent with the buyer-side usage_events row.
		// EnsureDemoUsageEvent is INSERT OR IGNORE on PK; a failure
		// here is non-fatal because the usage_events row above is the
		// load-bearing money-path record.
		if subject.DemoIdentity != "" {
			if demoErr := s.store.EnsureDemoUsageEvent(context.Background(), storage.DemoUsageEvent{
				RequestID:     requestID(r),
				ClientIP:      subject.DemoIdentity,
				DemoTokenHash: subject.DemoTokenHash,
				WindowDate:    window,
				TotalTokens:   prompt + completion,
				CreatedAt:     s.now(),
			}); demoErr != nil {
				slog.Warn("gateway SPEC-006 fallback demo_usage_events insert failed (usage_events row is OK)",
					"request_id", requestID(r),
					"account_id", subject.AccountID,
					"demo_identity", subject.DemoIdentity,
					"error", demoErr.Error(),
				)
			}
		}
		//
		// R2 architect MAJOR: release any still-active reservation
		// hold so DailyUsage doesn't double-count the buyer's quota
		// (sum of usage_events.total_tokens AND active
		// quota_reservations.reserved_tokens). RefundReservation is a
		// no-op when the reservation row is missing or already
		// terminal (which is the common case here — settle_error was
		// ErrReservationNotFound or status != 'active'); when the row
		// IS still active (e.g., settleRequest failed on a transient
		// DB error, leaving the reservation row in 'active' state),
		// the call releases the quota hold.
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		slog.Warn("gateway settlement used SPEC-006 § 17.7 fallback usage_events insert (settle_path failure)",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"outcome", outcome,
			"settle_error", err.Error(),
		)
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

// estimateStreamingCompletionTokens caps the streaming-fallback
// completion-token estimate at the buyer's max_tokens. Pre-2026-06-28
// this derived the cap as `maxUsageTokens - promptEstimate`, which
// silently inflated by the prompt-cap headroom (R1 CODE HIGH #1):
// a buyer who set max_tokens=1 could be billed 65 completion tokens
// because maxUsageTokens-promptEstimate = 64 headroom + 1. Now we
// take maxTokens directly so the billed completion side honors the
// buyer's stated cap regardless of the cap-headroom-vs-billing split.
func estimateStreamingCompletionTokens(emitted, maxTokens int64) int64 {
	completion := estimateTokensFromBytes(emitted)
	if completion > maxTokens {
		return maxTokens
	}
	return completion
}

func providerUsageImplausiblyUnderreports(observed, reported int64) bool {
	if observed <= reported {
		return false
	}
	gap := observed - reported
	if gap <= 20 {
		return false
	}
	if reported == 0 {
		return true
	}
	if observed > math.MaxInt64/2 || reported > math.MaxInt64/3 {
		return false
	}
	return observed*2 > reported*3
}

func maxStreamingCompletionTokens(maxTokens int64) int64 {
	if maxTokens < 0 {
		return 0
	}
	return maxTokens
}

func estimateTokensFromBytes(n int64) int64 {
	return int64(math.Ceil(float64(n) / 4.0))
}

func streamingCompletionDeltaBytes(data string) (int64, bool, bool) {
	var envelope struct {
		Choices []struct {
			Delta json.RawMessage `json:"delta"`
		} `json:"choices"`
	}
	if err := json.Unmarshal([]byte(data), &envelope); err != nil {
		return 0, false, false
	}
	var n int64
	for _, choice := range envelope.Choices {
		if len(choice.Delta) == 0 || bytes.Equal(choice.Delta, []byte("null")) {
			continue
		}
		deltaBytes, ok := generatedDeltaStringBytes(choice.Delta)
		if !ok {
			return 0, false, false
		}
		n += deltaBytes
	}
	return n, len(envelope.Choices) > 0, true
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

// terminalSSEErrorCode extracts the SPEC-006 §17.7.1 terminal error
// envelope code from an SSE data payload, but ONLY when the payload
// satisfies the "standalone envelope" clause: no `choices` key, no
// `usage` key at all (any presence — even zero tokens or empty
// containers — is rejected). A payload with `error.code` alongside
// content deltas or usage-token accounting is structurally inconsistent
// with the contract (a terminal envelope is the LAST buyer-visible
// frame before `[DONE]` and cannot carry content) and is rejected.
// Returns "" for non-standalone or unparseable payloads. Origin: #295
// (§17.7.1 producer-side enforcement, harness-side counterpart in #232).
//
// Parser is token-level (not lossy struct unmarshal) to defend against
// #295 R1 SEC/ARCH convergent HIGH bypasses:
//   - Duplicate keys: `{"choices":[{...}],"choices":[]}` — struct
//     unmarshal keeps the second value (empty), letting the frame
//     satisfy `len(choices) == 0` while the wire bytes still carry
//     content the buyer sees.
//   - Non-enumerated usage subfields: `{"usage":{"total_tokens":10}}`
//     is not covered by prompt/completion checks but still constitutes
//     usage accounting on a supposed "standalone" envelope.
//
// The strict parser rejects ANY presence of `choices` or `usage`, plus
// any duplicate top-level key, aligning with SPEC-006 §17.7.1's "no
// choices field, no usage field" clause literally.
func terminalSSEErrorCode(data string) string {
	dec := json.NewDecoder(strings.NewReader(data))
	tok, err := dec.Token()
	if err != nil {
		return ""
	}
	delim, ok := tok.(json.Delim)
	if !ok || delim != '{' {
		return ""
	}
	var code string
	seen := make(map[string]struct{})
	for dec.More() {
		keyTok, err := dec.Token()
		if err != nil {
			return ""
		}
		key, ok := keyTok.(string)
		if !ok {
			return ""
		}
		if _, dup := seen[key]; dup {
			// Duplicate top-level key on a purported terminal
			// envelope is a smuggling shape: reject unconditionally.
			return ""
		}
		seen[key] = struct{}{}
		switch key {
		case "choices", "usage":
			// SPEC-006 §17.7.1: standalone envelope has NO choices
			// and NO usage. Presence of the key at all — regardless
			// of value shape — disqualifies the frame.
			return ""
		case "error":
			// Parse `error` token-by-token to defend against nested
			// duplicate `code` keys — `{"error":{"code":"upstream",
			// "code":"provider_timeout"}}` — where a lossy decode
			// would keep the last value and let an attacker smuggle
			// a SPEC-019-listed code past the allow-list check.
			// (#295 R2 SEC MED.)
			errTok, err := dec.Token()
			if err != nil {
				return ""
			}
			errDelim, ok := errTok.(json.Delim)
			if !ok || errDelim != '{' {
				return ""
			}
			var errCode string
			errSeen := make(map[string]struct{})
			for dec.More() {
				eKeyTok, err := dec.Token()
				if err != nil {
					return ""
				}
				eKey, ok := eKeyTok.(string)
				if !ok {
					return ""
				}
				if _, dup := errSeen[eKey]; dup {
					return ""
				}
				errSeen[eKey] = struct{}{}
				if eKey == "code" {
					v, err := dec.Token()
					if err != nil {
						return ""
					}
					s, ok := v.(string)
					if !ok {
						return ""
					}
					errCode = strings.TrimSpace(s)
				} else {
					var raw json.RawMessage
					if err := dec.Decode(&raw); err != nil {
						return ""
					}
				}
			}
			if _, err := dec.Token(); err != nil {
				return ""
			}
			code = errCode
		default:
			// Other top-level fields (id, object, created, model,
			// etc.) are innocuous metadata; skip past their value.
			var raw json.RawMessage
			if err := dec.Decode(&raw); err != nil {
				return ""
			}
		}
	}
	// Consume the closing '}'.
	if _, err := dec.Token(); err != nil {
		return ""
	}
	// Reject trailing garbage after the object. `dec.Token()` at EOF
	// returns io.EOF; anything else (another value OR a syntax error
	// on invalid trailing bytes) means the input is not a clean
	// standalone envelope. (#295 R2 SEC HIGH — prior implementation
	// only checked err==nil, so invalid suffixes like `{...}x` fell
	// through to accept.)
	if _, err := dec.Token(); err != io.EOF {
		return ""
	}
	return code
}

func isSpec019TerminalSSEErrorCode(code string) bool {
	// AC-V2-3a + AC-V2-9 + AC-V2-9b (SPEC-019 v0.2.4 §5): these
	// four terminal structured-output codes are the canonical table.
	// Asymmetry across provider WS, coordinator SSE, and gateway SSE
	// allow-lists is a money-path violation.
	switch code {
	case "malformed_json_response", "json_schema_validation_failed", "response_byte_cap_exceeded", "provider_timeout":
		return true
	default:
		return false
	}
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

// writeSSEError emits an SSE error event followed by `data: [DONE]`.
// errType is the OpenAI error `type` field. Call sites use this
// helper for several mid-stream error shapes: malformed upstream
// chunks (api_error / stream_malformed), max-tokens overflow
// (api_error / stream_output_exceeded), gateway-side line
// truncation (api_error / stream_truncated), and the SPEC-002
// FR-B6 provider-disconnect envelope (server_error /
// provider_disconnected). The FR-B6 envelope is built via the
// dedicated writeProviderDisconnectedSSE wrapper so its strings
// are centralized and resistant to drift.
func writeSSEError(w http.ResponseWriter, message, errType, code string) {
	payload, _ := json.Marshal(map[string]any{"error": map[string]any{"message": message, "type": errType, "code": code}})
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(payload)
	_, _ = w.Write([]byte("\n\ndata: [DONE]\n\n"))
}

func writeStructuredOutputTimeoutSSE(w http.ResponseWriter, requestID string) {
	// AC-V2-9 (SPEC-019 v0.2.4 §10): gateway wall-clock timeout emits
	// provider_timeout with refund-only settlement semantics.
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	payload, _ := json.Marshal(map[string]any{
		"error": map[string]any{
			"message":        "Provider timed out during structured-output streaming",
			"type":           "api_error",
			"param":          nil,
			"code":           "provider_timeout",
			"retryable":      false,
			"request_id":     requestID,
			"inference_ran":  true,
			"settlement_ran": true,
		},
	})
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(payload)
	_, _ = w.Write([]byte("\n\ndata: [DONE]\n\n"))
}

// writeProviderDisconnectedSSE emits the SPEC-002 § FR-B6 mid-stream
// provider-disconnect envelope verbatim. The strings are
// load-bearing: SDK clients route on (error.code, error.type) and
// any drift breaks compatibility. Centralizing the call here lets
// future refactors lean on a single named contract surface instead
// of free-form writeSSEError args. Issue #186; architect R1 NOTE.
func writeProviderDisconnectedSSE(w http.ResponseWriter) {
	writeSSEError(w, "Provider disconnected during streaming", "server_error", "provider_disconnected")
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

// usageFromJSON validates and parses provider-reported usage.
//
// maxUsageTokens — overall ceiling on prompt + completion tokens
// (computed from promptCapTokens(body) + maxTokens at the call site
// so the chat-template headroom is included).
//
// maxCompletion is enforced for non-streaming responses. Streaming
// callers can allow completion_tokens above max_tokens so a provider
// usage chunk can settle as stream_output_exceeded instead of being
// treated as malformed usage.
func usageFromJSON(body []byte, maxUsageTokens, maxCompletion int64, allowCompletionOverMax ...bool) (tokenUsage, bool, error) {
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
		PromptTokens       *int64          `json:"prompt_tokens"`
		CachedPromptTokens json.RawMessage `json:"cached_prompt_tokens"`
		CompletionTokens   *int64          `json:"completion_tokens"`
		TotalTokens        *int64          `json:"total_tokens"`
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
	usage.CachedPromptTokens = sanitizedCachedPromptTokens(rawUsage.CachedPromptTokens, usage.PromptTokens)
	if usage.PromptTokens > math.MaxInt64-usage.CompletionTokens {
		return tokenUsage{}, true, fmt.Errorf("usage token total overflows int64")
	}
	if len(allowCompletionOverMax) == 0 && usage.CompletionTokens > maxCompletion {
		return tokenUsage{}, true, fmt.Errorf("usage completion_tokens exceeds request max_tokens")
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

func sanitizedCachedPromptTokens(raw json.RawMessage, promptTokens int64) int64 {
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return 0
	}
	var cached int64
	if err := json.Unmarshal(raw, &cached); err != nil {
		return 0
	}
	if cached < 0 || cached > promptTokens {
		return 0
	}
	return cached
}

func usageBodyWithTokenUsage(body []byte, usage tokenUsage) []byte {
	updated, ok := usageJSONWithCachedPromptTokens(body, usage.CachedPromptTokens)
	if ok {
		return updated
	}
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return body
	}
	total := usage.TotalTokens
	if total == 0 {
		total = usage.PromptTokens + usage.CompletionTokens
	}
	usageObject := map[string]int64{
		"prompt_tokens":        usage.PromptTokens,
		"completion_tokens":    usage.CompletionTokens,
		"total_tokens":         total,
		"cached_prompt_tokens": usage.CachedPromptTokens,
	}
	rawUsage, err := json.Marshal(usageObject)
	if err != nil {
		return body
	}
	envelope["usage"] = rawUsage
	updated, err = json.Marshal(envelope)
	if err != nil {
		return body
	}
	return updated
}

func sseDataLineWithCachedPromptTokens(line []byte, cachedPromptTokens int64) []byte {
	text := string(line)
	trimmed := strings.TrimRight(text, "\r\n")
	suffix := text[len(trimmed):]
	data, ok := sseDataValue(trimmed)
	if !ok || data == "[DONE]" {
		return line
	}
	updated, ok := usageJSONWithCachedPromptTokens([]byte(data), cachedPromptTokens)
	if !ok {
		return line
	}
	return []byte("data: " + string(updated) + suffix)
}

func usageJSONWithCachedPromptTokens(body []byte, cachedPromptTokens int64) ([]byte, bool) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(body, &envelope); err != nil {
		return nil, false
	}
	rawUsage, ok := envelope["usage"]
	if !ok || bytes.Equal(bytes.TrimSpace(rawUsage), []byte("null")) {
		return nil, false
	}
	var usage map[string]json.RawMessage
	if err := json.Unmarshal(rawUsage, &usage); err != nil {
		return nil, false
	}
	if cachedPromptTokens < 0 {
		cachedPromptTokens = 0
	}
	encoded, err := json.Marshal(cachedPromptTokens)
	if err != nil {
		return nil, false
	}
	usage["cached_prompt_tokens"] = encoded
	rawUsage, err = json.Marshal(usage)
	if err != nil {
		return nil, false
	}
	envelope["usage"] = rawUsage
	updated, err := json.Marshal(envelope)
	if err != nil {
		return nil, false
	}
	return updated, true
}

// completionFromHeader reads the upstream's X-MacProvider-Completion-Tokens
// hint and clamps it to maxTokens. Without the clamp, an upstream that
// reports a header value above the buyer's max_tokens could over-bill
// the buyer through the upstream-error and provider-timeout
// settlement paths — same shape as the inline-usage HIGH #1 closed
// by usageFromJSON's separate maxCompletion check (R2 CODE HIGH,
// 2026-06-28).
func completionFromHeaderCapped(header http.Header, maxTokens int64) int64 {
	c := completionFromHeader(header)
	if c > maxTokens {
		return maxTokens
	}
	return c
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

// estimatePromptTokens — billable prompt-token count for the gateway-
// estimated settlement paths (provider error, invalid_provider_usage
// fallback, streaming pre-commit cancel, etc.). This is what the
// buyer actually pays for on those paths, so the value is the
// conservative byte-heuristic (NO headroom). The value also seeds
// the streaming completion-token estimate and the receipt audit
// trail.
//
// Headroom for the VALIDATION cap is added separately by
// promptCapTokens; conflating the two would over-charge the buyer on
// every error path (R1 CODE HIGH #2, 2026-06-28).
func estimatePromptTokens(body []byte) int64 {
	if len(body) == 0 {
		return 0
	}
	return int64(math.Ceil(float64(len(body)) / 4.0))
}

// promptHeadroomTokens absorbs the chat-template overhead that the
// byte-heuristic cannot see (im_start/role/content/im_end markers,
// BOS token, etc.) — fixed-cost per request, independent of body
// length. 64 covers the largest chat templates observed in the
// operator fleet with margin.
const promptHeadroomTokens = 64

// promptCapTokens — generous upper bound used ONLY in the usage-
// validation cap (maxUsageTokens). Equal to the billable estimate
// plus fixed chat-template headroom. Never used as a billed
// quantity.
//
// Background. estimatePromptTokens returns ceil(bytes/4), which is
// fine for English prose but consistently 5-50 tokens below the
// provider's actual tokenizer output. The provider's tokenizer
// applies the chat template AFTER body parse, adding fixed-cost
// overhead the byte-heuristic cannot see. Empirically reproducible
// on mlx-community/Qwen2.5-Coder-7B-Instruct-4bit during the
// 2026-06-28 phase-A re-run: a 115-byte body + max_tokens=4 → bare
// cap=33; provider tokenized to prompt=30+completion=4=34 → falsely
// rejected as invalid_provider_usage. Adding +64 to the cap (only)
// fixes the false reject without inflating any billed quantity.
func promptCapTokens(body []byte) int64 {
	return estimatePromptTokens(body) + promptHeadroomTokens
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
