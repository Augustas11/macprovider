package buyer

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// toolGrammarFamily mirrors ToolCallGrammar.family(modelID:) in
// phase3-binary/Sources/MacProviderCore/ToolCallGrammar.swift for every
// catalog row (#2107 D1/D4).
func TestToolGrammarFamilyCoversEveryCatalogFamily(t *testing.T) {
	for model, want := range map[string]string{
		"zai-org/glm-5.3-flash":                    toolGrammarGLM,
		"Jundot/GLM-5.3-Flash-oQ4e-mtp":            toolGrammarGLM,
		"z-ai/glm-4.5-air":                         toolGrammarGLM,
		"meta-llama/llama-3.1-8b-instruct":         toolGrammarLlama3,
		"mlx-community/Llama-3.2-3B-Instruct-4bit": toolGrammarLlama3,
		"google-gemma-4-26b-a4b-it":                toolGrammarGemma4,
		"nvidia/nemotron-3-nano-30b-a3b":           toolGrammarQwen,
		"qwen3-8b":                                 toolGrammarQwen,
		"qwen3-coder-30b-a3b-instruct":             toolGrammarQwen,
		"qwen2.5-coder-32b-instruct":               toolGrammarQwen,
		"qwen/qwen3.6-35b-a3b":                     toolGrammarQwen,
		"openai/gpt-oss-20b":                       toolGrammarHarmony,
		"mlx-community/Qwen2-VL-2B-Instruct-4bit":  "",
		"qwen2-vl-2b-instruct":                     "",
		"some/unknown-model":                       "",
	} {
		if got := toolGrammarFamily(model); got != want {
			t.Errorf("toolGrammarFamily(%q)=%q want %q", model, got, want)
		}
	}
}

func TestToolsUnsupportedForModelGate(t *testing.T) {
	configureGateCatalog(t)
	withTools := func(model string) chatRequest {
		body, _ := json.Marshal(map[string]any{
			"model":    model,
			"messages": []map[string]any{{"role": "user", "content": "hi"}},
			"tools":    []map[string]any{{"type": "function", "function": map[string]any{"name": "lookup", "parameters": map[string]any{"type": "object"}}}},
		})
		req, status, code, msg := validateChatRequest(body)
		if status != 0 {
			t.Fatalf("validateChatRequest status=%d code=%s msg=%s", status, code, msg)
		}
		req.declaresTools = requestDeclaresTools(req.raw)
		return req
	}
	ids := func() []string { return []string{gateLlama32ID, gateQwen36ID} }
	if status, code, _ := unsupportedToolsModel(withTools(gateLlama32ID), ids, nil, nil); status != http.StatusBadRequest || code != "tools_unsupported_for_model" {
		t.Fatalf("tool-less family: status=%d code=%s want 400 tools_unsupported_for_model", status, code)
	}
	if status, _, _ := unsupportedToolsModel(withTools(gateQwen36ID), ids, nil, nil); status != 0 {
		t.Fatalf("tool family rejected: %d", status)
	}
	if status, _, _ := unsupportedToolsModel(withTools("byom/unresolved"), ids, nil, nil); status != 0 {
		t.Fatalf("unresolved BYOM model keeps provider-side behavior, got %d", status)
	}
	external := withTools(gateLlama32ID)
	external.engineClass = "ollama_loopback"
	if status, _, _ := unsupportedToolsModel(external, ids, nil, nil); status != 0 {
		t.Fatalf("an external runtime route keeps provider-side behavior, got %d", status)
	}
	noTools := withTools(gateLlama32ID)
	noTools.declaresTools = false
	if status, _, _ := unsupportedToolsModel(noTools, ids, nil, nil); status != 0 {
		t.Fatalf("a request without tools is never gated, got %d", status)
	}
}

