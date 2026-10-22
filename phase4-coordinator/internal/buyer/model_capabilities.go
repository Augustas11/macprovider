package buyer

import (
	"sort"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// modelCapabilities is the per-model capability object on /v1/models
// (SPEC-006 §21, #2107 D6). Each field is derived from the predicate the
// coordinator or provider enforces for that model:
//
//   - tools: the model family has a tool grammar (toolGrammarFamily, the
//     same predicate behind tools_unsupported_for_model).
//   - tool_choice: auto/none with tools, plus every guaranteed mode a native
//     provider declares for its exact loaded model (providerSupportsToolSelection).
//   - reasoning: the family's template always opens a reasoning block, so
//     responses carry reasoning_content and honour reasoning_effort.
//   - response_format: every native provider validates json_object and strict
//     json_schema output (SPEC-019).
//   - vision: at least one provider passes providerSupportsVision.
//   - context_length: the largest advertised max_context_tokens.
type modelCapabilities struct {
	Tools          bool     `json:"tools"`
	ToolChoice     []string `json:"tool_choice"`
	Reasoning      bool     `json:"reasoning"`
	ResponseFormat bool     `json:"response_format"`
	Vision         bool     `json:"vision"`
	ContextLength  int      `json:"context_length"`
}

// reasoningFamily reports families whose chat template always reasons before
// answering (GLM-5 opens `<think>`; gpt-oss Harmony has an analysis channel).
func reasoningFamily(model string) bool {
	id := strings.ToLower(model)
	return strings.Contains(id, "glm-5") || strings.Contains(id, "gpt-oss")
}

func mergeModelCapabilities(current *modelCapabilities, p pool.Provider, vision bool) *modelCapabilities {
	caps := current
	if caps == nil {
		caps = &modelCapabilities{}
	}
	if toolGrammarFamily(p.ModelID) != "" {
		caps.Tools = true
		modes := map[string]bool{"auto": true, "none": true}
		for _, mode := range caps.ToolChoice {
			modes[mode] = true
		}
		for _, mode := range []string{"required", "named"} {
			if providerSupportsToolSelection(p, &toolSelectionPolicy{mode: mode}) {
				modes[mode] = true
			}
		}
		caps.ToolChoice = caps.ToolChoice[:0]
		for _, mode := range []string{"auto", "none", "required", "named"} {
			if modes[mode] {
				caps.ToolChoice = append(caps.ToolChoice, mode)
			}
		}
	}
	if reasoningFamily(p.ModelID) {
		caps.Reasoning = true
	}
	if p.RuntimeSource == "" || p.RuntimeSource == engineClassNative {
		caps.ResponseFormat = true
	}
	if vision {
		caps.Vision = true
	}
	if p.MaxContextTokens > caps.ContextLength {
		caps.ContextLength = p.MaxContextTokens
	}
	return caps
}

// finishModelCapabilities derives the OpenRouter-style supported_parameters
// list from the capability object.
func finishModelCapabilities(entry *modelEntry) {
	caps := entry.Capabilities
	if caps == nil {
		return
	}
	if caps.ToolChoice == nil {
		caps.ToolChoice = []string{}
	}
	params := []string{"max_tokens", "temperature", "top_p", "stop", "seed", "frequency_penalty", "presence_penalty"}
	if caps.Tools {
		params = append(params, "tools", "tool_choice", "parallel_tool_calls")
	}
	if caps.Reasoning {
		params = append(params, "reasoning_effort")
	}
	if caps.ResponseFormat {
		params = append(params, "response_format")
	}
	sort.Strings(params)
	entry.SupportedParameters = params
}
