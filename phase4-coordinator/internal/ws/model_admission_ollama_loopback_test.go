package ws

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/rs/zerolog"
)

// TestParseHelloRuntimeSource covers the #1569 hello field: `ollama_loopback` is
// parsed and stored, an unknown value is rejected under closed-schema discipline,
// and omission leaves it empty (legacy/MLX providers).
func TestParseHelloRuntimeSource(t *testing.T) {
	base := map[string]any{
		"type":                    "hello",
		"version":                 1,
		"tier":                    1,
		"provider_id":             "p-ollama",
		"hostname":                "h-ok",
		"model_id":                "ollama:gemma3:270m",
		"model_params_b":          0.27,
		"ram_gb":                  16,
		"max_context_tokens":      50000,
		"max_concurrency":         1,
		"throughput_tps_estimate": 19.8,
		"binary_version":          "1.8.120",
		"attestation":             nil,
	}
	with := func(runtimeSource any) []byte {
		payload := make(map[string]any, len(base)+1)
		for k, v := range base {
			payload[k] = v
		}
		if runtimeSource != nil {
			payload["runtime_source"] = runtimeSource
		}
		raw, err := json.Marshal(payload)
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		return raw
	}

	h, _, err := ParseHello(with("ollama_loopback"))
	if err != nil {
		t.Fatalf("ParseHello rejected ollama_loopback: %v", err)
	}
	if h.RuntimeSource != "ollama_loopback" {
		t.Fatalf("hello runtime_source = %q, want ollama_loopback", h.RuntimeSource)
	}

	if _, badField, err := ParseHello(with("openai_compatible_loopback")); err == nil || badField != "runtime_source" {
		t.Fatalf("ParseHello accepted unknown runtime_source: badField=%q err=%v", badField, err)
	}

	h, _, err = ParseHello(with(nil))
	if err != nil {
		t.Fatalf("ParseHello rejected omitted runtime_source: %v", err)
	}
	if h.RuntimeSource != "" {
		t.Fatalf("omitted runtime_source = %q, want empty", h.RuntimeSource)
	}
}

// ollamaLoopbackProbeOffer builds a novel uncatalogued ollama_loopback offer
// (null catalog_model_key) for the given served GGUF ref, mirroring the gate-off
// sandbox candidate the E2E rig admits.
func ollamaLoopbackProbeOffer(providerID, servedModelRef, candidateRune string) ModelAdmissionEvent {
	return ModelAdmissionEvent{
		ProviderID:               providerID,
		CandidateID:              "byom_" + strings.Repeat(candidateRune, 52),
		ServedModelRef:           servedModelRef,
		RuntimeSource:            "ollama_loopback",
		DiscoveryDigestSHA256:    modelAdmissionProbeStringsOf("a", 64),
		EvaluationDigestSHA256:   modelAdmissionProbeStringsOf("b", 64),
		RequestedDisclosureClass: "non_earning_provider_asserted",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_ollama_" + candidateRune,
		Nonce:                    "nonce_offer_ollama_" + candidateRune,
		PayloadDigestSHA256:      modelAdmissionProbeStringsOf("c", 64),
		SignatureDigestSHA256:    modelAdmissionProbeStringsOf("d", 64),
		CreatedAt:                time.Unix(1800000300, 0).UTC(),
	}
}

