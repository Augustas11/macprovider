package buyer

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

func TestDSMLCapabilitiesRequireExactLoadedModelDeclaration(t *testing.T) {
	p := pool.Provider{ModelID: "deepseek-ai/DeepSeek-V4", BinaryVersion: "1.8.262"}
	if providerParsesToolGrammar(p) {
		t.Fatal("old shared parser floor granted DSML support")
	}
	p.ToolSelectionCapabilities = []pool.ToolSelectionCapability{{ModelID: p.ModelID, Runtime: "mlx_cache", Modes: []string{"required", "named"}, Validation: "schema-holdback-v1"}}
	if !providerParsesToolGrammar(p) {
		t.Fatal("exact loaded-model grammar declaration was ignored")
	}
	p.ModelID = "deepseek-ai/DeepSeek-V4-other"
	if providerParsesToolGrammar(p) {
		t.Fatal("stale declaration granted DSML support after model swap")
	}
}
