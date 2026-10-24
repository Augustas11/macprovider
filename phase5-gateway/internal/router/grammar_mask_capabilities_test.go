package router

import "testing"

func TestDSMLCapabilitiesFollowCoordinatorConformance(t *testing.T) {
	model := "deepseek-ai/DeepSeek-V4"
	for _, caps := range []*openRouterModelCapabilities{nil, {Tools: false}} {
		if _, ok := openRouterSupportedParameters(model, 1024, caps)["tools"]; ok {
			t.Fatal("DSML tools advertised without coordinator capability")
		}
	}
	caps := &openRouterModelCapabilities{Tools: true, ToolChoice: []string{"auto", "none"}}
	params := openRouterSupportedParameters(model, 1024, caps)
	if _, ok := params["tools"]; !ok {
		t.Fatal("main's DSML parser capability was lost")
	}
	if len(params["tool_choice"].Values) != 2 {
		t.Fatal("parser support inflated guaranteed modes")
	}
	caps.ToolChoice = []string{"auto", "none", "required", "named"}
	if len(openRouterSupportedParameters(model, 1024, caps)["tool_choice"].Values) != 3 {
		t.Fatal("coordinator guaranteed mode was lost")
	}
}
