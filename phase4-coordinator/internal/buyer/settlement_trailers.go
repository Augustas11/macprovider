package buyer

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
)

// Negotiated settlement finality (SPEC-022 R-5.6, R-12.8). A gateway that
// reads MAC'd settlement finality advertises it on the
// service-token-authenticated gateway-to-coordinator hop. Only then does the
// coordinator record a non-streaming success after its body write and sign
// every finality tuple it sends. Any other caller gets the pre-#1690 order:
// record before the write, unsigned finality in headers. An older gateway
// ignores trailers, so trailer-only finality would let it debit a
// quarantined, zero-settled or pending attempt locally.
//
// For a negotiating gateway every 200 carries signed finality, so the
// gateway's coordinator.require_settlement_trailers pin holds only a
// stripped declaration or MAC:
//   - non-streaming: declared trailers, always, with the attempt's tuple, a
//     signed legacy tuple when there is none (no route snapshot, observe
//     mode, a keyless provider), or, when post-delivery evidence failed, a
//     signed closed refund (enforce) or the signed legacy tuple (otherwise);
//   - streaming with a route snapshot: declared trailers with the tuple;
//   - streaming without one: a signed legacy tuple in the headers, decided
//     before the first byte, so a stream the gateway ends locally still
//     settles as before.
const (
	// settlementTrailersCapabilityHeader sits in the X-MacProvider-Internal-*
	// namespace, so a buyer-port request carrying it without the gateway
	// service token is refused (hasInternalRoutingHeader).
	settlementTrailersCapabilityHeader = "X-MacProvider-Internal-Settlement-Trailers"
	// settlementFinalityMACHeader carries the hex HMAC-SHA256 over the
	// request binding and the finality tuple (settlementFinalityMAC).
	settlementFinalityMACHeader = "X-MacProvider-Settlement-Finality-Mac"
	settlementFinalityMACDomain = "macprovider-settlement-finality-trailers-v1"
	// settlementLegacyMode marks a tuple the gateway settles with local
	// (pre-SPEC-022) accounting, exactly as a response without finality.
	settlementLegacyMode = "legacy"
	// settlementRecordFailedAfterDeliveryReason names a post-delivery record
	// or receipt ingest failure (setSettlementEvidenceFailedFinality).
	settlementRecordFailedAfterDeliveryReason = "settlement_record_failed_after_delivery"
	// settlementOutputMissingAfterCreditReason is the sibling reason when the
	// credit row committed but the settlement evidence write failed
	// transiently (marked missing, or the mark itself failed): no finality
	// can ever verify it.
	settlementOutputMissingAfterCreditReason = "settlement_output_missing_after_credit"
	// settlementFinalityUnsetReason names a negotiated 200, streaming or not,
	// that reached the end of the handler without a tuple
	// (finalizeNegotiatedSettlementFinality).
	settlementFinalityUnsetReason = "settlement_finality_unset_after_delivery"
	internalRequestIDHeader       = "X-MacProvider-Internal-Request-ID"
)

// gatewayNegotiatedSettlementTrailers reports whether the gateway, holding
// the service token, advertised signed finality for this request.
func (s *Server) gatewayNegotiatedSettlementTrailers(h http.Header) bool {
	return strings.TrimSpace(h.Get(settlementTrailersCapabilityHeader)) == "1" &&
		auth.GatewayInternalBearerMatches(h, s.gatewayServiceToken) != auth.BearerKindNone
}

func negotiatedSettlementFinality(rec *billingRecorder) bool {
	return rec != nil && rec.accountID != "" && rec.settlementTrailersNegotiated
}

// clearNegotiatedSettlementFinality drops a previous attempt's declaration
// or signed header tuple, so a retry on another provider starts clean.
func clearNegotiatedSettlementFinality(dst http.Header, rec *billingRecorder) {
	names := map[string]bool{strings.ToLower(settlementFinalityMACHeader): true}
	for _, name := range settlementOutcomeHeaderNames {
		names[strings.ToLower(name)] = true
	}
	var kept []string
	for _, value := range dst.Values("Trailer") {
		for _, name := range strings.Split(value, ",") {
			if name = strings.TrimSpace(name); name != "" && !names[strings.ToLower(name)] {
				kept = append(kept, name)
			}
		}
	}
	dst.Del("Trailer")
	for _, name := range kept {
		dst.Add("Trailer", name)
	}
	for _, name := range settlementOutcomeHeaderNames {
		dst.Del(name)
	}
	dst.Del(settlementFinalityMACHeader)
	rec.settlementFinalityMACActive = false
}

