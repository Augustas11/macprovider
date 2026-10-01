package router

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"log/slog"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

const (
	demandTelemetryRetention = 14 * 24 * time.Hour
	demandUnknownModelID     = "unknown_model_id"
	demandInvalidModelID     = "invalid_model_id"
)

var demandTelemetryPruneInterval = time.Hour

type demandTelemetryContextKey struct{}

type demandTelemetryState struct {
	mu                     sync.Mutex
	startedAt              time.Time
	requestID              string
	accountID              string
	buyerHash              string
	trafficClass           string
	requestedModel         string
	routedModel            string
	providerID             string
	poolID                 string
	engineClass            string
	stream                 bool
	structuredOutput       bool
	toolsRequested         bool
	maxOutputTokens        int64
	requestedPromptTokens  int64
	requestedOutputTokens  int64
	promptTokens           int64
	cachedPromptTokens     int64
	completionTokens       int64
	reasoningTokens        int64
	totalTokens            int64
	terminalResult         string
	failureReason          string
	eligibleProviderExists bool
	substituted            bool
	queueLatencyMs         int64
	timeToFirstTokenMs     int64
	providerPrefillMs      int64
	providerDecodeMs       int64
	outputTPSMilliTokens   int64
	totalLatencyMs         int64
	suppressed             bool
}

func newDemandTelemetryState(startedAt time.Time, requestID string) *demandTelemetryState {
	return &demandTelemetryState{startedAt: startedAt, requestID: requestID, trafficClass: "unknown"}
}

func withDemandTelemetry(ctx context.Context, state *demandTelemetryState) context.Context {
	return context.WithValue(ctx, demandTelemetryContextKey{}, state)
}

func demandTelemetryFromContext(ctx context.Context) *demandTelemetryState {
	state, _ := ctx.Value(demandTelemetryContextKey{}).(*demandTelemetryState)
	return state
}

func (d *demandTelemetryState) setSubject(subject usageSubject, keySecret string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.accountID = subject.AccountID
	d.buyerHash = demandBuyerHash(keySecret, subject.AccountID)
	if subject.DemoIdentity != "" {
		d.trafficClass = "free"
	} else if subject.AccountID != "" {
		d.trafficClass = "paid"
	}
}

func (d *demandTelemetryState) setRequestID(requestID string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if requestID != "" {
		d.requestID = requestID
	}
}

func (d *demandTelemetryState) suppress() {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.suppressed = true
}

func (d *demandTelemetryState) setRequest(chat chatRequest, poolID, engineClass string, maxOutputTokens int64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.requestedModel = demandRequestedModelID(chat.Model)
	d.stream = chat.Stream
	d.structuredOutput = chat.hasStructuredOutput()
	d.toolsRequested = demandToolsRequested(chat.Tools)
	d.poolID = strings.TrimSpace(poolID)
	d.engineClass = strings.TrimSpace(engineClass)
	if maxOutputTokens >= 0 {
		d.maxOutputTokens = maxOutputTokens
		d.requestedOutputTokens = maxOutputTokens
	}
}

func demandToolsRequested(raw json.RawMessage) bool {
	trimmed := bytes.TrimSpace(raw)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		return false
	}
	var tools []json.RawMessage
	if err := json.Unmarshal(trimmed, &tools); err != nil {
		return true
	}
	return len(tools) > 0
}

func (d *demandTelemetryState) setAttemptedTokens(promptEstimate, maxOutputTokens int64) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.requestedPromptTokens = maxInt64(promptEstimate, 0)
	d.requestedOutputTokens = maxInt64(maxOutputTokens, 0)
	if d.maxOutputTokens == 0 && maxOutputTokens > 0 {
		d.maxOutputTokens = maxOutputTokens
	}
}

