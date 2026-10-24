package buyer

import (
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"testing"
)

func TestDSMLGuaranteedModesRequireExactLoadedModelDeclaration(t *testing.T) {
	p := pool.Provider{ModelID: "deepseek-ai/DeepSeek-V4", BinaryVersion: "1.8.262"}
	policy := &toolSelectionPolicy{mode: "required"}
	if !providerParsesToolGrammar(p) {
		t.Fatal("main's DSML parser support was lost")
	}
	if providerSupportsToolSelection(p, policy) {
		t.Fatal("parser support granted a guaranteed mode")
	}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{ModelID: p.ModelID, Runtime: "mlx_cache", Modes: []string{"required", "named"}, Validation: "schema-holdback-v1"}}
	if !providerSupportsToolSelection(p, policy) {
		t.Fatal("exact loaded-model declaration was ignored")
	}
	p.ModelID = "deepseek-ai/DeepSeek-V4-other"
	if providerSupportsToolSelection(p, policy) {
		t.Fatal("stale declaration granted guaranteed selection after swap")
	}
}
