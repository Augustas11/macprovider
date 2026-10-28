package ws

// Native profile preflight for SPEC-030-R021 / SPEC-036-R018. These genuine
// authenticated probe variants terminate before measurement: neither protocol
// has an independently trusted native execution binding. No measurement, TV,
// profile-state, breaker, receipt, reward or settlement consumer is called.
import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/augstar/macprovider-coordinator/internal/tier2"
)

const nativePathReason = "inconclusive:native_path_untrusted"
const computeProbeProfile = "compute_integrity_probe_v1"

type nativePathPending struct {
	request map[string]any
	digest  string
	expires time.Time
	results chan map[string]any
}

func nativePathKey(provider, assigned, profile string) string {
	return provider + "\x00" + assigned + "\x00" + profile
}
func nativePathString(v any) string { s, _ := v.(string); return s }
func nativePathInt(v any) (int, bool) {
	n, ok := v.(float64)
	return int(n), ok && n >= 0 && n <= float64(1<<31-1) && float64(int(n)) == n
}
func nativePathSHA(v any) bool {
	s := nativePathString(v)
	if len(s) != 64 {
		return false
	}
	for _, r := range s {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}
func nativePathKeys(v map[string]any, keys []string) bool {
	if len(v) != len(keys) {
		return false
	}
	for _, k := range keys {
		if _, ok := v[k]; !ok {
			return false
		}
	}
	return true
}
func nativePathDecode(raw []byte) (map[string]any, error) {
	if len(raw) > 64*1024 {
		return nil, errors.New("native probe exceeds bound")
	}
	if _, err := rejectDuplicateJSONFields(raw); err != nil {
		return nil, err
	}
	var v map[string]any
	err := json.Unmarshal(raw, &v)
	return v, err
}
func nativePathDigest(profile, kind string, payload map[string]any) (string, error) {
	var input any = payload
	if profile == computeProbeProfile {
		input = map[string]any{"type": profile + "." + kind, "schema_version": profile + "." + kind, "payload": payload}
	}
	raw, err := json.Marshal(input)
	if err != nil {
		return "", err
	}
	return LosslessnessDigest(raw)
}

// Full native request shape is validated before the unsupported-path preflight.
// Compute references MAY be absent only for this non-calibration schema dry-run
// (FR-6); a provider_inconclusive result never supplies distributions or TV.
func validateNativePathRequest(profile string, p map[string]any, now time.Time) error {
	fail := errors.New("invalid native profile request")
	if profile != LosslessnessProbeVersion && profile != computeProbeProfile {
		return fail
	}
	for _, k := range []string{"probe_id", "model_id", "target_model_hash", "tokenizer_identity", "corpus_version", "threshold_version"} {
		s := nativePathString(p[k])
		if s == "" || len(s) > 256 {
			return fail
		}
	}
	g, ok := nativePathInt(p["target_generation"])
	if !ok || g < 1 || !nativePathSHA(p["native_mtp_runtime_tuple_sha256"]) {
		return fail
	}
	expiry, err := time.Parse(time.RFC3339Nano, nativePathString(p["expires_at"]))
	if err != nil || !now.Before(expiry) || expiry.After(now.Add(61*time.Second)) {
		return fail
	}
	sampler, ok := p["sampling_profile"].(map[string]any)
	if !ok || !nativePathKeys(sampler, []string{"temperature", "top_p"}) {
		return fail
	}
	t, tok := sampler["temperature"].(float64)
	top, pok := sampler["top_p"].(float64)
	if !tok || !pok || t < 0 || t > 2 || top <= 0 || top > 1 {
		return fail
	}
	if profile == LosslessnessProbeVersion {
		keys := strings.Fields("probe_version probe_id probe_nonce expires_at model_id target_model_hash target_generation tokenizer_identity sampling_profile corpus_version threshold_version prompts measurement_positions requested_k support_selection max_prompts max_stochastic_positions timeout_ms decode_path native_mtp_runtime_tuple_sha256")
		if !nativePathKeys(p, keys) || p["probe_version"] != profile || p["decode_path"] != "native_mtp" || p["support_selection"] != losslessnessSupportSelection || nativePathString(p["probe_nonce"]) == "" {
			return fail
		}
		k, kok := nativePathInt(p["requested_k"])
		mp, a := nativePathInt(p["max_prompts"])
		ms, b := nativePathInt(p["max_stochastic_positions"])
		timeout, c := nativePathInt(p["timeout_ms"])
		prompts, d := p["prompts"].([]any)
		positions, e := p["measurement_positions"].([]any)
		if !kok || (k != 64 && k != 256) || !a || mp < 1 || mp > 4 || !b || ms < 1 || ms > 8 || !c || timeout != 60000 || !d || len(prompts) < 1 || len(prompts) > mp || !e || len(positions) < 1 || len(positions) > ms {
			return fail
		}
		seen := map[int]bool{}
		for _, pos := range positions {
			n, ok := nativePathInt(pos)
			if !ok || seen[n] {
				return fail
			}
			seen[n] = true
		}
		for _, item := range prompts {
			q, ok := item.(map[string]any)
			if !ok || !nativePathKeys(q, strings.Fields("prompt_id prompt coordinator_owned buyer_origin")) || nativePathString(q["prompt_id"]) == "" || len(nativePathString(q["prompt"])) > 4096 || q["coordinator_owned"] != true || q["buyer_origin"] != false {
				return fail
			}
		}
	} else {
		keys := strings.Fields("schema_version probe_id nonce expires_at model_id target_model_hash tokenizer_identity sampler_stage target_generation sampling_profile corpus_version threshold_version hardware_runtime_class support_selection normalization_basis k positions expected_decode_path native_mtp_runtime_tuple_sha256")
		if !nativePathKeys(p, keys) || p["schema_version"] != profile+".request" || p["expected_decode_path"] != "native_mtp" || p["support_selection"] != "compute_integrity_support_selection_v1" || p["normalization_basis"] != "full_distribution" || p["sampler_stage"] != "post_sampler_probabilities" || nativePathString(p["hardware_runtime_class"]) == "" || nativePathString(p["nonce"]) == "" {
			return fail
		}
		k, kok := nativePathInt(p["k"])
		positions, ok := p["positions"].([]any)
		if !kok || k != 64 || !ok || len(positions) < 1 || len(positions) > 8 {
			return fail
		} // no calibration/retry endpoint
		prompts := map[string]string{}
		refs := map[string]string{}
		seen := map[string]bool{}
		for _, item := range positions {
			q, ok := item.(map[string]any)
			if !ok || !nativePathKeys(q, strings.Fields("prompt_id prompt_ref position_index token_prefix_digest context_hash")) {
				return fail
			}
			id, ref := nativePathString(q["prompt_id"]), nativePathString(q["prompt_ref"])
			pos, ok := nativePathInt(q["position_index"])
			if !ok || id == "" || ref != "synthetic:native-path-binding-v1" || len(ref) > 256 {
				return fail
			}
			for _, key := range []string{"token_prefix_digest", "context_hash"} {
				s := nativePathString(q[key])
				if !strings.HasPrefix(s, "sha256:") || !nativePathSHA(strings.TrimPrefix(s, "sha256:")) {
					return fail
				}
			}
			key := id + ":" + strconv.Itoa(pos)
			if seen[key] || prompts[id] != "" && prompts[id] != ref || refs[ref] != "" && refs[ref] != id {
				return fail
			}
			seen[key] = true
			prompts[id] = ref
			refs[ref] = id
		}
		if len(prompts) > 4 {
			return fail
		}
	}
	return nil
}
func nativePathEnvelope(profile string, p map[string]any) (map[string]any, string, error) {
	digest, err := nativePathDigest(profile, "request", p)
	if err != nil {
		return nil, "", err
	}
	out := map[string]any{"type": profile + ".request", "payload": p, "probe_request_digest": digest}
	if profile == LosslessnessProbeVersion {
		out["probe_id"] = p["probe_id"]
	} else {
		out["schema_version"] = profile + ".request"
	}
	return out, digest, nil
}

// Operator-only loopback dispatch is diagnostic, not a settlement action.
// The caller supplies an actual bounded synthetic corpus request. Issued replay
// fields are regenerated here; expected identity may deliberately mismatch.
func (s *Server) handleAdminNativePathProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", 405)
		return
	}
	if !s.authorizedOperator(r) {
		http.Error(w, "unauthorized", 401)
		return
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		http.Error(w, "loopback required", 403)
		return
	}
	raw, err := io.ReadAll(io.LimitReader(r.Body, 64*1024+1))
	if err != nil {
		http.Error(w, "invalid body", 400)
		return
	}
	body, err := nativePathDecode(raw)
	if err != nil || !nativePathKeys(body, strings.Fields("provider_id profile request_payload")) {
		http.Error(w, "invalid body", 400)
		return
	}
	profile := nativePathString(body["profile"])
	p, ok := body["request_payload"].(map[string]any)
	if !ok {
		http.Error(w, "invalid payload", 400)
		return
	}
	if s.pool == nil {
		http.Error(w, "pool unavailable", 503)
		return
	}
	var provider pool.Provider
	found := false
	for _, candidate := range s.pool.Snapshot() {
		if candidate.ProviderID == body["provider_id"] {
			provider = candidate
			found = true
			break
		}
	}
	if !found || provider.NativeMTPCanary == nil {
		http.Error(w, "native tuple unavailable", 409)
		return
	}
	if provider.SafetyTelemetry == nil || provider.SafetyTelemetry.RequestsInFlight != 0 || provider.SafetyTelemetry.RequestsQueued != 0 {
		http.Error(w, "buyer load must drain", 409)
		return
	}
	session, ok := s.sessionFor(provider.ProviderID, provider.AssignedID)
	if !ok {
		http.Error(w, "session unavailable", 409)
		return
	}
	now := s.now()
	id, err := losslessnessRandomID("native-path-", 16)
	if err != nil {
		http.Error(w, "entropy unavailable", 503)
		return
	}
	nonce, err := losslessnessRandomID("", 32)
	if err != nil {
		http.Error(w, "entropy unavailable", 503)
		return
	}
	p["probe_id"] = id
	p["expires_at"] = now.Add(time.Minute).UTC().Format(time.RFC3339Nano)
	if profile == LosslessnessProbeVersion {
		p["probe_nonce"] = nonce
	} else {
		p["nonce"] = nonce
	}
	if err := validateNativePathRequest(profile, p, now); err != nil {
		http.Error(w, err.Error(), 400)
		return
	}
	outer, digest, err := nativePathEnvelope(profile, p)
	if err != nil {
		http.Error(w, "invalid envelope", 400)
		return
	}
	key := nativePathKey(provider.ProviderID, provider.AssignedID, profile)
	pending := &nativePathPending{request: p, digest: digest, expires: now.Add(time.Minute), results: make(chan map[string]any, 1)}
	if !s.reserveNativePathProbe(provider, profile, key, pending) {
		http.Error(w, "profile busy", 409)
		return
	}
	defer s.nativePathPending.CompareAndDelete(key, pending)
	session.rekeyMu.Lock()
	_, due := session.tier2RekeyReason(s.now(), s.tier2Config())
	if session.rekey != nil || due {
		session.rekeyMu.Unlock()
		http.Error(w, "session rekeying", 409)
		return
	}
	cleartext, _ := json.Marshal(outer)
	frame, err := session.sealNativePathProbeRequest(provider, id, cleartext, profile)
	if err == nil {
		err = session.send(frame)
	}
	session.rekeyMu.Unlock()
	if err != nil {
		http.Error(w, "dispatch failed", 503)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Minute)
	defer cancel()
	select {
	case result := <-pending.results:
		writeJSON(w, 200, map[string]any{"profile": profile, "request": outer, "result": result, "classification": nativePathReason, "trust_semantics": "observe_only"})
	case <-ctx.Done():
		http.Error(w, "native diagnostic timed out", 504)
	}
}