func TestModelCapabilitiesFollowEnforcedPredicates(t *testing.T) {
	native := selectionProvider()
	native.MaxContextTokens = 65536
	caps := mergeModelCapabilities(nil, native, false)
	entry := modelEntry{Capabilities: caps}
	finishModelCapabilities(&entry)
	if !caps.Tools || strings.Join(caps.ToolChoice, ",") != "auto,none,required,named" || !caps.ResponseFormat || caps.Vision || caps.ContextLength != 65536 {
		t.Fatalf("capabilities=%+v", caps)
	}
	if !strings.Contains(strings.Join(entry.SupportedParameters, ","), "tool_choice") {
		t.Fatalf("supported_parameters=%v", entry.SupportedParameters)
	}

	glm := pool.Provider{ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", MaxContextTokens: 32768, BinaryVersion: toolGrammarProviderMinVersion}
	caps = mergeModelCapabilities(nil, glm, false)
	if !caps.Tools || !caps.Reasoning || strings.Join(caps.ToolChoice, ",") != "auto" {
		t.Fatalf("glm capabilities=%+v (no declared modes means auto only)", caps)
	}
	// An older provider that does not parse GLM calls is not advertised.
	old := glm
	old.BinaryVersion = "1.8.261"
	if caps := mergeModelCapabilities(nil, old, false); caps.Tools || caps.Reasoning {
		t.Fatalf("pre-#2107 GLM provider capabilities=%+v", caps)
	}
	// Families an older provider already served keep tools.
	qwen := pool.Provider{ModelID: "mlx-community/Qwen3-8B-4bit", BinaryVersion: "1.8.200"}
	if caps := mergeModelCapabilities(nil, qwen, false); !caps.Tools {
		t.Fatalf("legacy qwen capabilities=%+v", caps)
	}

	vl := pool.Provider{ModelID: "mlx-community/Qwen2-VL-2B-Instruct-4bit", MaxContextTokens: 4096}
	caps = mergeModelCapabilities(nil, vl, true)
	entry = modelEntry{Capabilities: caps}
	finishModelCapabilities(&entry)
	if caps.Tools || !caps.Vision || strings.Contains(strings.Join(entry.SupportedParameters, ","), "tools") {
		t.Fatalf("qwen2-vl capabilities=%+v params=%v", caps, entry.SupportedParameters)
	}
}

func TestReasoningContentDeltaCountsAsCommitSignal(t *testing.T) {
	if inspectOpenAIDeltaSignal(json.RawMessage(`{"reasoning_content":"thinking"}`)) != deltaSignalWorthy {
		t.Fatal("a reasoning_content delta is provider work")
	}
	if inspectOpenAIDeltaSignal(json.RawMessage(`{"reasoning_content":""}`)) == deltaSignalWorthy {
		t.Fatal("an empty reasoning_content delta is not")
	}
}

func TestProviderFailureFrameCarriesReasonCode(t *testing.T) {
	for status, want := range map[string]string{
		"error_context_exceeded":                  "error_context_exceeded",
		"continuous_batching_request_failed":      "continuous_batching_request_failed",
		"Bad Reason with spaces":                  "provider_error",
		"":                                        "provider_error",
		strings.Repeat("a", 65):                   "provider_error",
		"upstream\nprovider_error":                "provider_error",
		"continuous_batching_stream_backpressure": "continuous_batching_stream_backpressure",
	} {
		if got := providerFailureReason(status); got != want {
			t.Errorf("providerFailureReason(%q)=%q want %q", status, got, want)
		}
	}
	rr := httptest.NewRecorder()
	writeSSEProviderFailure(rr, "error_context_exceeded", "req_1")
	body := rr.Body.String()
	if !strings.Contains(body, `"code":"provider_error"`) || !strings.Contains(body, `"reason":"error_context_exceeded"`) ||
		!strings.Contains(body, "Provider failed during streaming (error_context_exceeded)") || !strings.HasSuffix(body, "data: [DONE]\n\n") {
		t.Fatalf("frame=%s", body)
	}
}