// TestOllamaLoopbackProbeRecordsIntegerCompletionTokens exercises the #1569 token
// evidence path: a novel uncatalogued ollama_loopback candidate is probed over the
// provider wire, the stream:false response carries usage.completion_tokens, and the
// coordinator records that INTEGER on the synthetic_probe_passed decision without
// ever reaching settlement.
func TestOllamaLoopbackProbeRecordsIntegerCompletionTokens(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()

	const servedRef = "ollama:gemma3:270m"
	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:      "provider-ollama-loopback",
		AssignedID:      "session-ollama",
		ModelID:         servedRef,
		RuntimeSource:   "ollama_loopback",
		HashStatus:      pool.HashStatusUncatalogued,
		EndpointURL:     "http://127.0.0.1:11434/forbidden",
		Tier:            pool.TierProvisional,
		InferencePath:   pool.InferencePathWSTunneled,
		State:           pool.StateReady,
		SlotsFree:       1,
		SlotsTotal:      1,
		MaxConcurrency:  1,
		LastActivityAt:  time.Now().UTC(),
		LastHeartbeatAt: time.Now().UTC(),
	}
	registry.Register(provider, serverConn)
	store := NewMemoryModelAdmissionStore()
	server := NewServer(config.Default(), registry, zerolog.Nop(), WithModelAdmissionStore(store))
	server.newUUID = func() string { return "ollama-proof" }
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, provider.MaxConcurrency)
	server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
	go session.runWriter()

	offer := ollamaLoopbackProbeOffer(provider.ProviderID, servedRef, "g")
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}

	probeDone := make(chan struct{})
	go func() {
		defer close(probeDone)
		probed := readModelAdmissionProbeRequestFrame(t, providerConn)
		if !strings.Contains(probed.Body, `"model":"ollama:gemma3:270m"`) {
			t.Errorf("probe body = %s", probed.Body)
		}
		// stream:false single response chunk carrying usage.completion_tokens.
		server.handleInferenceChunk(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: probed.RequestID,
			Seq:       0,
			Data:      `{"choices":[{"message":{"content":"ok"}}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`,
		}))
		server.handleInferenceEnd(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  probed.RequestID,
			Status:     "complete",
			ChunksSent: 1,
		}))
	}()

	admitted, err := server.runModelAdmissionSyntheticProbe(context.Background(), submitted, *provider, "network_admitted_unsettled", false)
	if err != nil {
		t.Fatalf("run synthetic probe: %v", err)
	}
	<-probeDone

	if admitted.State != "network_admitted_unsettled" {
		t.Fatalf("probe state = %q, want network_admitted_unsettled", admitted.State)
	}
	if admitted.ReasonCode != "synthetic_probe_passed" {
		t.Fatalf("probe reason = %q, want synthetic_probe_passed", admitted.ReasonCode)
	}
	if admitted.SyntheticProbeCompletionTokens != 3 {
		t.Fatalf("recorded completion tokens = %d, want 3", admitted.SyntheticProbeCompletionTokens)
	}
	if ModelAdmissionSettlementStateCandidate(admitted) {
		t.Fatalf("uncatalogued probe outcome leaked settlement state: %+v", admitted)
	}
	if admitted.CatalogModelKey != "" {
		t.Fatalf("uncatalogued candidate must carry null catalog_model_key, got %q", admitted.CatalogModelKey)
	}

	// Token evidence must round-trip out of the store as an integer.
	latest, found, err := store.LatestModelAdmissionStatus(context.Background(), provider.ProviderID, offer.CandidateID)
	if err != nil || !found {
		t.Fatalf("latest status found=%v err=%v", found, err)
	}
	if latest.SyntheticProbeCompletionTokens != 3 {
		t.Fatalf("persisted completion tokens = %d, want 3", latest.SyntheticProbeCompletionTokens)
	}

	// The probe outcome must never be default paid-routing eligible.
	if ModelAdmissionDefaultPaidRoutingEligible(latest, ModelAdmissionPaidRoutingPredicate{
		ProviderID:             latest.ProviderID,
		CandidateID:            latest.CandidateID,
		ServedModelRef:         latest.ServedModelRef,
		DiscoveryDigestSHA256:  latest.DiscoveryDigestSHA256,
		EvaluationDigestSHA256: latest.EvaluationDigestSHA256,
	}) {
		t.Fatal("ollama_loopback probe outcome must not be default paid-routing eligible")
	}
}

// TestOllamaLoopbackProbeIntegerTokensPersistViaSQLite confirms the new integer
// column round-trips through the SQLite store's insert + scan path.
func TestOllamaLoopbackProbeIntegerTokensPersistViaSQLite(t *testing.T) {
	db := openProbeAdmissionStore(t)
	store, err := NewSQLiteModelAdmissionStore(db.DB())
	if err != nil {
		t.Fatal(err)
	}
	offer := ollamaLoopbackProbeOffer("provider-ollama-sqlite", "ollama:gemma3:270m", "h")
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	probeOnlyDecision, ok := modelAdmissionSandboxProbeDecision(submitted, "synthetic_probe_required", time.Unix(1800000310, 0).UTC())
	if !ok {
		t.Fatal("submitted offer did not produce sandbox probe decision")
	}
	probeOnly, err := store.AppendModelAdmissionDecision(context.Background(), probeOnlyDecision)
	if err != nil {
		t.Fatalf("sandbox probe decision: %v", err)
	}
	admitDecision, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "provider_wire_ollama_probe",
		Passed:                true,
		TargetState:           "network_admitted_unsettled",
		ReasonCode:            "synthetic_probe_passed",
		CompletionTokens:      7,
		CreatedAt:             time.Unix(1800000320, 0).UTC(),
	})
	if !ok {
		t.Fatal("probe result did not produce network admission decision")
	}
	if admitDecision.SyntheticProbeCompletionTokens != 7 {
		t.Fatalf("decision completion tokens = %d, want 7", admitDecision.SyntheticProbeCompletionTokens)
	}
	admitted, err := store.AppendModelAdmissionDecision(context.Background(), admitDecision)
	if err != nil {
		t.Fatalf("network admission decision: %v", err)
	}
	if admitted.SyntheticProbeCompletionTokens != 7 {
		t.Fatalf("persisted completion tokens = %d, want 7", admitted.SyntheticProbeCompletionTokens)
	}
	// A failed/revoked probe must carry no positive token claim.
	revocation, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "provider_wire_ollama_probe_fail",
		Passed:                false,
		TargetState:           "network_admitted_unsettled",
		ReasonCode:            "synthetic_probe_failed",
		CompletionTokens:      99,
		CreatedAt:             time.Unix(1800000330, 0).UTC(),
	})
	if !ok {
		t.Fatal("failed probe did not produce revocation decision")
	}
	if revocation.SyntheticProbeCompletionTokens != 0 {
		t.Fatalf("failed probe recorded token claim = %d, want 0", revocation.SyntheticProbeCompletionTokens)
	}
}

