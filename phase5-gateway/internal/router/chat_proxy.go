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
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/config"
	"github.com/augstar/macprovider-gateway/internal/settlement/journal"
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
	// settlementNoPriorDispatchHeader mirrors the coordinator constant of the
	// same name (separate Go module, intentionally duplicated). The coordinator
	// sets it on a route_snapshot_failed ONLY when it is the genuine first
	// route-snapshot attempt of the request (no prior provider dispatch); item
	// 18 refunds the reservation ONLY when this POSITIVE marker is present, so
	// an unmarked legacy/rolled-back-coordinator response settles on the
	// estimate. Keep in sync with
	// phase4-coordinator/internal/buyer/route_snapshot.go (deploy coordinator
	// first, roll back in reverse).
	settlementNoPriorDispatchHeader = "X-MacProvider-Settlement-No-Prior-Dispatch"
	// settlementPolicyVersion is the current coordinator route-snapshot
	// policy version (see billing.RouteSnapshotPolicyVersion). It was
	// bumped v0 -> v1 when the settlement pending-deadline default moved
	// from 30s to 300s (SPEC-022). legacySettlementPolicyVersion is kept
	// accepted below so rows/receipts pinned to the prior version during
	// the rollout window keep settling instead of holding indefinitely.
	settlementPolicyVersion           = "spec022-prereq-v1"
	legacySettlementPolicyVersion     = "spec022-prereq-v0"
	settlementHoldFallbackTTL         = 5 * time.Minute
	maxStreamingFallbackMetadataBytes = int64(64 << 10)
	decodeIdleSlowModelProgressTokens = 5
	decodeIdleSlowModelMax            = 60 * time.Second
)

