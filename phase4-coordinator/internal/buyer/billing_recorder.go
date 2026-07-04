package buyer

import (
	"context"
	"fmt"
	"net/http"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/requestlog"
)

// billingRecorder is the typed extraction of the previously-inline
// logRowWithBilling closure from handleChatCompletions. M3-10
// (audits/2026-06-10/REPO_AUDIT.md ARCH-6) hoisted the closure into
// this struct so the per-request orchestration of request_log +
// billing-ledger writes is no longer hidden inside a handler closure.
//
// Lifecycle: exactly one billingRecorder per handleChatCompletions
// invocation, constructed up front and passed by pointer through the
// three transport sequence helpers (forwardStreamSequence,
// forwardWSNonStreamSequence, forwardHTTPSequence). Single-goroutine
// per request — the recorder is NOT shared across requests, so its
// mutable fields (attemptN, model, stream, requestID) are unguarded
// by design, matching the pre-refactor closure's capture semantics.
//
// Byte-identical preservation: every field written, every operation
// order, every NULL-vs-zero treatment matches the pre-refactor
// closure. The only structural change is that captured outer-scope
// variables become struct fields, and the closure body becomes the
// recordRow method. The hot-path-then-fallback flow inside
// WriteHotPath / WriteRequestLogWithIdentity is unchanged.
//
// Mutation contract:
//   - attemptN auto-increments on every provider-bound recordRow call
//     (providerAssignedID != ""), regardless of write outcome — the
//     deferred increment fires even when the hot-path or fallback
//     write errors. Matches the pre-refactor `defer billingAttemptN++`
//     semantics: the counter tracks provider-bound record attempts,
//     not successful row writes.
//   - model / stream / requestID are setters called from
//     handleChatCompletions as the request parses (the closure read
//     these by-reference from outer scope; the recorder updates the
//     field on Set). All sets land BEFORE the first provider-bound
//     recordRow call, preserving the pre-refactor value-at-fire-time
//     contract.
type billingRecorder struct {
	server    *Server
	state     *forwardState
	req       *http.Request
	startedAt time.Time

	// Late-bound per-request fields. Set as the request parses, before
	// any provider-bound recordRow call. Pre-refactor these were
	// captured outer-scope variables (requestLogModel, requestLogStream,
	// originalRequestID).
	model     string
	stream    bool
	requestID string
	// externalRequestID is the inbound X-Request-ID per SPEC-002 §11 /
	// v1.4.2 R-2 — preserved into request_log.external_request_id so
	// out-of-process auditors can join gateway usage_events with
	// coordinator request_log by a stable shared id. Empty when the
	// inbound request carried no X-Request-ID.
	externalRequestID string
	// accountID is the gateway-forwarded X-MacProvider-Account (SPEC-002
	// v1.5.0, SPEC-006 v0.9.1, issue #211). Preserved into
	// request_log.account_id so reconciliation can use the composite
	// (account_id, external_request_id) key instead of
	// external_request_id alone — the latter is ambiguous on
	// cross-account X-Request-ID collisions after #196. Empty when the
	// inbound request carried no header (direct legacy buyer, demo
	// without gateway, pre-v0.9.1 gateway).
	accountID             string
	promptTokenUpperBound *int64

	// attemptN is the running per-provider-attempt counter. Pre-refactor
	// this was billingAttemptN, incremented via deferred closure on
	// every successful provider-bound record.
	attemptN int
	// routeSnapshotAttemptN is the pre-dispatch provider-dispatch
	// ordinal used by settlement_route_snapshots. It advances at the
	// dispatch boundary, not at request_log write time, so streaming
	// failover-before-first-chunk and HTTP/WS retries share one
	// monotonic attempt identity surface for later receipt settlement.
	routeSnapshotAttemptN   int
	outputCursorByte        int64
	settlementAttemptN      int
	hasSettlementAttemptN   bool
	settlementPolicyMode    string
	settlementPolicyVersion string
}