// declareNonStreamingSettlementTrailers declares the finality tuple and its
// MAC as trailers for a negotiated attempt. From here
// setInternalSettlementOutcomeHeaders also sets the MAC.
func declareNonStreamingSettlementTrailers(dst http.Header, rec *billingRecorder) {
	if !negotiatedSettlementFinality(rec) {
		return
	}
	clearNegotiatedSettlementFinality(dst, rec)
	declareInternalSettlementOutcomeTrailers(dst, rec)
	dst.Add("Trailer", settlementFinalityMACHeader)
	rec.settlementFinalityMACActive = true
}

// prepareStreamingSettlementFinality is the streaming counterpart, run
// before the first byte: signed trailers when the attempt has a route
// snapshot, else a signed legacy tuple in the headers. It reports whether it
// handled the attempt (a negotiating gateway).
func prepareStreamingSettlementFinality(dst http.Header, rec *billingRecorder, hasRouteSnapshot bool) bool {
	if !negotiatedSettlementFinality(rec) {
		return false
	}
	if hasRouteSnapshot {
		declareNonStreamingSettlementTrailers(dst, rec)
		return true
	}
	clearNegotiatedSettlementFinality(dst, rec)
	dst.Set(settlementModeHeader, settlementLegacyMode)
	signSettlementFinality(dst, rec)
	return true
}

// setSettlementFinalityMAC signs the finality tuple now in dst when this
// response declared MAC'd trailers.
func setSettlementFinalityMAC(dst http.Header, rec *billingRecorder) {
	if rec == nil || !rec.settlementFinalityMACActive {
		return
	}
	signSettlementFinality(dst, rec)
}

func signSettlementFinality(dst http.Header, rec *billingRecorder) {
	if rec == nil || rec.server == nil || rec.req == nil {
		return
	}
	key := strings.TrimSpace(rec.server.gatewayServiceToken)
	if key == "" {
		return
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, dst.Get(name))
	}
	dst.Set(settlementFinalityMACHeader, settlementFinalityMAC(key,
		rec.req.Header.Get("X-MacProvider-Account"), rec.req.Header.Get("X-Request-ID"),
		dst.Get(internalRequestIDHeader), values))
}

// settlementFinalityMAC is hex HMAC-SHA256, keyed by the trimmed gateway
// service token, over a domain tag, the account and request id the gateway
// sent, the coordinator's X-MacProvider-Internal-Request-ID, and the
// finality values in settlementOutcomeHeaderNames order. Every field is
// trimmed and length-prefixed. The gateway computes the same function
// (phase5-gateway settlementFinalityMAC); a shared test vector pins both.
func settlementFinalityMAC(key, accountID, requestID, internalRequestID string, values []string) string {
	mac := hmac.New(sha256.New, []byte(strings.TrimSpace(key)))
	write := func(field string) {
		field = strings.TrimSpace(field)
		mac.Write([]byte(strconv.Itoa(len(field))))
		mac.Write([]byte{':'})
		mac.Write([]byte(field))
	}
	write(settlementFinalityMACDomain)
	write(accountID)
	write(requestID)
	write(internalRequestID)
	for _, value := range values {
		write(value)
	}
	return hex.EncodeToString(mac.Sum(nil))
}

// setNonStreamingSettlementFinality sets the negotiated non-streaming
// tuple after a successful post-delivery record: the attempt's receipt
// state, or a signed legacy tuple when it has none, which the gateway
// settles as it settles a response without finality. A no-op in the
// record-before-write order.
func setNonStreamingSettlementFinality(dst http.Header, rec *billingRecorder, state billing.SettlementReceiptState, hasState bool) {
	if hasState {
		setInternalSettlementOutcomeHeaders(dst, rec, state)
		return
	}
	if rec == nil || !rec.settlementFinalityMACActive {
		return
	}
	if rec.settlementOutputMissingAfterCredit {
		// The credit committed but its settlement evidence did not, so no
		// finality can ever verify the attempt.
		setSettlementEvidenceFailedFinality(dst, rec, settlementOutputMissingAfterCreditReason)
		return
	}
	setSignedLegacyTuple(dst, rec)
}