func validateNativePathResult(profile string, outer map[string]any, pending *nativePathPending, now time.Time) error {
	fail := errors.New("invalid native profile result")
	if !now.Before(pending.expires) || outer["type"] != profile+".result" || outer["probe_request_digest"] != pending.digest {
		return fail
	}
	keys := "type probe_id probe_request_digest probe_result_digest payload"
	if profile == computeProbeProfile {
		keys = "type schema_version probe_request_digest probe_result_digest payload"
		if outer["schema_version"] != profile+".result" {
			return fail
		}
	}
	if !nativePathKeys(outer, strings.Fields(keys)) {
		return fail
	}
	p, ok := outer["payload"].(map[string]any)
	if !ok {
		return fail
	}
	fields := "probe_id probe_request_digest result_kind provider_reason_code expected_decode_path actual_decode_path native_mtp_runtime_tuple_sha256 actual_native_mtp_runtime_tuple_sha256 fallback_used identity_unavailable_reason model_id target_model_hash target_generation tokenizer_identity"
	if profile == computeProbeProfile {
		fields += " schema_version nonce sampling_profile corpus_version threshold_version hardware_runtime_class support_selection normalization_basis sampler_stage"
	} else {
		fields += " probe_nonce"
		if outer["probe_id"] != pending.request["probe_id"] {
			return fail
		}
	}
	if !nativePathKeys(p, strings.Fields(fields)) || p["probe_id"] != pending.request["probe_id"] || p["probe_request_digest"] != pending.digest || p["result_kind"] != "provider_inconclusive" || p["provider_reason_code"] != nativePathReason || p["expected_decode_path"] != "native_mtp" || p["actual_decode_path"] != nil || p["fallback_used"] != false || p["native_mtp_runtime_tuple_sha256"] != pending.request["native_mtp_runtime_tuple_sha256"] || p["identity_unavailable_reason"] != "native_execution_binding_unavailable" {
		return fail
	}
	nonceKey := "probe_nonce"
	if profile == computeProbeProfile {
		nonceKey = "nonce"
		if p["hardware_runtime_class"] != nil {
			return fail
		}
		if p["schema_version"] != profile+".result" {
			return fail
		}
		for _, key := range strings.Fields("sampling_profile corpus_version threshold_version support_selection normalization_basis sampler_stage") {
			a, _ := json.Marshal(p[key])
			b, _ := json.Marshal(pending.request[key])
			if !bytes.Equal(a, b) {
				return fail
			}
		}
	}
	if p[nonceKey] != pending.request[nonceKey] {
		return fail
	}
	known := p["actual_native_mtp_runtime_tuple_sha256"] != nil
	for _, key := range strings.Fields("model_id target_model_hash target_generation tokenizer_identity") {
		if known {
			if key == "target_generation" {
				g, ok := nativePathInt(p[key])
				if !ok || g < 1 {
					return fail
				}
			} else if nativePathString(p[key]) == "" {
				return fail
			}
		} else if p[key] != nil {
			return fail
		}
	}
	if known && !nativePathSHA(p["actual_native_mtp_runtime_tuple_sha256"]) {
		return fail
	}
	digest, err := nativePathDigest(profile, "result", p)
	if err != nil || outer["probe_result_digest"] != digest {
		return fail
	}
	return nil
}