// newBillingRecorder constructs the per-request recorder. Called once
// from handleChatCompletions before any logging fires. state is the
// forwardState pointer the sequence helpers will mutate; the recorder
// reads state.routingDone at write time to compute RoutingMs (matching
// the pre-refactor closure's live-capture semantics).
func (s *Server) newBillingRecorder(r *http.Request, state *forwardState, startedAt time.Time, requestID, externalRequestID, accountID string) *billingRecorder {
	return &billingRecorder{
		server:            s,
		state:             state,
		req:               r,
		startedAt:         startedAt,
		requestID:         requestID,
		externalRequestID: externalRequestID,
		accountID:         accountID,
	}
}

func (s *Server) logCacheBillingRoutingDecision(d billing.CacheBillingRoutingDecision) {
	event := s.log.Info().
		Str("event", "routing_decision").
		Str("request_id", d.RequestID).
		Int("attempt_n", d.AttemptN).
		Str("provider_id", d.ProviderID).
		Str("provider_assigned_id", d.ProviderAssignedID).
		Int64("cached_prompt_tokens", d.CachedPromptTokens)
	if d.StickyResult != "" {
		event = event.Str("sticky_result", d.StickyResult)
	}
	if d.StickyMissReason != "" {
		event = event.Str("sticky_miss_reason", d.StickyMissReason)
	}
	if d.ValidationReason != "" {
		event = event.Str("cache_validation_reason", d.ValidationReason).Str("cache_json_type", "invalid_or_policy_rejected")
	}
	event.Msg("routing_decision")
}

// setModel updates the model field. Called from handleChatCompletions
// after body parse, before any provider-bound recordRow fires. The
// pre-refactor closure read this from a captured outer-scope variable;
// the setter preserves the same "latest value at fire time" contract.
func (b *billingRecorder) setModel(model string) {
	b.model = model
}

// setStream updates the stream field. See setModel for contract.
func (b *billingRecorder) setStream(stream bool) {
	b.stream = stream
}

func (b *billingRecorder) setPromptTokenUpperBound(tokens int64) {
	if tokens < 0 {
		tokens = 0
	}
	b.promptTokenUpperBound = &tokens
}

// setRequestID updates the requestID field after idempotency-key
// reservation may have rewritten it. Pre-refactor the closure read
// `originalRequestID` from outer scope; the setter preserves the same
// post-idempotency-rewrite semantics.
func (b *billingRecorder) setRequestID(requestID string) {
	b.requestID = requestID
}

