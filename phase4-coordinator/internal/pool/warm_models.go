package pool

// WarmModelState is a SPEC-001-R016 `warm_models[].state` value.
type WarmModelState string

const (
	WarmModelLoading  WarmModelState = "loading"
	WarmModelWarm     WarmModelState = "warm"
	WarmModelEvicting WarmModelState = "evicting"
)

// ValidWarmModelState reports whether s is one of the three R016 states.
func ValidWarmModelState(s WarmModelState) bool {
	switch s {
	case WarmModelLoading, WarmModelWarm, WarmModelEvicting:
		return true
	default:
		return false
	}
}

// WarmModel is one member of a provider's SPEC-001-R016 warm set as the
// provider reported it (SPEC-002-R011). The primary member repeats the
// session's top-level model fields.
type WarmModel struct {
	ModelID               string               `json:"model_id"`
	State                 WarmModelState       `json:"state"`
	Primary               bool                 `json:"primary"`
	Pinned                bool                 `json:"pinned"`
	SlotsTotal            int                  `json:"slots_total"`
	SlotsFree             int                  `json:"slots_free"`
	MaxContextTokens      int                  `json:"max_context_tokens,omitempty"`
	ThroughputTPSEstimate float64              `json:"throughput_tps_estimate,omitempty"`
	ModelParamsB          float64              `json:"model_params_b,omitempty"`
	ModelHash             string               `json:"model_hash,omitempty"`
	ModelHashAlgorithm    string               `json:"model_hash_algorithm,omitempty"`
	WeightsManifestSHA256 string               `json:"weights_manifest_sha256,omitempty"`
	WeightsHashAlgorithm  string               `json:"weights_manifest_algorithm,omitempty"`
	CBSelfCheck           *ProviderCBSelfCheck `json:"cb_self_check,omitempty"`
	EngineProfile         *EngineProfile       `json:"-"`
}
