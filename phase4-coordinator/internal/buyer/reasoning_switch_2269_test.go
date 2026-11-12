package buyer

import (
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-018 v0.3.16 / SPEC-006 v0.9.75 (#2269): /v1/models advertises
// reasoning for a thinking-switch family only when an eligible provider
// renders thinking on for an explicit reasoning_effort and splits its output.
func TestOnRequestReasoningCapabilityMatchesWhatIsServed(t *testing.T) {
	reasons := func(p pool.Provider) bool {
		caps := mergeModelCapabilities(nil, p, false)
		entry := modelEntry{Capabilities: caps}
		finishModelCapabilities(&entry)
		hasParam := strings.Contains(strings.Join(entry.SupportedParameters, ","), "reasoning_effort")
		if caps.Reasoning != hasParam {
			t.Fatalf("%s: reasoning=%v but supported_parameters=%v", p.ModelID, caps.Reasoning, entry.SupportedParameters)
		}
		return caps.Reasoning
	}
	for _, model := range []string{
		"mlx-community/Qwen3.5-27B-4bit", "mlx-community/Qwen3.5-35B-A3B-4bit",
		"mlx-community/Qwen3.6-27B-4bit", "mlx-community/Qwen3.6-35B-A3B-4bit",
		"mlx-community/Qwen3.8-27B-4bit", "mlx-community/NVIDIA-Nemotron-3-Nano-30B-A3B-4bit",
		"mlx-community/NVIDIA-Nemotron-3.5-Lightning-30B-A3B-4bit",
	} {
		p := pool.Provider{ModelID: model, BinaryVersion: onRequestReasoningProviderMinVersion}
		if !reasons(p) {
			t.Fatalf("%s at %s must advertise reasoning", model, p.BinaryVersion)
		}
		old := p
		old.BinaryVersion = "1.8.283"
		if reasons(old) {
			t.Fatalf("%s on a provider that keeps thinking off must not advertise reasoning", model)
		}
		external := p
		external.RuntimeSource = "ollama"
		if reasons(external) {
			t.Fatalf("%s on an external runtime must not advertise reasoning", model)
		}
		head := p
		head.ShardGroupHeadV1 = true
		if reasons(head) {
			t.Fatalf("%s on a shard group head must not advertise reasoning", model)
		}
	}
	// Thinking-switch families whose output the provider cannot split, and
	// families with no switch, keep their prior capability.
	for _, model := range []string{
		"mlx-community/Qwen3-8B-4bit", "mlx-community/GLM-4.5-Air-4bit", "mlx-community/gemma-4-26b-a4b-it-4bit",
		"mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit", "mlx-community/Meta-Llama-3.1-8B-Instruct-4bit",
	} {
		if reasons(pool.Provider{ModelID: model, BinaryVersion: "999.0.0"}) {
			t.Fatalf("%s must not advertise reasoning", model)
		}
	}
	// Families that always reason are unchanged.
	if !reasons(pool.Provider{ModelID: "Jundot/GLM-5.3-Flash-oQ4e-mtp", BinaryVersion: toolGrammarProviderMinVersion}) {
		t.Fatal("GLM-5.3 keeps reasoning")
	}
}