func setSignedLegacyTuple(dst http.Header, rec *billingRecorder) {
	for _, name := range settlementOutcomeHeaderNames {
		dst.Del(name)
	}
	dst.Set(settlementModeHeader, settlementLegacyMode)
	signSettlementFinality(dst, rec)
}

// setSettlementRecordFailedFinality handles a post-delivery record or
// receipt ingest failure (setSettlementEvidenceFailedFinality).
func setSettlementRecordFailedFinality(dst http.Header, rec *billingRecorder) {
	setSettlementEvidenceFailedFinality(dst, rec, settlementRecordFailedAfterDeliveryReason)
}

// finalizeNegotiatedSettlementFinality runs as the chat handler returns,
// before net/http writes the trailers. A negotiated response that declared
// signed trailers but set no tuple would otherwise hold at the gateway with
// no coordinator finality to find (a 404 hold that never ends). Every
// expected path sets a tuple (a pending verdict included, which the
// reconciler closes), so a negotiated response, streaming or not, that
// reaches here unset takes the evidence-failure rule.
func finalizeNegotiatedSettlementFinality(dst http.Header, rec *billingRecorder) {
	if rec == nil || !rec.settlementFinalityMACActive {
		return
	}
	// Only a 200 carries settleable finality: the gateway settles a non-200
	// from its headers and never reads its trailers, and a request whose
	// earlier attempt billed a 502 must not gain a refund tuple here.
	if rec.terminal != nil {
		if claim, ok := rec.terminal.claimedBuyer(); ok && claim.Status != http.StatusOK {
			return
		}
	}
	for _, name := range settlementOutcomeHeaderNames {
		if dst.Get(name) != "" {
			return
		}
	}
	if rec.settlementOutputMissingAfterCredit {
		setSettlementEvidenceFailedFinality(dst, rec, settlementOutputMissingAfterCreditReason)
		return
	}
	setSettlementEvidenceFailedFinality(dst, rec, settlementFinalityUnsetReason)
}

// setSettlementEvidenceFailedFinality settles an attempt whose buyer
// response was delivered but whose settlement evidence failed, so buyer and
// provider agree without an operator:
//   - enforce route mode (the attempt's snapshot, or the enforce policy when
//     store pressure skipped the snapshot): an enforce credit is payable only
//     once a verified verdict and attempt output exist
//     (spec022_payable_request_credits); the credit is quarantined (never
//     one already verified), which the finality lookup then reports as
//     closed quarantined, and the buyer gets a signed closed refund, so
//     neither side is paid. If the quarantine cannot land the refund is sent
//     only when the credit is provably unpayable
//     (decideEnforceEvidenceFailure); a verified attempt gets its verified
//     finality.
//   - observe mode, or no snapshot and no enforce policy: the credit stays
//     payable as every observe credit is, so the buyer gets the signed
//     legacy tuple and is debited locally, the #1675 behaviour. Both sides
//     are paid.
//
// Either way the error log names the attempt for operator review.
func setSettlementEvidenceFailedFinality(dst http.Header, rec *billingRecorder, reason string) {
	if rec == nil || !rec.settlementFinalityMACActive {
		return
	}
	mode, _ := rec.settlementPolicyForLedger()
	if mode != billing.RouteSnapshotModeEnforce {
		logSettlementEvidenceFailure(rec, reason, mode, "legacy")
		setSignedLegacyTuple(dst, rec)
		return
	}
	action := enforceEvidenceFailureAction(rec, reason)
	logSettlementEvidenceFailure(rec, reason, mode, action.String())
	state := billing.SettlementReceiptState{
		RouteSnapshotMode:          billing.RouteSnapshotModeEnforce,
		RouteSnapshotPolicyVersion: billing.RouteSnapshotPolicyVersion,
	}
	switch action {
	case evidenceFailureVerified:
		// The attempt already verified: its credit is payable, so the
		// buyer settles through the verified finality (the reconciler
		// debits it from the coordinator lookup), not a refund.
		state.SettlementOutcome, state.ReceiptResult, state.Reason, state.Closed = billing.SettlementOutcomeVerified, billing.SettlementReceiptResultValid, "verified_settlement", true
	case evidenceFailurePending:
		// Payability is not yet decided: hold for the reconciler, whose
		// lookup reaches a terminal verdict once the attempt output's
		// pending deadline passes.
		state.SettlementOutcome, state.ReceiptResult, state.Reason = billing.SettlementOutcomePending, billing.SettlementReceiptResultInconclusive, reason
	default:
		state.SettlementOutcome, state.ReceiptResult, state.Reason, state.Closed = billing.SettlementOutcomeQuarantined, billing.SettlementReceiptResultInconclusive, reason, true
	}
	dst.Del(settlementPendingUntilHeader)
	setInternalSettlementOutcomeHeaders(dst, rec, state)
}

