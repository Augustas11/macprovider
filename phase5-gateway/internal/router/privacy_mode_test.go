package router

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// privacyModeHarness is the engine harness with the coordinator response
// carrying routeTrace and the coordinator capturing the internal mode.
func privacyModeHarness(t *testing.T) (http.Handler, *engineCoordCapture, string) {
	t.Helper()
	return newEngineHarness(t, "")
}

func TestPrivacyMode_DefaultAndPoolServeAsToday(t *testing.T) {
	for _, mode := range []string{"", "pool", " pool "} {
		h, cap, key := privacyModeHarness(t)
		headers := map[string]string{}
		if mode != "" {
			headers[privacyModeHeader] = mode
		}
		resp := postChat(t, h, key, poolChatBody, headers)
		if resp.Code != http.StatusOK || cap.chatHits != 1 {
			t.Fatalf("mode %q: status=%d hits=%d body=%s", mode, resp.Code, cap.chatHits, resp.Body.String())
		}
		if resp.Header().Get(privacyModeHeader) != "pool" || resp.Header().Get(privacyModeDisclosureHeader) != privacyModeDisclosures["pool"] {
			t.Fatalf("mode %q: disclosure %q / %q", mode, resp.Header().Get(privacyModeHeader), resp.Header().Get(privacyModeDisclosureHeader))
		}
	}
}

func TestPrivacyMode_InvalidValuesRejectedBeforeDispatch(t *testing.T) {
	for _, mode := range []string{"Pool", "relay_blind", "local_only", "pool,owned_provider", "\t"} {
		h, cap, key := privacyModeHarness(t)
		resp := postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: mode})
		if resp.Code != http.StatusBadRequest || cap.chatHits != 0 {
			t.Fatalf("mode %q: status=%d hits=%d", mode, resp.Code, cap.chatHits)
		}
		assertErrorCode(t, resp.Body.String(), privacyModeInvalid)
	}
	// Two header lines are invalid even when both name a valid mode.
	h, cap, key := privacyModeHarness(t)
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(poolChatBody))
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Add(privacyModeHeader, "pool")
	req.Header.Add(privacyModeHeader, "pool")
	resp := httptest.NewRecorder()
	h.ServeHTTP(resp, req)
	if resp.Code != http.StatusBadRequest || cap.chatHits != 0 {
		t.Fatalf("repeated header: status=%d hits=%d", resp.Code, cap.chatHits)
	}
}

// relay_blind_required never serves plaintext and refuses pool scope (#1985).
func TestPrivacyMode_RelayBlindRequiredFailsClosed(t *testing.T) {
	h, cap, key := privacyModeHarness(t)
	resp := postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: "relay_blind_required"})
	if resp.Code != http.StatusBadRequest || cap.chatHits != 0 {
		t.Fatalf("plaintext: status=%d hits=%d", resp.Code, cap.chatHits)
	}
	assertErrorCode(t, resp.Body.String(), privacyModeUnsatisfied)
	if !strings.Contains(resp.Body.String(), `"retryable":false`) {
		t.Fatalf("must be non-retryable: %s", resp.Body.String())
	}

	h, cap, key = privacyModeHarness(t)
	resp = postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: "relay_blind_required", poolSelectHeader: testPoolID})
	if resp.Code != http.StatusBadRequest || cap.chatHits != 0 {
		t.Fatalf("pool scope: status=%d hits=%d", resp.Code, cap.chatHits)
	}
	assertErrorCode(t, resp.Body.String(), privacyModeUnsatisfied)

	// An envelope is handed to the existing relay-blind path, which owns
	// every outcome; it is never dispatched as plaintext chat.
	h, cap, key = privacyModeHarness(t)
	resp = postChat(t, h, key, `{"version":"relay-blind-request-v1","mode":"required"}`, map[string]string{privacyModeHeader: "relay_blind_required"})
	if cap.chatHits != 0 || strings.Contains(resp.Body.String(), privacyModeUnsatisfied) {
		t.Fatalf("envelope: status=%d hits=%d body=%s", resp.Code, cap.chatHits, resp.Body.String())
	}
	if resp.Header().Get(privacyModeHeader) != "relay_blind_required" {
		t.Fatalf("envelope disclosure %q", resp.Header().Get(privacyModeHeader))
	}
}

