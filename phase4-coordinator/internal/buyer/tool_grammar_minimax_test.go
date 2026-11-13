package buyer

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

// #2189: MiniMax M3.1-Flash has a tool grammar, so tools are advertised and
// admitted, but only from a provider that declares the MiniMax family for its
// exact loaded model.
func TestMiniMaxToolsAdvertisedFromDeclaringProvider(t *testing.T) {
	const model = "mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp"
	for _, id := range []string{model, "minimaxai/minimax-m3.1-flash", "minimax/minimax-m3.1-flash", "MiniMaxAI/MiniMax-M3"} {
		if toolGrammarFamily(id) != toolGrammarMiniMax {
			t.Fatalf("toolGrammarFamily(%q) = %q, want %q", id, toolGrammarFamily(id), toolGrammarMiniMax)
		}
	}
	for _, id := range []string{"MiniMaxAI/MiniMax-M2.5", "MiniMaxAI/MiniMax-Text-01"} {
		if toolGrammarFamily(id) != "" {
			t.Fatalf("toolGrammarFamily(%q) = %q, want none", id, toolGrammarFamily(id))
		}
	}

	req := chatRequest{Model: model, declaresTools: true, engineClass: engineClassNative}
	if status, code, _ := unsupportedToolsModel(req, func() []string { return []string{model} }, nil, nil); status != 0 {
		t.Fatalf("tools refused for MiniMax: %d %s", status, code)
	}
	if status, code, _ := unsupportedToolsModel(chatRequest{Model: "other/no-grammar", declaresTools: true, engineClass: engineClassNative},
		func() []string { return []string{"other/no-grammar"} }, nil, nil); status != http.StatusBadRequest || code != "tools_unsupported_for_model" {
		t.Fatalf("control model not refused: %d %s", status, code)
	}

	// A provider without the MiniMax family declares auto and none only.
	p := pool.Provider{ModelID: model, BinaryVersion: "1.8.300", RuntimeSource: engineClassNative}
	cap := pool.ToolSelectionCapability{ModelID: model, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: []string{"auto", "none"}}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{cap}
	if providerParsesToolGrammar(p) || providerToolGrammarEligible(p) {
		t.Fatal("provider without the MiniMax family gained MiniMax tools")
	}
	if caps := mergeModelCapabilities(nil, p, false); caps.Tools {
		t.Fatal("tools advertised from a provider without the MiniMax family")
	}

	cap.Modes = []string{"auto", "none", "required", "named"}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{cap}
	if !providerParsesToolGrammar(p) || !providerToolGrammarEligible(p) {
		t.Fatal("declaring provider rejected")
	}
	caps := mergeModelCapabilities(nil, p, false)
	if !caps.Tools || !slices.Equal(caps.ToolChoice, []string{"auto", "none", "required", "named"}) {
		t.Fatalf("capabilities = %+v, want tools with every tool_choice mode", caps)
	}

	p.ShardGroupHeadV1 = true
	if providerParsesToolGrammar(p) {
		t.Fatal("shard head gained MiniMax tools")
	}
}

