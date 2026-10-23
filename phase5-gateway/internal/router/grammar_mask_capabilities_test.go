package router

import "testing"

func TestDSMLCapabilitiesRequireLiveGrammarDeclaration(t *testing.T) {
	model := "deepseek-ai/DeepSeek-V4"
	if _, ok := openRouterSupportedParameters(model, 1024)["tools"]; ok {
		t.Fatal("DSML tools advertised without a live grammar declaration")
	}
	if _, ok := openRouterSupportedParameters(model, 1024, "auto", "required", "named")["tools"]; !ok {
		t.Fatal("DSML live grammar declaration was not advertised")
	}
}