// TestOllamaLoopbackProbeRejectsServedRefMismatch is the #1569 binding guard: a
// leftover session serving a different model (Llama) must NOT satisfy a Gemma
// candidate's probe. The mismatch is rejected before any wire dispatch.
func TestOllamaLoopbackProbeRejectsServedRefMismatch(t *testing.T) {
	registry := pool.NewRegistry(nil)
	provider := pool.Provider{
		ProviderID:      "provider-ollama-mismatch",
		AssignedID:      "session-mismatch",
		ModelID:         "ollama:llama3.2:1b", // session serves Llama
		RuntimeSource:   "ollama_loopback",
		InferencePath:   pool.InferencePathWSTunneled,
		State:           pool.StateReady,
		SlotsFree:       1,
		SlotsTotal:      1,
		MaxConcurrency:  1,
		LastActivityAt:  time.Now().UTC(),
		LastHeartbeatAt: time.Now().UTC(),
	}
	store := NewMemoryModelAdmissionStore()
	server := NewServer(config.Default(), registry, zerolog.Nop(), WithModelAdmissionStore(store))

	offer := ollamaLoopbackProbeOffer(provider.ProviderID, "ollama:gemma3:270m", "m") // candidate is Gemma
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), offer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	_, err = server.runModelAdmissionSyntheticProbe(context.Background(), submitted, provider, "network_admitted_unsettled", false)
	if err == nil {
		t.Fatal("Llama session satisfied a Gemma candidate's probe; served-ref binding not enforced")
	}
	if !strings.Contains(err.Error(), "serve the offered model ref") {
		t.Fatalf("unexpected error = %v", err)
	}
	// The candidate must remain in offer_submitted; no probe decision was written.
	latest, found, err := store.LatestModelAdmissionStatus(context.Background(), provider.ProviderID, offer.CandidateID)
	if err != nil || !found {
		t.Fatalf("latest status found=%v err=%v", found, err)
	}
	if latest.State != modelAdmissionOfferSubmitted {
		t.Fatalf("served-ref mismatch advanced admission to %q", latest.State)
	}
}

// TestOllamaLoopbackSandboxSessionNeverBuyerServing pins the SPEC-032 gate-ON
// guardrail: when the proof-of-weights hello gate is enabled the uncatalogued
// session carries the ceiling-exclusion flag and is therefore neither
// RoutingEligible nor ServingCapable, so it can never carry buyer traffic.
//
// The #1569 E2E rig runs the gate OFF (config default), which CLEARS
// AdmissionCeilingExcluded — so in that posture the pool-level session IS
// RoutingEligible (the pool gates never consult HashStatus). The non-buyer-
// serving guarantee then holds one layer up, at the money-path admission gate:
// an uncatalogued (null catalog_model_key) candidate can never reach a
// settlement/catalog_priced state, so ModelAdmissionDefaultPaidRoutingEligible
// is false (asserted on the real post-probe state in
// TestOllamaLoopbackProbeRecordsIntegerCompletionTokens). Both postures are
// covered so a future routing-path refactor cannot silently regress either one.
func TestOllamaLoopbackSandboxSessionNeverBuyerServing(t *testing.T) {
	// Gate-ON posture: the ceiling-exclusion flag keeps the session off routing.
	gateOnSandbox := pool.Provider{
		ProviderID:               "provider-ollama-sandbox",
		AssignedID:               "session-sandbox",
		ModelID:                  "ollama:gemma3:270m",
		RuntimeSource:            "ollama_loopback",
		HashStatus:               pool.HashStatusUncatalogued,
		AdmissionCeilingExcluded: true,
		InferencePath:            pool.InferencePathWSTunneled,
		State:                    pool.StateReady,
		SlotsFree:                1,
		SlotsTotal:               1,
		MaxConcurrency:           1,
	}
	if gateOnSandbox.RoutingEligible() {
		t.Fatal("gate-on route-excluded ollama_loopback sandbox session must not be RoutingEligible")
	}
	if gateOnSandbox.ServingCapable() {
		t.Fatal("gate-on route-excluded ollama_loopback sandbox session must not be ServingCapable")
	}

	// Gate-OFF posture (the E2E rig): the ceiling flag is cleared, so the pool
	// gates admit the session. Document that reality explicitly so nobody
	// mistakes the pool gates for the buyer-exclusion mechanism; the real
	// exclusion is the money-path admission gate exercised elsewhere.
	gateOffSandbox := gateOnSandbox
	gateOffSandbox.AdmissionCeilingExcluded = false
	if !gateOffSandbox.RoutingEligible() {
		t.Fatal("gate-off posture regressed: the pool gate no longer admits (buyer exclusion must rest on the admission gate, not this flag)")
	}
}
