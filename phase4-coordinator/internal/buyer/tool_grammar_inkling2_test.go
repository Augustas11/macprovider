package buyer

import (
	"context"
	"net/http"
	"slices"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// #2467: Inkling 2 has a tool grammar (`<|message_model|>NAME<|content_invoke_tool_json|>`
// frames), so tools are advertised and admitted, but only from a provider that
// declares the family for its exact loaded model.
func TestInkling2ToolsAdvertisedFromDeclaringProvider(t *testing.T) {
	const model = "mlx-community/Inkling-2-Mini-oQ4e-mtp"
	for _, id := range []string{model, "thinkingmachines/inkling-2-mini", "openuncensored/inkling-2-mini-uncensored",
		"aug11/Inkling-2-Mini-oQ4e-mtp-uncensored", "local/inkling2_loop"} {
		if toolGrammarFamily(id) != toolGrammarInkling2 {
			t.Fatalf("toolGrammarFamily(%q) = %q, want %q", id, toolGrammarFamily(id), toolGrammarInkling2)
		}
	}
	if !reasoningFamily(model) || !splitsFamilyReasoning(toolGrammarFamily(model)) {
		t.Fatal("Inkling 2 reasons by default and its frames are split by the provider")
	}

	req := chatRequest{Model: model, declaresTools: true, engineClass: engineClassNative}
	if status, code, _ := unsupportedToolsModel(req, func() []string { return []string{model} }, nil, nil); status != 0 {
		t.Fatalf("tools refused for Inkling 2: %d %s", status, code)
	}

	// A provider without the Inkling 2 family declares auto and none only.
	p := pool.Provider{ModelID: model, BinaryVersion: "1.8.300", RuntimeSource: engineClassNative}
	cap := pool.ToolSelectionCapability{ModelID: model, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: []string{"auto", "none"}}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{cap}
	if providerParsesToolGrammar(p) || providerToolGrammarEligible(p) || providerServesModelOutput(p) {
		t.Fatal("provider without the Inkling 2 family gained Inkling 2 tools or output")
	}
	if caps := mergeModelCapabilities(nil, p, false); caps.Tools {
		t.Fatal("tools advertised from a provider without the Inkling 2 family")
	}

	cap.Modes = []string{"auto", "none", "required", "named"}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{cap}
	if !providerParsesToolGrammar(p) || !providerToolGrammarEligible(p) || !providerServesModelOutput(p) {
		t.Fatal("declaring provider rejected")
	}
	caps := mergeModelCapabilities(nil, p, false)
	if !caps.Tools || !slices.Equal(caps.ToolChoice, []string{"auto", "none", "required", "named"}) || !caps.Reasoning {
		t.Fatalf("capabilities = %+v, want tools with every tool_choice mode and reasoning", caps)
	}

	p.ShardGroupHeadV1 = true
	if providerParsesToolGrammar(p) {
		t.Fatal("shard head gained Inkling 2 tools")
	}
}

// #2467: a provider that does not declare the family would pass Inkling 2's
// frame markers and thinking into content, so plain chat needs the declaring
// provider too, with the retryable output-format refusal when none is left.
func TestInkling2PlainChatNeedsTheDeclaringProvider(t *testing.T) {
	const model = "mlx-community/Inkling-2-Mini-oQ4e-mtp"
	withModes := func(id string, modes ...string) pool.Provider {
		p := poolProvider(id)
		p.ModelID = model
		p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{
			ModelID: model, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: modes,
		}}
		return p
	}
	undeclared := withModes("old", "auto", "none")
	declaring := withModes("new", "auto", "none", "required", "named")
	plain := chatRequest{Model: model, raw: []byte(`{"model":"` + model + `","messages":[{"role":"user","content":"hi"}]}`)}

	s, registry, _ := poolIsolationServer(t)
	registry.Register(&undeclared, nil)
	registry.Register(&declaring, nil)
	for i := 0; i < 4; i++ {
		p, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, http.Header{}, nil, "2024-01-01", &forwardState{})
		if routeErr != nil || p.ProviderID != "new" {
			t.Fatalf("plain Inkling 2 chat routed to %q (%+v), want the declaring provider", p.ProviderID, routeErr)
		}
	}

	s, registry, _ = poolIsolationServer(t)
	registry.Register(&undeclared, nil)
	if _, routeErr := s.selectProviderExcluding(context.Background(), "rid", plain, http.Header{}, nil, "2024-01-01", &forwardState{}); routeErr == nil ||
		routeErr.code != "tool_grammar_provider_unavailable" || routeErr.status != http.StatusServiceUnavailable ||
		routeErr.message != modelOutputProviderUnavailableMessage {
		t.Fatalf("undeclared-only Inkling 2: %+v", routeErr)
	}
}