func (d *demandTelemetryState) markCoordinatorResponse(resp *http.Response) {
	if resp == nil {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.providerID = sanitizeDemandProviderID(resp.Header.Get("X-MacProvider-Provider"))
	if routed := sanitizeDemandModelID(resp.Header.Get("X-MacProvider-Routed-Model")); routed != "" {
		d.routedModel = routed
	} else if routed := sanitizeDemandModelID(resp.Header.Get("X-MacProvider-Model")); routed != "" {
		d.routedModel = routed
	}
	d.eligibleProviderExists = d.providerID != "" || resp.StatusCode == http.StatusOK || resp.StatusCode == http.StatusGatewayTimeout || resp.StatusCode == http.StatusBadGateway
}

func (d *demandTelemetryState) setRoutedModel(model string) {
	model = sanitizeDemandModelID(model)
	if model == "" {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.routedModel = model
	d.substituted = d.requestedModel != "" && model != d.requestedModel
}

func (d *demandTelemetryState) markSettlement(prompt, completion int64, outcome string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.markOutcomeLocked(prompt, completion, outcome, true)
}

func (d *demandTelemetryState) setTokenUsage(usage tokenUsage) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.promptTokens = maxInt64(usage.PromptTokens, 0)
	d.cachedPromptTokens = maxInt64(usage.observedCachedTokens(), 0)
	d.completionTokens = maxInt64(usage.CompletionTokens, 0)
	d.reasoningTokens = minInt64(maxInt64(usage.ReasoningTokens, 0), d.completionTokens)
	d.totalTokens = d.promptTokens + d.completionTokens
}

func (d *demandTelemetryState) setTiming(timing *gatewayPhaseTiming, now time.Time) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.totalLatencyMs = maxInt64(now.Sub(d.startedAt).Milliseconds(), 0)
	snapshot := timing.demandSnapshot(d.completionTokens)
	d.queueLatencyMs = snapshot.queueLatencyMS
	d.timeToFirstTokenMs = snapshot.timeToFirstTokenMS
	d.providerPrefillMs = snapshot.providerPrefillMS
	d.providerDecodeMs = snapshot.providerDecodeMS
	d.outputTPSMilliTokens = snapshot.outputTokensPerSecondMilliTokens
}

func (d *demandTelemetryState) markTerminalOutcome(prompt, completion int64, outcome string, eligibleProviderExists bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.markOutcomeLocked(prompt, completion, outcome, eligibleProviderExists)
}

func (d *demandTelemetryState) markProviderFailure(prompt, completion int64, status int, code string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.promptTokens = maxInt64(prompt, 0)
	d.completionTokens = maxInt64(completion, 0)
	d.cachedPromptTokens = minInt64(maxInt64(d.cachedPromptTokens, 0), d.promptTokens)
	d.reasoningTokens = minInt64(maxInt64(d.reasoningTokens, 0), d.completionTokens)
	d.totalTokens = d.promptTokens + d.completionTokens
	if status == http.StatusGatewayTimeout {
		d.terminalResult = "timeout"
	} else {
		d.terminalResult = "failure"
	}
	d.failureReason = normalizeProviderFailureReason(status, code)
	d.eligibleProviderExists = true
}

func (d *demandTelemetryState) markOutcomeLocked(prompt, completion int64, outcome string, eligibleProviderExists bool) {
	d.promptTokens = maxInt64(prompt, 0)
	d.completionTokens = maxInt64(completion, 0)
	d.cachedPromptTokens = minInt64(maxInt64(d.cachedPromptTokens, 0), d.promptTokens)
	d.reasoningTokens = minInt64(maxInt64(d.reasoningTokens, 0), d.completionTokens)
	d.totalTokens = d.promptTokens + d.completionTokens
	d.terminalResult, d.failureReason = demandTerminalFromOutcome(outcome)
	d.eligibleProviderExists = eligibleProviderExists
}

func (d *demandTelemetryState) markNoProvider(status int, code string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.terminalResult = "failure"
	d.failureReason = normalizeDemandFailureReason(status, code)
	d.eligibleProviderExists = demandEligibleProviderExists(d.failureReason)
}

func (d *demandTelemetryState) markGatewayFailure(status int, code string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.terminalResult = "failure"
	d.failureReason = normalizeDemandFailureReason(status, code)
	d.eligibleProviderExists = demandEligibleProviderExists(d.failureReason)
}

