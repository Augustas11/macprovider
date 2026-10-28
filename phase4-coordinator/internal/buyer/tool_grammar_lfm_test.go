package buyer

import (
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"testing"
)

func TestLFMToolsRequireExactLoadedModelCapability(t *testing.T) {
	const model = "LiquidAI/LFM2.5-24B-A2B-MLX-4bit"
	if toolGrammarFamily(model) != toolGrammarLFM2 {
		t.Fatal("missing LFM family")
	}
	p := pool.Provider{ModelID: model, BinaryVersion: "1.8.274", RuntimeSource: engineClassNative}
	if providerParsesToolGrammar(p) || providerToolGrammarEligible(p) {
		t.Fatal("old released provider gained LFM support")
	}
	cap := pool.ToolSelectionCapability{ModelID: model, Runtime: engineClassNative, Validation: "schema-holdback-v1", Modes: []string{"auto", "none"}}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{cap}
	if providerParsesToolGrammar(p) {
		t.Fatal("legacy modes admitted LFM")
	}
	cap.Modes = []string{"auto", "none", "required", "named"}
	for _, bad := range []pool.ToolSelectionCapability{
		{ModelID: "other", Runtime: engineClassNative, Validation: cap.Validation, Modes: cap.Modes},
		{ModelID: model, Runtime: "external", Validation: cap.Validation, Modes: cap.Modes},
		{ModelID: model, Runtime: engineClassNative, Validation: "", Modes: cap.Modes},
		{ModelID: model, Runtime: engineClassNative, Validation: cap.Validation, Modes: []string{"required"}},
	} {
		p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{bad}
		if providerParsesToolGrammar(p) {
			t.Fatalf("invalid declaration admitted: %+v", bad)
		}
	}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{cap}
	if !providerParsesToolGrammar(p) || !providerToolGrammarEligible(p) {
		t.Fatal("complete native declaration rejected")
	}
	p.ShardGroupHeadV1 = true
	if providerParsesToolGrammar(p) {
		t.Fatal("shard head gained LFM tools")
	}
	p = pool.Provider{ModelID: "zai-org/glm-5.3-flash", BinaryVersion: "1.8.262", RuntimeSource: engineClassNative}
	if !providerParsesToolGrammar(p) {
		t.Fatal("existing family floor regressed")
	}
}
