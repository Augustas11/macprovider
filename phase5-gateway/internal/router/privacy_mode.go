package router

import (
	"net/http"
	"strings"
)

// SPEC-006-R019 buyer privacy mode and SPEC-006-R020 route trace forwarding.
const (
	privacyModeHeader             = "X-MacProvider-Privacy-Mode"
	privacyModeDisclosureHeader   = "X-MacProvider-Privacy-Mode-Disclosure"
	internalPrivacyModeEmitHeader = "X-MacProvider-Internal-Privacy-Mode"
	routeTraceResponseHeader      = "X-MacProvider-Route-Trace"

	privacyModePool               = "pool"
	privacyModeRelayBlindRequired = "relay_blind_required"
	privacyModeOwnedProvider      = "owned_provider"

	privacyModeInvalid     = "invalid_privacy_mode"
	privacyModeUnsatisfied = "privacy_mode_unsatisfied"
)

// privacyModeDisclosures are the fixed SPEC-006-R019 strings. They never
// claim hardware isolation, attestation, end-to-end encryption that excludes
// the provider, or buyer ownership of the serving Mac.
var privacyModeDisclosures = map[string]string{
	privacyModePool:               "content_visible_to_serving_provider_and_network_relays; no_confidentiality_claim",
	privacyModeRelayBlindRequired: "content_hidden_from_network_relays; serving_provider_runtime_reads_plaintext; metadata_visible_to_relays",
	privacyModeOwnedProvider:      "served_only_by_selected_trusted_pool_members; content_visible_to_serving_member_and_network_relays",
}

// privacyModePoolScopedDisclosure is the SPEC-006-R019 string for a
// pool-scoped privacy-class envelope (SPEC-049-R032); its effective mode is
// relay_blind_required.
const privacyModePoolScopedDisclosure = "content_hidden_from_network_relays_and_pool_surfaces; served_only_by_selected_trusted_pool_members; serving_member_runtime_reads_plaintext; metadata_visible_to_relays"

func setPoolScopedPrivacyModeHeaders(h http.Header) {
	h.Set(privacyModeHeader, privacyModeRelayBlindRequired)
	h.Set(privacyModeDisclosureHeader, privacyModePoolScopedDisclosure)
}

// requestedPrivacyMode parses the closed buyer header. Absent means pool.
func requestedPrivacyMode(r *http.Request) (string, bool) {
	values := r.Header.Values(privacyModeHeader)
	if len(values) == 0 {
		return privacyModePool, true
	}
	if len(values) != 1 {
		return "", false
	}
	mode := strings.Trim(values[0], " \t")
	if _, ok := privacyModeDisclosures[mode]; !ok {
		return "", false
	}
	return mode, true
}

func setPrivacyModeHeaders(h http.Header, effective string) {
	disclosure, ok := privacyModeDisclosures[effective]
	if !ok {
		return
	}
	h.Set(privacyModeHeader, effective)
	h.Set(privacyModeDisclosureHeader, disclosure)
}

// gatePrivacyModeBeforeRelayBlind applies the parts of SPEC-006-R019 that are
// known from the raw request: the closed vocabulary, relay_blind_required
// needing a relay-blind envelope and no pool selection, and owned_provider
// needing a pool selection. It writes the refusal and returns ok=false, or
// returns the requested mode. A relay-blind envelope is disclosed here
// because the relay-blind path writes its own responses.
func gatePrivacyModeBeforeRelayBlind(w http.ResponseWriter, r *http.Request, body []byte) (string, bool) {
	mode, ok := requestedPrivacyMode(r)
	if !ok {
		writeError(w, http.StatusBadRequest, "invalid_request_error", privacyModeInvalid, "X-MacProvider-Privacy-Mode must be exactly one of pool, relay_blind_required, owned_provider")
		return "", false
	}
	_, envelope, malformed := parseRelayBlindEnvelopeProbe(body)
	switch mode {
	case privacyModeRelayBlindRequired:
		// SPEC-049-R032: only a privacy-class envelope may be pool-scoped.
		if len(r.Header.Values(poolSelectHeader)) > 0 && len(r.Header.Values(privacyClassHeader)) == 0 {
			writeError(w, http.StatusBadRequest, "invalid_request_error", privacyModeUnsatisfied, "relay_blind_required is not available for pool-scoped requests")
			return "", false
		}
		if !envelope && !malformed {
			writeError(w, http.StatusBadRequest, "invalid_request_error", privacyModeUnsatisfied, "relay_blind_required needs a relay-blind encrypted request envelope; plaintext is refused")
			return "", false
		}
	case privacyModeOwnedProvider:
		if len(r.Header.Values(poolSelectHeader)) == 0 {
			writeError(w, http.StatusBadRequest, "invalid_request_error", privacyModeUnsatisfied, "owned_provider needs a Trusted Pool selection")
			return "", false
		}
	}
	if envelope || malformed {
		setPrivacyModeHeaders(w.Header(), privacyModeRelayBlindRequired)
	}
	return mode, true
}

// effectivePrivacyModeForPlaintext finishes SPEC-006-R019 once the pool
// selection is resolved. owned_provider without a resolved pool fails closed.
func effectivePrivacyModeForPlaintext(w http.ResponseWriter, requested, poolID string) (string, bool) {
	effective := privacyModePool
	if poolID != "" {
		effective = privacyModeOwnedProvider
	}
	if requested == privacyModeOwnedProvider && poolID == "" {
		writeError(w, http.StatusBadRequest, "invalid_request_error", privacyModeUnsatisfied, "owned_provider needs a Trusted Pool selection")
		return "", false
	}
	setPrivacyModeHeaders(w.Header(), effective)
	return effective, true
}

// buyerVisibleRouteTraceHeader returns value only when it byte-exactly
// matches the SPEC-002-R007 grammar (SPEC-006-R020).
func buyerVisibleRouteTraceHeader(value string) string {
	rest, ok := strings.CutPrefix(value, "v=1; ")
	if !ok {
		return ""
	}
	members := []struct {
		name    string
		allowed []string
	}{
		{"phase", []string{"interactive", "long_input", "throughput"}},
		{"basis", []string{"measured", "explore", "fallback", "pinned"}},
		{"evidence", []string{"fresh", "none"}},
		{"engine", []string{"general_mlx", "continuous_batching", "native_mtp", "unknown"}},
		{"latency", []string{"low", "medium", "high", "unknown"}},
	}
	parts := strings.Split(rest, "; ")
	if len(parts) != len(members) {
		return ""
	}
	for i, m := range members {
		v, ok := strings.CutPrefix(parts[i], m.name+"=")
		if !ok {
			return ""
		}
		known := false
		for _, a := range m.allowed {
			if v == a {
				known = true
				break
			}
		}
		if !known {
			return ""
		}
	}
	return value
}