// Called only after transport/session authentication. No classic measurement
// parser sees native provider_inconclusive variants, and no profile store runs.
func (s *Server) consumeNativePathProbeResult(providerID, assignedID, profile string, cleartext []byte) bool {
	outer, err := nativePathDecode(cleartext)
	if err != nil {
		return false
	}
	payload, ok := outer["payload"].(map[string]any)
	if !ok || payload["expected_decode_path"] != "native_mtp" {
		return false
	}
	key := nativePathKey(providerID, assignedID, profile)
	value, ok := s.nativePathPending.Load(key)
	if !ok {
		return true
	}
	pending := value.(*nativePathPending)
	if err := validateNativePathResult(profile, outer, pending, s.now()); err != nil {
		s.log.Warn().Err(err).Str("provider_id", providerID).Str("profile", profile).Msg("native profile diagnostic result validation failed")
		return true
	}
	if _, ok := s.pool.Resolve(providerID, assignedID); !ok {
		return true
	}
	// CompareAndDelete is the one replay-consumption fence. Duplicate frames
	// cannot satisfy a later request or produce a second diagnostic observation.
	if !s.nativePathPending.CompareAndDelete(key, pending) {
		return true
	}
	pending.results <- outer
	return true
}
func (s *Server) handleComputeNativePathProbeResult(providerID, assignedID string, payload []byte) {
	outer, err := nativePathDecode(payload)
	if err != nil {
		return
	}
	profile := computeProbeProfile
	if outer["type"] == profile+".encrypted_result" {
		provider, ok := s.pool.Resolve(providerID, assignedID)
		if !ok {
			return
		}
		session, ok := s.sessionFor(providerID, assignedID)
		if !ok {
			return
		}
		var carrier encryptedLosslessnessResult
		if json.Unmarshal(payload, &carrier) != nil || !carrier.Encrypted || carrier.Stream || carrier.RequestID == "" {
			return
		}
		opened, err := session.openNativePathProbeResult(provider, carrier.RequestID, tier2.AEADEnvelope{Encrypted: true, Enc: carrier.Enc}, profile)
		if err != nil {
			return
		}
		parsed, err := nativePathDecode(opened)
		if err != nil {
			return
		}
		p, ok := parsed["payload"].(map[string]any)
		if !ok || p["probe_id"] != carrier.RequestID {
			return
		}
		payload = opened
	} else if session, ok := s.sessionFor(providerID, assignedID); ok && session.hasTier2Session() {
		return
	}
	s.consumeNativePathProbeResult(providerID, assignedID, profile, payload)
}