// recordRow is the typed equivalent of the pre-refactor
// logRowWithBilling closure. Behaviour preserved byte-identical:
//   - reqLog nil → no-op nil return (early exit).
//   - attemptN snapshot before deferred increment matches the
//     pre-refactor `attemptN := billingAttemptN` + `defer ...++`
//     pattern; increment fires only when providerAssignedID != "".
//   - row construction reads state.routingDone live, so RoutingMs
//     reflects the latest routing decision (M2-1c invariant).
//   - billing hot-path branch: providerAssignedID set AND status !=
//     503 AND both stores present → resolve stableProviderID, call
//     WriteHotPath, fall back to WriteRequestLogWithIdentity on
//     hot-path error.
//   - non-hot-path branch: fall through to reqLog.Insert.
func (b *billingRecorder) recordRow(
	providerAssignedID string,
	providerID string,
	status int,
	promptTok, cachedPromptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
	estimatedCompTokens *int64,
	faultFlag string,
	settlementOutput *billing.SettlementOutput,
) error {
	s := b.server
	if s.reqLog == nil {
		return nil
	}
	attemptN := b.attemptN
	if providerAssignedID != "" {
		defer func() {
			b.attemptN++
		}()
	}
	recoveryCachedPromptTok, cacheQuarantineReason := requestLogCacheRecoveryFields(cachedPromptTok, promptTok, b.state, attemptN)
	row := requestlog.Row{
		TSUtc:                 b.startedAt,
		RequestID:             b.requestID,
		ExternalRequestID:     b.externalRequestID,
		AccountID:             b.accountID,
		Model:                 sanitizeRequestLogText(b.model),
		ProviderAssignedID:    providerAssignedID,
		PromptTokens:          promptTok,
		CachedPromptTokens:    recoveryCachedPromptTok,
		CompletionTokens:      completionTok,
		EstimatedCompTokens:   estimatedCompTokens,
		LatencyMs:             float64(time.Since(b.startedAt).Milliseconds()),
		RoutingMs:             float64(b.state.routingDone.Sub(b.startedAt).Milliseconds()),
		Status:                status,
		Stream:                b.stream,
		BuyerIP:               buyerIP(b.req.RemoteAddr),
		Error:                 sanitizeRequestLogText(errMsg),
		ErrorCode:             errCode,
		CacheQuarantineReason: cacheQuarantineReason,
		PrefHeader:            sanitizeRequestLogText(b.req.Header.Get("X-MacProvider-Pref")),
		ProviderHeader:        sanitizeRequestLogText(b.req.Header.Get("X-MacProvider-Provider")),
		Retried:               retried,
	}
	ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
	defer cancel()
	billingStore, billingCfg, billingSnapshotID := s.billingState()
	if billingStore != nil && s.reqLogStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable {
		stableProviderID := providerID
		if stableProviderID == "" {
			for _, p := range s.pool.Snapshot() {
				if p.AssignedID == providerAssignedID {
					stableProviderID = p.ProviderID
					break
				}
			}
		}
		if stableProviderID == "" {
			s.log.Warn().Str("request_id", b.requestID).Str("provider_assigned_id", providerAssignedID).Msg("billing hot-path skipped without stable provider identity")
			return fmt.Errorf("billing hot-path missing stable provider identity")
		}
		if faultFlag == "" {
			faultFlag = billing.FaultNone
		}
		accountScope := accountScopeForSettlement(b.accountID)
		settlementMode, settlementVersion := b.settlementPolicyForLedger()
		billingInput := billing.HotPathInput{
			RequestID:                  row.RequestID,
			AttemptN:                   attemptN,
			ProviderAssignedID:         providerAssignedID,
			ProviderID:                 stableProviderID,
			Model:                      row.Model,
			Status:                     status,
			Stream:                     row.Stream,
			TSUtc:                      row.TSUtc,
			PromptTokens:               promptTok,
			PromptTokenUpperBound:      b.promptTokenUpperBound,
			CachedPromptTokens:         cachedPromptTok,
			CompletionTokens:           completionTok,
			EstimatedCompTokens:        estimatedCompTokens,
			ErrorCode:                  errCode,
			FaultFlag:                  faultFlag,
			StickyResult:               b.state.stickyResult,
			StickyMissReason:           b.state.stickyMissReason,
			ConfigSnapshotID:           billingSnapshotID,
			RateEntry:                  billing.RateFor(billingCfg.RateCard, row.Model),
			MultiplierPPM:              billing.ParseMultiplierPPM(billingCfg.GlobalMultiplier),
			ProviderShareBps:           billing.ParseShareBps(billingCfg.ProviderShare),
			SettlementAccountScopeHash: billing.SettlementAccountScopeHash(accountScope),
			SettlementPolicyMode:       settlementMode,
			SettlementPolicyVersion:    settlementVersion,
			RoutingDecisionLog:         s.logCacheBillingRoutingDecision,
		}
		err := billingStore.WriteHotPath(ctx, s.reqLogStore, row, billingInput)
		if err != nil {
			s.log.Warn().Err(err).Str("request_id", b.requestID).Msg("billing hot-path insert failed")
			fallbackCtx, fallbackCancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
			defer fallbackCancel()
			if fallbackErr := billingStore.WriteRequestLogWithIdentity(fallbackCtx, s.reqLogStore, row, billingInput); fallbackErr != nil {
				s.log.Warn().Err(fallbackErr).Str("request_id", b.requestID).Msg("request_log identity fallback insert failed")
				return fmt.Errorf("billing hot-path insert failed: %w; fallback failed: %v", err, fallbackErr)
			}
		}
		if err := b.recordSettlementAttemptOutput(ctx, billingStore, billingInput, settlementOutput); err != nil {
			return err
		}
		return nil
	}
	if err := s.reqLog.Insert(ctx, row); err != nil {
		s.log.Warn().Err(err).Str("request_id", b.requestID).Msg("request_log insert failed")
		return err
	}
	if billingStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable {
		accountScope := accountScopeForSettlement(b.accountID)
		settlementMode, settlementVersion := b.settlementPolicyForLedger()
		billingInput := billing.HotPathInput{
			RequestID:                  row.RequestID,
			AttemptN:                   attemptN,
			ProviderAssignedID:         providerAssignedID,
			ProviderID:                 providerID,
			Model:                      row.Model,
			Status:                     status,
			Stream:                     row.Stream,
			TSUtc:                      row.TSUtc,
			PromptTokens:               promptTok,
			PromptTokenUpperBound:      b.promptTokenUpperBound,
			CachedPromptTokens:         cachedPromptTok,
			CompletionTokens:           completionTok,
			EstimatedCompTokens:        estimatedCompTokens,
			ErrorCode:                  errCode,
			FaultFlag:                  faultFlag,
			SettlementAccountScopeHash: billing.SettlementAccountScopeHash(accountScope),
			SettlementPolicyMode:       settlementMode,
			SettlementPolicyVersion:    settlementVersion,
		}
		if err := b.recordSettlementAttemptOutput(ctx, billingStore, billingInput, settlementOutput); err != nil {
			return err
		}
	}
	return nil
}

