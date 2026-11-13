package buyer

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
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
		routeErr.code != "tool_grammar_provider_unavailable" {
		t.Fatalf("pin to the old MiniMax provider: %+v", routeErr)
	}

	// Only the old provider: fail closed with the retryable grammar code.
	s, registry, _ = poolIsolationServer(t)
	registry.Register(&oldMiniMax, nil)
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, http.Header{}, nil, "2024-01-01", &forwardState{}); routeErr == nil ||
		routeErr.code != "tool_grammar_provider_unavailable" {
		t.Fatalf("old-only MiniMax: %+v", routeErr)
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
