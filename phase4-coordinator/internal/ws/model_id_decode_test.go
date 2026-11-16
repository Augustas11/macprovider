package ws

import (
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/pool"
)

// nonCanonicalModelIDs are spellings that differ from a catalog id only in
// surrounding whitespace, control characters or Unicode form/case beyond
// ASCII letter case. Each would fold to the key of "model-z" (or of a
// catalog id with the same letters) yet compare unequal under the ASCII
// lower() of settlement SQL.
var nonCanonicalModelIDs = map[string]string{
	"trailing space":    "model-z ",
	"leading space":     " model-z",
	"tab":               "model-z\t",
	"no-break space":    "model-z\u00a0",
	"empty":             "",
	"control character": "model\u0085z",
	"kelvin sign":       "\u212Aimi",
	"dotted capital I":  "k\u0130mi",
	"non-ASCII upper":   "CAF\u00c9",
	"NFD":               "cafe\u0301",
}

// SPEC-002-R011 decode rule: a non-canonical model id is rejected on every
// field that carries one, through that field's existing invalid-frame path.
// ASCII case variants, which every legacy provider may send, stay accepted.
func TestModelIDDecodeRejectsNonCanonicalSpellings(t *testing.T) {
	for name, id := range nonCanonicalModelIDs {
		hello := modelIDTestHello()
		hello["model_id"] = id
		if _, field, err := ParseHello(mustAuthJSON(t, hello)); err == nil || field != "model_id" {
			t.Fatalf("%s: hello model_id accepted: field=%q err=%v", name, field, err)
		}

		auth := validAuthRequestInitial()
		auth["model_id"] = id
		if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, auth)); err == nil || field != "model_id" {
			t.Fatalf("%s: auth model_id accepted: field=%q err=%v", name, field, err)
		}

		auth = validAuthRequestInitial()
		auth["supported_models"] = []string{auth["model_id"].(string), id}
		if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, auth)); err == nil || field != "supported_models must be array of strings" {
			t.Fatalf("%s: supported_models entry accepted: field=%q err=%v", name, field, err)
		}

		proof := validAuthRequestProof()
		proof["supported_models"] = []string{"model-a", id}
		if _, _, field, err := ParseAuthRequest(mustAuthJSON(t, proof)); err == nil || field != "supported_models" {
			t.Fatalf("%s: proof supported_models entry accepted: field=%q err=%v", name, field, err)
		}

		hb := warmModelsHeartbeat()
		hb["model_id"] = id
		warmModelsEntry(hb, 0)["model_id"] = id
		if _, _, field, err := ParseHeartbeat(mustAuthJSON(t, hb)); err == nil || field != "model_id" {
			t.Fatalf("%s: heartbeat model_id accepted: field=%q err=%v", name, field, err)
		}

		hb = warmModelsHeartbeat()
		warmModelsEntry(hb, 1)["model_id"] = id
		if _, _, field, err := ParseHeartbeat(mustAuthJSON(t, hb)); err == nil || field != warmModelsField {
			t.Fatalf("%s: warm_models entry accepted: field=%q err=%v", name, field, err)
		}
	}

	for _, id := range []string{"Model-A", "MLX-Community/Qwen2.5-7B", "caf\u00e9-7b", "model with inner space"} {
		if !wellFormedModelID(id) {
			t.Fatalf("legal spelling %q rejected", id)
		}
		hello := modelIDTestHello()
		hello["model_id"] = id
		if _, field, err := ParseHello(mustAuthJSON(t, hello)); err != nil {
			t.Fatalf("legal hello model_id %q rejected: field=%q err=%v", id, field, err)
		}
	}
}

// Every accepted spelling's ASCII lower() is its canonical key, so the
// settlement hold predicate compares exactly the key a sanction names.
func TestWellFormedModelIDLowerIsTheModelKey(t *testing.T) {
	for _, id := range []string{"Model-A", "model-a", "MODEL-CI", "caf\u00e9", "Qwen/Qwen3-30B"} {
		if !wellFormedModelID(id) || asciiLower(id) != pool.ModelKey(id) {
			t.Fatalf("%q: well-formed=%v lower=%q key=%q", id, wellFormedModelID(id), asciiLower(id), pool.ModelKey(id))
		}
	}
}

func modelIDTestHello() map[string]any {
	return map[string]any{
		"type": "hello", "version": 1, "tier": 1, "provider_id": "p-ok", "hostname": "h-ok",
		"model_id": "m-ok", "model_params_b": 7.0, "ram_gb": 16, "max_context_tokens": 50000,
		"max_concurrency": 1, "throughput_tps_estimate": 19.8, "binary_version": "0.1.0", "attestation": nil,
	}
}