func (b *billingRecorder) settlementPolicyForLedger() (string, string) {
	if !b.hasSettlementAttemptN {
		return "legacy", ""
	}
	mode := b.settlementPolicyMode
	if mode == "" {
		mode = billing.RouteSnapshotModeObserve
	}
	version := b.settlementPolicyVersion
	if version == "" {
		version = billing.RouteSnapshotPolicyVersion
	}
	return mode, version
}

func (b *billingRecorder) recordSettlementAttemptOutput(ctx context.Context, store *billing.Store, in billing.HotPathInput, output *billing.SettlementOutput) error {
	if store == nil || in.ProviderID == "" {
		return nil
	}
	if output == nil {
		output = settlementOutputForContent("", nil, nil, terminalStateFromAttempt(in.Status, "", in.ErrorCode))
	}
	out := *output
	outputAvailable := !settlementOutputIsUnavailable(output)
	delivered := out.OutputPrefixEndByte - out.OutputPrefixStartByte
	start := b.outputCursorByte
	if outputAvailable {
		out.OutputPrefixStartByte = b.outputCursorByte
		out.OutputPrefixEndByte = b.outputCursorByte + delivered
	} else {
		delivered = 0
		out.OutputPrefixStartByte = 0
		out.OutputPrefixEndByte = 0
	}

	observedInput := int64(0)
	observedOutput := int64(0)
	usageSource := billing.UsageSourceByteEstimated
	if in.PromptTokens != nil && in.CompletionTokens != nil {
		observedInput = *in.PromptTokens
		observedOutput = *in.CompletionTokens
		usageSource = billing.UsageSourceCoordinatorObserved
	} else if outputAvailable {
		coordinatorOutputEstimate := b.server.estimatedCompletionTokensFromBytes(int(delivered))
		if coordinatorOutputEstimate != nil {
			observedOutput = *coordinatorOutputEstimate
		} else if in.EstimatedCompTokens != nil {
			observedOutput = *in.EstimatedCompTokens
		}
	}
	billableInput := observedInput
	billableOutput := observedOutput
	if in.PromptTokenUpperBound != nil && billableInput > *in.PromptTokenUpperBound {
		billableInput = *in.PromptTokenUpperBound
	}
	if usageSource == billing.UsageSourceByteEstimated {
		billableInput = 0
		billableOutput = 0
	}
	if out.TerminalState != billing.TerminalStateNormalDone && delivered == 0 {
		billableInput = 0
		billableOutput = 0
	}
	terminalTS := out.TerminalStateTSUnixMS
	if terminalTS <= 0 {
		terminalTS = time.Now().UTC().UnixMilli()
	}
	settlementAttemptN := in.AttemptN
	if b.hasSettlementAttemptN {
		settlementAttemptN = b.settlementAttemptN
	}
	attempt := billing.SettlementAttemptOutput{
		AccountScope:          accountScopeForSettlement(b.accountID),
		RequestID:             in.RequestID,
		AttemptN:              int64(settlementAttemptN),
		ProviderID:            in.ProviderID,
		Output:                out,
		OutputAvailable:       outputAvailable,
		UsageSource:           usageSource,
		TerminalStateTSUnixMS: terminalTS,
		Usage: billing.SettlementUsage{
			BillableInputTokens:  billableInput,
			BillableOutputTokens: billableOutput,
			DeliveredOutputBytes: delivered,
			ObservedInputTokens:  observedInput,
			ObservedOutputTokens: observedOutput,
		},
	}
	_, err := store.InsertSettlementAttemptOutput(ctx, attempt)
	if err == nil {
		b.outputCursorByte = start + delivered
	}
	return err
}