var errStreamingIdleTimeout = errors.New("streaming upstream idle timeout")

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
	timing := newGatewayPhaseTiming(start)
	// AC-V2-9: gateway-side first-byte-of-request is the SPEC-019 v0.2
	// wall-clock zero-point. Phases that bound the whole request are armed
	// FROM this point, so pre-upstream gateway time (slow request-body read,
	// quota/concurrency reservation) still counts against the budget.
	//
	// #760: this used to be one flat context.WithTimeout(CoordinatorTimeout())
	// spanning admission + first token + the entire decode, which cut healthy
	// long generations. It is now a single cancel funnel with re-armable
	// per-phase budgets; the admission phase is armed here and narrowed or
	// replaced once the request is parsed.
	deadlines := newRequestDeadlines(r.Context())
	defer deadlines.Stop()
	deadlines.armPhaseFromStart(deadlinePhaseAdmission, s.cfg.CoordinatorAdmissionTimeout())
	upCtx := deadlines.Context()
	sw := &statusWriter{ResponseWriter: w, statusCode: 0}
	w = sw
	// Issue #190 R1 security HIGH: chat-completion responses now
	// carry per-tenant headers (X-RateLimit-Remaining-Requests).
	// Forbid intermediary caching unconditionally so a misconfigured
	// CDN/proxy cannot serve another buyer's rate-limit state via
	// a shared cache. Vary covers public auth headers (bearer,
	// Anthropic X-Api-Key shim, and demo token) so any proxy that
	// does cache will at least key correctly per-tenant.
	setNoStoreHeaders(w.Header())
	// Use Add (not Set) so an existing CORS-supplied Vary: Origin
	// is preserved alongside the auth-mode signals we add here.
	w.Header().Add("Vary", "Authorization")
	w.Header().Add("Vary", "X-Api-Key")
	w.Header().Add("Vary", "X-Demo-Token")
	var accountID, model string
	var streamMode bool
	defer func() {
		// deadline_phase names the clock that ended the request when one
		// did (admission / first_token / stream_ceiling / decode_idle /
		// non_stream_wall). Operator-facing ONLY: every buyer-visible
		// terminal keeps its existing code (provider_timeout,
		// coordinator_unavailable), so no error-code contract widens here.
		attrs := []any{
			"request_id", requestID(r),
			"account_id", accountID,
			"model", model,
			"stream", streamMode,
			"wall_ms", s.now().Sub(start).Milliseconds(),
			"status", sw.statusCode,
			"deadline_phase", deadlines.expiredPhase(),
		}
		attrs = append(attrs, timing.attrs(s.now())...)
		slog.Info("chat completion", attrs...)
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
	requestRate := s.chatStartLimits.allow(subject.AccountID, s.cfg.Quotas.AccountRequestRatePerSecond, s.now())
	if !requestRate.Admitted {
		slog.Warn("chat completion request rate limited",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"limit_rps", requestRate.Limit,
			"retry_after_s", requestRate.RetryAfterSeconds,
		)
		setConcurrencyRateLimitHeaders(w, requestRate.Limit, requestRate.Remaining, requestRate.RetryAfterSeconds, s.now())
		writeError(w, http.StatusTooManyRequests, "rate_limit_exceeded", "account_request_rate_exceeded", "Account request rate limit exceeded")
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
	dedupeEntrypoint := idlessDedupeEntrypointChat
	dedupeBody := body
	if adapter := responsesAdapterFromContext(r.Context()); adapter != nil {
		translatedBody, translateErr := adapter.translateRequest(body)
		if translateErr != nil {
			writeResponsesTranslationError(w, http.StatusBadRequest, translateErr)
			return
		}
		dedupeEntrypoint = idlessDedupeEntrypointResponses
		body = translatedBody
	}
	if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil {
		translatedBody, translateErr := adapter.translateRequest(r.Header, body)
		if translateErr != nil {
			writeAnthropicMessagesError(w, http.StatusBadRequest, translateErr.typ, translateErr.code, translateErr.message)
			return
		}
		dedupeEntrypoint = idlessDedupeEntrypointMessages
		body = translatedBody
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
	if maxTokens < 0 || maxTokens > maxAllowed {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "max_tokens_exceeded", "max_tokens exceeds configured limit")
		return
	}
	structuredStreaming := chat.Stream && chat.hasStructuredOutput()
	// #760: max_tokens is now known, so the request's total bound can be
	// armed. Streaming gets the derived safety ceiling (never shorter than
	// the legacy flat wall); non-streaming KEEPS the flat wall, because the
	// coordinator buffers the whole response and there is no intermediate
	// phase to observe. Both are measured from gateway first byte of request
	// (AC-V2-9), so this is not a budget extension for non-streaming.
	requestBound := s.cfg.NonStreamRequestTimeout()
	if chat.Stream {
		requestBound = s.effectiveStreamCeiling(maxTokens, structuredStreaming)
		deadlines.armCeiling(requestBound)
	} else {
		deadlines.armPhaseFromStart(deadlinePhaseNonStreamWall, requestBound)
	}
	// #762 (seam finding P1-1): bill each buyer intent once even when the
	// retry carries no id. An id-less retry — the OpenRouter default — mints
	// a fresh request_id per attempt, so the durable (account_id, request_id)
	// reservation key never matches and every attempt reserves and settles
	// again.
	//
	// Precedence, highest first: a buyer-supplied Idempotency-Key owns dedupe
	// (the coordinator path, issue #200) and a client-supplied UUID
	// X-Request-ID already deduped durably. Only gateway-minted ids — the
	// case where the buyer expressed no identity at all — reach the
	// fingerprint path.
	//
	// The fingerprint is computed here, AFTER validation, so a malformed or
	// over-cap request can never occupy a slot. The index is a UX layer, not
	// the money invariant: on any miss the retry adopts attempt 1's id and
	// falls through to the durable duplicate_request_id 409 below.
	var dedupeFingerprint string
	if dedupeWindow := s.idlessDedupeWindow(); dedupeWindow > 0 &&
		requestIDClass(r) == retry503RequestIDClassGatewayGenerated &&
		strings.TrimSpace(r.Header.Get("Idempotency-Key")) == "" {
		dedupeFingerprint = idlessRequestFingerprint(
			dedupeEntrypoint,
			subject.AccountID,
			subject.DemoTokenHash,
			strings.TrimSpace(r.Header.Get("X-MacProvider-Conversation")),
			strings.TrimSpace(r.Header.Get("X-MacProvider-Retry")),
			dedupeBody,
		)
		entry, adopted := s.idlessDedupe.claim(dedupeFingerprint, requestID(r), s.now(), dedupeWindow)
		switch {
		case entry == nil:
			// In-flight claim cap is full. Skip dedupe entirely rather than
			// letting the map grow: this request behaves exactly as it did
			// pre-#762 (its own id, its own reservation, its own bill).
			dedupeFingerprint = ""
		case adopted:
			// Attempt 1 owns this entry. Clearing the fingerprint is
			// load-bearing: it makes the terminal defer below a no-op, so
			// only the claim winner can ever publish or drop.
			dedupeFingerprint = ""
			// Adopt attempt 1's id for the rest of the request. The response
			// header must be overwritten too — the middleware already wrote
			// this attempt's freshly minted id (server.go:257) — or a
			// fall-through 409 would name an id the buyer cannot correlate.
			r = r.WithContext(context.WithValue(r.Context(), requestIDKey{}, entry.requestID))
			w.Header().Set("X-Request-ID", entry.requestID)
			var replayAdapter *responsesAdapter
			if adapter := responsesAdapterFromContext(r.Context()); adapter != nil {
				replayAdapter = adapter
				replayAdapter.beginReplayPassthrough()
			}
			if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil {
				adapter.replayBody = true
			}
			if s.replayIdlessDuplicate(w, r, subject, dailyQuota, entry, dedupeWindow, deadlines) {
				return
			}
			if replayAdapter != nil {
				replayAdapter.endReplayPassthrough()
			}
			if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil {
				adapter.replayBody = false
			}
		default:
			sw.armDedupeCapture(idlessDedupeMaxEntryBytes)
			if adapter := responsesAdapterFromContext(r.Context()); adapter != nil {
				adapter.armDedupeCapture(idlessDedupeMaxEntryBytes)
			}
			defer func() {
				if dedupeFingerprint == "" {
					return
				}
				// A panic unwinding through here has already written part of
				// a 2xx in the streaming case; the recovery middleware will
				// turn it into internal_error. Publishing that partial would
				// cache a response no buyer ever completed, so drop it and
				// re-panic so the middleware still sees and handles the
				// panic exactly as before.
				if recovered := recover(); recovered != nil {
					s.idlessDedupe.drop(dedupeFingerprint, requestID(r))
					panic(recovered)
				}
				adapter := responsesAdapterFromContext(r.Context())
				if adapter != nil {
					adapter.finish()
				}
				// Publish is gated on a buyer-visible 2xx, not on settlement
				// finality: a SPEC-022 hold is still a delivered answer, and
				// a retry of it must not re-run inference. A buyer who
				// disconnected never saw the whole response, so nothing is
				// cached for them (their partial is settled as usual).
				if adapter != nil && sw.dedupeDelivered2xx() && r.Context().Err() == nil {
					capture := adapter.dedupeCapture()
					if capture != nil {
						s.idlessDedupe.publish(dedupeFingerprint, requestID(r), sw.statusCode,
							w.Header().Get("Content-Type"), w.Header().Get("X-Provider-Id"),
							capture, s.now())
						return
					}
					if adapter.dedupeDeliveredButUncacheable() {
						s.idlessDedupe.publish(dedupeFingerprint, requestID(r), sw.statusCode,
							w.Header().Get("Content-Type"), w.Header().Get("X-Provider-Id"),
							nil, s.now())
						return
					}
					s.idlessDedupe.drop(dedupeFingerprint, requestID(r))
					return
				}
				if adapter == nil && sw.dedupePublishable() && r.Context().Err() == nil {
					s.idlessDedupe.publish(dedupeFingerprint, requestID(r), sw.statusCode,
						w.Header().Get("Content-Type"), w.Header().Get("X-Provider-Id"),
						sw.dedupeCapture(), s.now())
					return
				}
				// Audit R2 (code HIGH): a COMPLETE, delivered, billed 2xx
				// whose body merely exceeded the replay cap must keep its
				// fp->request_id mapping — dropping it would let an identical
				// id-less retry mint a fresh id and bill again. Publish a
				// body-less stub instead: the retry adopts the id and lands
				// on the durable 409. Only poisoned attempts (partial or
				// error content, failed buyer writes) and buyer disconnects
				// drop, because those retries MUST re-dispatch.
				if sw.dedupeDeliveredButUncacheable() && r.Context().Err() == nil {
					s.idlessDedupe.publish(dedupeFingerprint, requestID(r), sw.statusCode,
						w.Header().Get("Content-Type"), w.Header().Get("X-Provider-Id"),
						nil, s.now())
					return
				}
				s.idlessDedupe.drop(dedupeFingerprint, requestID(r))
			}()
		}
	}
	promptEstimate := estimatePromptTokens(body)
	if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil {
		adapter.setPromptEstimate(promptEstimate)
	}
	promptReservation := promptCapTokens(body)
	reservationTokens := promptReservation + maxTokens
	if reservationTokens < maxTokens {
		writeError(w, http.StatusBadRequest, "invalid_request_error", "token_limit_overflow", "Requested token reservation overflows")
		return
	}
	window := s.now().UTC().Format("2006-01-02")
	reservationMaxAge := time.Duration(s.cfg.Quotas.ReservationMaxAgeHours) * time.Hour
	decision, err := s.store.ReserveQuota(r.Context(), storage.ReservationRequest{
		AccountID: subject.AccountID, RequestID: requestID(r), WindowDate: window,
		RequestedTokens: reservationTokens, DailyQuota: dailyQuota,
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
		if errors.Is(err, storage.ErrReservationExists) {
			writeError(w, http.StatusConflict, "invalid_request_error", "duplicate_request_id", "Request ID already has an active quota reservation")
			return
		}
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
	// #760 R4: the lease must outlive the request's own bound, or a long
	// streaming generation releases its concurrency slot while still running
	// and reopens the M1-8 / PERF-6 pool-saturation regression. requestBound
	// is the streaming ceiling (or the non-streaming flat wall), so the
	// lease scales with it instead of the fixed legacy wall.
	concurrencyDecision, concurrencyErr := s.store.AcquireConcurrency(r.Context(), storage.ConcurrencyRequest{
		AccountID: subject.AccountID, RequestID: requestID(r), Limit: concurrencyLimit,
		CreatedAt: s.now(), ExpiresAt: s.now().Add(requestBound + time.Minute),
	})
	if errors.Is(concurrencyErr, storage.ErrQuotaExceeded) {
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		slog.Warn("chat completion concurrency limited",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"limit", concurrencyLimit,
			"retry_after_s", concurrencyRetryAfterSeconds,
		)
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

	internalConversation := ""
	if s.cfg.Routing.StickyEnabled && !authn.Demo {
		if tag := strings.TrimSpace(r.Header.Get("X-MacProvider-Conversation")); tag != "" {
			if !validConversationTag(tag) {
				_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
				writeError(w, http.StatusBadRequest, "invalid_request_error", "invalid_conversation_tag", "Invalid conversation tag")
				return
			}
			if metadata, ok := s.coordinatorRoutingMetadata(upCtx); ok && metadata.Sticky.Enabled && metadata.Sticky.TTLSeconds == s.cfg.Routing.StickyTTLS {
				internalConversation = s.deriveConversationKey(subject.AccountID, tag)
			}
		}
	}
	// Validation cap matches the reservation exposure so any accepted
	// provider usage is already covered by the buyer's active quota hold.
	// Gateway-estimated billing paths still use bare promptEstimate so
	// error-path settlement does not over-charge.
	maxUsageTokens := reservationTokens
	buildUpReq := func() (*http.Request, error) {
		upReq, err := http.NewRequestWithContext(upCtx, http.MethodPost, strings.TrimRight(s.coordinatorBuyerURL(), "/")+"/v1/chat/completions", bytes.NewReader(body))
		if err != nil {
			return nil, err
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
		// already sends. M3-2 / SECU-4 post-cutover: the upstream
		// bearer is service-token-only. ISS-211 R1 security audit HIGH.
		if subject.AccountID != "" {
			upReq.Header.Set("Authorization", "Bearer "+s.cfg.Coordinator.UpstreamCoordinatorBearer())
			upReq.Header.Set("X-MacProvider-Account", subject.AccountID)
		}
		if internalConversation != "" {
			// Authorization + X-MacProvider-Account are set
			// unconditionally above (SPEC-006 v0.9.1). The sticky
			// path's distinguishing header is X-MacProvider-Internal-Conv.
			upReq.Header.Set("X-MacProvider-Internal-Conv", internalConversation)
		}
		return upReq, nil
	}
	timing.markCoordinatorStart(s.now())
	resp, retryExhausted, priorProviderDispatch, err := s.doCoordinatorChatWithRetry(upCtx, r, subject.AccountID, buildUpReq)
	if err == nil && resp != nil && structuredStreaming {
		// #760 audit (code lane): the retry loop returns its last retryable
		// 502/503 with err == nil when the admission budget expires during
		// backoff. A structured-streaming buyer's contract is an SSE stream,
		// so passing that JSON error through would bypass the structured
		// provider_timeout terminal. Convert here, covering every stale-resp
		// return path in the loop at once.
		if _, phaseExpired := phaseDeadlineExceeded(upCtx); phaseExpired {
			_ = resp.Body.Close()
			if !s.settleBeforeResponse(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "provider_timeout") {
				return
			}
			writeStructuredOutputTimeoutSSE(w, requestID(r))
			return
		}
	}
	if err != nil {
		// #760: upCtx is now cancel-with-cause, so upCtx.Err() reports
		// context.Canceled on an expired phase budget and the legacy
		// errors.Is(upCtx.Err(), context.DeadlineExceeded) check would
		// silently stop matching. Ask the cause instead.
		if _, phaseExpired := phaseDeadlineExceeded(upCtx); structuredStreaming && phaseExpired {
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
	timing.observeCoordinatorResponse(resp.Header, s.now())

	if chat.Stream {
		// ISS-187 R1 architect/code MAJOR: thread the reservation
		// window through to forwardStreamingChat so the SPEC-006 §
		// 17.7 fallback usage_events insert in settleAfterCommit
		// uses the SAME window_date as the original reservation
		// (avoids drift for streams that cross UTC midnight).
		s.forwardStreamingChat(w, r, resp, subject, promptEstimate, maxUsageTokens, maxTokens, model, retryExhausted, priorProviderDispatch, deadlines, structuredStreaming, window, timing)
		return
	}
	s.forwardNonStreamingChat(w, r, resp, subject, promptEstimate, maxUsageTokens, maxTokens, retryExhausted, priorProviderDispatch, window)
}

func (s *Server) doCoordinatorChatWithRetry(upCtx context.Context, r *http.Request, accountID string, buildUpReq func() (*http.Request, error)) (*http.Response, bool, bool, error) {
	maxAttempts := 1
	if s.cfg.Retry503.Enabled {
		maxAttempts = s.cfg.Retry503.MaxAttempts
	}
	if maxAttempts < 1 {
		maxAttempts = 1
	}
	totalBackoffMS := int64(0)
	// priorProviderDispatch records whether an EARLIER attempt in this retry
	// loop returned a provider-dispatched (502-class) response that we then
	// retried. Item 18: a retried provider_error/failed/disconnected 502 can
	// have billed a prompt credit on the coordinator side (observe settlement
	// mode synthesizes prompt tokens for a dispatched-but-failed attempt), so
	// a subsequent terminal route_snapshot_failed MUST NOT be refunded as
	// "no provider ran" — that would erase real provider work the coordinator
	// already credited (verified realizable trace, security lane). A retried
	// 503 no_provider_available does NOT set this: no provider was dispatched.
	priorProviderDispatch := false
	for attempt := 1; attempt <= maxAttempts; attempt++ {
		if err := upCtx.Err(); err != nil {
			return nil, false, priorProviderDispatch, err
		}
		upReq, err := buildUpReq()
		if err != nil {
			return nil, false, priorProviderDispatch, err
		}
		resp, err := s.client.Do(upReq)
		if err != nil {
			return nil, false, priorProviderDispatch, err
		}
		if !s.cfg.Retry503.Enabled || maxAttempts == 1 {
			return resp, false, priorProviderDispatch, nil
		}
		if resp.StatusCode != http.StatusServiceUnavailable && resp.StatusCode != http.StatusBadGateway {
			if attempt > 1 && resp.StatusCode == http.StatusOK {
				s.retry503Metrics.recordRecovered(requestIDClass(r), totalBackoffMS)
				slog.Info("gateway coord retry recovered",
					"request_id", requestID(r),
					"attempt", attempt,
					"total_backoff_ms", totalBackoffMS,
				)
			}
			return resp, false, priorProviderDispatch, nil
		}
		body, readErr := readCoordRetryBody(resp.Body)
		_ = resp.Body.Close()
		if readErr != nil {
			// CODE R1 MEDIUM: preserve the body read-error semantic for
			// downstream. Wrapping partial bytes in io.NopCloser would
			// give forwardNonStreamingChat's readLimitedBody a clean EOF
			// and skip the 502 upstream_provider_error branch, so a
			// coordinator with a truncated body would be treated as a
			// complete response. Replay the prefix then surface readErr.
			resp.Body = &coord503PrefixErrBody{prefix: body, err: readErr}
		} else {
			resp.Body = io.NopCloser(bytes.NewReader(body))
		}
		resp.ContentLength = int64(len(body))
		if readErr != nil || !isCoordinatorChatRetryEligible(resp.StatusCode, body) {
			return resp, false, priorProviderDispatch, nil
		}
		if attempt == maxAttempts {
			s.retry503Metrics.recordExhausted(totalBackoffMS)
			slog.Warn("gateway coord retry exhausted",
				"request_id", requestID(r),
				"attempts", maxAttempts,
				"total_backoff_ms", totalBackoffMS,
				"status", resp.StatusCode,
			)
			return resp, true, priorProviderDispatch, nil
		}
		// About to retry to a further attempt. If THIS (soon-to-be-discarded)
		// response followed a billed provider dispatch, remember it so a later
		// terminal route_snapshot_failed is not wrongly refunded. The
		// coordinator stamps X-MacProvider-Settlement-No-Prior-Dispatch on any
		// response written while no provider has been billably credited yet
		// (ledger-exact providerCredited, plus the current terminal attempt's
		// dispatch), so the marker's ABSENCE is the "a provider was already
		// credited this request" signal — covering both a provider-dispatched 502
		// and a failover-exhaustion no_provider 503 after a billed attempt. A
		// marked response (genuine cold-start 502/503) leaves the flag clear. A
		// legacy coordinator emits no marker, so the gateway conservatively
		// settles — deploy the coordinator before the gateway.
		if strings.TrimSpace(resp.Header.Get(settlementNoPriorDispatchHeader)) == "" {
			priorProviderDispatch = true
		}
		if err := upCtx.Err(); err != nil {
			return resp, false, priorProviderDispatch, nil
		}
		backoff := coord503RetryBackoff(attempt, s.cfg.Retry503)
		select {
		case <-time.After(backoff):
			totalBackoffMS += backoff.Milliseconds()
			if err := upCtx.Err(); err != nil {
				return resp, false, priorProviderDispatch, nil
			}
			retryRate := s.chatStartLimits.allow(accountID, s.cfg.Quotas.AccountRequestRatePerSecond, s.now())
			if !retryRate.Admitted {
				slog.Warn("gateway coord retry request rate limited",
					"request_id", requestID(r),
					"account_id", accountID,
					"limit_rps", retryRate.Limit,
					"retry_after_s", retryRate.RetryAfterSeconds,
				)
				return resp, false, priorProviderDispatch, nil
			}
			slog.Info("gateway coord retry",
				"request_id", requestID(r),
				"attempt", attempt+1,
				"backoff_ms", backoff.Milliseconds(),
				"status", resp.StatusCode,
				"body_code", openAIErrorCode(body),
			)
			_ = resp.Body.Close()
		case <-upCtx.Done():
			return resp, false, priorProviderDispatch, nil
		}
	}
	return nil, false, priorProviderDispatch, upCtx.Err()
}

func coord503RetryBackoff(attempt int, cfg config.Retry503Config) time.Duration {
	if attempt < 1 {
		attempt = 1
	}
	sleepMS := cfg.BackoffBaseMs
	for i := 1; i < attempt; i++ {
		if sleepMS >= cfg.BackoffMaxMs {
			sleepMS = cfg.BackoffMaxMs
			break
		}
		sleepMS *= 2
		if sleepMS > cfg.BackoffMaxMs {
			sleepMS = cfg.BackoffMaxMs
			break
		}
	}
	jittered := int64(sleepMS) + (int64(sleepMS)*int64(rand.IntN(51)-25))/100
	if jittered < 0 {
		jittered = 0
	}
	return time.Duration(jittered) * time.Millisecond
}

func readCoordRetryBody(r io.Reader) ([]byte, error) {
	lr := &io.LimitedReader{R: r, N: maxUpstreamResponseBodyBytes + 1}
	body, err := io.ReadAll(lr)
	if err != nil {
		return body, err
	}
	if int64(len(body)) > maxUpstreamResponseBodyBytes {
		return body, fmt.Errorf("upstream response body exceeds %d bytes", maxUpstreamResponseBodyBytes)
	}
	return body, nil
}

// coord503PrefixErrBody replays a captured body prefix and then surfaces a
// deferred read error on the next Read call. It is used when the retry loop
// buffered partial bytes from the coordinator response before hitting a
// read error; downstream handlers must observe that same error so they can
// take their upstream-error branch instead of treating a truncated body as
// complete.
type coord503PrefixErrBody struct {
	prefix []byte
	err    error
	pos    int
}

func (b *coord503PrefixErrBody) Read(p []byte) (int, error) {
	if b.pos < len(b.prefix) {
		n := copy(p, b.prefix[b.pos:])
		b.pos += n
		return n, nil
	}
	if b.err != nil {
		return 0, b.err
	}
	return 0, io.EOF
}

func (b *coord503PrefixErrBody) Close() error { return nil }

func (s *Server) forwardNonStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate, maxUsageTokens, maxTokens int64, retryExhausted, priorProviderDispatch bool, window string) {
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
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
			return
		}
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
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
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
		return
	}
	if coordinatorTier2PolicyError(resp.StatusCode, body) {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
		return
	}
	if coordinatorIdempotencyError(resp.StatusCode, body) {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
		return
	}
	if !priorProviderDispatch && coordinatorPreDispatchNoChargeError(resp.StatusCode, body, resp.Header) {
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
		return
	}
	if resp.StatusCode != http.StatusOK {
		if coordinatorValidationError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, window)
			return
		}
		if isNullUsageProviderError(body) {
			s.passThroughReceiptEligibleProviderError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, maxTokens)
			return
		}
		completion := completionFromHeaderCapped(resp.Header, maxTokens)
		if !s.settleOrRefundPreStreamUpstreamError(w, r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "upstream_error", resp.StatusCode, body, resp.Header, false, window) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	anthropicDuplicateProviderResponse := false
	if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && !adapter.stream && anthropicRawHasDuplicateKeys(body) {
		anthropicDuplicateProviderResponse = true
	}
	usage, ok, usageErr := usageFromJSON(body, maxUsageTokens, maxTokens)
	tokenSource := "gateway_estimated"
	if !ok {
		usage = tokenUsage{PromptTokens: promptEstimate, CachedPromptTokens: 0, CompletionTokens: 0, TotalTokens: promptEstimate}
	} else if usageErr == nil {
		tokenSource = "provider_reported"
	}
	if anthropicDuplicateProviderResponse {
		settlePrompt, settleCompletion, settleSource := promptEstimate, int64(0), "gateway_estimated"
		if ok && usageErr == nil {
			settlePrompt, settleCompletion, settleSource = usage.PromptTokens, usage.CompletionTokens, tokenSource
		}
		if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, settlePrompt, settleCompletion, maxUsageTokens, settleSource, "invalid_provider_response", resp.Header) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "invalid_provider_response", "Upstream provider returned invalid response")
		return
	}
	if usageErr != nil {
		if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, promptEstimate, 0, maxUsageTokens, "gateway_estimated", "invalid_provider_usage", resp.Header) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "invalid_provider_usage", "Upstream provider returned invalid usage")
		return
	}
	body = usageBodyWithTokenUsage(body, usage)
	if adapter := responsesAdapterFromContext(r.Context()); adapter != nil && !adapter.stream {
		if err := adapter.prepareNonStreamingResponse(body); err != nil {
			settlePrompt, settleCompletion, settleSource := promptEstimate, int64(0), "gateway_estimated"
			if ok {
				settlePrompt, settleCompletion, settleSource = usage.PromptTokens, usage.CompletionTokens, tokenSource
			}
			if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, settlePrompt, settleCompletion, maxUsageTokens, settleSource, "invalid_provider_response", resp.Header) {
				return
			}
			writeError(w, http.StatusBadGateway, "api_error", "invalid_provider_response", "Upstream provider returned invalid response")
			return
		}
	}
	if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && !adapter.stream {
		if err := adapter.prepareNonStreamingResponse(body); err != nil {
			if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, usage.PromptTokens, usage.CompletionTokens, maxUsageTokens, tokenSource, "invalid_provider_response", resp.Header) {
				return
			}
			writeAnthropicMessagesError(w, http.StatusBadGateway, "api_error", "invalid_provider_response", "Upstream provider returned invalid response")
			return
		}
	}
	if !s.settleBeforeResponseWithCoordinatorFinality(w, r, subject, usage.PromptTokens, usage.CompletionTokens, maxUsageTokens, tokenSource, "ok", resp.Header) {
		return
	}
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

