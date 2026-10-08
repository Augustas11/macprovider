package router

import (
	"encoding/json"
	"io"
	"net/http"

	"github.com/augstar/macprovider-gateway/internal/relayblind"
)

const (
	privacyDirectoryRoute      = "/v1/privacy-class/directory"
	privacyDirectoryWalletText = "The privacy identity directory requires API-key authentication; wallet sessions pin the provider with --identity-pin"
)

// handlePrivacyDirectory is the SPEC-049-R028 buyer route. The gateway adds
// no trust: it authenticates the buyer as for a reservation, forwards the
// coordinator's signed envelope byte for byte, and never verifies, re-signs,
// filters, or caches it. The buyer client verifies the signature.
func (s *Server) handlePrivacyDirectory(w http.ResponseWriter, r *http.Request) {
	setNoStoreHeaders(w.Header())
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "invalid_request_error", "method_not_allowed", "Method not allowed")
		return
	}
	authn, ok := s.authenticateAny(w, r)
	if !ok {
		return
	}
	// v0.2 serves the directory to API-key buyers only. A wallet session has
	// no signed-request profile for this route, so it pins by --identity-pin.
	if authn.WalletSession != nil {
		writePrivacyClassError(w, privacyClassUnavailable, privacyDirectoryWalletText)
		return
	}
	accountID := relayBlindAccountID(authn)
	if privacyBuyerIntentDenied(r, accountID, authn.Demo) {
		writePrivacyClassError(w, privacyClassDowngrade, privacyIntentDowngradeMessage(r, accountID, authn.Demo))
		return
	}
	if !s.privacyClassEnabled() {
		writePrivacyClassError(w, privacyClassDisabled, "")
		return
	}
	resp, err := s.relayBlindUpstream(r, http.MethodGet, privacyDirectoryRoute, accountID, "", nil, false)
	if err != nil {
		writePrivacyClassError(w, privacyClassUnavailable, "")
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, relayblind.MaxIdentityDirectoryBytes+1))
	if err != nil || len(body) > relayblind.MaxIdentityDirectoryBytes {
		writePrivacyClassError(w, privacyClassUnavailable, "")
		return
	}
	if resp.StatusCode != http.StatusOK {
		var wire struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		if json.Unmarshal(body, &wire) == nil && privacyClassKnown(wire.Error.Code) {
			writePrivacyClassError(w, wire.Error.Code, "")
			return
		}
		writePrivacyClassError(w, privacyClassUnavailable, "")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}
