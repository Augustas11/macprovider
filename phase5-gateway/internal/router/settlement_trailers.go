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

// Negotiated settlement finality (SPEC-022 R-5.6, R-12.8). The gateway
// advertises on the service-token-authenticated coordinator hop that it reads
// signed finality. A coordinator that negotiates records a non-streaming
// attempt after its body write and signs every finality tuple it sends:
// declared trailers on a non-streaming 200 and on a stream with a route
// snapshot, a signed legacy header tuple on a stream without one. An older
// coordinator ignores the header and sends unsigned header finality (or
// unsigned trailers on a stream), which this gateway still reads unless the
// coordinator.require_settlement_trailers pin is on.
const (
	// settlementTrailersCapabilityHeader is in the coordinator's
	// X-MacProvider-Internal-* namespace: honored only with the service
	// token. copyForwardHeaders never forwards a buyer-supplied copy.
	settlementTrailersCapabilityHeader = "X-MacProvider-Internal-Settlement-Trailers"
	settlementFinalityMACHeader        = "X-MacProvider-Settlement-Finality-Mac"
	settlementFinalityMACDomain        = "macprovider-settlement-finality-trailers-v1"
	missingSettlementFinalityTrailer   = "missing_settlement_finality_trailer"
)

// settlementFinalityMAC is hex HMAC-SHA256, keyed by the trimmed coordinator
// service token, over a domain tag, the account and request id this gateway
// sent, the coordinator's X-MacProvider-Internal-Request-ID, and the
// finality values in the coordinator's settlementOutcomeHeaderNames order.
// Every field is trimmed and length-prefixed. It must stay byte-identical to
// phase4-coordinator settlementFinalityMAC; a shared test vector pins both.
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

// setCoordinatorChatContext stamps a gateway-to-coordinator chat request
// that can return a settleable 200 with the trusted context the finality MAC
// binds: the service-token bearer, the account and request id the gateway
// settles under (settlementFinalityBinding), and the signed-finality
// capability. Every chat builder goes through it, so none can forget the
// capability and have its 200s held under the pin
// (TestEveryCoordinatorChatBuilderNegotiatesSignedFinality).
func (s *Server) setCoordinatorChatContext(h http.Header, r *http.Request, accountID string) {
	bearer := s.cfg.Coordinator.UpstreamCoordinatorBearer()
	h.Set("Authorization", "Bearer "+bearer)
	h.Set("X-MacProvider-Account", accountID)
	h.Set("X-Request-ID", requestID(r))
	// The MAC key is the bearer, so advertise only when one is configured.
	if strings.TrimSpace(bearer) != "" {
		h.Set(settlementTrailersCapabilityHeader, "1")
	}
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

// settlementFinalityBinding is what a finality MAC is checked against.
type settlementFinalityBinding struct {
	key, accountID, requestID string
	// requireSigned is the coordinator.require_settlement_trailers pin.
	requireSigned bool
}

func (s *Server) settlementFinalityBinding(r *http.Request, subject usageSubject) settlementFinalityBinding {
	return settlementFinalityBinding{
		key:           strings.TrimSpace(s.cfg.Coordinator.UpstreamCoordinatorBearer()),
		accountID:     subject.AccountID,
		requestID:     requestID(r),
		requireSigned: s.cfg.Coordinator.RequireSettlementTrailers,
	}
}

// finalityMACValid checks the MAC carried in src over the tuple in src.
func finalityMACValid(resp *http.Response, src http.Header, b settlementFinalityBinding) bool {
	got := strings.TrimSpace(src.Get(settlementFinalityMACHeader))
	if b.key == "" || got == "" {
		return false
	}
	want := settlementFinalityMAC(b.key, b.accountID, b.requestID, resp.Header.Get(coordinatorInternalRequestIDHeader), settlementFinalityMACValues(src))
	return hmac.Equal([]byte(got), []byte(want))
}

// settlementFinalityMACDeclared reports whether the response declared the
// finality MAC trailer. On a real net/http client response the transport
// removes "Trailer" from resp.Header and instead pre-populates resp.Trailer
// with the declared keys (nil values until EOF), so both are checked, as
// hasSettlementFinalityTrailerDeclaration does.
func settlementFinalityMACDeclared(resp *http.Response) bool {
	for name := range resp.Trailer {
		if strings.EqualFold(strings.TrimSpace(name), settlementFinalityMACHeader) {
			return true
		}
	}
	for _, value := range resp.Header.Values("Trailer") {
		for _, name := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(name), settlementFinalityMACHeader) {
				return true
			}
		}
	}
	return false
}

