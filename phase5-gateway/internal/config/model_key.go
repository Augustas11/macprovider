package config

import "strings"

// NormalizeModelKey mirrors the coordinator's billing.NormalizeModelKey (the
// model equivalence routing and billing use), so a gateway per-model setting
// keyed by a catalog id also applies to that id's accepted aliases. The
// gateway is a separate module and cannot import the coordinator; keep the
// two in step. TestNormalizeModelKeyMatchesCoordinatorAliases pins the
// spellings that must collapse.
func NormalizeModelKey(model string) string {
	key := strings.ToLower(strings.TrimSpace(model))
	namespace := ""
	if slash := strings.IndexByte(key, '/'); slash >= 0 {
		namespace = key[:slash]
		switch namespace {
		case "mlx-community", "openai", "google", "meta-llama", "nvidia", "qwen":
			key = key[slash+1:]
		}
	}
	for _, suffix := range []string{"-free", "-mxfp4-q8", "-4bit", "-8bit"} {
		key = strings.TrimSuffix(key, suffix)
	}
	normalized := normalizeServedModelAlias(namespace, key)
	if catalogKey, ok := exactModelKeyAliases[normalized]; ok {
		return catalogKey
	}
	return normalized
}

var exactModelKeyAliases = map[string]string{
	"z-ai/glm-5.3-flash":                                    "zai-org/glm-5.3-flash",
	"jundot/glm-5.3-flash-oq4e-mtp":                         "zai-org/glm-5.3-flash",
	"z-ai/glm-5.3-flash-abliterated":                        "zai-org/glm-5.3-flash-abliterated",
	"grant-ai/glm-5.3-flash-abliterated-mlx":                "zai-org/glm-5.3-flash-abliterated",
	"z-ai/glm-5.3-flash-uncensored":                         "zai-org/glm-5.3-flash-uncensored",
	"solstice-ai/glm-5.3-flash-uncensored-mlx-oq4e-dflash2": "zai-org/glm-5.3-flash-uncensored",
	"frogggias/ripple-65b-preview-mlx":                      "ricursiveai/ripple-65b-preview",
	"liquidai/lfm3-1.7b-mlx":                                "liquidai/lfm3-1.7b",
	"minimax-m3.1-flash-oq3e-mtp":                           "minimaxai/minimax-m3.1-flash",
	"minimax/minimax-m3.1-flash":                            "minimaxai/minimax-m3.1-flash",
	"tensorfold/deepseek-v4-flash-0731-mxfp4-mlx":           "deepseek/deepseek-v4-flash",
	"deepseek-ai/deepseek-v4-flash-0731":                    "deepseek/deepseek-v4-flash",
}

func normalizeServedModelAlias(namespace, key string) string {
	served := func(vendor string) bool {
		return namespace == "" || namespace == "mlx-community" || namespace == vendor
	}
	switch {
	case served("meta-llama") && strings.HasPrefix(key, "llama-"):
		return "meta-llama/" + key
	case served("meta-llama") && strings.HasPrefix(key, "meta-llama-"):
		return "meta-llama/" + strings.TrimPrefix(key, "meta-")
	case served("nvidia") && strings.HasPrefix(key, "nvidia-nemotron-"):
		return strings.TrimPrefix(key, "nvidia-")
	case served("openai") && strings.HasPrefix(key, "gpt-oss-"):
		return "openai/" + key
	case served("z-ai") && strings.HasPrefix(key, "glm-"):
		return "z-ai/" + key
	default:
		return key
	}
}