func (s *Server) forwardStreamingChat(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, promptEstimate, maxUsageTokens, maxTokens int64, model string, retryExhausted, priorProviderDispatch bool, deadlines *requestDeadlines, structuredStreaming bool, reservationWindow string, timing *gatewayPhaseTiming) {
	upstreamCtx := deadlines.Context()
	cancelUpstream := deadlines.Cancel
	if resp.StatusCode == http.StatusServiceUnavailable {
		body, _ := io.ReadAll(resp.Body)
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
			return
		}
		s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
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
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
			return
		}
		body, _ := io.ReadAll(resp.Body)
		if coordinatorValidationError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
			return
		}
		if coordinatorIdempotencyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
			return
		}
		if coordinatorTier2PolicyError(resp.StatusCode, body) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
			return
		}
		if !priorProviderDispatch && coordinatorPreDispatchNoChargeError(resp.StatusCode, body, resp.Header) {
			s.passThroughNoProviderCoordinatorError(w, r, resp, subject, body, promptEstimate, maxUsageTokens, retryExhausted, reservationWindow)
			return
		}
		if !s.settleOrRefundPreStreamUpstreamError(w, r, subject, promptEstimate, completionFromHeaderCapped(resp.Header, maxTokens), maxUsageTokens, "gateway_estimated", "upstream_error", resp.StatusCode, body, resp.Header, true, reservationWindow) {
			return
		}
		writeError(w, http.StatusBadGateway, "api_error", "upstream_provider_error", "Upstream provider error")
		return
	}
	if timing != nil {
		defer timing.observeCoordinatorTrailers(resp.Trailer)
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
	// #760: the coordinator has committed streaming headers, which post-#92
	// means it accepted the request and is relaying provider output. The
	// admission budget is done; from here the first content-bearing delta is
	// on its own clock, disarmed below the moment one arrives.
	deadlines.armPhase(deadlinePhaseFirstToken, s.cfg.FirstTokenTimeout())
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
	// #760: the streaming idle timer is now an absolute CONTENT-progress
	// deadline rather than a per-read duration. It is re-based only when a
	// frame carries generated text (see forwardLine), so a provider that
	// keeps the socket warm with role-only or usage-only frames no longer
	// holds the stream open forever. A zero deadline preserves the legacy
	// "no idle timeout" sentinel (streaming_idle_ms <= 0).
	idleTimeout := adaptiveDecodeIdleTimeout(model, s.cfg)
	progressDeadline := streamingProgressDeadline(idleTimeout)
	var emitted int64
	var serializedEmitted int64
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
	gatewayContentEstimatedCompletion := func() int64 {
		return estimateStreamingCompletionTokens(emitted, maxTokens)
	}
	gatewaySerializedEstimatedCompletion := func() int64 {
		return estimateStreamingCompletionTokens(maxInt64(emitted, serializedEmitted), maxTokens)
	}
	cleanLengthFallbackCompletion := func(observedBytes int64) int64 {
		completion := estimateStreamingCompletionTokens(maxInt64(maxInt64(emitted, serializedEmitted), observedBytes), maxTokens)
		if completion == 0 && maxTokens > 0 {
			return 1
		}
		return completion
	}
	setCleanLengthFallbackUsage := func(completion int64) {
		if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
			adapter.setFallbackStreamUsage(promptEstimate, completion)
		}
		if adapter := responsesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
			adapter.setFallbackStreamUsage(promptEstimate, completion)
		}
	}
	cleanLengthFacadeCompletion := func(completion int64) int64 {
		if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
			return completion
		}
		if adapter := responsesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
			return completion
		}
		return 0
	}
	settleGatewayTerminalOutputExceeded := func(completion int64) {
		// This is a gateway-authored terminal SSE error. The gateway cancels
		// the coordinator stream before EOF, so declared settlement trailers
		// may be unavailable and must not rewrite the buyer-visible outcome.
		if hasSettlementFinalityTrailerDeclaration(resp) {
			holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if !s.boundStreamingSettlementHold(holdCtx, r, subject, coordinatorSettlementFinality{
				Action:  settlementFinalityHold,
				Outcome: "stream_output_exceeded",
				Reason:  "gateway_stream_output_exceeded",
			}) {
				slog.Error("gateway failed to persist output-exceeded streaming settlement hold",
					"request_id", requestID(r),
					"account_id", subject.AccountID,
				)
			}
			return
		}
		s.settleAfterCommit(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "stream_output_exceeded", reservationWindow)
	}
	settleTruncated := func() {
		if reported != nil {
			settleReported("stream_truncated")
			return
		}
		s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, gatewaySerializedEstimatedCompletion(), maxUsageTokens, "gateway_estimated", "stream_truncated", reservationWindow, resp)
	}
	settleObservedContent := func(outcome string) {
		if estimateTokensFromBytes(emitted) > maxStreamingCompletionTokens(maxTokens) {
			outcome = "stream_output_exceeded"
		}
		if hasSettlementFinalityTrailerDeclaration(resp) {
			holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			if !s.boundStreamingSettlementHold(holdCtx, r, subject, coordinatorSettlementFinality{
				Action:  settlementFinalityHold,
				Outcome: outcome,
				Reason:  "gateway_" + outcome,
			}) {
				slog.Error("gateway failed to persist local terminal streaming settlement hold",
					"request_id", requestID(r),
					"account_id", subject.AccountID,
					"settlement_outcome", outcome,
				)
			}
			return
		}
		s.settleAfterCommit(r, subject, promptEstimate, gatewayContentEstimatedCompletion(), maxUsageTokens, "gateway_estimated", outcome, reservationWindow)
	}
	settleCancelled := func() {
		cancelCoordinator()
		// #762: the buyer never received the whole stream — either they
		// disconnected or a write to them failed. Poison explicitly rather
		// than relying on r.Context().Err() being observable in the publish
		// defer: a failed write does not necessarily cancel the context.
		poisonDedupeCapture(w)
		settleObservedContent("client_disconnect")
	}
	settleIdleTimeout := func() {
		cancelCoordinator()
		if terminalStructuredErrorCode != "" {
			refundTerminalStructuredError()
			return
		}
		if structuredStreaming {
			writeStructuredOutputTimeoutSSE(w, requestID(r))
		} else {
			writeSSEError(w, "Provider timed out during streaming", "api_error", "provider_timeout")
		}
		if flusher != nil {
			flusher.Flush()
		}
		settleObservedContent("provider_timeout")
	}
	forwardLine := func(line []byte) bool {
		select {
		case <-r.Context().Done():
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
				terminalCode := terminalSSEErrorCode(data)
				cleanLengthTerminalFrame := sseErrorDeliveredClean(w, terminalCode)
				if isSpec019TerminalSSEErrorCode(terminalCode) && !cleanLengthTerminalFrame {
					terminalStructuredErrorCode = terminalCode
					// #762: a 200 stream that ends in a SPEC-019 terminal
					// error envelope is refunded, not an answer. Caching it
					// would replay a stale provider error to a retry that
					// deserves a fresh dispatch.
					poisonDedupeCapture(w)
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
				anthropicTerminalFrame := false
				if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
					anthropicTerminalFrame = terminalCode != ""
					if gatewayCleanLengthTruncationTerminalCode(terminalCode) {
						adapter.setFallbackStreamUsage(promptEstimate, cleanLengthFallbackCompletion(0))
					}
				}
				if adapter := responsesAdapterFromContext(r.Context()); adapter != nil && adapter.stream && cleanLengthTerminalFrame {
					adapter.setFallbackStreamUsage(promptEstimate, cleanLengthFallbackCompletion(0))
				}
				if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream && !anthropicTerminalFrame && anthropicRawHasDuplicateKeys([]byte(data)) {
					slog.Warn("anthropic stream saw duplicate-key provider chunk; rejecting before normalization", "request_id", requestID(r))
					adapter.emitInvalidProviderResponse("Upstream provider returned ambiguous stream data")
					if flusher != nil {
						flusher.Flush()
					}
					poisonDedupeCapture(w)
					cancelCoordinator()
					completion := gatewayContentEstimatedCompletion()
					s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "invalid_provider_response", reservationWindow, resp)
					return false
				}
				if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream && !anthropicTerminalFrame {
					if err := anthropicValidateStreamProviderRaw([]byte(data)); err != nil {
						slog.Warn("anthropic stream rejected provider chunk before accounting", "request_id", requestID(r), "error", err)
						adapter.emitInvalidProviderResponse(err.Error())
						if flusher != nil {
							flusher.Flush()
						}
						poisonDedupeCapture(w)
						cancelCoordinator()
						completion := gatewayContentEstimatedCompletion()
						s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "invalid_provider_response", reservationWindow, resp)
						return false
					}
				}
				deltaBytes, hasChoices, parseOK := streamingCompletionDeltaBytes(data)
				if deltaBytes > 0 {
					// #760: CONTENT progress, not byte progress. Only a frame
					// carrying generated text counts — role-only deltas, ids,
					// keepalives and usage-only frames are exactly what a
					// wedged provider keeps emitting, so letting them reset
					// the idle timer made the timer unable to catch the
					// failure it exists for. streamingCompletionDeltaBytes
					// already excludes the role/id/type/name scaffolding keys.
					progressDeadline = streamingProgressDeadline(idleTimeout)
					// First content-bearing delta: the first-token phase is
					// satisfied. Only the (never-re-armed) ceiling remains.
					deadlines.disarmPhase()
				}
				frameBytes := boundedStreamingFallbackFrameBytes(line)
				if !parseOK {
					slog.Warn("streaming gateway estimate saw malformed chunk; truncating stream", "request_id", requestID(r))
					writeSSEError(w, "Upstream stream returned malformed data", "api_error", "stream_malformed")
					if flusher != nil {
						flusher.Flush()
					}
					cancelCoordinator()
					completion := gatewayContentEstimatedCompletion()
					s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "stream_malformed", reservationWindow, resp)
					return false
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
				} else if !hasChoices && !anthropicTerminalFrame && !cleanLengthTerminalFrame {
					slog.Warn("streaming gateway estimate saw data chunk without choices or usage; truncating stream", "request_id", requestID(r))
					writeSSEError(w, "Upstream stream returned malformed data", "api_error", "stream_malformed")
					if flusher != nil {
						flusher.Flush()
					}
					cancelCoordinator()
					completion := gatewayContentEstimatedCompletion()
					s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "stream_malformed", reservationWindow, resp)
					return false
				}
				if len(line) > 0 && (deltaBytes > 0 || frameBytes > 0) {
					frameBytes = boundedStreamingFallbackFrameBytes(line)
					projectedContentBytes := emitted + deltaBytes
					projectedSerializedBytes := serializedEmitted + frameBytes
					maxCompletion := maxStreamingCompletionTokens(maxTokens)
					hardByteCeiling := maxCompletion * 8
					if hardByteCeiling < 1 {
						hardByteCeiling = 1
					}
					if projectedContentBytes > hardByteCeiling {
						slog.Warn("streaming gateway estimate exceeded hard byte ceiling; truncating stream", "request_id", requestID(r), "estimated_completion_tokens", estimateTokensFromBytes(projectedContentBytes), "max_completion_tokens", maxCompletion, "emitted_bytes", projectedContentBytes, "hard_byte_ceiling", hardByteCeiling)
						completion := cleanLengthFallbackCompletion(maxInt64(projectedContentBytes, projectedSerializedBytes))
						setCleanLengthFallbackUsage(completion)
						writeSSEError(w, "Upstream stream exceeded requested max_tokens", "api_error", "stream_output_exceeded")
						if flusher != nil {
							flusher.Flush()
						}
						cancelCoordinator()
						settleGatewayTerminalOutputExceeded(cleanLengthFacadeCompletion(completion))
						return false
					}
					if projectedSerializedBytes-projectedContentBytes > maxStreamingFallbackMetadataBytes {
						slog.Warn("streaming gateway estimate exceeded serialized metadata ceiling; truncating stream", "request_id", requestID(r), "serialized_bytes", projectedSerializedBytes, "content_bytes", projectedContentBytes, "metadata_ceiling", maxStreamingFallbackMetadataBytes)
						completion := cleanLengthFallbackCompletion(maxInt64(projectedContentBytes, projectedSerializedBytes))
						setCleanLengthFallbackUsage(completion)
						writeSSEError(w, "Upstream stream exceeded requested max_tokens", "api_error", "stream_output_exceeded")
						if flusher != nil {
							flusher.Flush()
						}
						cancelCoordinator()
						settleGatewayTerminalOutputExceeded(cleanLengthFacadeCompletion(completion))
						return false
					}
					emitted = projectedContentBytes
					serializedEmitted = projectedSerializedBytes
				}
			}
		}
		if len(line) == 0 {
			return true
		}
		if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream && bytes.Equal(bytes.TrimSpace(line), []byte("data: [DONE]")) && reported == nil {
			adapter.setFallbackStreamUsage(promptEstimate, gatewaySerializedEstimatedCompletion())
		}
		if _, err := w.Write(line); err != nil {
			slog.Warn("streaming buyer write failed", "request_id", requestID(r), "error", err)
			// #762: explicit, even though settleCancelled poisons too — this
			// is the exact path an audit flagged as publishing a partial,
			// never-delivered 2xx.
			poisonDedupeCapture(w)
			settleCancelled()
			return false
		}
		if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.hasStreamInvalid() {
			slog.Warn("anthropic stream translation rejected provider data", "request_id", requestID(r), "error", adapter.invalidMessage())
			poisonDedupeCapture(w)
			cancelCoordinator()
			completion := gatewayContentEstimatedCompletion()
			s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "invalid_provider_response", reservationWindow, resp)
			return false
		}
		if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.streamDone && terminalStructuredErrorCode == "" {
			if reported != nil && !invalidReportedUsage {
				settleReported(adapter.settlementOutcome("ok"))
			} else {
				outcome := adapter.settlementOutcome("ok")
				completion := gatewaySerializedEstimatedCompletion()
				if outcome == "stream_output_exceeded" {
					completion = cleanLengthFallbackCompletion(0)
				}
				s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", outcome, reservationWindow, resp)
			}
			return false
		}
		if adapter := responsesAdapterFromContext(r.Context()); adapter != nil && adapter.streamTerminal && terminalStructuredErrorCode == "" {
			if reported != nil && !invalidReportedUsage {
				settleReported(adapter.settlementOutcome("ok"))
			} else {
				outcome := adapter.settlementOutcome("ok")
				completion := gatewaySerializedEstimatedCompletion()
				if outcome == "stream_output_exceeded" {
					completion = cleanLengthFallbackCompletion(0)
				}
				s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", outcome, reservationWindow, resp)
			}
			return false
		}
		if flusher != nil {
			flusher.Flush()
		}
		return true
	}
	for {
		line, err := readStreamingLineWithIdleTimeout(r.Context(), reader, progressDeadline, cancelCoordinator, resp.Body)
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
		if errors.Is(err, errStreamingIdleTimeout) {
			slog.Warn("streaming coordinator idle timeout",
				"request_id", requestID(r),
				"timeout_ms", idleTimeout.Milliseconds(),
				"deadline_phase", deadlineReasonDecodeIdle,
			)
			deadlines.noteReason(deadlineReasonDecodeIdle)
			settleIdleTimeout()
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
		if r.Context().Err() != nil {
			settleCancelled()
			return
		}
		// #760: a phase budget (first_token / stream_ceiling) expiring cancels
		// the upstream, which surfaces here as a read error. That is a TIMEOUT,
		// not a provider disconnect: it must settle through the same
		// settleIdleTimeout funnel as the decode-idle timer so the buyer sees
		// provider_timeout and the usage row records provider_timeout. Emitting
		// provider_disconnected + settleTruncated here was the SPEC-019 AC-V2-9
		// violation. settleIdleTimeout already handles the structured-output
		// envelope and the already-forwarded-terminal-frame case, so this
		// subsumes the former structuredStreaming-only DeadlineExceeded branch
		// (which, post-cause-cancellation, would never match again anyway).
		if phase, expired := phaseDeadlineExceeded(upstreamCtx); expired {
			slog.Warn("streaming phase deadline exceeded",
				"request_id", requestID(r),
				"deadline_phase", phase,
				"structured_streaming", structuredStreaming,
			)
			settleIdleTimeout()
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
		writeProviderDisconnectedSSE(w)
		if flusher != nil {
			flusher.Flush()
		}
		settleTruncated()
		return
	}
	if r.Context().Err() != nil {
		settleCancelled()
		return
	}
	if terminalStructuredErrorCode != "" {
		refundTerminalStructuredError()
		return
	}
	if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream && !adapter.streamDone {
		if err := adapter.validateStreamComplete(); err != nil {
			adapter.emitInvalidProviderResponse(err.Error())
			if sw, ok := w.(*statusWriter); ok && sw.captureArmed && !sw.overflowed && !sw.poisoned {
				sw.captureDedupeBytes(sw.drainTransformedDedupeBytes(nil))
			}
			if flusher != nil {
				flusher.Flush()
			}
			poisonDedupeCapture(w)
			if adapter.writeErr != nil {
				slog.Warn("anthropic stream invalid-response write failed", "request_id", requestID(r), "error", adapter.writeErr)
				settleCancelled()
				return
			}
			completion := gatewayContentEstimatedCompletion()
			s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", "invalid_provider_response", reservationWindow, resp)
			return
		}
		fallbackCompletion := gatewaySerializedEstimatedCompletion()
		adapter.setFallbackStreamUsage(promptEstimate, fallbackCompletion)
		adapter.emitMessageStop()
		if sw, ok := w.(*statusWriter); ok && sw.captureArmed && !sw.overflowed && !sw.poisoned {
			sw.captureDedupeBytes(sw.drainTransformedDedupeBytes(nil))
		}
		if adapter.writeErr != nil {
			slog.Warn("anthropic stream finalization buyer write failed", "request_id", requestID(r), "error", adapter.writeErr)
			poisonDedupeCapture(w)
			settleCancelled()
			return
		}
	}
	if reported != nil && !invalidReportedUsage {
		outcome := "ok"
		if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
			outcome = adapter.settlementOutcome(outcome)
		}
		settleReported(outcome)
		return
	}
	completion := gatewaySerializedEstimatedCompletion()
	outcome := "ok"
	if adapter := anthropicMessagesAdapterFromContext(r.Context()); adapter != nil && adapter.stream {
		outcome = adapter.settlementOutcome(outcome)
	}
	if estimateTokensFromBytes(maxInt64(emitted, serializedEmitted)) > maxStreamingCompletionTokens(maxTokens) {
		outcome = "stream_output_exceeded"
	}
	s.settleStreamingAfterCommitWithCoordinatorFinality(r, subject, promptEstimate, completion, maxUsageTokens, "gateway_estimated", outcome, reservationWindow, resp)
}

