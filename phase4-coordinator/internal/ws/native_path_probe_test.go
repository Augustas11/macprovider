package ws

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func nativePathFixture(t *testing.T, profile string, now time.Time) map[string]any {
	t.Helper()
	p := map[string]any{"probe_id": "fixture", "expires_at": now.Add(time.Minute).Format(time.RFC3339Nano), "model_id": "fixture-model", "target_model_hash": strings.Repeat("a", 64), "target_generation": 7, "tokenizer_identity": strings.Repeat("b", 64), "sampling_profile": map[string]any{"temperature": 0, "top_p": 1}, "corpus_version": "synthetic-native-preflight-v1", "threshold_version": "no-measurement", "native_mtp_runtime_tuple_sha256": strings.Repeat("c", 64)}
	if profile == LosslessnessProbeVersion {
		p["probe_version"] = profile
		p["probe_nonce"] = "nonce"
		p["decode_path"] = "native_mtp"
		p["prompts"] = []any{map[string]any{"prompt_id": "p", "prompt": "synthetic fixture", "coordinator_owned": true, "buyer_origin": false}}
		p["measurement_positions"] = []int{0}
		p["requested_k"] = 64
		p["support_selection"] = losslessnessSupportSelection
		p["max_prompts"] = 1
		p["max_stochastic_positions"] = 1
		p["timeout_ms"] = 60000
	} else {
		p["schema_version"] = profile + ".request"
		p["nonce"] = "nonce"
		p["expected_decode_path"] = "native_mtp"
		p["sampler_stage"] = "post_sampler_probabilities"
		p["hardware_runtime_class"] = "fixture"
		p["support_selection"] = "compute_integrity_support_selection_v1"
		p["normalization_basis"] = "full_distribution"
		p["k"] = 64
		p["positions"] = []any{map[string]any{"prompt_id": "p", "prompt_ref": "synthetic:native-path-binding-v1", "position_index": 0, "token_prefix_digest": "sha256:" + strings.Repeat("d", 64), "context_hash": "sha256:" + strings.Repeat("e", 64)}}
	}
	raw, _ := json.Marshal(p)
	var decoded map[string]any
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}
func nativePathResultFixture(t *testing.T, profile string, p map[string]any, digest string) map[string]any {
	t.Helper()
	out := map[string]any{"probe_id": p["probe_id"], "probe_request_digest": digest, "result_kind": "provider_inconclusive", "provider_reason_code": nativePathReason, "expected_decode_path": "native_mtp", "actual_decode_path": nil, "native_mtp_runtime_tuple_sha256": p["native_mtp_runtime_tuple_sha256"], "actual_native_mtp_runtime_tuple_sha256": strings.Repeat("f", 64), "fallback_used": false, "identity_unavailable_reason": "native_execution_binding_unavailable", "model_id": "actual-model", "target_model_hash": strings.Repeat("1", 64), "target_generation": float64(8), "tokenizer_identity": strings.Repeat("2", 64)}
	if profile == computeProbeProfile {
		out["hardware_runtime_class"] = nil
		out["schema_version"] = profile + ".result"
		out["nonce"] = p["nonce"]
		for _, k := range strings.Fields("sampling_profile corpus_version threshold_version support_selection normalization_basis sampler_stage") {
			out[k] = p[k]
		}
	} else {
		out["probe_nonce"] = p["probe_nonce"]
	}
	resultDigest, err := nativePathDigest(profile, "result", out)
	if err != nil {
		t.Fatal(err)
	}
	result := map[string]any{"type": profile + ".result", "probe_request_digest": digest, "probe_result_digest": resultDigest, "payload": out}
	if profile == computeProbeProfile {
		result["schema_version"] = profile + ".result"
	} else {
		result["probe_id"] = p["probe_id"]
	}
	return result
}
func TestNativePathProbeProfilesValidateMismatchWithoutMeasurement(t *testing.T) {
	now := time.Date(2026, 10, 26, 0, 0, 0, 0, time.UTC)
	for _, profile := range []string{LosslessnessProbeVersion, computeProbeProfile} {
		t.Run(profile, func(t *testing.T) {
			p := nativePathFixture(t, profile, now)
			if err := validateNativePathRequest(profile, p, now); err != nil {
				t.Fatal(err)
			}
			_, digest, err := nativePathEnvelope(profile, p)
			if err != nil {
				t.Fatal(err)
			}
			pending := &nativePathPending{request: p, digest: digest, expires: now.Add(time.Minute)}
			result := nativePathResultFixture(t, profile, p, digest)
			if err := validateNativePathResult(profile, result, pending, now); err != nil {
				t.Fatal(err)
			}
			for _, mutation := range []string{"nonce", "measurement", "digest", "expiry", "positions", "actual_path"} {
				t.Run(mutation, func(t *testing.T) {
					r := nativePathResultFixture(t, profile, p, digest)
					body := r["payload"].(map[string]any)
					switch mutation {
					case "nonce":
						body["probe_nonce"] = "wrong"
						if profile == computeProbeProfile {
							delete(body, "probe_nonce")
							body["nonce"] = "wrong"
						}
					case "measurement":
						body["result_kind"] = "measurement"
					case "digest":
						r["probe_result_digest"] = "sha256:" + strings.Repeat("0", 64)
					case "positions":
						body["positions"] = []any{}
					case "actual_path":
						body["actual_decode_path"] = "native_mtp"
					}
					if mutation != "digest" {
						r["probe_result_digest"], _ = nativePathDigest(profile, "result", body)
					}
					at := now
					if mutation == "expiry" {
						at = now.Add(time.Minute)
					}
					if validateNativePathResult(profile, r, pending, at) == nil {
						t.Fatal("invalid native result accepted")
					}
				})
			}
			p["draft_model_id"] = "must-not-mix"
			if validateNativePathRequest(profile, p, now) == nil {
				t.Fatal("external draft accepted in native profile")
			}
		})
	}
}
func TestNativePathProbeDigestsAreProfileSeparated(t *testing.T) {
	p := map[string]any{"probe_id": "p"}
	a, _ := nativePathDigest(LosslessnessProbeVersion, "request", p)
	b, _ := nativePathDigest(computeProbeProfile, "request", p)
	c, _ := nativePathDigest(computeProbeProfile, "result", p)
	if a == b || b == c || a == c {
		t.Fatal("profile/type domains collapsed")
	}
}
func TestNativePathProbeAuthenticatedSessionConsumeAndReplay(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	for _, profile := range []string{LosslessnessProbeVersion, computeProbeProfile} {
		p := nativePathFixture(t, profile, *h.now)
		_, digest, _ := nativePathEnvelope(profile, p)
		pending := &nativePathPending{request: p, digest: digest, expires: h.now.Add(time.Minute), results: make(chan map[string]any, 1)}
		key := nativePathKey(h.provider.ProviderID, h.provider.AssignedID, profile)
		h.server.nativePathPending.Store(key, pending)
		result := nativePathResultFixture(t, profile, p, digest)
		raw, _ := json.Marshal(result)
		h.server.consumeNativePathProbeResult(h.provider.ProviderID, "wrong-session", profile, raw)
		select {
		case <-pending.results:
			t.Fatal("wrong session accepted")
		default:
		}
		if !h.server.consumeNativePathProbeResult(h.provider.ProviderID, h.provider.AssignedID, profile, raw) {
			t.Fatal("native result not handled")
		}
		select {
		case <-pending.results:
		default:
			t.Fatal("actual pending result missing")
		}
		h.server.consumeNativePathProbeResult(h.provider.ProviderID, h.provider.AssignedID, profile, raw)
		select {
		case <-pending.results:
			t.Fatal("replay accepted")
		default:
		}
	}
}
func TestNativePathProbeOperatorAndLoopbackRequired(t *testing.T) {
	h := newNativeMTPCanaryIntegrationHarness(t)
	s := h.server
	s.cfg.Auth.OperatorKey = "fixture-token"
	for _, test := range []struct {
		token, remote string
		status        int
	}{{"", "127.0.0.1:19301", 401}, {"fixture-token", "192.0.2.1:19301", 403}} {
		req := httptest.NewRequest(http.MethodPost, "/admin/native-mtp-path-diagnostic", strings.NewReader("{}"))
		req.RemoteAddr = test.remote
		if test.token != "" {
			req.Header.Set("Authorization", "Bearer "+test.token)
		}
		w := httptest.NewRecorder()
		s.handleAdminNativePathProbe(w, req)
		if w.Code != test.status {
			t.Fatalf("HTTP %d want %d", w.Code, test.status)
		}
	}
}
