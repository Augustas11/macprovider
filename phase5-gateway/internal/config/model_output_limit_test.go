package config

import (
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

func TestNormalizeModelKeyMatchesCoordinatorAliases(t *testing.T) {
	for want, spellings := range map[string][]string{
		"zai-org/glm-5.3-flash":             {"glm-5.3-flash", "zai-org/glm-5.3-flash", "ZAI-ORG/GLM-5.3-Flash", "z-ai/glm-5.3-flash", "Jundot/GLM-5.3-Flash-oQ4e-mtp"},
		"zai-org/glm-5.3-flash-abliterated": {"zai-org/glm-5.3-flash-abliterated", "z-ai/glm-5.3-flash-abliterated", "grant-ai/GLM-5.3-Flash-Abliterated-MLX-4bit"},
		"zai-org/glm-5.3-flash-uncensored":  {"zai-org/glm-5.3-flash-uncensored", "z-ai/glm-5.3-flash-uncensored", "Solstice-AI/GLM-5.3-Flash-UNCENSORED-mlx-oQ4e-DFlash2"},
		"openai/gpt-oss-20b":                {"openai/gpt-oss-20b", "mlx-community/gpt-oss-20b-MXFP4-Q8"},
		"deepseek/deepseek-v4-flash":        {"deepseek/deepseek-v4-flash", "TensorFold/DeepSeek-V4-Flash-0731-MXFP4-MLX"},
	} {
		for _, spelling := range spellings {
			if got := NormalizeModelKey(spelling); got != want {
				t.Errorf("NormalizeModelKey(%q)=%q want %q", spelling, got, want)
			}
		}
	}
	// A foreign namespace must not collapse into another vendor's key.
	if got := NormalizeModelKey("qwen/glm-5.3-flash"); got == "zai-org/glm-5.3-flash" {
		t.Fatalf("qwen/glm-5.3-flash collapsed into the GLM catalog key")
	}
}

func TestMaxOutputTokensForModel(t *testing.T) {
	limits := Default().Limits
	if got := limits.MaxOutputTokensForModel("zai-org/glm-5.3-flash"); got != 32768 {
		t.Fatalf("no override: limit=%d want the gateway-wide 32768", got)
	}
	limits.ModelMaxOutputTokens = map[string]int64{"zai-org/glm-5.3-flash": 131072}
	for _, model := range []string{"glm-5.3-flash", "zai-org/glm-5.3-flash", "Jundot/GLM-5.3-Flash-oQ4e-mtp"} {
		if got := limits.MaxOutputTokensForModel(model); got != 131072 {
			t.Errorf("MaxOutputTokensForModel(%q)=%d want 131072", model, got)
		}
	}
	for _, model := range []string{"zai-org/glm-5.3-flash-abliterated", "llama", ""} {
		if got := limits.MaxOutputTokensForModel(model); got != 32768 {
			t.Errorf("MaxOutputTokensForModel(%q)=%d want the gateway-wide 32768", model, got)
		}
	}
}

func TestModelMaxOutputTokensValidation(t *testing.T) {
	cases := []struct {
		name    string
		limits  map[string]int64
		wantErr string
	}{
		{name: "valid", limits: map[string]int64{"zai-org/glm-5.3-flash": 131072, "llama": 1024}},
		{name: "ceiling allowed", limits: map[string]int64{"zai-org/glm-5.3-flash": ModelMaxOutputTokensCeiling}},
		{name: "zero", limits: map[string]int64{"zai-org/glm-5.3-flash": 0}, wantErr: "must be in 1..262144"},
		{name: "negative", limits: map[string]int64{"zai-org/glm-5.3-flash": -1}, wantErr: "must be in 1..262144"},
		{name: "above ceiling", limits: map[string]int64{"zai-org/glm-5.3-flash": ModelMaxOutputTokensCeiling + 1}, wantErr: "must be in 1..262144"},
		{name: "empty key", limits: map[string]int64{"  ": 1024}, wantErr: "non-empty model ids"},
		{name: "aliases collide", limits: map[string]int64{"zai-org/glm-5.3-flash": 65536, "Jundot/GLM-5.3-Flash-oQ4e-mtp": 131072}, wantErr: "name the same model"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.Limits.ModelMaxOutputTokens = tc.limits
			err := cfg.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("Validate() err=%v want nil", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("Validate() err=%v want substring %q", err, tc.wantErr)
			}
		})
	}
}

func TestModelMaxOutputTokensDecodesFromYAML(t *testing.T) {
	var cfg Config
	raw := "limits:\n  max_tokens_per_request: 32768\n  model_max_output_tokens:\n    zai-org/glm-5.3-flash: 131072\n"
	if err := yaml.Unmarshal([]byte(raw), &cfg); err != nil {
		t.Fatal(err)
	}
	if got := cfg.Limits.ModelMaxOutputTokens["zai-org/glm-5.3-flash"]; got != 131072 {
		t.Fatalf("decoded limit=%d want 131072", got)
	}
}
