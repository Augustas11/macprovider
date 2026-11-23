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
		"rapid-mlx/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-MLX-4bit",
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

// DaisyRose-27B (#2465) ships the Qwen3.8-27B template, but only a CLI from
// the DaisyRose cut on maps its exact ids to it: 1.8.296 advertises neither
// reasoning nor tools for it, and look-alike ids never inherit the family.
func TestDaisyRoseReasoningAndToolsNeedTheDaisyRoseCLI(t *testing.T) {
	for _, model := range []string{"radixark/daisyrose-27b", "mlx-community/DaisyRose-27B-4bit", "daisyrose-27b"} {
		if got := toolGrammarFamily(model); got != toolGrammarQwen {
			t.Fatalf("%s: tool grammar family %q, want qwen", model, got)
		}
		for version, want := range map[string]bool{"1.8.285": false, "1.8.296": false, daisyRoseProviderMinVersion: true, "1.8.300": true} {
			p := pool.Provider{ModelID: model, BinaryVersion: version, MaxContextTokens: 32768}
			caps := mergeModelCapabilities(nil, p, false)
			if caps.Reasoning != want || caps.Tools != want {
				t.Fatalf("%s at %s: reasoning=%v tools=%v, want %v", model, version, caps.Reasoning, caps.Tools, want)
			}
			if providerParsesToolGrammar(p) != want || providerToolGrammarEligible(p) != want {
				t.Fatalf("%s at %s: tool grammar eligibility must be %v", model, version, want)
			}
			if !want {
				continue
			}
			external := p
			external.RuntimeSource = "ollama"
			if mergeModelCapabilities(nil, external, false).Reasoning {
				t.Fatalf("%s on an external runtime must not advertise reasoning", model)
			}
			head := p
			head.ShardGroupHeadV1 = true
			if caps := mergeModelCapabilities(nil, head, false); caps.Reasoning || caps.Tools {
				t.Fatalf("%s on a shard group head: %+v", model, caps)
			}
		}
	}
	for _, lookalike := range []string{"radixark/daisyrose-27b-v2", "other/daisyrose", "daisyrose"} {
		p := pool.Provider{ModelID: lookalike, BinaryVersion: "1.8.300"}
		if toolGrammarFamily(lookalike) != "" || onRequestReasoningFamily(lookalike) || mergeModelCapabilities(nil, p, false).Reasoning {
			t.Fatalf("%s must not inherit the DaisyRose family", lookalike)
		}
	}
}
