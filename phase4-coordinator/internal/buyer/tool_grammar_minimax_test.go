package buyer

import (
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
