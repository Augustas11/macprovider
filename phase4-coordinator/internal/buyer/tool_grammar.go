package buyer

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
)

// Tool-call grammars (SPEC-018 §3.1). toolGrammarFamily mirrors
// ToolCallGrammar.family(modelID:) in
// phase3-binary/Sources/MacProviderCore/ToolCallGrammar.swift: the provider
// selects the parser from the loaded chat template and falls back to this
// catalog family; the coordinator only needs the family to refuse tool
// requests to a model whose template has no tool grammar.
const (
	toolGrammarQwen    = "qwen"
	toolGrammarGLM     = "glm"
	toolGrammarLlama3  = "llama3"
	toolGrammarGemma4  = "gemma4"
	toolGrammarHarmony = "harmony"
	toolGrammarDSML    = "dsml"
	toolGrammarLFM2    = "lfm2"
)

func toolGrammarFamily(model string) string {
	id := strings.ToLower(model)
	switch {
	case strings.Contains(id, "qwen2-vl"), strings.Contains(id, "qwen2vl"):
		return ""
	case strings.Contains(id, "qwen2.5"), strings.Contains(id, "qwen3"):
		// Table order (SPEC-018 §3.6): the Qwen row wins a mixed name.
		return toolGrammarQwen
	case strings.Contains(id, "gpt-oss"):
		return toolGrammarHarmony
	case strings.Contains(id, "glm-4.5"), strings.Contains(id, "glm-4.6"), strings.Contains(id, "glm-4.7"), strings.Contains(id, "glm-5"):
		return toolGrammarGLM
	case strings.Contains(id, "llama-3.1"), strings.Contains(id, "llama-3.2"), strings.Contains(id, "llama-3.3"),
		strings.Contains(id, "llama3.1"), strings.Contains(id, "llama3.2"), strings.Contains(id, "llama3.3"):
		return toolGrammarLlama3
	case strings.Contains(id, "gemma-4"), strings.Contains(id, "gemma4"):
		return toolGrammarGemma4
	case strings.Contains(id, "nemotron-3"), strings.Contains(id, "nemotron3"):
		return toolGrammarQwen
	case strings.Contains(id, "deepseek-v4"), strings.Contains(id, "deepseek_v4"):
		return toolGrammarDSML
	case strings.Contains(id, "lfm2.5-24b-a2b"):
		return toolGrammarLFM2
	}
	return ""
}

// requestDeclaresTools reports a non-empty `tools` array in the raw body.
func requestDeclaresTools(raw json.RawMessage) bool {
	var body struct {
		Tools []json.RawMessage `json:"tools"`
	}
	return json.Unmarshal(raw, &body) == nil && len(body.Tools) > 0
}

// unsupportedToolsModel returns 400 tools_unsupported_for_model when a
// request declaring tools resolves to a catalog model (or a class with no
// member) whose family has no tool grammar, on a route that can only reach
// native providers. External runtimes and unresolved (BYOM) models keep
// provider-side behavior, as for the multi-turn gate.
func unsupportedToolsModel(req chatRequest, catalogModelIDs func() []string, class *config.ModelClassConfig, poolRuntimeAllowlist []string) (int, string, string) {
	if !req.declaresTools || !nativeOnlyRoute(req, poolRuntimeAllowlist) {
		return 0, "", ""
	}
	if class != nil {
		for _, member := range modelClassMembers(class) {
			if toolGrammarFamily(member) != "" {
				return 0, "", ""
			}
		}
		if len(modelClassMembers(class)) == 0 {
			return 0, "", ""
		}
		return http.StatusBadRequest, "tools_unsupported_for_model", "This model does not support tool calls"
	}
	if catalogModelIDs == nil {
		return 0, "", ""
	}
	resolved := false
	for _, id := range catalogModelIDs() {
		if !billing.ModelsEquivalent(req.Model, id) {
			continue
		}
		if toolGrammarFamily(id) != "" {
			return 0, "", ""
		}
		resolved = true
	}
	if !resolved {
		return 0, "", ""
	}
	return http.StatusBadRequest, "tools_unsupported_for_model", "This model does not support tool calls"
}

// nativeOnlyRoute reports whether the route can only reach native providers.
func nativeOnlyRoute(req chatRequest, poolRuntimeAllowlist []string) bool {
	switch req.engineClass {
	case engineClassNative:
		return true
	case "":
		return req.poolID == "" || len(poolRuntimeAllowlist) == 0
	default:
		return false
	}
}
