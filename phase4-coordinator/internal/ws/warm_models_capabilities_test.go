package ws

import (
	"reflect"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// SPEC-001-R019 / SPEC-002-R011: a further member's own tool and vision
// declarations decode onto its entry with the top-level lists' schema; a
// malformed one rejects the frame like a malformed top-level list does.
func TestParseHeartbeatDecodesMemberCapabilities(t *testing.T) {
	payload := warmModelsHeartbeat()
	tool := map[string]any{"model_id": "model-b", "runtime": "mlx_cache", "modes": []any{"auto", "required"}, "validation": "schema-holdback-v1", "schema_profiles": []any{"ordinary-parameters-v1"}}
	vision := map[string]any{"model_id": "model-b", "model_hash": warmModelsTestHash, "model_hash_algorithm": "macprovider.snapshot-manifest.v1", "weights_manifest_sha256": warmModelsTestHash, "processor_digest": "p", "runtime": "mlx_cache", "runtime_revision": "r", "media_profile": "m"}
	warmModelsEntry(payload, 1)["tool_selection_capabilities"] = []any{tool}
	warmModelsEntry(payload, 1)["vision_runtime_capabilities"] = []any{vision}
	hb, _, field, err := ParseHeartbeat(mustAuthJSON(t, payload))
	if err != nil {
		t.Fatalf("ParseHeartbeat field=%q err=%v", field, err)
	}
	wantTool := []pool.ToolSelectionCapability{{ModelID: "model-b", Runtime: "mlx_cache", Modes: []string{"auto", "required"}, Validation: "schema-holdback-v1", SchemaProfiles: []string{"ordinary-parameters-v1"}}}
	wantVision := []pool.VisionRuntimeCapability{{ModelID: "model-b", ModelHash: warmModelsTestHash, ModelHashAlgorithm: "macprovider.snapshot-manifest.v1", WeightsManifestSHA256: warmModelsTestHash, ProcessorDigest: "p", Runtime: "mlx_cache", RuntimeRevision: "r", MediaProfile: "m"}}
	member := hb.WarmModels[1]
	if !reflect.DeepEqual(member.ToolSelectionCapabilities, wantTool) || !reflect.DeepEqual(member.VisionRuntimeCapabilities, wantVision) {
		t.Fatalf("member declarations = %+v / %+v", member.ToolSelectionCapabilities, member.VisionRuntimeCapabilities)
	}
	if hb.WarmModels[0].ToolSelectionCapabilities != nil || hb.WarmModels[2].VisionRuntimeCapabilities != nil {
		t.Fatal("declarations appeared on an entry that sent none")
	}
	for _, key := range []string{"tool_selection_capabilities", "vision_runtime_capabilities"} {
		bad := warmModelsHeartbeat()
		warmModelsEntry(bad, 1)[key] = "not-a-list"
		if _, _, field, err := ParseHeartbeat(mustAuthJSON(t, bad)); err == nil || field != warmModelsField {
			t.Fatalf("malformed member %s accepted (field=%q err=%v)", key, field, err)
		}
	}
}
