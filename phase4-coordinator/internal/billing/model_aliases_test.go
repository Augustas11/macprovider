package billing

import "testing"

func TestModelAliasesUseExistingRoutingBindings(t *testing.T) {
	for _, model := range []string{"Jundot/GLM-5.3-Flash-oQ4e-mtp", "mlx-community/gpt-oss-20b-MXFP4-Q8", "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX", "acme/gpt-oss-20b"} {
		for _, alias := range ModelAliases(model) {
			if !ModelsEquivalent(alias, model) {
				t.Fatalf("%q incorrectly advertised for %q", alias, model)
			}
		}
	}
	aliases := ModelAliases("Jundot/GLM-5.3-Flash-oQ4e-mtp")
	if len(aliases) != 3 || aliases[0] != "glm-5.3-flash" || aliases[1] != "z-ai/glm-5.3-flash" || aliases[2] != "zai-org/glm-5.3-flash" {
		t.Fatalf("aliases = %#v", aliases)
	}
	for _, alias := range ModelAliases("qwen/gpt-oss-20b") {
		if alias == "openai/gpt-oss-20b" {
			t.Fatal("namespace spoof accepted")
		}
	}
}
