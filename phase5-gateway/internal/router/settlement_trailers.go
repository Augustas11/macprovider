package router

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
)

// Non-streaming settlement trailers (SPEC-022 R-5.6, R-12.8). The gateway
// advertises on the service-token-authenticated coordinator hop that it reads
// non-streaming settlement finality from trailers. A coordinator that
// negotiates records the attempt after its body write and sends the finality
// tuple as declared trailers with a MAC; an older coordinator ignores the
// header and keeps header finality, which this gateway still reads.
const (
	// settlementTrailersCapabilityHeader is in the coordinator's
	// X-MacProvider-Internal-* namespace: honored only with the service
	// token. copyForwardHeaders never forwards a buyer-supplied copy.
	settlementTrailersCapabilityHeader = "X-MacProvider-Internal-Settlement-Trailers"
	settlementFinalityMACHeader        = "X-MacProvider-Settlement-Finality-Mac"
	settlementFinalityMACDomain        = "macprovider-settlement-finality-trailers-v1"
	missingSettlementFinalityTrailer   = "missing_settlement_finality_trailer"
)

// settlementFinalityMAC is hex HMAC-SHA256, keyed by the coordinator service
// token, over a domain tag, the account and request id this gateway sent, and
// the finality values in the coordinator's settlementOutcomeHeaderNames order.
// Every field is trimmed and length-prefixed. It must stay byte-identical to
// phase4-coordinator settlementFinalityMAC; a shared test vector pins both.
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

// settlementFinalityMACValues are the finality values in MAC order.
func settlementFinalityMACValues(h http.Header) []string {
	return []string{
		h.Get(settlementOutcomeHeader),
		h.Get(settlementReceiptResultHeader),
		h.Get(settlementReasonHeader),
		h.Get(settlementClosedHeader),
		h.Get(settlementModeHeader),
		h.Get(settlementPolicyVersionHeader),
		h.Get(settlementPendingUntilHeader),
	}
}

// coordinatorNonStreamingSettlementFinality reads a non-streaming 200's
// finality after its body was read. A coordinator that declared finality
// trailers recorded the attempt after the write: its finality is the
// trailers alone, and only with a valid MAC. Missing values, a missing MAC or
// a bad MAC hold as missing_settlement_finality_trailer, never a local debit.
// Without a declaration (an older coordinator, or no route snapshot) the
// headers stand as before.
func coordinatorNonStreamingSettlementFinality(resp *http.Response, key, accountID, requestID string) coordinatorSettlementFinality {
	if resp == nil {
		return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
	}
	if !hasSettlementFinalityTrailerDeclaration(resp) {
		return coordinatorSettlementFinalityFromHeaders(resp.Header)
	}
	missing := coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: missingSettlementFinalityTrailer}
	if !hasAnySettlementFinalityHeader(resp.Trailer) {
		return missing
	}
	got := strings.TrimSpace(resp.Trailer.Get(settlementFinalityMACHeader))
	want := settlementFinalityMAC(key, accountID, requestID, settlementFinalityMACValues(resp.Trailer))
	if key == "" || got == "" || !hmac.Equal([]byte(got), []byte(want)) {
		slog.Warn("gateway held non-streaming settlement: finality trailer MAC missing or invalid",
			"request_id", requestID,
			"account_id", accountID,
			"mac_present", got != "",
		)
		return missing
	}
	return coordinatorSettlementFinalityFromHeaders(resp.Trailer)
}
