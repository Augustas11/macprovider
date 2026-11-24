package billing

import (
	"reflect"
	"testing"
)

func TestModelAliasesUseExistingRoutingBindings(t *testing.T) {
	for _, model := range []string{"Jundot/GLM-5.3-Flash-oQ4e-mtp", "aug11/GLM-5.3-Flash-oQ4e-mtp", "mlx-community/gpt-oss-20b-MXFP4-Q8", "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX", "acme/gpt-oss-20b"} {
		for _, alias := range ModelAliases(model) {
			if !ModelsEquivalent(alias, model) {
				t.Fatalf("%q incorrectly advertised for %q", alias, model)
			}
		}
	}
	// #2480: the byte-identical aug11 mirror and the deleted upstream repo
	// route as one model, each advertising the other.
	for served, want := range map[string][]string{
		"Jundot/GLM-5.3-Flash-oQ4e-mtp": {"aug11/glm-5.3-flash-oq4e-mtp", "glm-5.3-flash", "z-ai/glm-5.3-flash", "zai-org/glm-5.3-flash"},
		"aug11/GLM-5.3-Flash-oQ4e-mtp":  {"glm-5.3-flash", "jundot/glm-5.3-flash-oq4e-mtp", "z-ai/glm-5.3-flash", "zai-org/glm-5.3-flash"},
	} {
		if aliases := ModelAliases(served); !reflect.DeepEqual(aliases, want) {
			t.Fatalf("%s aliases = %#v, want %#v", served, aliases, want)
		}
	}
	for _, alias := range ModelAliases("qwen/gpt-oss-20b") {
		if alias == "openai/gpt-oss-20b" {
			t.Fatal("namespace spoof accepted")
		}
	}
}