func (d *demandTelemetryState) snapshot(now time.Time, status int) (storage.DemandEvent, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.suppressed {
		return storage.DemandEvent{}, false
	}
	if d.requestedModel == "" || d.buyerHash == "" {
		return storage.DemandEvent{}, false
	}
	terminal := d.terminalResult
	reason := d.failureReason
	if terminal == "" {
		terminal, reason = demandTerminalFromStatus(status)
	}
	total := d.totalTokens
	if total == 0 {
		total = d.promptTokens + d.completionTokens
	}
	routed := d.routedModel
	if routed == "" && terminal == "success" {
		routed = d.requestedModel
	}
	substituted := d.substituted || (routed != "" && routed != d.requestedModel)
	return storage.DemandEvent{
		RequestID:              d.requestID,
		BuyerHash:              d.buyerHash,
		TrafficClass:           nonEmptyString(d.trafficClass, "unknown"),
		RequestedModel:         d.requestedModel,
		RoutedModel:            routed,
		ProviderID:             d.providerID,
		PoolID:                 d.poolID,
		EngineClass:            d.engineClass,
		Stream:                 d.stream,
		StructuredOutput:       d.structuredOutput,
		ToolsRequested:         d.toolsRequested,
		MaxOutputTokens:        d.maxOutputTokens,
		RequestedPromptTokens:  maxInt64(d.requestedPromptTokens, 0),
		RequestedOutputTokens:  maxInt64(d.requestedOutputTokens, 0),
		RequestedTotalTokens:   maxInt64(d.requestedPromptTokens, 0) + maxInt64(d.requestedOutputTokens, 0),
		PromptTokens:           maxInt64(d.promptTokens, 0),
		CachedPromptTokens:     maxInt64(d.cachedPromptTokens, 0),
		CompletionTokens:       maxInt64(d.completionTokens, 0),
		ReasoningTokens:        maxInt64(d.reasoningTokens, 0),
		TotalTokens:            maxInt64(total, 0),
		TerminalResult:         terminal,
		FailureReason:          reason,
		EligibleProviderExists: d.eligibleProviderExists,
		Substituted:            substituted,
		QueueLatencyMs:         maxInt64(d.queueLatencyMs, 0),
		TimeToFirstTokenMs:     maxInt64(d.timeToFirstTokenMs, 0),
		ProviderPrefillMs:      maxInt64(d.providerPrefillMs, 0),
		ProviderDecodeMs:       maxInt64(d.providerDecodeMs, 0),
		OutputTPSMilliTokens:   maxInt64(d.outputTPSMilliTokens, 0),
		TotalLatencyMs:         maxInt64(maxInt64(d.totalLatencyMs, 0), maxInt64(now.Sub(d.startedAt).Milliseconds(), 0)),
		CreatedAt:              now.UTC(),
	}, true
}

func (s *Server) flushDemandTelemetry(r *http.Request, state *demandTelemetryState, status int) {
	if state == nil {
		return
	}
	state.setRequestID(requestID(r))
	event, ok := state.snapshot(s.now(), status)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()
	if err := s.store.InsertDemandEvent(ctx, event); err != nil {
		slog.Error("gateway demand telemetry insert failed",
			"request_id", requestID(r),
			"terminal_result", event.TerminalResult,
			"failure_reason", event.FailureReason,
			"error", err)
	}
}

func (s *Server) pruneDemandTelemetryRetention(ctx context.Context) {
	cutoff := s.now().Add(-demandTelemetryRetention)
	pruneCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	deleted, err := s.store.PruneDemandEvents(pruneCtx, cutoff)
	if err != nil {
		slog.Warn("gateway demand telemetry retention prune failed",
			"retention_hours", int(demandTelemetryRetention.Hours()),
			"error", err)
		return
	}
	if deleted > 0 {
		slog.Info("gateway demand telemetry retention pruned",
			"rows_deleted", deleted,
			"retention_hours", int(demandTelemetryRetention.Hours()))
	}
}

func (s *Server) startDemandTelemetryRetentionPruner() {
	if demandTelemetryPruneInterval <= 0 {
		return
	}
	stop := make(chan struct{})
	s.demandRetentionMu.Lock()
	s.demandRetentionStop = stop
	s.demandRetentionMu.Unlock()
	go func(stop <-chan struct{}) {
		ticker := time.NewTicker(demandTelemetryPruneInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
			case <-stop:
				return
			}
			s.pruneDemandTelemetryRetention(context.Background())
		}
	}(stop)
}

func (s *Server) stopDemandTelemetryRetentionPruner() {
	if s == nil {
		return
	}
	s.demandRetentionMu.Lock()
	defer s.demandRetentionMu.Unlock()
	if s.demandRetentionStop == nil {
		return
	}
	close(s.demandRetentionStop)
	s.demandRetentionStop = nil
}

func demandBuyerHash(keySecret string, accountID string) string {
	accountID = strings.TrimSpace(accountID)
	keySecret = strings.TrimSpace(keySecret)
	if accountID == "" || keySecret == "" {
		return ""
	}
	mac := hmac.New(sha256.New, []byte(keySecret))
	_, _ = mac.Write([]byte("macprovider-demand-v2\n"))
	_, _ = mac.Write([]byte(accountID))
	return hex.EncodeToString(mac.Sum(nil))
}

