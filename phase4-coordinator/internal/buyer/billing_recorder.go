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
	accountID               string
	authenticatedAccount    requestlog.AuthenticatedAccount
	hasAuthenticatedAccount bool
	promptTokenUpperBound   *int64

	// attemptN is the running per-provider-attempt counter. Pre-refactor
	// this was billingAttemptN, incremented via deferred closure on
	// every successful provider-bound record.
	attemptN int
	// providerCredited is the LEDGER-EXACT "a provider has been billably
	// credited in this request" signal that drives the item-18 no-charge
	// marker (see noPriorDispatchResponseWriter). It is set true INSIDE
	// recordRow at the exact point a provider-bound billing/settlement row
	// is durably persisted with a billable status (providerAssignedID != ""
	// AND status != 503) — never on a 503/no_provider/queue-full row (those
	// bypass billing at recordRow's `status != http.StatusServiceUnavailable`
	// gate) and never on a buyer/routing row (providerAssignedID == ""). It
	// is monotonic within a request: once a credit lands it stays true, so a
	// later terminal write (e.g. failover-exhaustion 503, or a retried
	// route_snapshot_failed observed by the gateway) is correctly treated as
	// following a billed attempt. This replaces the R5 attemptN==0 marker
	// source, which over-counted (incremented on non-billed 503 rows) and
	// under-covered (incremented AFTER the terminal write on WS paths).
	providerCredited bool
	// dispatchedThisAttempt is the per-attempt companion to providerCredited.
	// It answers "did the CURRENT attempt dispatch to a provider before it
	// produced its terminal response?" — needed because a single attempt's
	// own billing row is recorded AFTER its terminal HTTP write on the WS
	// paths (handleNonRetryableTerminal runs post-write), so providerCredited
	// is not yet set when the marker is stamped. It is reset to false at the
	// top of every forwardWithFailover loop iteration (beginDispatchAttempt)
	// and set true immediately before the provider relay (markProviderDispatched).
	// The marker wrapper combines it with the write status: a dispatched
	// attempt that writes a non-503 terminal WILL be billed (recordRow bills
	// iff status != 503), so it must not carry the no-charge marker.
	dispatchedThisAttempt bool
	// routeSnapshotAttemptN is the pre-dispatch provider-dispatch
	// ordinal used by settlement_route_snapshots. It advances at the
	// dispatch boundary, not at request_log write time, so streaming
	// failover-before-first-chunk and HTTP/WS retries share one
	// monotonic attempt identity surface for later receipt settlement.
	routeSnapshotAttemptN int
	// terminal is the per-request single-terminal-wins arbiter (#766).
	// OBSERVE-ONLY: it latches the buyer-visible terminal at the first
	// committed write and records every credited row, then asserts the two
	// agree. It NEVER gates a billing row. May be nil on recorders built by
	// direct struct construction in tests — every call site nil-guards.
	terminal                *requestTerminal
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
func (s *Server) newBillingRecorder(r *http.Request, state *forwardState, startedAt time.Time, requestID, externalRequestID, accountID string, authenticatedAccount requestlog.AuthenticatedAccount, hasAuthenticatedAccount bool) *billingRecorder {
	return &billingRecorder{
		server:                  s,
		state:                   state,
		req:                     r,
		startedAt:               startedAt,
		requestID:               requestID,
		externalRequestID:       externalRequestID,
		accountID:               accountID,
		authenticatedAccount:    authenticatedAccount,
		hasAuthenticatedAccount: hasAuthenticatedAccount,
		terminal:                newRequestTerminal(&s.log, requestID, accountID),
	}
}

// claimBuyerTerminal latches the buyer-visible terminal status. Called from
// noPriorDispatchResponseWriter.mark at the first committed write (#766).
func (b *billingRecorder) claimBuyerTerminal(code int) {
	if b == nil || b.terminal == nil {
		return
	}
	b.terminal.claimBuyer(code)
}

