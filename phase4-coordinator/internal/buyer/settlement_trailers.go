package buyer

import (
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
//     mode, a keyless provider), or a signed closed refund tuple when the
//     post-delivery record failed;
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
	// settlementRecordFailedAfterDeliveryReason is the reason on the closed
	// refund tuple sent when the post-delivery record or receipt ingest
	// fails.
	settlementRecordFailedAfterDeliveryReason = "settlement_record_failed_after_delivery"
	internalRequestIDHeader                   = "X-MacProvider-Internal-Request-ID"
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
	for _, name := range settlementOutcomeHeaderNames {
		dst.Del(name)
	}
	dst.Set(settlementModeHeader, settlementLegacyMode)
	signSettlementFinality(dst, rec)
}

// setSettlementRecordFailedRefund sends a signed, closed refund tuple when
// the post-delivery record or receipt ingest failed. The buyer already holds
// the body, but no durable row backs a charge and there is no finality for a
// reconciler to find, so the gateway releases the reservation at once: the
// buyer is not charged, as with the pre-#1690 500 request_log_failed. Any
// provider credit the failed write did land stays for operator review; the
// error log line is the operator's signal.
func setSettlementRecordFailedRefund(dst http.Header, rec *billingRecorder) {
	if rec == nil || !rec.settlementFinalityMACActive {
		return
	}
	if rec.server != nil {
		rec.server.log.Error().
			Str("event", "settlement_record_failed_after_delivery").
			Str("request_id", rec.requestID).
			Str("account_id", rec.accountID).
			Msg("post-delivery settlement record failed; buyer reservation released, review provider credit")
	}
	dst.Del(settlementPendingUntilHeader)
	setInternalSettlementOutcomeHeaders(dst, rec, billing.SettlementReceiptState{
		SettlementOutcome:          billing.SettlementOutcomeQuarantined,
		ReceiptResult:              billing.SettlementReceiptResultInconclusive,
		Reason:                     settlementRecordFailedAfterDeliveryReason,
		Closed:                     true,
		RouteSnapshotMode:          billing.RouteSnapshotModeEnforce,
		RouteSnapshotPolicyVersion: billing.RouteSnapshotPolicyVersion,
	})
}
