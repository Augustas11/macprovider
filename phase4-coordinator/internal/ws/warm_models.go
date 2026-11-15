package ws

import (
	"encoding/json"
	"fmt"
	"math"
	"reflect"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-001-R016 bounds each warm_models entry like its top-level counterpart
// and the array by supported_models (at most 64 entries, SPEC-010).
const (
	maxWarmModels             = 64
	maxWarmModelSlots         = 4096
	maxWarmModelContextTokens = 10_000_000
	maxWarmModelThroughputTPS = 1_000_000
	maxWarmModelParamsB       = 100_000
	warmModelsField           = "warm_models"
)

// warmModelsPrimaryFieldKeys are the top-level fields the primary entry
// repeats (SPEC-001-R016 "Primary model"); a primary entry that disagrees with
// any of them contradicts the message it rides on.
var warmModelsPrimaryFieldKeys = []string{
	"model_id",
	"max_context_tokens",
	"throughput_tps_estimate",
	"model_hash",
	"model_hash_algorithm",
	"weights_manifest_sha256",
	"weights_manifest_algorithm",
	"model_params_b",
	"cb_self_check",
	"engine_profile",
}

// warmModelsTopLevel is what the primary entry is checked against beyond the
// repeated keys. Only a heartbeat reports slots and loading at top level.
type warmModelsTopLevel struct {
	ramGB          int
	slotsReported  bool
	slotsTotal     int
	slotsFree      int
	loadingPresent bool
	loading        bool
}

// parseWarmModels decodes the optional SPEC-001-R016 `warm_models` array. An
// absent key returns nil (a provider without a warm set). Every malformed
// array, including one whose primary entry contradicts the top-level fields,
// is rejected whole (SPEC-002-R011).
func parseWarmModels(raw map[string]json.RawMessage, top warmModelsTopLevel) ([]pool.WarmModel, error) {
	v, ok := raw[warmModelsField]
	if !ok {
		return nil, nil
	}
	var entries []map[string]json.RawMessage
	if string(v) == "null" || json.Unmarshal(v, &entries) != nil {
		return nil, fmt.Errorf("warm_models must be an array of objects")
	}
	if len(entries) == 0 || len(entries) > maxWarmModels {
		return nil, fmt.Errorf("warm_models must have 1..%d entries", maxWarmModels)
	}
	out := make([]pool.WarmModel, 0, len(entries))
	seen := make(map[string]struct{}, len(entries))
	for i, entry := range entries {
		if entry == nil {
			return nil, fmt.Errorf("warm_models[%d] must be an object", i)
		}
		model, err := parseWarmModelEntry(entry, top.ramGB)
		if err != nil {
			return nil, fmt.Errorf("warm_models[%d]: %w", i, err)
		}
		if model.Primary != (i == 0) {
			return nil, fmt.Errorf("warm_models must list exactly one primary entry, first")
		}
		key := normalizeSupportedModelEntry(model.ModelID)
		if _, dup := seen[key]; dup {
			return nil, fmt.Errorf("warm_models[%d]: duplicate model_id", i)
		}
		seen[key] = struct{}{}
		out = append(out, model)
	}
	if err := checkWarmModelsPrimary(raw, entries[0], out[0], top); err != nil {
		return nil, err
	}
	return out, nil
}

func parseWarmModelEntry(entry map[string]json.RawMessage, ramGB int) (pool.WarmModel, error) {
	var model pool.WarmModel
	if err := requireString(entry, "model_id", &model.ModelID); err != nil {
		return pool.WarmModel{}, err
	}
	if len([]byte(model.ModelID)) > maxHandshakeModelIDBytes {
		return pool.WarmModel{}, fmt.Errorf("model_id exceeds %d bytes", maxHandshakeModelIDBytes)
	}
	var state string
	if err := requireString(entry, "state", &state); err != nil {
		return pool.WarmModel{}, err
	}
	model.State = pool.WarmModelState(state)
	if !pool.ValidWarmModelState(model.State) {
		return pool.WarmModel{}, fmt.Errorf("unknown state")
	}
	if err := requireBool(entry, "primary", &model.Primary); err != nil {
		return pool.WarmModel{}, err
	}
	if err := requireBool(entry, "pinned", &model.Pinned); err != nil {
		return pool.WarmModel{}, err
	}
	if err := requireInt(entry, "slots_total", &model.SlotsTotal); err != nil {
		return pool.WarmModel{}, err
	}
	if model.SlotsTotal < 0 || model.SlotsTotal > maxWarmModelSlots {
		return pool.WarmModel{}, fmt.Errorf("slots_total must be in 0..%d", maxWarmModelSlots)
	}
	if v, ok := entry["slots_free"]; ok {
		if model.State != pool.WarmModelWarm {
			return pool.WarmModel{}, fmt.Errorf("slots_free on a %s entry", model.State)
		}
		if string(v) == "null" || json.Unmarshal(v, &model.SlotsFree) != nil {
			return pool.WarmModel{}, fmt.Errorf("slots_free must be an integer")
		}
		if model.SlotsFree < 0 || model.SlotsFree > model.SlotsTotal {
			return pool.WarmModel{}, fmt.Errorf("slots_free must be in 0..slots_total")
		}
	}
	if v, ok := entry["max_context_tokens"]; ok {
		if string(v) == "null" || json.Unmarshal(v, &model.MaxContextTokens) != nil ||
			model.MaxContextTokens < 0 || model.MaxContextTokens > maxWarmModelContextTokens {
			return pool.WarmModel{}, fmt.Errorf("max_context_tokens must be an integer in 0..%d", maxWarmModelContextTokens)
		}
	}
	for _, f := range []struct {
		field string
		out   *float64
		max   float64
	}{
		{"throughput_tps_estimate", &model.ThroughputTPSEstimate, maxWarmModelThroughputTPS},
		{"model_params_b", &model.ModelParamsB, maxWarmModelParamsB},
	} {
		v, ok := entry[f.field]
		if !ok {
			continue
		}
		if string(v) == "null" || json.Unmarshal(v, f.out) != nil ||
			math.IsNaN(*f.out) || math.IsInf(*f.out, 0) || *f.out < 0 || *f.out > f.max {
			return pool.WarmModel{}, fmt.Errorf("%s must be a number in 0..%v", f.field, f.max)
		}
	}
	if v, ok := entry["model_hash"]; ok {
		if string(v) == "null" || json.Unmarshal(v, &model.ModelHash) != nil || containsControlChar(model.ModelHash) {
			return pool.WarmModel{}, fmt.Errorf("model_hash must be a string")
		}
	}
	if field, err := parseModelIdentityMetadata(
		entry,
		model.ModelHash,
		&model.ModelHashAlgorithm,
		&model.WeightsManifestSHA256,
		&model.WeightsHashAlgorithm,
	); err != nil {
		return pool.WarmModel{}, fmt.Errorf("%s: %w", field, err)
	}
	if v, ok := entry["cb_self_check"]; ok && string(v) != "null" {
		selfCheck, err := parseCBSelfCheck(v)
		if err != nil {
			return pool.WarmModel{}, fmt.Errorf("cb_self_check: %w", err)
		}
		model.CBSelfCheck = selfCheck
	}
	if v, ok := entry["engine_profile"]; ok {
		// As on the heartbeat: an invalid or disagreeing profile is dropped,
		// never a reason to reject the entry.
		model.EngineProfile = parseEngineProfile(v)
		if p := model.EngineProfile; p != nil && (p.MaxStableContextTokens != model.MaxContextTokens || p.RAMClassGB != engineProfileRAMClassFor(ramGB)) {
			model.EngineProfile = nil
		}
	}
	return model, nil
}

// checkWarmModelsPrimary rejects a primary entry that says something other
// than the top-level fields of the message it rides on.
func checkWarmModelsPrimary(raw, entry map[string]json.RawMessage, primary pool.WarmModel, top warmModelsTopLevel) error {
	for _, key := range warmModelsPrimaryFieldKeys {
		if !sameJSONValue(raw[key], entry[key]) {
			return fmt.Errorf("warm_models primary %s contradicts the top-level field", key)
		}
	}
	if primary.State == pool.WarmModelEvicting {
		return fmt.Errorf("warm_models primary cannot be evicting")
	}
	if top.loadingPresent && top.loading != (primary.State == pool.WarmModelLoading) {
		return fmt.Errorf("warm_models primary state contradicts the top-level loading")
	}
	if top.slotsReported {
		if primary.SlotsTotal != top.slotsTotal {
			return fmt.Errorf("warm_models primary slots_total contradicts the top-level field")
		}
		if primary.State == pool.WarmModelWarm && primary.SlotsFree != top.slotsFree {
			return fmt.Errorf("warm_models primary slots_free contradicts the top-level field")
		}
	}
	return nil
}

// sameJSONValue compares two optional JSON values semantically; an absent
// value and an explicit null are the same.
func sameJSONValue(a, b json.RawMessage) bool {
	var av, bv any
	if len(a) > 0 && json.Unmarshal(a, &av) != nil {
		return false
	}
	if len(b) > 0 && json.Unmarshal(b, &bv) != nil {
		return false
	}
	return reflect.DeepEqual(av, bv)
}

// validateWarmModelsSupported enforces SPEC-002-R011: every entry's model_id is
// in the session's supported_models (case-folded per SPEC-010), and the array
// is at most that long. A session that declared no supported_models supports
// its top-level model only, so its warm set can only be that one model.
func validateWarmModelsSupported(models []pool.WarmModel, supported []string, topLevelModelID string) error {
	if models == nil {
		return nil
	}
	if len(supported) == 0 {
		supported = []string{topLevelModelID}
	}
	if len(models) > len(supported) {
		return fmt.Errorf("warm_models has more entries than supported_models")
	}
	allowed := make(map[string]struct{}, len(supported))
	for _, model := range supported {
		allowed[normalizeSupportedModelEntry(model)] = struct{}{}
	}
	for _, model := range models {
		if _, ok := allowed[normalizeSupportedModelEntry(model.ModelID)]; !ok {
			return fmt.Errorf("warm_models model_id not in supported_models")
		}
	}
	return nil
}

// warmModelsForPool readies a validated warm set for the registry: each
// further member's seats are clamped by the operator ceiling like the
// top-level ones (issue #764), and each carries the catalog hash expected for
// its own model. The primary entry is the session's top-level fields.
func (s *Server) warmModelsForPool(models []pool.WarmModel, expectedHash func(modelID string) string) []pool.WarmModel {
	if models == nil {
		return nil
	}
	out := append([]pool.WarmModel(nil), models...)
	ceiling := s.maxConcurrencyCeiling()
	for i := range out {
		if out[i].Primary {
			continue
		}
		capacity := pool.ClampCapacity(out[i].SlotsTotal, out[i].SlotsTotal, out[i].SlotsFree, ceiling)
		out[i].SlotsTotal = capacity.SlotsTotal
		out[i].SlotsFree = capacity.SlotsFree
		out[i].ExpectedModelHash = expectedHash(out[i].ModelID)
	}
	return out
}