// noteLateBuyerTerminal records a buyer write that arrived after the terminal
// was latched. Telemetry only — net/http already discarded it.
func (b *billingRecorder) noteLateBuyerTerminal(code int) {
	if b == nil || b.terminal == nil {
		return
	}
	b.terminal.noteLateBuyerWrite(code)
}

// noteBillableRow publishes a durably-credited provider row to the arbiter.
func (b *billingRecorder) noteBillableRow(status, attemptN int, faultFlag string) {
	if b == nil || b.terminal == nil {
		return
	}
	b.terminal.noteBillableRow(status, attemptN, faultFlag)
}

// evaluateTerminalAgreement runs once per request, deferred from
// handleChatCompletions so it observes the WS paths' post-write billing rows.
// Observe-only: it emits warn logs + bumps package counters, and never changes
// the response or the ledger.
func (b *billingRecorder) evaluateTerminalAgreement() {
	if b == nil || b.terminal == nil {
		return
	}
	billingEnabled := false
	if b.server != nil {
		store, _, _ := b.server.billingState()
		billingEnabled = store != nil && b.server.reqLog != nil
	}
	b.terminal.evaluateEndOfRequest(billingEnabled)
	if b.server != nil && b.server.terminalObserver != nil {
		b.server.terminalObserver(b.terminal)
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

// beginDispatchAttempt clears the per-attempt dispatched flag at the start
// of every forwardWithFailover iteration. providerCredited is deliberately
// NOT reset — it accumulates billed credits across the whole request.
func (b *billingRecorder) beginDispatchAttempt() {
	b.dispatchedThisAttempt = false
}

// markProviderDispatched records that the current attempt is about to relay
// to a selected provider. Called immediately before the provider relay in
// each transport's dispatch callback, i.e. AFTER a successful route-snapshot
// write — so a pre-dispatch failure (route_snapshot_failed) leaves the flag
// false and the response carries the item-18 no-charge marker.
func (b *billingRecorder) markProviderDispatched() {
	b.dispatchedThisAttempt = true
	// Monotonic twin for the arbiter's end-of-request "served but unpaid"
	// predicate — dispatchedThisAttempt resets above on every failover
	// iteration, so it cannot answer "did this REQUEST ever dispatch?".
	if b.terminal != nil {
		b.terminal.noteDispatch()
	}
}

// setRequestID updates the requestID field after idempotency-key
// reservation may have rewritten it. Pre-refactor the closure read
// `originalRequestID` from outer scope; the setter preserves the same
// post-idempotency-rewrite semantics.
func (b *billingRecorder) setRequestID(requestID string) {
	b.requestID = requestID
	if b.terminal != nil {
		b.terminal.setRequestID(requestID)
	}
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
	var ttftMs, decodeMs *float64
	if providerAssignedID != "" {
		phaseTiming := b.state.phaseTiming.snapshot()
		if phaseTiming.matchesProviderAssignedID(providerAssignedID) {
			ttftMs = phaseTiming.requestLogTTFTMs()
			decodeMs = phaseTiming.requestLogDecodeMs()
		}
	}
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
		QueueWaitMs:           float64(b.state.queueWait.Milliseconds()),
		TTFTMs:                ttftMs,
		DecodeMs:              decodeMs,
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
	// FR-CAN23 observed-serving residual: stamp successful buyer relays whenever
	// we have a stable provider identity (independent of billing store wiring).
	if status >= 200 && status < 300 && s.pool != nil {
		stampID := providerID
		if stampID == "" && providerAssignedID != "" {
			for _, p := range s.pool.Snapshot() {
				if p.AssignedID == providerAssignedID {
					stampID = p.ProviderID
					break
				}
			}
		}
		if stampID != "" {
			s.pool.NoteBuyerSuccess(stampID, time.Now().UTC())
		}
	}
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
		var err error
		if b.hasAuthenticatedAccount {
			err = billingStore.WriteHotPathForAccount(ctx, s.reqLogStore, b.authenticatedAccount, row, billingInput)
		} else {
			err = billingStore.WriteHotPath(ctx, s.reqLogStore, row, billingInput)
		}
		if err != nil {
			s.log.Warn().Err(err).Str("request_id", b.requestID).Msg("billing hot-path insert failed")
			fallbackCtx, fallbackCancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
			defer fallbackCancel()
			var fallbackErr error
			if b.hasAuthenticatedAccount {
				fallbackErr = billingStore.WriteRequestLogWithIdentityForAccount(fallbackCtx, s.reqLogStore, b.authenticatedAccount, row, billingInput)
			} else {
				fallbackErr = billingStore.WriteRequestLogWithIdentity(fallbackCtx, s.reqLogStore, row, billingInput)
			}
			if fallbackErr != nil {
				s.log.Warn().Err(fallbackErr).Str("request_id", b.requestID).Msg("request_log identity fallback insert failed")
				return fmt.Errorf("billing hot-path insert failed: %w; fallback failed: %v", err, fallbackErr)
			}
		}
		// A provider-bound, billable (status != 503) row is now durably
		// persisted — the provider has been credited. Mark BEFORE the
		// settlement-output bookkeeping so a settlement-persist hiccup still
		// leaves the ledger-exact "credited" signal set (conservative vs
		// under-charge: the gateway settles rather than erasing real credit).
		b.providerCredited = true
		// #766 observe-only: publish the credited row to the request arbiter
		// so the buyer terminal / ledger agreement is checkable. Placed with
		// providerCredited (i.e. BEFORE the settlement-output bookkeeping) so
		// the arbiter sees exactly what the ledger credited, including when a
		// settlement-persist failure later turns the buyer terminal into a 500.
		b.noteBillableRow(status, attemptN, faultFlag)
		if err := b.recordSettlementAttemptOutput(ctx, billingStore, billingInput, settlementOutput); err != nil {
			return err
		}
		return nil
	}
	var err error
	if b.hasAuthenticatedAccount {
		err = s.reqLog.InsertForAccount(ctx, b.authenticatedAccount, row)
	} else {
		err = s.reqLog.Insert(ctx, row)
	}
	if err != nil {
		s.log.Warn().Err(err).Str("request_id", b.requestID).Msg("request_log insert failed")
		return err
	}
	if billingStore != nil && providerAssignedID != "" && status != http.StatusServiceUnavailable {
		// Same ledger-exact credit signal as the hot-path branch: a
		// provider-bound billable row has persisted (reqLog.Insert above
		// succeeded) and settlement is being recorded now.
		b.providerCredited = true
		// #766 observe-only, same contract as the hot-path site above.
		b.noteBillableRow(status, attemptN, faultFlag)
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
	// The settlement evidence tuple must mirror what an honest provider signs in
	// its receipt, because tupleUsageMatchesLedger requires the coordinator's
	// ExpectedUsage to EXACTLY equal the provider receipt's 5 usage fields for
	// EVERY terminal state (settlement_verifier.go), and SPEC-015 (receipts
	// terminal-state table) fixes billable_input_tokens == observed_input_tokens
	// for the fully consumed prompt (== for normal_done; the delivered prefix on
	// positive-money partial/error states also bills the whole input).
	//
	// The prompt-token upper bound is a byte-heuristic (len(body)/4, see
	// estimateTokens) anti-inflation cap for the buyer LEDGER money amount
	// (billing.boundProviderReportedPromptTokens). It MUST NOT be applied to the
	// settlement evidence here: the provider cannot reproduce the coordinator's
	// len(body)/4 value, so capping billable_input below observed_input produces a
	// tuple no honest receipt can match -> usage_mismatch -> quarantine of EVERY
	// settlement for models whose chat-template tokenization exceeds len(body)/4
	// (Llama-3.2/3.1, gpt-oss). This is evidence-only and changes no credited
	// amount: verified settlement credit sync re-bounds billable to the ledger
	// prompt (syncVerifiedReceiptLedgerCreditForAttemptTx) and the ledger prompt is
	// itself independently capped in the hot path.
	//
	// Byte-estimated usage is not settlement-capable (UsageCrossChecked is false),
	// and non-normal_done zero-prefix attempts bill nothing: both zero billable
	// below, which is what an honest provider also reports for those cases.
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