type evidenceFailureAction int

const (
	evidenceFailureRefund evidenceFailureAction = iota
	evidenceFailureVerified
	evidenceFailurePending
)

func (a evidenceFailureAction) String() string {
	switch a {
	case evidenceFailureVerified:
		return "verified"
	case evidenceFailurePending:
		return "pending"
	default:
		return "refund"
	}
}

const undeliveredQuarantineAttempts = 3

// enforceEvidenceFailureAction quarantines the delivered attempt's credit
// (bounded retries) and decides the buyer's finality from what is durably
// true, so the refund never outruns the provider side.
func enforceEvidenceFailureAction(rec *billingRecorder, reason string) evidenceFailureAction {
	if !rec.hasLastProviderAttempt || rec.server == nil {
		// No provider row was recorded for the delivered attempt: there is
		// no credit to pay.
		return evidenceFailureRefund
	}
	store, _, _ := rec.server.billingState()
	if store == nil {
		return evidenceFailureRefund
	}
	scope := accountScopeForSettlement(rec.accountID)
	var result billing.UndeliveredQuarantineResult
	var qErr error
	for attempt := 0; attempt < undeliveredQuarantineAttempts; attempt++ {
		ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
		if quarantineUndeliveredErrForTest != nil {
			result, qErr = billing.UndeliveredQuarantineNoCredit, quarantineUndeliveredErrForTest
		} else {
			result, qErr = store.QuarantineUndeliveredSettlementCredit(ctx, scope, rec.requestID, rec.lastProviderAttemptN, rec.lastProviderID, reason)
		}
		cancel()
		if qErr == nil {
			break
		}
		rec.server.log.Error().Err(qErr).Int("attempt", attempt+1).Str("request_id", rec.requestID).Msg("could not quarantine provider credit after settlement evidence failure")
	}
	var hasOutput, verified bool
	var evErr error
	if qErr != nil {
		ctx, cancel := context.WithTimeout(context.Background(), requestLogWriteTimeout)
		hasOutput, verified, evErr = store.SettlementAttemptEvidence(ctx, scope, rec.requestID, rec.lastProviderID)
		cancel()
	}
	return decideEnforceEvidenceFailure(result, qErr, hasOutput, verified, evErr)
}

// decideEnforceEvidenceFailure is the enforce-mode decision table:
//   - quarantine landed, or found no credit: refund (the credit is excluded
//     from payment, or there is none);
//   - the attempt already has a closed verified verdict: verified finality;
//   - quarantine failed but the attempt has no attempt output and no
//     verified verdict: refund. The credit can never become payable, because
//     enforce payability needs both, only the in-request recorder writes an
//     attempt output, and none of these failure paths queues receipt
//     recovery, the only other writer of a verdict;
//   - anything else (an output exists, or the evidence read failed): an
//     open pending tuple the reconciler resolves.
func decideEnforceEvidenceFailure(result billing.UndeliveredQuarantineResult, qErr error, hasOutput, verified bool, evErr error) evidenceFailureAction {
	if qErr == nil {
		if result == billing.UndeliveredQuarantineVerified {
			return evidenceFailureVerified
		}
		return evidenceFailureRefund
	}
	if evErr != nil {
		return evidenceFailurePending
	}
	if verified {
		return evidenceFailureVerified
	}
	if !hasOutput {
		return evidenceFailureRefund
	}
	return evidenceFailurePending
}

func logSettlementEvidenceFailure(rec *billingRecorder, reason, mode, outcome string) {
	if rec.server == nil {
		return
	}
	rec.server.log.Error().
		Str("event", reason).
		Str("request_id", rec.requestID).
		Str("account_id", rec.accountID).
		Str("settlement_mode", mode).
		Str("buyer_finality", outcome).
		Msg("post-delivery settlement evidence failed")
}