type streamingReadResult struct {
	line []byte
	err  error
}

// streamingProgressDeadline converts the configured idle budget into the
// absolute content-progress deadline the read loop carries. It preserves the
// legacy "no idle timeout" sentinel: a non-positive budget yields the zero
// time, which readStreamingLineWithIdleTimeout treats as unbounded.
func streamingProgressDeadline(idleTimeout time.Duration) time.Time {
	if idleTimeout <= 0 {
		return time.Time{}
	}
	return time.Now().Add(idleTimeout)
}

func adaptiveDecodeIdleTimeout(model string, cfg config.Config) time.Duration {
	base := cfg.StreamingIdleTimeout()
	if base <= 0 {
		return base
	}
	expectedTPS, ok := expectedDecodeTokensPerSecond(model)
	if !ok || expectedTPS <= 0 {
		return base
	}
	perToken := time.Duration(math.Ceil(float64(time.Second) / expectedTPS))
	adaptive := perToken * decodeIdleSlowModelProgressTokens
	if adaptive > decodeIdleSlowModelMax {
		adaptive = decodeIdleSlowModelMax
	}
	if adaptive > base {
		return adaptive
	}
	return base
}

func expectedDecodeTokensPerSecond(model string) (float64, bool) {
	name := strings.ToLower(model)
	switch {
	case strings.Contains(name, "70b"), strings.Contains(name, "72b"):
		return 0.17, true
	case strings.Contains(name, "30b"), strings.Contains(name, "32b"):
		return 0.25, true
	case strings.Contains(name, "20b"), strings.Contains(name, "22b"), strings.Contains(name, "24b"):
		return 0.5, true
	default:
		return 0, false
	}
}