func demandRoutedModelFromJSON(body []byte) string {
	var envelope struct {
		Model string `json:"model"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return ""
	}
	return sanitizeDemandModelID(envelope.Model)
}

func demandTerminalFromOutcome(outcome string) (string, string) {
	switch strings.TrimSpace(outcome) {
	case "ok", "unverified_streaming":
		return "success", ""
	case "client_disconnect":
		return "cancellation", "buyer_cancelled"
	case "provider_timeout":
		return "timeout", "upstream_provider_failure"
	case "stream_output_exceeded", "context_exceeds_capacity", "context_length_exceeded":
		return "failure", "unsupported_context"
	case "unsupported_tools":
		return "failure", "unsupported_tools"
	case "no_provider_available":
		return "failure", "all_providers_busy"
	case "quota_exhausted", "account_request_rate_exceeded", "account_concurrency_exceeded", "demo_concurrency_exceeded":
		return "failure", normalizeDemandFailureReason(0, outcome)
	default:
		return "failure", "upstream_provider_failure"
	}
}

func demandTerminalFromStatus(status int) (string, string) {
	switch {
	case status >= 200 && status < 300:
		return "success", ""
	case status == http.StatusGatewayTimeout:
		return "timeout", "upstream_provider_failure"
	case status == http.StatusTooManyRequests:
		return "failure", "gateway_rejection"
	default:
		return "failure", "gateway_rejection"
	}
}

func normalizeDemandFailureReason(status int, code string) string {
	switch strings.TrimSpace(code) {
	case "":
		if status == http.StatusTooManyRequests || status == http.StatusServiceUnavailable {
			return "all_providers_busy"
		}
		return "gateway_rejection"
	case "model_not_found":
		return "no_provider"
	case "no_provider_available":
		return "all_providers_busy"
	case "quota_exhausted":
		return "quota_exhausted"
	case "n_must_be_1", "invalid_request", "invalid_engine_selection":
		return "gateway_rejection"
	case "account_request_rate_exceeded", "account_concurrency_exceeded", "demo_concurrency_exceeded":
		return "tenant_concurrency_limited"
	case "context_exceeds_capacity", "context_length_exceeded", "max_tokens_exceeded":
		return "unsupported_context"
	case "error_context_exceeded":
		return "unsupported_context"
	case "unsupported_tools", "tool_calling_unsupported", "structured_output_unsupported":
		return "unsupported_tools"
	case "trust_rejected", "trust_pool_rejected", "pool_not_authorized", "pool_unavailable", "engine_selection_required", "unsupported_engine", "engine_unavailable":
		return "trust_routing_rejection"
	case "error_queue_full":
		return "all_providers_busy"
	case "coordinator_unavailable", "provider_timeout", "upstream_provider_error", "invalid_provider_response", "invalid_provider_usage", "stream_malformed", "stream_truncated", "error_model_not_loaded", "error_internal", "malformed_json_response", "json_schema_validation_failed":
		return "upstream_provider_failure"
	default:
		return demandFallbackFailureReason(status)
	}
}

func normalizeProviderFailureReason(status int, code string) string {
	trimmed := strings.TrimSpace(code)
	if trimmed == "" && status >= 500 {
		return "upstream_provider_failure"
	}
	if trimmed != "" && !knownDemandFailureCode(trimmed) {
		if status >= 500 {
			return "upstream_provider_failure"
		}
		return "gateway_rejection"
	}
	return normalizeDemandFailureReason(status, code)
}

func knownDemandFailureCode(code string) bool {
	switch code {
	case "", "model_not_found", "no_provider_available", "quota_exhausted",
		"n_must_be_1", "invalid_request", "invalid_engine_selection",
		"account_request_rate_exceeded", "account_concurrency_exceeded", "demo_concurrency_exceeded",
		"context_exceeds_capacity", "context_length_exceeded", "max_tokens_exceeded", "error_context_exceeded",
		"unsupported_tools", "tool_calling_unsupported", "structured_output_unsupported",
		"trust_rejected", "trust_pool_rejected", "pool_not_authorized", "pool_unavailable",
		"engine_selection_required", "unsupported_engine", "engine_unavailable",
		"error_queue_full", "coordinator_unavailable", "provider_timeout", "upstream_provider_error", "invalid_provider_response",
		"invalid_provider_usage", "stream_malformed", "stream_truncated", "error_model_not_loaded",
		"error_internal", "malformed_json_response", "json_schema_validation_failed":
		return true
	default:
		return false
	}
}

func demandFallbackFailureReason(status int) string {
	switch {
	case status == http.StatusTooManyRequests || status == http.StatusServiceUnavailable:
		return "all_providers_busy"
	case status >= 500:
		return "upstream_provider_failure"
	default:
		return "gateway_rejection"
	}
}

func demandEligibleProviderExists(reason string) bool {
	switch reason {
	case "no_provider", "gateway_rejection", "quota_exhausted", "tenant_concurrency_limited", "unsupported_context", "unsupported_tools", "trust_routing_rejection":
		return false
	default:
		return true
	}
}

func nonEmptyString(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func sanitizeDemandModelID(model string) string {
	model = strings.TrimSpace(model)
	if model == "" {
		return ""
	}
	if !demandModelIDLooksPublic(model) {
		return demandInvalidModelID
	}
	if !knownDemandModelID(model) {
		return demandUnknownModelID
	}
	return model
}

func demandRequestedModelID(model string) string {
	if sanitized := sanitizeDemandModelID(model); sanitized != "" {
		return sanitized
	}
	if strings.TrimSpace(model) != "" {
		return demandInvalidModelID
	}
	return ""
}

func demandModelIDLooksPublic(model string) bool {
	if len(model) > 128 {
		return false
	}
	for _, r := range model {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '.' || r == '-' || r == '_' || r == '/':
		default:
			return false
		}
	}
	return true
}

func knownDemandModelID(model string) bool {
	switch model {
	case demandUnknownModelID, demandInvalidModelID,
		"llama", "qwen", "test-model", "model-a", "model-b", "model-c",
		"openai/gpt-oss-20b",
		"google/gemma-4-26b-a4b-it", "google-gemma-4-26b-a4b-it",
		"nvidia/nemotron-3-nano-30b-a3b",
		"qwen/qwen2.5-coder-32b-instruct", "qwen2.5-coder-32b-instruct",
		"meta-llama/llama-3.2-3b-instruct",
		"meta-llama/llama-3.1-8b-instruct",
		"qwen/qwen3-8b", "qwen3-8b",
		"openai/gpt-oss-120b",
		"qwen/qwen3-32b", "qwen3-32b",
		"qwen/qwen3-coder-30b-a3b-instruct", "qwen3-coder-30b-a3b-instruct",
		"qwen/qwen3.8-27b",
		"qwen/qwen3.5-27b",
		"qwen/qwen3.6-27b",
		"qwen/qwen3.6-35b-a3b",
		"qwen/qwen3.5-35b-a3b",
		"qwen/qwen3-30b-a3b-instruct-2507",
		"z-ai/glm-4.5-air",
		"mlx-community/gpt-oss-20b-MXFP4-Q4",
		"mlx-community/gpt-oss-20b-MXFP4-Q8",
		"mlx-community/gpt-oss-120b-4bit",
		"mlx-community/gemma-4-26b-a4b-it-4bit",
		"mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
		"mlx-community/Qwen2.5-7B-Instruct-4bit",
		"mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
		"mlx-community/Llama-3.2-3B-Instruct-4bit",
		"mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
		"mlx-community/Qwen3-8B-4bit",
		"mlx-community/Qwen3-32B-4bit",
		"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
		"mlx-community/Qwen3.8-27B-4bit",
		"mlx-community/Qwen3.5-27B-4bit",
		"mlx-community/Qwen3.5-9B-4bit",
		"mlx-community/Qwen3.6-27B-4bit",
		"mlx-community/Qwen3.6-35B-A3B-4bit",
		"mlx-community/Qwen3.5-35B-A3B-4bit",
		"mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
		"mlx-community/Ministral-3-3B-Instruct-2512-4bit",
		"Ministral-3-3B-Instruct-2512-4bit",
		"Qwen3.5-9B-4bit",
		"mlx-community/GLM-4.5-Air-4bit":
		return true
	default:
		return false
	}
}

func sanitizeDemandProviderID(providerID string) string {
	providerID = strings.TrimSpace(providerID)
	if providerID == "" || len(providerID) > 64 {
		return ""
	}
	for _, r := range providerID {
		switch {
		case r >= 'a' && r <= 'z':
		case r >= 'A' && r <= 'Z':
		case r >= '0' && r <= '9':
		case r == '.' || r == '-' || r == '_':
		default:
			return ""
		}
	}
	return providerID
}

func minInt64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
