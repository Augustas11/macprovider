package buyer

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// toolGrammarFamily mirrors ToolCallGrammar.family(modelID:) in
// phase3-binary/Sources/MacProviderCore/ToolCallGrammar.swift for every
// catalog row (#2107 D1/D4).
func TestToolGrammarFamilyCoversEveryCatalogFamily(t *testing.T) {
	for model, want := range map[string]string{
		"zai-org/glm-5.3-flash":                       toolGrammarGLM,
		"Jundot/GLM-5.3-Flash-oQ4e-mtp":               toolGrammarGLM,
		"z-ai/glm-4.5-air":                            toolGrammarGLM,
		"meta-llama/llama-3.1-8b-instruct":            toolGrammarLlama3,
		"mlx-community/Llama-3.2-3B-Instruct-4bit":    toolGrammarLlama3,
		"google-gemma-4-26b-a4b-it":                   toolGrammarGemma4,
		"nvidia/nemotron-3-nano-30b-a3b":              toolGrammarQwen,
		"qwen3-8b":                                    toolGrammarQwen,
		"qwen3-coder-30b-a3b-instruct":                toolGrammarQwen,
		"qwen2.5-coder-32b-instruct":                  toolGrammarQwen,
		"qwen/qwen3.6-35b-a3b":                        toolGrammarQwen,
		"openai/gpt-oss-20b":                          toolGrammarHarmony,
		"deepseek/deepseek-v4-flash":                  toolGrammarDSML,
		"TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX": toolGrammarDSML,
		"mlx-community/Qwen2-VL-2B-Instruct-4bit":     "",
		"qwen2-vl-2b-instruct":                        "",
		"some/unknown-model":                          "",
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

func TestToolRequestsReachOnlyProvidersThatParseTheGrammar(t *testing.T) {
	oldGLM := pool.Provider{ProviderID: "old", ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", BinaryVersion: "1.8.261"}
	newGLM := pool.Provider{ProviderID: "new", ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", BinaryVersion: toolGrammarProviderMinVersion}
	got := toolGrammarEligibleProviders([]pool.Provider{oldGLM, newGLM})
	if len(got) != 1 || got[0].ProviderID != "new" {
		t.Fatalf("eligible=%v want only the upgraded provider", got)
	}
	if providerToolGrammarEligible(oldGLM) {
		t.Fatal("a pre-#2107 GLM provider cannot serve tool requests (pins and queued reconnects use this predicate)")
	}
	legacy := pool.Provider{ProviderID: "q", ModelID: "mlx-community/Qwen3-8B-4bit", BinaryVersion: "1.8.100"}
	external := pool.Provider{ProviderID: "x", ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", RuntimeSource: "ollama_loopback"}
	if got := toolGrammarEligibleProviders([]pool.Provider{legacy, external, newGLM}); len(got) != 3 {
		t.Fatalf("legacy families and external runtimes stay eligible: %v", got)
	}
	if err := toolGrammarProviderUnavailableRouteError(); err.status != 503 || !spec018Retryable(err.code) {
		t.Fatalf("route error=%+v", err)
	}
}

func TestBuyerUXConformanceMasksFailedCapabilities(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/buyer-ux-conformance.json"
	body := `{"schema_version":"macprovider.buyer-ux-conformance.v1","records":{"zai-org/glm-5.3-flash":{"model":"Jundot/GLM-5.3-Flash-oQ4e-mtp","gateway":"https://api.malibu.tech/v1","checked_at":"2026-10-22T00:00:00Z","checks":{},"capabilities":{"base":true,"tools":false,"tool_choice":[],"reasoning":true,"response_format":false,"messages":true,"responses":true}}}}`
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	records, err := LoadBuyerUXConformance(path)
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now().UTC())
	s.SetBuyerUXConformance(records)
	glm := pool.Provider{ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", BinaryVersion: toolGrammarProviderMinVersion}
	entry := modelEntry{ID: glm.ModelID, Capabilities: mergeModelCapabilities(nil, glm, false)}
	s.applyBuyerUXConformance(&entry)
	finishModelCapabilities(&entry)
	if entry.Capabilities.Tools || entry.Capabilities.ResponseFormat || !entry.Capabilities.Reasoning || len(entry.Capabilities.ToolChoice) != 0 {
		t.Fatalf("masked capabilities=%+v", entry.Capabilities)
	}
	if strings.Contains(strings.Join(entry.SupportedParameters, ","), "tools") {
		t.Fatalf("supported_parameters=%v", entry.SupportedParameters)
	}
	// A model without a record keeps the derived set.
	qwen := pool.Provider{ModelID: "mlx-community/Qwen3-8B-4bit"}
	other := modelEntry{ID: qwen.ModelID, Capabilities: mergeModelCapabilities(nil, qwen, false)}
	s.applyBuyerUXConformance(&other)
	if !other.Capabilities.Tools {
		t.Fatal("unrecorded model lost tools")
	}
	if _, err := LoadBuyerUXConformance(dir + "/absent.json"); err == nil {
		t.Fatal("an unreadable record file must be an error")
	}
	// The checked-in record file loads.
	if _, err := LoadBuyerUXConformance("../../../phase3-binary/catalog/autotune/buyer-ux-conformance.json"); err != nil {
		t.Fatal(err)
	}
}

// The checked-in live records (#2107): Llama-3.2-3B failed tool_round_trip, so
// /v1/models drops tools for it; GLM-5.3-Flash passed everything and keeps its
// derived set.
func TestCheckedInBuyerUXConformanceRecords(t *testing.T) {
	records, err := LoadBuyerUXConformance("../../../phase3-binary/catalog/autotune/buyer-ux-conformance.json")
	if err != nil {
		t.Fatal(err)
	}
	s := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now().UTC())
	s.SetBuyerUXConformance(records)
	entryFor := func(model string, conform bool) modelEntry {
		p := pool.Provider{ModelID: model, BinaryVersion: toolGrammarProviderMinVersion}
		entry := modelEntry{ID: model, Capabilities: mergeModelCapabilities(nil, p, false)}
		if conform {
			s.applyBuyerUXConformance(&entry)
		}
		finishModelCapabilities(&entry)
		return entry
	}
	llama := entryFor("mlx-community/Llama-3.2-3B-Instruct-4bit", true)
	if !entryFor("mlx-community/Llama-3.2-3B-Instruct-4bit", false).Capabilities.Tools {
		t.Fatal("Llama-3.2 must derive tools before the record masks it")
	}
	if llama.Capabilities.Tools || len(llama.Capabilities.ToolChoice) != 0 || !llama.Capabilities.ResponseFormat {
		t.Fatalf("llama capabilities=%+v", llama.Capabilities)
	}
	if strings.Contains(strings.Join(llama.SupportedParameters, ","), "tool") {
		t.Fatalf("llama supported_parameters=%v", llama.SupportedParameters)
	}
	glm := entryFor("Jundot/GLM-5.3-Flash-oQ4e-mtp", true)
	derived := entryFor("Jundot/GLM-5.3-Flash-oQ4e-mtp", false)
	if !reflect.DeepEqual(glm.Capabilities, derived.Capabilities) || !reflect.DeepEqual(glm.SupportedParameters, derived.SupportedParameters) {
		t.Fatalf("glm capabilities changed: got %+v want %+v", glm.Capabilities, derived.Capabilities)
	}
	if !glm.Capabilities.Tools || !glm.Capabilities.Reasoning {
		t.Fatalf("glm capabilities=%+v", glm.Capabilities)
	}
}

// SPEC-023 §16.11 fail-closed reload: an unreadable, malformed or oversized
// record file never widens what /v1/models publishes. At boot that means no
// records (every model keeps its derived set); after a good load the records
// in force stay.
func TestReloadBuyerUXConformanceKeepsRecordsInForce(t *testing.T) {
	dir := t.TempDir()
	path := dir + "/buyer-ux-conformance.json"
	s := NewServer(pool.NewRegistry(nil), zerolog.Nop(), time.Now().UTC())
	if _, err := s.ReloadBuyerUXConformance(path); err == nil {
		t.Fatal("a missing record file must be an error")
	}
	if sha, n := s.BuyerUXConformanceStatus(); sha != "" || n != 0 {
		t.Fatalf("status after a failed first load: %q %d", sha, n)
	}
	good := `{"schema_version":"macprovider.buyer-ux-conformance.v1","records":{"k":{"model":"mlx-community/Llama-3.2-3B-Instruct-4bit","capabilities":{"tools":false,"tool_choice":[],"reasoning":true,"response_format":true}}}}`
	if err := os.WriteFile(path, []byte(good), 0o600); err != nil {
		t.Fatal(err)
	}
	changed, err := s.ReloadBuyerUXConformance(path)
	if err != nil || !changed {
		t.Fatalf("good load: changed=%v err=%v", changed, err)
	}
	sha, n := s.BuyerUXConformanceStatus()
	if len(sha) != 64 || n != 1 {
		t.Fatalf("status after a good load: %q %d", sha, n)
	}
	if changed, err := s.ReloadBuyerUXConformance(path); err != nil || changed {
		t.Fatalf("same bytes: changed=%v err=%v", changed, err)
	}
	masked := func() bool {
		p := pool.Provider{ModelID: "mlx-community/Llama-3.2-3B-Instruct-4bit", BinaryVersion: toolGrammarProviderMinVersion}
		entry := modelEntry{ID: p.ModelID, Capabilities: mergeModelCapabilities(nil, p, false)}
		s.applyBuyerUXConformance(&entry)
		return !entry.Capabilities.Tools
	}
	if !masked() {
		t.Fatal("the loaded record does not mask tools")
	}
	for name, body := range map[string][]byte{
		"malformed":       []byte(`{"records":`),
		"wrong schema":    []byte(`{"schema_version":"v0","records":{}}`),
		"missing fields":  []byte(`{"schema_version":"macprovider.buyer-ux-conformance.v1","records":{"k":{"model":"m"}}}`),
		"missing records": []byte(`{"schema_version":"macprovider.buyer-ux-conformance.v1"}`),
		"null records":    []byte(`{"schema_version":"macprovider.buyer-ux-conformance.v1","records":null}`),
		"oversized":       append([]byte(good), bytes.Repeat([]byte(" "), buyerUXConformanceMaxBytes)...),
	} {
		if err := os.WriteFile(path, body, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ReloadBuyerUXConformance(path); err == nil {
			t.Fatalf("%s record file was accepted", name)
		}
		if got, _ := s.BuyerUXConformanceStatus(); got != sha || !masked() {
			t.Fatalf("%s record file changed the records in force", name)
		}
	}
	// A FIFO at the path is refused without blocking (no writer is ever
	// attached).
	fifo := dir + "/fifo.json"
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := s.ReloadBuyerUXConformance(fifo); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("a FIFO record path was accepted")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a FIFO record path blocked the reload")
	}
	if got, _ := s.BuyerUXConformanceStatus(); got != sha || !masked() {
		t.Fatal("a FIFO record path changed the records in force")
	}
	if changed, err := s.ReloadBuyerUXConformance(""); err != nil || !changed {
		t.Fatalf("clearing the path: changed=%v err=%v", changed, err)
	}
	if got, n := s.BuyerUXConformanceStatus(); got != "" || n != 0 || masked() {
		t.Fatalf("cleared path still masks: %q %d", got, n)
	}
}