func (ps *providerSession) sealNativePathProbeRequest(provider pool.Provider, probeID string, cleartextOuterEnvelope []byte, profile string) ([]byte, error) {
	ps.tier2Mu.Lock()
	session := ps.tier2
	if session == nil {
		ps.tier2Mu.Unlock()
		return cleartextOuterEnvelope, nil
	}
	defer ps.tier2Mu.Unlock()
	if session.C2PCounter == ^uint64(0) {
		return nil, errTier2C2PCounterExhausted
	}
	seq := session.C2PCounter
	aad := tier2.AEADFrameAAD{
		Type:       (profile + ".encrypted_request"),
		Direction:  "c2p",
		RequestID:  probeID,
		Stream:     false,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	plaintext, err := json.Marshal(encryptedLosslessnessPlaintext{
		Type:    (profile + ".request_plaintext"),
		Payload: cleartextOuterEnvelope,
	})
	if err != nil {
		return nil, err
	}
	envelope, err := tier2.SealPillarBFrame(session.C2PKey, session.C2PNonceBase, session.KeyID, seq, aad, plaintext)
	if err != nil {
		return nil, err
	}
	session.C2PCounter++
	return json.Marshal(encryptedLosslessnessRequest{
		Type:      (profile + ".encrypted_request"),
		RequestID: probeID,
		Stream:    false,
		Encrypted: true,
		Enc:       envelope.Enc,
	})
}

func (ps *providerSession) openNativePathProbeResult(provider pool.Provider, probeID string, envelope tier2.AEADEnvelope, profile string) ([]byte, error) {
	ps.tier2Mu.Lock()
	defer ps.tier2Mu.Unlock()
	if ps.tier2 == nil {
		return nil, errors.New("encrypted losslessness result for provider without tier2 session")
	}
	if ps.tier2.P2CCounter == ^uint64(0) {
		return nil, errors.New("tier2 p2c frame counter exhausted")
	}
	seq := ps.tier2.P2CCounter
	aad := tier2.AEADFrameAAD{
		Type:       (profile + ".encrypted_result"),
		Direction:  "p2c",
		RequestID:  probeID,
		Stream:     false,
		ProviderID: provider.ProviderID,
		AssignedID: provider.AssignedID,
		Seq:        seq,
	}
	plaintext, err := tier2.OpenPillarBFrame(ps.tier2.P2CKey, ps.tier2.P2CNonceBase, ps.tier2.KeyID, seq, aad, envelope)
	if err != nil {
		return nil, err
	}
	var carrier encryptedLosslessnessPlaintext
	if err := json.Unmarshal(plaintext, &carrier); err != nil {
		return nil, err
	}
	if carrier.Type != (profile+".result_plaintext") || len(carrier.Payload) == 0 {
		return nil, errors.New("invalid losslessness result plaintext envelope")
	}
	ps.tier2.P2CCounter++
	return carrier.Payload, nil
}

func (s *Server) reserveNativePathProbe(provider pool.Provider, profile, key string, pending *nativePathPending) bool {
	s.nativePathDispatchMu.Lock()
	defer s.nativePathDispatchMu.Unlock()
	if profile == LosslessnessProbeVersion && (!s.cfg.Pool.LosslessnessProbe.Enabled || s.losslessnessProviderHasPending(provider.ProviderID, provider.AssignedID)) {
		return false
	}
	_, busy := s.nativePathPending.LoadOrStore(key, pending)
	return !busy
}
