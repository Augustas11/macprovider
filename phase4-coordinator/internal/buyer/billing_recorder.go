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
//   - attemptN auto-increments on each successful recordRow call that
//     names a provider (providerAssignedID != ""), matching the
//     pre-refactor `defer billingAttemptN++` semantics.
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

	// attemptN is the running per-provider-attempt counter. Pre-refactor
	// this was billingAttemptN, incremented via deferred closure on
	// every successful provider-bound record.
	attemptN int
}

// newBillingRecorder constructs the per-request recorder. Called once
// from handleChatCompletions before any logging fires. state is the
// forwardState pointer the sequence helpers will mutate; the recorder
// reads state.routingDone at write time to compute RoutingMs (matching
// the pre-refactor closure's live-capture semantics).
func (s *Server) newBillingRecorder(r *http.Request, state *forwardState, startedAt time.Time, requestID string) *billingRecorder {
	return &billingRecorder{
		server:    s,
		state:     state,
		req:       r,
		startedAt: startedAt,
		requestID: requestID,
	}
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
	promptTok, completionTok *int64,
	errMsg, errCode string,
	retried int,
	estimatedCompTokens *int64,
	faultFlag string,
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
	row := requestlog.Row{
		TSUtc:               b.startedAt,
		RequestID:           b.requestID,
		Model:               b.model,
		ProviderAssignedID:  providerAssignedID,
		PromptTokens:        promptTok,
		CompletionTokens:    completionTok,
		EstimatedCompTokens: estimatedCompTokens,
		LatencyMs:           float64(time.Since(b.startedAt).Milliseconds()),
		RoutingMs:           float64(b.state.routingDone.Sub(b.startedAt).Milliseconds()),
		Status:              status,
		Stream:              b.stream,
		BuyerIP:             buyerIP(b.req.RemoteAddr),
		Error:               sanitizeRequestLogText(errMsg),
		ErrorCode:           errCode,
		PrefHeader:          sanitizeRequestLogText(b.req.Header.Get("X-MacProvider-Pref")),
		ProviderHeader:      sanitizeRequestLogText(b.req.Header.Get("X-MacProvider-Provider")),
		Retried:             retried,
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
		billingInput := billing.HotPathInput{
			RequestID:           row.RequestID,
			AttemptN:            attemptN,
			ProviderAssignedID:  providerAssignedID,
			ProviderID:          stableProviderID,
			Model:               row.Model,
			Status:              status,
			Stream:              row.Stream,
			TSUtc:               row.TSUtc,
			PromptTokens:        promptTok,
			CompletionTokens:    completionTok,
			EstimatedCompTokens: estimatedCompTokens,
			ErrorCode:           errCode,
			FaultFlag:           faultFlag,
			ConfigSnapshotID:    billingSnapshotID,
			RateEntry:           billing.RateFor(billingCfg.RateCard, row.Model),
			MultiplierPPM:       billing.ParseMultiplierPPM(billingCfg.GlobalMultiplier),
			ProviderShareBps:    billing.ParseShareBps(billingCfg.ProviderShare),
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
		return nil
	}
	if err := s.reqLog.Insert(ctx, row); err != nil {
		s.log.Warn().Err(err).Str("request_id", b.requestID).Msg("request_log insert failed")
		return err
	}
	return nil
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
	_ = b.recordRow(providerAssignedID, "", status, promptTok, completionTok, errMsg, errCode, retried, nil, billing.FaultNone)
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
	return b.recordRow(provider.AssignedID, provider.ProviderID, status, promptTok, completionTok, errMsg, errCode, retried, nil, billing.FaultNone)
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
	return b.recordRow(provider.AssignedID, provider.ProviderID, status, promptTok, completionTok, errMsg, errCode, retried, estimatedCompTokens, billing.FaultNone)
}