// readStreamingLineWithIdleTimeout reads one SSE line, giving up at deadline.
//
// #760: the parameter is an absolute CONTENT-progress deadline, not a
// per-read duration. The caller re-bases it only when a frame carried
// generated text, so heartbeat/keepalive/usage-only frames consume the budget
// instead of renewing it. A zero deadline means "no idle timeout" and matches
// the pre-#760 `idleTimeout <= 0` sentinel.
func readStreamingLineWithIdleTimeout(ctx context.Context, reader *bufio.Reader, deadline time.Time, cancelUpstream func(), body io.Closer) ([]byte, error) {
	if deadline.IsZero() {
		return reader.ReadSlice('\n')
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		cancelUpstream()
		_ = body.Close()
		return nil, errStreamingIdleTimeout
	}
	ch := make(chan streamingReadResult, 1)
	go func() {
		line, err := reader.ReadSlice('\n')
		ch <- streamingReadResult{line: line, err: err}
	}()
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case result := <-ch:
		return result.line, result.err
	case <-timer.C:
		cancelUpstream()
		_ = body.Close()
		return nil, errStreamingIdleTimeout
	case <-ctx.Done():
		cancelUpstream()
		_ = body.Close()
		return nil, ctx.Err()
	}
}

func (s *Server) passThroughNoProviderCoordinatorError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte, promptEstimate, maxUsageTokens int64, retryExhausted bool, window string) {
	if (resp.StatusCode >= 500 && resp.StatusCode < 600) || coordinatorTier2PolicyError(resp.StatusCode, body) {
		if !s.recordRefundedCoordinatorAudit(w, r, subject, window, refundedCoordinatorAuditOutcome(resp.StatusCode, body)) {
			return
		}
	}
	if err := s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
		slog.Error("gateway no-provider refund failed after audit row",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"error", err,
		)
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
		return
	}
	if len(bytes.TrimSpace(body)) == 0 && resp.StatusCode == http.StatusServiceUnavailable {
		writeError(w, http.StatusServiceUnavailable, "service_unavailable", "no_provider_available", "No provider available")
		return
	}
	copyCleanHeaders(w.Header(), resp.Header)
	w.Header().Set("X-Request-ID", requestID(r))
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	// H1/M4/M-R2-2: this forwards the coordinator's body verbatim, so its
	// own retryable field (if present) is already preserved byte-for-byte
	// in the JSON below. setGatewayRetryAfter reads that same verdict, plus
	// the coordinator's own code, to decide whether to attach the
	// gateway-owned Retry-After hint — copyCleanHeaders above already
	// stripped any upstream Retry-After (issue #190), so a code with a
	// known fixed backoff window (e.g. provisional_quota_exceeded's 3600s)
	// must be restored explicitly via gatewayRetryAfterByCode or the buyer
	// loses the backoff signal entirely, not just its precision.
	setGatewayRetryAfter(w, resp.StatusCode, openAIErrorCode(body), coordinatorErrorRetryable(resp.StatusCode, body))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func refundedCoordinatorAuditOutcome(status int, body []byte) string {
	if isCoordNoProviderAvailable503(status, body) {
		return "no_provider_available"
	}
	if code := openAIErrorCode(body); code != "" {
		return code
	}
	return "upstream_error"
}