// owned_provider maps onto the Trusted Pool selection and never spills.
func TestPrivacyMode_OwnedProviderNeedsPoolSelection(t *testing.T) {
	h, cap, key := privacyModeHarness(t)
	resp := postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: "owned_provider"})
	if resp.Code != http.StatusBadRequest || cap.chatHits != 0 {
		t.Fatalf("no pool: status=%d hits=%d", resp.Code, cap.chatHits)
	}
	assertErrorCode(t, resp.Body.String(), privacyModeUnsatisfied)

	h, cap, key = privacyModeHarness(t)
	resp = postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: "owned_provider", poolSelectHeader: testPoolID})
	if resp.Code != http.StatusOK || cap.poolHeader != testPoolID {
		t.Fatalf("pool: status=%d pool=%q body=%s", resp.Code, cap.poolHeader, resp.Body.String())
	}
	if resp.Header().Get(privacyModeHeader) != "owned_provider" || resp.Header().Get(privacyModeDisclosureHeader) != privacyModeDisclosures["owned_provider"] {
		t.Fatalf("disclosure %q", resp.Header().Get(privacyModeHeader))
	}

	// An unauthorized pool keeps the generic pool_unavailable.
	h, cap, key = privacyModeHarness(t)
	resp = postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: "owned_provider", poolSelectHeader: "zzzzzzzzzzzzzzzzzzzzzz"})
	if cap.chatHits != 0 || !strings.Contains(resp.Body.String(), "pool_unavailable") {
		t.Fatalf("unauthorized pool: status=%d body=%s", resp.Code, resp.Body.String())
	}
}

// The effective mode is what the request got, even when the buyer asked for
// the default: a resolved pool is disclosed as owned_provider.
func TestPrivacyMode_EffectiveModeAndInternalLabel(t *testing.T) {
	h, cap, key := privacyModeHarness(t)
	resp := postChat(t, h, key, poolChatBody, map[string]string{poolSelectHeader: testPoolID})
	if resp.Code != http.StatusOK || resp.Header().Get(privacyModeHeader) != "owned_provider" {
		t.Fatalf("status=%d mode=%q", resp.Code, resp.Header().Get(privacyModeHeader))
	}
	if cap.privacyMode != "owned_provider" || cap.sawBuyerPrivacyMode {
		t.Fatalf("upstream internal mode %q, buyer header forwarded=%v", cap.privacyMode, cap.sawBuyerPrivacyMode)
	}
	h, cap, key = privacyModeHarness(t)
	if resp := postChat(t, h, key, poolChatBody, map[string]string{privacyModeHeader: "pool"}); resp.Code != http.StatusOK || cap.privacyMode != "pool" || cap.sawBuyerPrivacyMode {
		t.Fatalf("pool: status=%d internal=%q forwarded=%v", resp.Code, cap.privacyMode, cap.sawBuyerPrivacyMode)
	}
	for mode, disclosure := range privacyModeDisclosures {
		for _, overclaim := range []string{"encrypted_end_to_end", "attested", "enclave", "owned_by_buyer", "private"} {
			if strings.Contains(disclosure, overclaim) {
				t.Fatalf("%s disclosure overclaims %q: %s", mode, overclaim, disclosure)
			}
		}
	}
	for _, code := range []string{privacyModeInvalid, privacyModeUnsatisfied} {
		if !gatewayPermanentCodes[code] || gatewayRetryable(code) {
			t.Fatalf("%s must be permanent and non-retryable", code)
		}
	}
}

// SPEC-006-R020: only an exact SPEC-002-R007 value reaches the buyer.
func TestRouteTraceForwardingIsClosed(t *testing.T) {
	valid := "v=1; phase=interactive; basis=measured; evidence=fresh; engine=native_mtp; latency=low"
	for upstream, want := range map[string]string{
		valid: valid,
		"v=1; phase=long_input; basis=fallback; evidence=none; engine=unknown; latency=unknown":  "v=1; phase=long_input; basis=fallback; evidence=none; engine=unknown; latency=unknown",
		"v=2; phase=interactive; basis=measured; evidence=fresh; engine=native_mtp; latency=low": "",
		valid + "; provider=p1": "",
		" " + valid:             "",
		strings.Replace(valid, "basis=measured", "basis=provider-1", 1):                          "",
		strings.Replace(valid, "; ", ";", 1):                                                     "",
		"v=1; basis=measured; phase=interactive; evidence=fresh; engine=native_mtp; latency=low": "",
		valid + "\r\nX-Evil: 1": "",
	} {
		dst := http.Header{}
		copyCleanHeaders(dst, http.Header{routeTraceResponseHeader: []string{upstream}})
		if got := dst.Get(routeTraceResponseHeader); got != want {
			t.Fatalf("upstream %q: buyer saw %q want %q", upstream, got, want)
		}
	}
	// The gateway never forwards the buyer privacy header or the upstream
	// privacy-mode headers verbatim.
	dst := http.Header{}
	copyCleanHeaders(dst, http.Header{privacyModeHeader: []string{"relay_blind_required"}, privacyModeDisclosureHeader: []string{"fully_private"}})
	if dst.Get(privacyModeHeader) != "" || dst.Get(privacyModeDisclosureHeader) != "" {
		t.Fatalf("upstream privacy headers leaked: %v", dst)
	}
}
