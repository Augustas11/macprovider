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

// Non-streaming settlement trailers (SPEC-022 R-5.6, R-12.8). A gateway that
// reads non-streaming settlement finality from trailers advertises it on the
// service-token-authenticated gateway-to-coordinator hop. Only then does the
// coordinator record a non-streaming success after its body write and send
// the finality tuple as trailers, authenticated by a MAC. Any other caller
// gets the pre-#1690 order: record before the write, finality in headers.
// An older gateway ignores trailers, so trailer-only finality would let it
// debit a quarantined, zero-settled or pending attempt locally.
const (
	// settlementTrailersCapabilityHeader sits in the X-MacProvider-Internal-*
	// namespace, so a buyer-port request carrying it without the gateway
	// service token is refused (hasInternalRoutingHeader).
	settlementTrailersCapabilityHeader = "X-MacProvider-Internal-Settlement-Trailers"
	// settlementFinalityMACHeader carries the hex HMAC-SHA256 over the
	// request binding and the finality tuple (settlementFinalityMAC).
	settlementFinalityMACHeader = "X-MacProvider-Settlement-Finality-Mac"
	settlementFinalityMACDomain = "macprovider-settlement-finality-trailers-v1"
	// settlementRecordFailedAfterDeliveryReason is the explicit hold sent when
	// the post-delivery record or receipt ingest fails.
	settlementRecordFailedAfterDeliveryReason = "settlement_record_failed_after_delivery"
)

// gatewayNegotiatedSettlementTrailers reports whether the gateway, holding
// the service token, advertised trailer finality for this request.
func (s *Server) gatewayNegotiatedSettlementTrailers(h http.Header) bool {
	return strings.TrimSpace(h.Get(settlementTrailersCapabilityHeader)) == "1" &&
		auth.GatewayInternalBearerMatches(h, s.gatewayServiceToken) != auth.BearerKindNone
}

// declareNonStreamingSettlementTrailers declares the finality tuple and its
// MAC as trailers for a negotiated non-streaming attempt that has a route
// snapshot. From here setInternalSettlementOutcomeHeaders also sets the MAC.
func declareNonStreamingSettlementTrailers(dst http.Header, rec *billingRecorder) {
	if rec == nil || rec.accountID == "" || !rec.settlementTrailersNegotiated {
		return
	}
	declareInternalSettlementOutcomeTrailers(dst, rec)
	dst.Add("Trailer", settlementFinalityMACHeader)
	rec.settlementFinalityMACActive = true
}

// setSettlementFinalityMAC signs the finality tuple now in dst.
func setSettlementFinalityMAC(dst http.Header, rec *billingRecorder) {
	if rec == nil || !rec.settlementFinalityMACActive || rec.server == nil || rec.server.gatewayServiceToken == "" || rec.req == nil {
		return
	}
	values := make([]string, 0, len(settlementOutcomeHeaderNames))
	for _, name := range settlementOutcomeHeaderNames {
		values = append(values, dst.Get(name))
	}
	dst.Set(settlementFinalityMACHeader, settlementFinalityMAC(rec.server.gatewayServiceToken,
		rec.req.Header.Get("X-MacProvider-Account"), rec.req.Header.Get("X-Request-ID"), values))
}

// settlementFinalityMAC is hex HMAC-SHA256, keyed by the gateway service
// token, over a domain tag, the account and request id the gateway sent, and
// the finality values in settlementOutcomeHeaderNames order. Every field is
// trimmed and length-prefixed. The gateway computes the same function
// (phase5-gateway settlementFinalityMAC); a shared test vector pins both.
func settlementFinalityMAC(key, accountID, requestID string, values []string) string {
	mac := hmac.New(sha256.New, []byte(key))
	write := func(field string) {
		field = strings.TrimSpace(field)
		mac.Write([]byte(strconv.Itoa(len(field))))
		mac.Write([]byte{':'})
		mac.Write([]byte(field))
	}
	write(settlementFinalityMACDomain)
	write(accountID)
	write(requestID)
	for _, value := range values {
		write(value)
	}
	return hex.EncodeToString(mac.Sum(nil))
}

// setSettlementRecordFailedHold sends the explicit pending tuple when the
// post-delivery record or receipt ingest failed: the gateway holds and the
// reconciler resolves the attempt from durable state. In observe mode the
// gateway accounts locally, as it does for every observe-mode attempt.
func setSettlementRecordFailedHold(dst http.Header, rec *billingRecorder) {
	if rec == nil || !rec.settlementFinalityMACActive {
		return
	}
	mode, version := rec.settlementPolicyForLedger()
	if mode == "legacy" {
		mode, version = billing.RouteSnapshotModeEnforce, billing.RouteSnapshotPolicyVersion
	}
	dst.Del(settlementPendingUntilHeader)
	setInternalSettlementOutcomeHeaders(dst, rec, billing.SettlementReceiptState{
		SettlementOutcome:          "pending",
		Reason:                     settlementRecordFailedAfterDeliveryReason,
		RouteSnapshotMode:          mode,
		RouteSnapshotPolicyVersion: version,
	})
}