func (s *Server) recordRefundedCoordinatorAudit(w http.ResponseWriter, r *http.Request, subject usageSubject, window, outcome string) bool {
	if window == "" {
		window = s.now().UTC().Format("2006-01-02")
	}
	if outcome == "" {
		outcome = "upstream_error"
	}
	if err := s.store.EnsureUsageEvent(context.Background(), storage.UsageEvent{
		RequestID:        requestID(r),
		AccountID:        subject.AccountID,
		DemoIdentity:     subject.DemoIdentity,
		WindowDate:       window,
		PromptTokens:     0,
		CompletionTokens: 0,
		TotalTokens:      0,
		TokenSource:      "gateway_estimated",
		Outcome:          outcome,
		CreatedAt:        s.now(),
	}); err != nil {
		slog.Error("gateway refunded coordinator audit row failed",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"outcome", outcome,
			"error", err,
		)
		_ = s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
		return false
	}
	return true
}

func (s *Server) settleOrRefundPreStreamUpstreamError(w http.ResponseWriter, r *http.Request, subject usageSubject, prompt, completion, maxTotal int64, source, outcome string, status int, body []byte, h http.Header, boundHold bool, window string) bool {
	if !shouldRefundLegacyPreStreamProvider502(status, body, h) {
		return s.settleBeforeResponseWithCoordinatorFinalityPolicy(w, r, subject, prompt, completion, maxTotal, source, outcome, h, boundHold)
	}
	if !s.recordRefundedCoordinatorAudit(w, r, subject, window, outcome) {
		return false
	}
	if err := s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix()); err != nil && !errors.Is(err, storage.ErrReservationNotFound) {
		slog.Error("gateway pre-stream upstream-error refund failed after audit row",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"outcome", outcome,
			"error", err,
		)
		writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
		return false
	}
	return true
}

func shouldRefundLegacyPreStreamProvider502(status int, body []byte, h http.Header) bool {
	if status != http.StatusBadGateway || hasAnySettlementFinalityHeader(h) {
		return false
	}
	switch openAIErrorCode(body) {
	case "provider_error", "provider_failed", "provider_disconnected":
		return true
	default:
		return false
	}
}