func missingSettlementFinality(b settlementFinalityBinding, why string) coordinatorSettlementFinality {
	slog.Warn("gateway held settlement: coordinator finality missing or not authenticated",
		"request_id", b.requestID,
		"account_id", b.accountID,
		"why", why,
	)
	return coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: missingSettlementFinalityTrailer}
}

// undeclaredSettlementFinality reads finality from a response that declared
// no settlement trailers: header finality, which with the pin on counts only
// when signed. A signed legacy tuple is a negotiating coordinator's attempt
// without a route snapshot.
func undeclaredSettlementFinality(resp *http.Response, b settlementFinalityBinding) coordinatorSettlementFinality {
	if !b.requireSigned {
		return coordinatorSettlementFinalityFromHeaders(resp.Header)
	}
	if !hasAnySettlementFinalityHeader(resp.Header) || !finalityMACValid(resp, resp.Header, b) {
		return missingSettlementFinality(b, "no signed finality declaration")
	}
	return coordinatorSettlementFinalityFromHeaders(resp.Header)
}

// coordinatorNonStreamingSettlementFinality reads a non-streaming 200's
// finality after its body was read. A coordinator that declared finality
// trailers recorded the attempt after the write: its finality is the
// trailers alone, and only with a valid MAC. Missing values, a missing MAC or
// a bad MAC hold as missing_settlement_finality_trailer, never a local debit.
func coordinatorNonStreamingSettlementFinality(resp *http.Response, b settlementFinalityBinding) coordinatorSettlementFinality {
	if resp == nil {
		if b.requireSigned {
			return missingSettlementFinality(b, "no response")
		}
		return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
	}
	if !hasSettlementFinalityTrailerDeclaration(resp) {
		return undeclaredSettlementFinality(resp, b)
	}
	if !hasAnySettlementFinalityHeader(resp.Trailer) {
		return missingSettlementFinality(b, "declared trailers missing")
	}
	if !finalityMACValid(resp, resp.Trailer, b) {
		return missingSettlementFinality(b, "trailer MAC missing or invalid")
	}
	return coordinatorSettlementFinalityFromHeaders(resp.Trailer)
}

// coordinatorStreamingSettlementFinality reads a stream's finality. Trailer
// finality is checked against its MAC whenever the MAC was declared (a
// negotiating coordinator) or the pin is on; an older coordinator's
// unsigned trailers still count without the pin.
func coordinatorStreamingSettlementFinality(resp *http.Response, b settlementFinalityBinding) coordinatorSettlementFinality {
	if resp == nil {
		if b.requireSigned {
			return missingSettlementFinality(b, "no response")
		}
		return coordinatorSettlementFinality{Action: settlementFinalityLegacy}
	}
	if hasAnySettlementFinalityHeader(resp.Trailer) {
		if (b.requireSigned || settlementFinalityMACDeclared(resp)) && !finalityMACValid(resp, resp.Trailer, b) {
			return missingSettlementFinality(b, "trailer MAC missing or invalid")
		}
		return coordinatorSettlementFinalityFromHeaders(resp.Trailer)
	}
	if hasSettlementFinalityTrailerDeclaration(resp) {
		return coordinatorSettlementFinality{Action: settlementFinalityHold, Reason: missingSettlementFinalityTrailer}
	}
	return undeclaredSettlementFinality(resp, b)
}

// streamingLocalTerminalMustHold decides a stream the gateway ends itself
// (buyer disconnect, timeout, output cap), whose trailers never arrive: hold
// for the reconciler when finality is coming as trailers or the headers do
// not authorize legacy accounting; settle locally only on (with the pin, a
// signed) legacy header tuple or no finality at all.
func streamingLocalTerminalMustHold(resp *http.Response, b settlementFinalityBinding) bool {
	if hasSettlementFinalityTrailerDeclaration(resp) {
		return true
	}
	return undeclaredSettlementFinality(resp, b).Action != settlementFinalityLegacy
}
