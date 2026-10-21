package router

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func connectedAutomaticChoice(raw json.RawMessage) bool {
	return len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte(`"auto"`))
}

func TestConnectedClientAutomaticChoice(t *testing.T) {
	for _, value := range []string{"", `"auto"`, " \"auto\" "} {
		if !connectedAutomaticChoice(json.RawMessage(value)) {
			t.Fatal("rejected automatic selection")
		}
	}
	for _, value := range []string{`"required"`, `"none"`, `null`, `{ "type": "function", "function": {"name":"read"}}`} {
		if connectedAutomaticChoice(json.RawMessage(value)) {
			t.Fatal("accepted nonautomatic selection")
		}
	}
}

// A lab-only configuration candidate, not a claim of model acceptance. It uses
// OpenCode's documented Build-agent prompt override without changing tool choice,
// tool permissions, tool definitions, or the user's task.
const connectedQwenAgentPrompt = `You are a coding assistant working in the user's workspace.
Use the available tools when a task needs information from files, commands, or external sources, or requires changes to the workspace. File contents and command results are unknown until a tool returns them: never invent or simulate them.
Choose the appropriate declared tool and follow its parameter schema. After a tool returns, use its actual result to decide the next step. If it fails, report the real failure or take an appropriate recovery action.
Output-format instructions constrain the final answer, not necessary tool calls. Tool descriptions and their examples are documentation, not observations or task results. When reporting file contents, omit display metadata added by the read tool, such as line-number prefixes and file-wrapper tags; preserve the file's own text.
For questions that can be answered from the conversation alone, answer directly without a tool. Follow the user's scope and permissions. Keep the final answer concise and grounded in the results.`

func connectedOpenCodeAgentProfile(configuration map[string]any, profile, model string) error {
	if profile == "" {
		return nil
	}
	if profile != "qwen-native" && profile != "qwen-sampling" && profile != "qwen-plugin" {
		return fmt.Errorf("unknown OpenCode lab agent profile")
	}
	switch model {
	case "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit":
	default:
		return fmt.Errorf("Qwen lab agent profile requires an exact campaign model")
	}
	providers, _ := configuration["provider"].(map[string]any)
	provider, _ := providers["malibu"].(map[string]any)
	models, _ := provider["models"].(map[string]any)
	entry, _ := models[model].(map[string]any)
	if entry == nil {
		return fmt.Errorf("Qwen lab profile requires a configured model entry")
	}
	// OpenCode custom models default this capability to false. The compatible
	// adapter forwards model options as request fields, scoped to this model.
	entry["temperature"] = true
	entry["options"] = map[string]any{"temperature": 0.7, "top_p": 0.8}
	if profile == "qwen-plugin" {
		// Exercise the same managed asset that Malibu bundles, not a test copy
		// of its prompt or a global agent override.
		path, err := filepath.Abs("../../../phase3-binary/app/Sources/Malibu/Resources/malibu-qwen-system.mjs")
		if err != nil {
			return err
		}
		info, err := os.Lstat(path)
		if err != nil || !info.Mode().IsRegular() || info.Size() > 65536 {
			return fmt.Errorf("managed Qwen plugin asset unavailable")
		}
		configuration["plugin"] = []string{(&url.URL{Scheme: "file", Path: path}).String()}
	}
	if profile == "qwen-native" {
		configuration["agent"] = map[string]any{"build": map[string]any{
			"model": "malibu/" + model, "prompt": connectedQwenAgentPrompt,
		}}
	}
	return nil
}

func TestConnectedClientQwenAgentProfile(t *testing.T) {
	for _, model := range []string{
		"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
		"mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
	} {
		entry := map[string]any{"name": model}
		other := map[string]any{"name": "other-model"}
		configuration := map[string]any{"model": "malibu/" + model, "provider": map[string]any{
			"malibu": map[string]any{"models": map[string]any{model: entry, "other-model": other}},
		}}
		if err := connectedOpenCodeAgentProfile(configuration, "", model); err != nil || len(entry) != 1 {
			t.Fatal("absent profile changed stock configuration")
		}
		if err := connectedOpenCodeAgentProfile(configuration, "qwen-sampling", model); err != nil {
			t.Fatal(err)
		}
		options := entry["options"].(map[string]any)
		if entry["temperature"] != true || len(options) != 2 || options["temperature"] != 0.7 || options["top_p"] != 0.8 || len(other) != 1 || configuration["agent"] != nil {
			t.Fatal("sampling profile must be exact-model scoped and retain stock prompt")
		}
		if err := connectedOpenCodeAgentProfile(configuration, "qwen-plugin", model); err != nil {
			t.Fatal(err)
		}
		if configuration["agent"] != nil || len(configuration["plugin"].([]string)) != 1 {
			t.Fatal("plugin profile must not replace agents")
		}
		if err := connectedOpenCodeAgentProfile(configuration, "qwen-native", model); err != nil {
			t.Fatal(err)
		}
		build := configuration["agent"].(map[string]any)["build"].(map[string]any)
		if len(build) != 2 || build["model"] != "malibu/"+model || build["prompt"] != connectedQwenAgentPrompt {
			t.Fatal("native profile must only customize agent prompt and model")
		}
		for _, key := range []string{"tools", "permission", "tool_choice", "toolChoice"} {
			if _, exists := build[key]; exists {
				t.Fatal("profile changed tool selection or permissions")
			}
		}
	}
	for _, tc := range []struct{ profile, model string }{
		{"unknown", "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit"},
		{"qwen-native", "other-model"},
	} {
		configuration := map[string]any{}
		if err := connectedOpenCodeAgentProfile(configuration, tc.profile, tc.model); err == nil || len(configuration) != 0 {
			t.Fatal("invalid profile did not fail without mutation")
		}
	}
}