func (s *Server) passThroughReceiptEligibleProviderError(w http.ResponseWriter, r *http.Request, resp *http.Response, subject usageSubject, body []byte, promptEstimate, maxUsageTokens, maxTokens int64) {
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
		holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if !s.boundStreamingSettlementHold(holdCtx, r, subject, finality) {
			writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
			return
		}
		slog.Info("gateway deferred verified provider-error buyer settlement to SPEC-022 reconciler",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
		)
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
	w.Header().Set("X-Request-ID", requestID(r))
	w.Header().Set("Content-Type", contentTypeOrJSON(resp.Header))
	// H1/M4/M-R2-2: preserve the coordinator's own retryable verdict from
	// body and attach the gateway-owned Retry-After hint accordingly (see
	// passThroughNoProviderCoordinatorError for the same pattern).
	setGatewayRetryAfter(w, resp.StatusCode, openAIErrorCode(body), coordinatorErrorRetryable(resp.StatusCode, body))
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

// coordinatorPreDispatchNoChargeError detects a coordinator 5xx emitted
// BEFORE any provider was dispatched, where no inference ran and the buyer
// must not be charged. The one case today is route_snapshot_failed — the
// SPEC-022 durable route-snapshot write failing: the coordinator
// (internal/buyer/route_snapshot.go) writes it via plain writeError with a
// 500 and NO settlement finality headers, i.e. no provider was invoked.
//
// Without this the gateway's generic upstream-error path settles the
// reservation on the prompt estimate — shouldRefundLegacyPreStreamProvider502
// only refunds 502s — debiting the buyer for a request that never reached a
// provider. Routing it through
// passThroughNoProviderCoordinatorError refunds the reservation, writes a
// 0-token refunded audit row, and passes the coordinator body through
// verbatim — identical to the 404 / idempotency / tier-2-policy no-provider
// cases. Applies to both streaming and non-streaming buyer requests.
//
// Gated on the absence of settlement finality headers so that if a future
// coordinator ever attaches finality to this code, the finality-policy path
// handles it instead.
//
// Two independent proofs are required before refunding, because a
// route_snapshot_failed can be terminal AFTER real provider work that observe
// settlement mode credits:
//   - the coordinator's POSITIVE X-MacProvider-Settlement-No-Prior-Dispatch
//     marker, present ONLY when this is the genuine first route-snapshot
//     attempt of the request (no coordinator-internal prior dispatch). Its
//     ABSENCE — a legacy/rolled-back coordinator, or an internal-failover
//     response — disqualifies the refund; and
//   - the caller's `!priorProviderDispatch` gate, which covers a
//     route_snapshot_failed the gateway reached only AFTER retrying a prior
//     provider-dispatched 502 across separate coordinator requests.
//
// Requiring the positive marker (rather than the absence of a negative one)
// makes a gateway-first deploy / coordinator rollback safe: no marker →
// settle-on-estimate, never a wrongful refund. This predicate certifies the
// response shape + the coordinator marker; the caller certifies no cross-retry
// dispatch.
func coordinatorPreDispatchNoChargeError(status int, body []byte, h http.Header) bool {
	if status != http.StatusInternalServerError || hasAnySettlementFinalityHeader(h) {
		return false
	}
	if strings.TrimSpace(h.Get(settlementNoPriorDispatchHeader)) == "" {
		return false
	}
	return openAIErrorCode(body) == "route_snapshot_failed"
}

func coordinatorValidationError(status int, body []byte) bool {
	if status < 400 || status >= 500 {
		return false
	}
	if status == http.StatusConflict || status == http.StatusNotFound {
		return false
	}
	return openAIErrorCode(body) != ""
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

// isCoordinatorChatRetryEligible returns true when the coordinator response
// indicates the request MAY succeed on a retry — momentarily unavailable pool
// (503) or transient provider transport failure (502). It intentionally does
// NOT retry null-usage provider errors, tier2 policy errors, or post-inference
// structured-output failures that already ran billing.
func isCoordinatorChatRetryEligible(status int, body []byte) bool {
	if isCoordNoProviderAvailable503(status, body) {
		return true
	}
	return isCoordTransientProvider502(status, body)
}

// isCoordTransientProvider502 returns true for coordinator 502 responses that
// signal provider disconnect / relay failure rather than billable inference
// faults. Mirrors the buyer-visible codes written on ErrRelayClosed and
// wsForwardProviderDisconnected paths in phase4-coordinator buyer/server.go.
func isCoordTransientProvider502(status int, body []byte) bool {
	if status != http.StatusBadGateway {
		return false
	}
	if isNullUsageProviderError(body) {
		return false
	}
	if coordinatorTier2PolicyError(status, body) {
		return false
	}
	code := openAIErrorCode(body)
	switch code {
	case "provider_error", "provider_failed", "provider_disconnected", "":
		return true
	default:
		return false
	}
}

// isCoordNoProviderAvailable503 returns true when the coordinator's
// response indicates the request MAY succeed on a retry — i.e. the
// provider pool was momentarily busy. It intentionally does NOT
// retry:
//   - null-usage provider errors (billable failures)
//   - tier2 policy errors (permanent for this request)
//   - any 5xx other than 503
func isCoordNoProviderAvailable503(status int, body []byte) bool {
	if status != http.StatusServiceUnavailable {
		return false
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return true
	}
	var raw any
	if err := json.Unmarshal(body, &raw); err != nil {
		return true
	}
	if isNullUsageProviderError(body) {
		return false
	}
	if coordinatorTier2PolicyError(status, body) {
		return false
	}
	code := openAIErrorCode(body)
	return code == "" || code == "no_provider_available"
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

// openAIErrorRetryable extracts the coordinator's own retryable verdict from
// a forwarded error body (finding H1: when the gateway passes a coordinator
// error body through verbatim, it must preserve the coordinator's retryable
// value rather than drop it or recompute a possibly-stale one). ok is false
// when the body does not parse or omits the field, in which case callers
// should fall back to gatewayRetryable(openAIErrorCode(body)).
func openAIErrorRetryable(body []byte) (value bool, ok bool) {
	var envelope struct {
		Error struct {
			Retryable *bool `json:"retryable"`
		} `json:"error"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil || envelope.Error.Retryable == nil {
		return false, false
	}
	return *envelope.Error.Retryable, true
}

// coordinatorErrorRetryable resolves the retryable value for a forwarded
// coordinator error body: preserve the coordinator's own verdict when the
// body carries one, else classify by code using the same rule the gateway
// applies to its own generated errors.
func coordinatorErrorRetryable(status int, body []byte) bool {
	if v, ok := openAIErrorRetryable(body); ok {
		return v
	}
	if len(bytes.TrimSpace(body)) == 0 && status == http.StatusServiceUnavailable {
		return gatewayRetryable("no_provider_available")
	}
	return gatewayRetryable(openAIErrorCode(body))
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
	if gatewayInvalidResponseOverridesCoordinatorFinality(outcome) {
		return s.settleBeforeResponse(w, r, subject, prompt, completion, maxTotal, source, outcome)
	}
	finality := coordinatorSettlementFinalityFromHeaders(h)
	switch finality.Action {
	case settlementFinalityLegacy:
		return s.settleBeforeResponse(w, r, subject, prompt, completion, maxTotal, source, outcome)
	case settlementFinalityDebit:
		holdCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if !s.boundStreamingSettlementHold(holdCtx, r, subject, finality) {
			writeError(w, http.StatusInternalServerError, "server_error", "settlement_failed", "Could not settle usage")
			return false
		}
		slog.Info("gateway deferred verified buyer settlement to SPEC-022 reconciler",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_hold_bound", boundHold,
		)
		return true
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
	if gatewayInvalidResponseOverridesCoordinatorFinality(outcome) {
		s.settleAfterCommit(r, subject, prompt, completion, maxTotal, source, outcome, reservationWindow)
		return
	}
	finality := coordinatorStreamingSettlementFinality(resp)
	switch finality.Action {
	case settlementFinalityLegacy:
		if outcome == "ok" {
			outcome = "unverified_streaming"
		}
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
		if finality.Reason == "missing_settlement_finality_trailer" {
			s.settleAfterCommit(r, subject, prompt, completion, maxTotal, source, "unverified_streaming", reservationWindow)
			return
		}
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

func gatewayInvalidResponseOverridesCoordinatorFinality(outcome string) bool {
	return outcome == "invalid_provider_response"
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
		deadline = now.Add(settlementHoldFallbackTTL).UTC()
		slog.Info("gateway bounded streaming settlement hold with expired coordinator receipt deadline to local fallback deadline",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"settlement_outcome", finality.Outcome,
			"settlement_reason", finality.Reason,
			"settlement_pending_deadline_unix_ms", finality.PendingDeadlineUnixMS,
			"settlement_fallback_deadline_unix_ms", deadline.UnixMilli(),
		)
	}
	if deadline.IsZero() {
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
	if policyVersion != settlementPolicyVersion && policyVersion != legacySettlementPolicyVersion {
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
	case "quarantined", "zero_settled", "overlap_blocked_terminal":
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
	case "overlap_blocked_terminal":
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
	// WINDOW: use the reservation window captured at admission time (not
	// s.now()) so a stream that crosses UTC midnight settles against the SAME
	// daily quota window the buyer's reservation was made against. ISS-187 R1
	// architect+code MAJOR.
	//
	// Hoisted above the settle attempt by #763 so the journal record and the
	// § 17.7 fallback below share ONE value. A journal record carrying a
	// different window than the fallback would re-drive into an
	// ErrUsageEventConflict against the row the fallback wrote.
	window := reservationWindow
	if window == "" {
		window = s.now().UTC().Format("2006-01-02")
	}
	// ARM (#763 / seam finding P1-2): durably record the money effect BEFORE
	// attempting it. Everything below this line — the settle, the fallback,
	// the refund — can fail logically, crash the process, or lose power; the
	// effect record survives all three and the recovery pass
	// (settlement_journal_recovery.go) re-drives it.
	//
	// The reservation is the PRE-DISPATCH arm and already exists, so v1
	// journals only this after-commit effect: it is the single point where
	// the buyer has been served and the durable bill has not been written.
	journalKey := journal.Key{
		AccountID: subject.AccountID,
		RequestID: requestID(r),
		Effect:    journal.EffectSettle,
	}
	armed := true
	if journalErr := s.journal.WriteEffect(journal.Record{
		AccountID:        journalKey.AccountID,
		RequestID:        journalKey.RequestID,
		Effect:           journalKey.Effect,
		WindowDate:       window,
		PromptTokens:     prompt,
		CompletionTokens: completion,
		TotalTokens:      prompt + completion,
		MaxTotalTokens:   maxTotal,
		TokenSource:      source,
		Outcome:          outcome,
		DemoIdentity:     subject.DemoIdentity,
		DemoTokenHash:    subject.DemoTokenHash,
	}); journalErr != nil {
		// FAIL-OPEN, deliberately. The buyer already has the bytes; refusing
		// to settle because the journal is unavailable would turn a
		// durability outage into a billing outage. The write-failure metric
		// and this log are the signal that recovery coverage is degraded for
		// this request. Pinned by TestSettlementJournal_WriteFailureDoesNotBlockSettle.
		armed = false
		slog.Error("gateway settlement journal effect write failed; settling anyway (recovery coverage lost for this request)",
			"request_id", journalKey.RequestID,
			"account_id", journalKey.AccountID,
			"source", source,
			"outcome", outcome,
			"error", journalErr,
		)
	}
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
		// The window is computed once above the arm — see the comment
		// there for why it is the admission-time window (#187) and why
		// it must be shared with the journal record (#763).
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
			// forever.
			//
			// #763: this branch does NOT seal. The effect record
			// armed above stays unsealed on purpose, so the
			// recovery pass re-drives it once the underlying
			// pathology clears. Pre-#763 the audit row was simply
			// lost here and operators had to reconcile from the
			// coordinator-side request_log; now that reconciliation
			// is deferred to the settlement journal, with the
			// request_log as the backstop for an effect that
			// eventually quarantines.
			slog.Error("gateway SPEC-006 § 17.7 fallback usage_events insert failed; audit row deferred to the settlement journal",
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
		refundErr := s.store.RefundReservation(context.Background(), subject.AccountID, requestID(r), s.now().Unix())
		// SEAL (#763): the durable bill exists (usage_events) and the hold is
		// released, so the effect is complete and must never be re-driven.
		//
		// Sealing LAST — after the refund rather than immediately after
		// EnsureUsageEvent — keeps every crash window recoverable: a crash
		// before the seal re-drives into EnsureUsageEvent (payload matches →
		// nil) and RefundReservation (no-op), which is exactly this branch
		// again. Sealing before the refund would instead leave a quota hold
		// that only the reaper clears. And the seal is GATED on the refund
		// (audit R1, architect MEDIUM): sealing past a failed refund would
		// suppress recovery's retry and leave DailyUsage double-counting the
		// usage row plus the still-active hold until the reaper.
		if refundErr != nil && !errors.Is(refundErr, storage.ErrReservationNotFound) &&
			!errors.Is(refundErr, storage.ErrReservationTerminal) {
			slog.Warn("gateway settlement §17.7 refund failed; leaving journal effect unsealed for recovery",
				"request_id", requestID(r),
				"account_id", subject.AccountID,
				"error", refundErr.Error(),
			)
		} else if armed {
			s.sealSettlementEffect(journalKey, journal.SealUsageEvent)
		}
		slog.Warn("gateway settlement used SPEC-006 § 17.7 fallback usage_events insert (settle_path failure)",
			"request_id", requestID(r),
			"account_id", subject.AccountID,
			"outcome", outcome,
			"settle_error", err.Error(),
		)
		return
	}
	// The normal path: SettleReservation wrote the usage_events row and
	// closed the reservation in one transaction. Seal the effect (#763).
	// A seal lost to a crash here is harmless: the re-drive finds the
	// reservation terminal, EnsureUsageEvent matches the row SettleReservation
	// already wrote, and the effect seals then — no second bill. That is what
	// TestSettlementJournal_SettleLandedButSealLost pins.
	if armed {
		s.sealSettlementEffect(journalKey, journal.SealSettled)
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

func boundedStreamingFallbackFrameBytes(line []byte) int64 {
	n := int64(len(line))
	if n > maxStreamingFallbackMetadataBytes {
		return maxStreamingFallbackMetadataBytes
	}
	return n
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
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

// generatedDeltaStringBytes counts the bytes of genuinely generated output in
// one choice delta. It is PATH-aware, not key-aware: only the known
// OpenAI-shape output paths count (delta.content, delta.reasoning_content,
// delta.refusal, delta.text, delta.function_call.arguments,
// delta.tool_calls[].function.arguments). This both bounds billing estimation
// to real content and — since #760 — gates the streaming content-progress
// deadline, so traversal must never descend through unknown containers: a
// per-key allowlist would let delta:{"foo":{"content":"x"}} fabricate
// progress and hold a slot to the stream ceiling (audit R2, code+security).
func generatedDeltaStringBytes(raw json.RawMessage) (int64, bool) {
	var delta struct {
		Content          *string `json:"content"`
		ReasoningContent *string `json:"reasoning_content"`
		Refusal          *string `json:"refusal"`
		Text             *string `json:"text"`
		FunctionCall     *struct {
			Arguments *string `json:"arguments"`
		} `json:"function_call"`
		ToolCalls []struct {
			Function *struct {
				Arguments *string `json:"arguments"`
			} `json:"function"`
		} `json:"tool_calls"`
	}
	if err := json.Unmarshal(raw, &delta); err != nil {
		// Also rejects non-object deltas, preserving the previous
		// "delta must be a JSON object" contract.
		return 0, false
	}
	var n int64
	for _, s := range []*string{delta.Content, delta.ReasoningContent, delta.Refusal, delta.Text} {
		if s != nil {
			n += int64(len(*s))
		}
	}
	if delta.FunctionCall != nil && delta.FunctionCall.Arguments != nil {
		n += int64(len(*delta.FunctionCall.Arguments))
	}
	for _, tc := range delta.ToolCalls {
		if tc.Function != nil && tc.Function.Arguments != nil {
			n += int64(len(*tc.Function.Arguments))
		}
	}
	return n, true
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

func gatewayCleanLengthTruncationTerminalCode(code string) bool {
	switch code {
	case "stream_output_exceeded", "response_byte_cap_exceeded":
		return true
	default:
		return false
	}
}

func gatewayCleanLengthTruncationSettlementOutcome(code string) string {
	if gatewayCleanLengthTruncationTerminalCode(code) {
		return "stream_output_exceeded"
	}
	return ""
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
//
// #762 extends it with a bounded capture of the buyer-visible body, armed
// ONLY for the request that won an id-less dedupe fingerprint claim. The
// capture is what a later identical id-less retry replays instead of paying
// for a second generation.
type statusWriter struct {
	http.ResponseWriter
	statusCode int
	flushed    bool

	captureArmed bool
	captureCap   int
	capture      []byte
	overflowed   bool
	// poisoned marks a response that reached the buyer as a 200 but is not
	// a complete answer — a mid-stream SSE error frame. Replaying a
	// truncated stream would hand a retry a worse answer than a fresh
	// dispatch, so poisoned responses are dropped, not cached.
	poisoned bool
}

type transformedDedupeCapture interface {
	drainDedupeCapture() []byte
}

type cleanSSEErrorDedupeTransformer interface {
	dedupeCleanSSEError(code string) bool
}

// armDedupeCapture starts recording the buyer-visible body, up to limit bytes.
func (sw *statusWriter) armDedupeCapture(limit int) {
	sw.captureArmed = true
	sw.captureCap = limit
}

// dedupePublishable reports whether the captured response may be replayed to
// an identical id-less retry: a complete, buyer-visible 2xx that fit the cap.
func (sw *statusWriter) dedupePublishable() bool {
	return sw.dedupeDelivered2xx() && !sw.overflowed
}

func (sw *statusWriter) dedupeDelivered2xx() bool {
	return sw.captureArmed && !sw.poisoned &&
		sw.statusCode >= 200 && sw.statusCode < 300
}

// dedupeDeliveredButUncacheable reports a fully-delivered, unpoisoned 2xx
// whose body exceeded the replay cap: the response reached the buyer and was
// billed, so its fp->request_id mapping must survive as a body-less stub
// even though replay is unavailable (audit R2, code HIGH).
func (sw *statusWriter) dedupeDeliveredButUncacheable() bool {
	return sw.captureArmed && !sw.poisoned && sw.overflowed &&
		sw.statusCode >= 200 && sw.statusCode < 300
}

func (sw *statusWriter) dedupeCapture() []byte {
	if !sw.captureArmed || sw.overflowed {
		return nil
	}
	return sw.capture
}

// poisonDedupeCapture marks the response behind w as un-replayable. Called
// from every mid-stream SSE error writer: those frames ride on an already
// committed 200, so the status code alone cannot tell a complete stream from
// a truncated one. A no-op for any writer that is not a *statusWriter.
func poisonDedupeCapture(w http.ResponseWriter) {
	if sw, ok := w.(*statusWriter); ok {
		sw.poisoned = true
	}
}

func sseErrorDedupePoisonRequired(w http.ResponseWriter, code string) bool {
	return !sseErrorDeliveredClean(w, code)
}

func sseErrorDeliveredClean(w http.ResponseWriter, code string) bool {
	if code == "" {
		return false
	}
	if sw, ok := w.(*statusWriter); ok {
		if transformed, ok := sw.ResponseWriter.(cleanSSEErrorDedupeTransformer); ok {
			return transformed.dedupeCleanSSEError(code)
		}
	}
	if transformed, ok := w.(cleanSSEErrorDedupeTransformer); ok {
		return transformed.dedupeCleanSSEError(code)
	}
	return false
}

func (sw *statusWriter) WriteHeader(code int) {
	if !sw.flushed {
		sw.statusCode = code
		sw.flushed = true
	}
	sw.ResponseWriter.WriteHeader(code)
	if sw.captureArmed && !sw.overflowed && !sw.poisoned {
		sw.captureDedupeBytes(sw.drainTransformedDedupeBytes(nil))
	}
}

func (sw *statusWriter) Write(b []byte) (int, error) {
	if !sw.flushed {
		sw.statusCode = http.StatusOK
		sw.flushed = true
	}
	// Capture what the buyer actually RECEIVED, which is what the underlying
	// writer reports — not what we handed it. Capturing before the write let
	// a failed or short write (buyer gone mid-stream) be published as a
	// complete 2xx and replayed to the next retry.
	n, err := sw.ResponseWriter.Write(b)
	if sw.captureArmed && !sw.overflowed && !sw.poisoned {
		captured := sw.drainTransformedDedupeBytes(b[:n])
		switch {
		case err != nil:
			// The buyer did not get all of this. Whatever we hold is a
			// partial response; it must never be replayed.
			sw.poisoned = true
			sw.capture = nil
		default:
			sw.captureDedupeBytes(captured)
		}
	}
	return n, err
}

func (sw *statusWriter) drainTransformedDedupeBytes(fallback []byte) []byte {
	if transformed, ok := sw.ResponseWriter.(transformedDedupeCapture); ok {
		return transformed.drainDedupeCapture()
	}
	return fallback
}

func (sw *statusWriter) captureDedupeBytes(b []byte) {
	if len(b) == 0 {
		return
	}
	if len(sw.capture)+len(b) > sw.captureCap {
		// Oversize responses are not cached at all (rather than
		// truncated): a partial replay would be a wrong answer.
		sw.overflowed = true
		sw.capture = nil
		return
	}
	sw.capture = append(sw.capture, b...)
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
	// #762: an SSE error frame means this 200 stream is NOT a complete
	// answer. Poison the dedupe capture so an identical id-less retry gets a
	// fresh dispatch instead of replaying a truncated generation.
	if sseErrorDedupePoisonRequired(w, code) {
		poisonDedupeCapture(w)
	}
	// H1: SSE error frames carry retryable too, classified by the same
	// gatewayRetryableByCode table writeError uses. Headers are already
	// flushed by the time an SSE frame is emitted (the stream started as
	// 200), so there's no Retry-After to set here — only writeError's
	// pre-header-flush 503/504 JSON path can attach that hint.
	payload, _ := json.Marshal(map[string]any{"error": map[string]any{"message": message, "type": errType, "code": code, "retryable": gatewayRetryable(code)}})
	_, _ = w.Write([]byte("data: "))
	_, _ = w.Write(payload)
	_, _ = w.Write([]byte("\n\ndata: [DONE]\n\n"))
}

func writeStructuredOutputTimeoutSSE(w http.ResponseWriter, requestID string) {
	// AC-V2-9 (SPEC-019 v0.2.4 §10): gateway wall-clock timeout emits
	// provider_timeout with refund-only settlement semantics.
	// H2 (finding, 3-lane re-audit): retryable is derived from the same
	// gatewayRetryable classifier used everywhere else provider_timeout is
	// emitted, rather than a hardcoded false — a provider timeout IS
	// retryable, and hardcoding false here contradicted the coordinator's
	// own provider_timeout:true classification for the identical code.
	// #762: a timeout terminal is never a replayable answer.
	poisonDedupeCapture(w)
	w.Header().Set("Content-Type", "text/event-stream; charset=utf-8")
	payload, _ := json.Marshal(map[string]any{
		"error": map[string]any{
			"message":        "Provider timed out during structured-output streaming",
			"type":           "api_error",
			"param":          nil,
			"code":           "provider_timeout",
			"retryable":      gatewayRetryable("provider_timeout"),
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
	// #762: explicit here as well as inside writeSSEError, so a future
	// refactor that stops routing this envelope through writeSSEError cannot
	// silently start caching truncated streams.
	poisonDedupeCapture(w)
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
	// Validate provider self-consistency on the ORIGINAL reported values before
	// any clamp.
	if rawUsage.TotalTokens != nil && usage.TotalTokens != sum {
		return tokenUsage{}, true, fmt.Errorf("usage total_tokens does not match prompt_tokens plus completion_tokens")
	}
	if sum > maxUsageTokens {
		// The provider's honest token count exceeded the reservation-derived
		// validation cap — common for token-dense prompts the byte heuristic
		// under-counts. Clamp to the cap (reduce prompt tokens first, then
		// completion) instead of rejecting: this mirrors the coordinator's
		// "charge bounded prompt tokens" behavior so the buyer keeps a
		// provider_reported usage frame and bounded billing, instead of losing
		// usage visibility and being silently billed on gateway_estimated byte
		// estimates. Never charges beyond the buyer's reservation hold. The
		// buyer-facing usage frame still reports the provider's actual counts
		// (only cached_prompt_tokens is rewritten downstream); this clamp bounds
		// only the value settled against the reservation.
		overage := sum - maxUsageTokens
		if overage <= usage.PromptTokens {
			usage.PromptTokens -= overage
		} else {
			usage.CompletionTokens -= overage - usage.PromptTokens
			usage.PromptTokens = 0
		}
		if usage.CompletionTokens < 0 {
			usage.CompletionTokens = 0
		}
		if usage.CachedPromptTokens > usage.PromptTokens {
			usage.CachedPromptTokens = usage.PromptTokens
		}
		sum = usage.PromptTokens + usage.CompletionTokens
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
//
// NOTE: this cap equals the reservation hold (chat_proxy §"Validation
// cap matches the reservation exposure"), so it cannot be widened
// without widening every request's quota hold. Token-dense prompts
// that still exceed it are handled by the clamp in usageFromJSON
// (bounded provider_reported billing) rather than a wider cap.
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