// logRow is the convenience wrapper matching the pre-refactor `logRow`
// closure shape. Used at no-provider sites (route errors, buyer
// failures) where providerID is unknown and faultFlag is implicitly
// FaultNone.
func (b *billingRecorder) logRow(
	providerAssignedID string,
	status int,
	promptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
) {
	_ = b.recordRow(providerAssignedID, "", status, promptTok, nil, completionTok, errMsg, errCode, retried, nil, billing.FaultNone, nil)
}

// logBuyerFailure mirrors the pre-refactor `logBuyerFailure` closure.
func (b *billingRecorder) logBuyerFailure(status int, msg string) {
	b.logRow("", status, nil, nil, msg, "", 0)
}

// logProviderRow mirrors the pre-refactor `logProviderRow` closure.
func (b *billingRecorder) logProviderRow(
	provider pool.Provider,
	status int,
	promptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
) error {
	return b.recordRow(provider.AssignedID, provider.ProviderID, status, promptTok, nil, completionTok, errMsg, errCode, retried, nil, billing.FaultNone, nil)
}

// logProviderRowWithEstimate mirrors the pre-refactor
// `logProviderRowWithEstimate` closure.
func (b *billingRecorder) logProviderRowWithEstimate(
	provider pool.Provider,
	status int,
	promptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
	estimatedCompTokens *int64,
) error {
	return b.recordRow(provider.AssignedID, provider.ProviderID, status, promptTok, nil, completionTok, errMsg, errCode, retried, estimatedCompTokens, billing.FaultNone, nil)
}

func (b *billingRecorder) logProviderRowWithEstimateAndOutput(
	provider pool.Provider,
	status int,
	promptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
	estimatedCompTokens *int64,
	output *billing.SettlementOutput,
) error {
	return b.recordRow(provider.AssignedID, provider.ProviderID, status, promptTok, nil, completionTok, errMsg, errCode, retried, estimatedCompTokens, billing.FaultNone, output)
}

func (b *billingRecorder) logProviderRowWithCacheEstimateAndOutput(
	provider pool.Provider,
	status int,
	promptTok, cachedPromptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
	estimatedCompTokens *int64,
	output *billing.SettlementOutput,
) error {
	return b.recordRow(provider.AssignedID, provider.ProviderID, status, promptTok, cachedPromptTok, completionTok, errMsg, errCode, retried, estimatedCompTokens, billing.FaultNone, output)
}
