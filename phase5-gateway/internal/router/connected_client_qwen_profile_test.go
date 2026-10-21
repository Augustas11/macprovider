package router

import (
	"bytes"
	"encoding/json"
	"fmt"
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
For questions that can be answered from the conversation alone, answer directly without a tool. Follow the user's scope and permissions. Keep the final answer concise and grounded in the results.`

func connectedOpenCodeAgentProfile(configuration map[string]any, profile, model string) error {
	if profile == "" {
		return nil
	}
	if profile != "qwen-native" {
		return fmt.Errorf("unknown OpenCode lab agent profile")
	}
	switch model {
	case "mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit":
	default:
		return fmt.Errorf("Qwen lab agent profile requires an exact campaign model")
	}
	configuration["agent"] = map[string]any{"build": map[string]any{
		"model": "malibu/" + model, "prompt": connectedQwenAgentPrompt,
		"temperature": 0.7, "top_p": 0.8,
	}}
	return nil
}

func TestConnectedClientQwenAgentProfile(t *testing.T) {
	for _, model := range []string{
		"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit",
		"mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
	} {
		configuration := map[string]any{"model": "malibu/" + model}
		if err := connectedOpenCodeAgentProfile(configuration, "", model); err != nil || len(configuration) != 1 {
			t.Fatal("absent profile changed stock configuration")
		}
		if err := connectedOpenCodeAgentProfile(configuration, "qwen-native", model); err != nil {
			t.Fatal(err)
		}
		build := configuration["agent"].(map[string]any)["build"].(map[string]any)
		if len(build) != 4 || build["model"] != "malibu/"+model || build["prompt"] != connectedQwenAgentPrompt || build["temperature"] != 0.7 || build["top_p"] != 0.8 {
			t.Fatal("profile must only customize prompt, model and documented sampling")
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