// #2189: a provider that loads MiniMax M3 without the family does not split
// <mm:think> reasoning, so every MiniMax request, plain chat included, needs
// the exact-model required+named declaration. Other families are unchanged.
func TestMiniMaxPlainChatNeedsTheDeclaringProvider(t *testing.T) {
	const model = "mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp"
	withModes := func(id, modelID string, modes ...string) pool.Provider {
		p := poolProvider(id)
		p.ModelID = modelID
		p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{
			ModelID: modelID, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: modes,
		}}
		return p
	}
	oldMiniMax := withModes("old", model, "auto", "none")
	newMiniMax := withModes("new", model, "auto", "none", "required", "named")
	if providerServesModelOutput(oldMiniMax) || !providerServesModelOutput(newMiniMax) {
		t.Fatal("MiniMax output eligibility must follow the exact-model declaration")
	}
	otherOld := withModes("glm", "Jundot/GLM-5.3-Flash-oQ4e-mtp", "auto", "none")
	external := withModes("ext", model, "auto", "none")
	external.RuntimeSource = "ollama_loopback"
	if !providerServesModelOutput(otherOld) || !providerServesModelOutput(external) {
		t.Fatal("other families and external runtimes are unaffected")
	}
	plain := chatRequest{Model: model, raw: []byte(`{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`)}

	// Plain chat: the old provider is excluded, the declaring one serves.
	s, registry, _ := poolIsolationServer(t)
	registry.Register(&oldMiniMax, nil)
	registry.Register(&newMiniMax, nil)
	for i := 0; i < 4; i++ {
		p, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, http.Header{}, nil, "2024-01-01", &forwardState{})
		if routeErr != nil || p.ProviderID != "new" {
			t.Fatalf("plain MiniMax chat routed to %q (%+v), want the declaring provider", p.ProviderID, routeErr)
		}
	}
	// A pin to the old provider is refused too.
	pinned := http.Header{}
	pinned.Set("X-MacProvider-Provider", "old")
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, pinned, nil, "2024-01-01", &forwardState{}); routeErr == nil ||
		routeErr.code != "tool_grammar_provider_unavailable" || routeErr.message != modelOutputProviderUnavailableMessage {
		t.Fatalf("pin to the old MiniMax provider: %+v", routeErr)
	}

	// Only the old provider: fail closed with the retryable grammar code.
	s, registry, _ = poolIsolationServer(t)
	registry.Register(&oldMiniMax, nil)
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, http.Header{}, nil, "2024-01-01", &forwardState{}); routeErr == nil ||
		routeErr.code != "tool_grammar_provider_unavailable" || routeErr.status != http.StatusServiceUnavailable ||
		routeErr.message != modelOutputProviderUnavailableMessage {
		t.Fatalf("old-only MiniMax: %+v", routeErr)
	}
	// A tool request keeps the tool-grammar wording.
	tools := plain
	tools.multiTurnToolHistory, tools.declaresTools = true, true
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid", tools, http.Header{}, nil, "2024-01-01", &forwardState{}); routeErr == nil ||
		routeErr.code != "tool_grammar_provider_unavailable" || routeErr.message == modelOutputProviderUnavailableMessage {
		t.Fatalf("old-only MiniMax tool request: %+v", routeErr)
	}

	// Another family's plain chat still reaches a provider without the
	// required/named declaration.
	s, registry, _ = poolIsolationServer(t)
	registry.Register(&otherOld, nil)
	glm := chatRequest{Model: otherOld.ModelID, raw: []byte(`{"model":"` + otherOld.ModelID + `","messages":[{"role":"user","content":"hi"}]}`)}
	if p, routeErr := s.selectProviderExcluding(context.Background(), "rid", glm, http.Header{}, nil, "2024-01-01", &forwardState{}); routeErr != nil || p.ProviderID != "glm" {
		t.Fatalf("GLM plain chat: provider %q err %+v", p.ProviderID, routeErr)
	}
}

// #2189: relay-blind and privacy-class reservations apply the same MiniMax
// output gate: a provider that does not declare the family is never bound.
// The refusal uses the closed inventories: the retryable SPEC-041-R007
// relay_blind_provider_unsupported, and the SPEC-049-R013 pre-consume
// privacy_class_unavailable, which names no per-provider cause.
func TestMiniMaxEncryptedReservationsNeedTheDeclaringProvider(t *testing.T) {
	const model = "mlx-community/MiniMax-M3.1-Flash-oQ3e-mtp"
	h := newPrivacyHarness(t, privacyHarnessConfig{privacyKey: true, relayKey: true, model: model})
	raw, _ := json.Marshal(relayblind.ReservationRequest{EndpointFamily: relayblind.EndpointChatCompletions, Model: model, MaxOutputTokens: 32, InputTokenUpperBound: 96, EncryptedRequestBytes: 2048})
	reserve := func(privacy bool) *httptest.ResponseRecorder {
		if privacy {
			return h.privacyRequest(t, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "", nil)
		}
		return relayBlindRequest(t, h.server, http.MethodPost, "/v1/relay-blind/route-reservations", raw, "")
	}
	relay := reserve(false)
	if body := relay.Body.String(); relay.Code != http.StatusServiceUnavailable || !strings.Contains(body, `"code":"relay_blind_provider_unsupported"`) ||
		!strings.Contains(body, `"retryable":true`) {
		t.Fatalf("relay-blind undeclared provider status=%d body=%s, want the retryable relay_blind_provider_unsupported", relay.Code, body)
	}
	private := reserve(true)
	if body := private.Body.String(); private.Code == http.StatusOK || !strings.Contains(body, `"code":"privacy_class_unavailable"`) ||
		strings.Contains(body, "tool_grammar") || strings.Contains(body, "output format") {
		t.Fatalf("privacy undeclared provider status=%d body=%s, want privacy_class_unavailable with no cause", private.Code, body)
	}
	if count := countRelayBlindReservations(t, h.server); count != 0 {
		t.Fatalf("refused reservations created %d rows", count)
	}

	h.provider.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{ModelID: model, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: []string{"auto", "none", "required", "named"}}}
	for _, privacy := range []bool{false, true} {
		if response := reserve(privacy); response.Code != http.StatusOK {
			t.Fatalf("privacy=%v declaring provider status=%d body=%s", privacy, response.Code, response.Body.String())
		}
	}
}
