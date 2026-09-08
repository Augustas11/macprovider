package ws

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	"github.com/augstar/macprovider-coordinator/internal/billing"
	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	gobwas "github.com/gobwas/ws"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

func TestModelAdmissionSyntheticProbeWorkflowKeepsNonSettlementBoundaryAcrossStores(t *testing.T) {
	run := func(t *testing.T, store ModelAdmissionStore) {
		submitted, replay, err := store.AppendModelAdmissionOffer(context.Background(), modelAdmissionProbeOffer("workflow", "p"))
		if err != nil || replay {
			t.Fatalf("append offer replay=%v err=%v", replay, err)
		}
		probeOnlyDecision, ok := modelAdmissionSandboxProbeDecision(submitted, "synthetic_probe_required", time.Unix(1800000210, 0).UTC())
		if !ok {
			t.Fatal("submitted offer did not produce sandbox probe decision")
		}
		probeOnly, err := store.AppendModelAdmissionDecision(context.Background(), probeOnlyDecision)
		if err != nil {
			t.Fatalf("sandbox probe decision: %v", err)
		}
		if probeOnly.State != "sandbox_probe_only" || ModelAdmissionSettlementStateCandidate(probeOnly) {
			t.Fatalf("sandbox probe decision leaked settlement state: %+v", probeOnly)
		}

		admitDecision, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
			ProviderWireRequestID: "provider_wire_probe_1",
			Passed:                true,
			TargetState:           "network_admitted_unsettled",
			ReasonCode:            "synthetic_probe_passed",
			CreatedAt:             time.Unix(1800000220, 0).UTC(),
		})
		if !ok {
			t.Fatal("sandbox probe result did not produce network admission decision")
		}
		admitted, err := store.AppendModelAdmissionDecision(context.Background(), admitDecision)
		if err != nil {
			t.Fatalf("network admission decision: %v", err)
		}
		if admitted.State != "network_admitted_unsettled" ||
			admitted.RequestID == "" ||
			admitted.Nonce == "" ||
			admitted.PayloadDigestSHA256 == "" ||
			ModelAdmissionSettlementStateCandidate(admitted) {
			t.Fatalf("unexpected admitted event: %+v", admitted)
		}
		events, err := store.SettlementCapableModelAdmissionStatusesForServedModel(context.Background(), admitted.ProviderID, admitted.ServedModelRef)
		if err != nil {
			t.Fatalf("settlement route set: %v", err)
		}
		if len(events) != 0 {
			t.Fatalf("non-settlement probe workflow produced settlement route events: %+v", events)
		}
		predicate := ModelAdmissionPaidRoutingPredicate{
			ProviderID:             admitted.ProviderID,
			CandidateID:            admitted.CandidateID,
			ServedModelRef:         admitted.ServedModelRef,
			DiscoveryDigestSHA256:  admitted.DiscoveryDigestSHA256,
			EvaluationDigestSHA256: admitted.EvaluationDigestSHA256,
		}
		if ModelAdmissionDefaultPaidRoutingEligible(admitted, predicate) {
			t.Fatal("network_admitted_unsettled probe outcome must not be default paid-routing eligible")
		}

		replayed, err := store.AppendModelAdmissionDecision(context.Background(), admitDecision)
		if err != nil {
			t.Fatalf("probe decision replay: %v", err)
		}
		if replayed.CoordinatorEventID != admitted.CoordinatorEventID || replayed.State != admitted.State {
			t.Fatalf("probe decision replay returned different event: %+v", replayed)
		}
	}
	t.Run("memory", func(t *testing.T) { run(t, NewMemoryModelAdmissionStore()) })
	t.Run("sqlite", func(t *testing.T) {
		db := openProbeAdmissionStore(t)
		store, err := NewSQLiteModelAdmissionStore(db.DB())
		if err != nil {
			t.Fatal(err)
		}
		run(t, store)
	})
}

func TestModelAdmissionSyntheticProbeDecisionRejectsUnsafeEdges(t *testing.T) {
	store := NewMemoryModelAdmissionStore()
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), modelAdmissionProbeOffer("rejects", "q"))
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	if _, ok := modelAdmissionSyntheticProbeDecision(submitted, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "provider_wire_probe_before_sandbox",
		Passed:                true,
		TargetState:           "network_admitted_unsettled",
		ReasonCode:            "synthetic_probe_passed",
	}); ok {
		t.Fatal("probe result from offer_submitted must require sandbox_probe_only first")
	}
	probeOnlyDecision, ok := modelAdmissionSandboxProbeDecision(submitted, "synthetic_probe_required", time.Unix(1800000240, 0).UTC())
	if !ok {
		t.Fatal("submitted offer did not produce sandbox decision")
	}
	probeOnly, err := store.AppendModelAdmissionDecision(context.Background(), probeOnlyDecision)
	if err != nil {
		t.Fatalf("sandbox decision: %v", err)
	}
	for _, target := range []string{"catalog_priced", "settlement_capable", "offer_submitted"} {
		if _, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
			ProviderWireRequestID: "provider_wire_probe_" + target,
			Passed:                true,
			TargetState:           target,
			ReasonCode:            "synthetic_probe_passed",
		}); ok {
			t.Fatalf("probe result must not produce %q", target)
		}
	}
	if _, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "provider_wire_probe_visible_unpriced_denied",
		Passed:                true,
		TargetState:           "network_visible_unpriced",
		ReasonCode:            "synthetic_probe_passed",
	}); ok {
		t.Fatal("probe result produced network_visible_unpriced without explicit visibility authorization")
	}
	if _, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID:            "provider_wire_probe_visible_unpriced_allowed",
		Passed:                           true,
		TargetState:                      "network_visible_unpriced",
		ExperimentalVisibilityAuthorized: true,
		ReasonCode:                       "synthetic_probe_passed",
	}); !ok {
		t.Fatal("probe result with explicit visibility authorization did not produce network_visible_unpriced")
	}
	if _, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "http://127.0.0.1:11434/v1/chat/completions",
		Passed:                true,
		TargetState:           "network_admitted_unsettled",
		ReasonCode:            "synthetic_probe_passed",
	}); ok {
		t.Fatal("probe result accepted endpoint material as provider wire request id")
	}
	if _, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "provider_wire_probe_missing_reason",
		Passed:                true,
		TargetState:           "network_admitted_unsettled",
	}); ok {
		t.Fatal("probe result without reason produced a decision")
	}

	revocationDecision, ok := modelAdmissionSyntheticProbeDecision(probeOnly, modelAdmissionSyntheticProbeResult{
		ProviderWireRequestID: "provider_wire_probe_failed",
		Passed:                false,
		TargetState:           "settlement_capable",
		ReasonCode:            "synthetic_probe_failed",
		CreatedAt:             time.Unix(1800000250, 0).UTC(),
	})
	if !ok {
		t.Fatal("failed probe did not produce revocation decision")
	}
	revoked, err := store.AppendModelAdmissionDecision(context.Background(), revocationDecision)
	if err != nil {
		t.Fatalf("failed probe revocation: %v", err)
	}
	if revoked.State != "revoked" || ModelAdmissionSettlementStateCandidate(revoked) {
		t.Fatalf("failed probe leaked unsafe state: %+v", revoked)
	}
}

func TestRunModelAdmissionSyntheticProbeUsesProviderWireSession(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:      "provider-byom-wire",
		AssignedID:      "session-wire",
		ModelID:         "catalog-default",
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
	server.newUUID = func() string { return "wire-proof" }
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, provider.MaxConcurrency)
	server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
	go session.runWriter()

	wireOffer := modelAdmissionProbeOffer("wire", "w")
	wireOffer.ProviderID = provider.ProviderID
	submitted, _, err := store.AppendModelAdmissionOffer(context.Background(), wireOffer)
	if err != nil {
		t.Fatalf("append offer: %v", err)
	}
	probeDone := make(chan struct{})
	var probed InferenceRequest
	go func() {
		defer close(probeDone)
		probed = readModelAdmissionProbeRequestFrame(t, providerConn)
		if probed.RequestID != "req-model-admission-probe-wire-proof" {
			t.Errorf("probe request id = %q", probed.RequestID)
		}
		if !strings.Contains(probed.Body, `"model":"ollama:qwen3-8b"`) {
			t.Errorf("probe body = %s", probed.Body)
		}
		server.handleInferenceChunk(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: probed.RequestID,
			Seq:       0,
			Data:      `{"choices":[{"message":{"content":"ok"}}]}`,
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
	if admitted.State != "network_admitted_unsettled" ||
		!strings.Contains(admitted.RequestID, "network_admitted_unsettled") ||
		ModelAdmissionSettlementStateCandidate(admitted) {
		t.Fatalf("unexpected synthetic probe admission: %+v", admitted)
	}
}

func TestModelAdmissionOfferHandlerTriggersProviderWireProbe(t *testing.T) {
	endpointHits := make(chan struct{}, 1)
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		endpointHits <- struct{}{}
		http.Error(w, "must not be called", http.StatusTeapot)
	}))
	defer endpoint.Close()

	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:      "provider-byom-trigger",
		AssignedID:      "session-trigger",
		ModelID:         "catalog-default",
		EndpointURL:     endpoint.URL,
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
	admissions := NewMemoryModelAdmissionStore()
	tokens, bearer, priv := bindModelAdmissionProbeIdentity(t, provider.ProviderID)
	server := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(),
		WithTokenValidator(tokens),
		WithTokenIssuer(tokens),
		WithBootstrapTokenStore(tokens),
		WithModelAdmissionStore(admissions),
	)
	server.newUUID = func() string { return "offer-trigger" }
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, provider.MaxConcurrency)
	server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
	go session.runWriter()

	probeDone := make(chan struct{})
	go func() {
		defer close(probeDone)
		probed := readModelAdmissionProbeRequestFrame(t, providerConn)
		if probed.RequestID != "req-model-admission-probe-offer-trigger" {
			t.Errorf("probe request id = %q", probed.RequestID)
		}
		if !strings.Contains(probed.Body, `"model":"ollama:qwen3-8b"`) {
			t.Errorf("probe body = %s", probed.Body)
		}
		server.handleInferenceChunk(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: probed.RequestID,
			Seq:       0,
			Data:      `{"choices":[{"message":{"content":"ok"}}]}`,
		}))
		server.handleInferenceEnd(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  probed.RequestID,
			Status:     "complete",
			ChunksSent: 1,
		}))
	}()

	candidateID := "byom_" + strings.Repeat("t", 52)
	payload := signedModelAdmissionProbeOffer(t, provider.ProviderID, candidateID, "ollama:qwen3-8b", priv, nil)
	status, body := postModelAdmissionProbeOffer(t, server, bearer, payload)
	if status != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", status, body)
	}
	<-probeDone
	response := decodeModelAdmissionProbeMap(t, body)
	if response["admission_state"] != "network_admitted_unsettled" ||
		response["admission_state_source"] != "coordinator" ||
		response["coordinator_event_id"] == "" {
		t.Fatalf("unexpected probe-triggered response: %#v", response)
	}
	latest, found, err := admissions.LatestModelAdmissionStatus(context.Background(), provider.ProviderID, candidateID)
	if err != nil || !found {
		t.Fatalf("latest status found=%v err=%v", found, err)
	}
	if latest.State != "network_admitted_unsettled" || ModelAdmissionSettlementStateCandidate(latest) {
		t.Fatalf("unexpected latest admission: %+v", latest)
	}
	settlement, err := admissions.SettlementCapableModelAdmissionStatusesForServedModel(context.Background(), provider.ProviderID, "ollama:qwen3-8b")
	if err != nil {
		t.Fatalf("settlement route statuses: %v", err)
	}
	if len(settlement) != 0 {
		t.Fatalf("probe-triggered admission leaked settlement route status: %+v", settlement)
	}
	select {
	case <-endpointHits:
		t.Fatal("WS model admission trigger dereferenced provider EndpointURL")
	case <-time.After(100 * time.Millisecond):
	}
}

func TestModelAdmissionOfferHandlerProbeSurvivesSubmitterCancellation(t *testing.T) {
	serverConn, providerConn := net.Pipe()
	defer serverConn.Close()
	defer providerConn.Close()

	registry := pool.NewRegistry(nil)
	provider := &pool.Provider{
		ProviderID:      "provider-byom-cancel",
		AssignedID:      "session-cancel",
		ModelID:         "catalog-default",
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
	authStore, bearer, priv := bindModelAdmissionProbeIdentity(t, provider.ProviderID)
	sqliteAdmissions, err := NewSQLiteModelAdmissionStore(authStore.DB())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancelRequest := context.WithCancel(context.Background())
	admissions := cancelAfterModelAdmissionOfferStore{
		ModelAdmissionStore: sqliteAdmissions,
		cancel:              cancelRequest,
	}
	server := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(),
		WithTokenValidator(authStore),
		WithTokenIssuer(authStore),
		WithBootstrapTokenStore(authStore),
		WithModelAdmissionStore(admissions),
	)
	server.newUUID = func() string { return "offer-cancel" }
	session := newProviderSession(provider.ProviderID, provider.AssignedID, serverConn, provider.MaxConcurrency)
	server.sessions.Store(sessionKey(provider.ProviderID, provider.AssignedID), session)
	go session.runWriter()

	probeDone := make(chan struct{})
	go func() {
		defer close(probeDone)
		probed := readModelAdmissionProbeRequestFrame(t, providerConn)
		server.handleInferenceChunk(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseChunk{
			Type:      "inference_response_chunk",
			RequestID: probed.RequestID,
			Seq:       0,
			Data:      `{"choices":[{"message":{"content":"ok"}}]}`,
		}))
		server.handleInferenceEnd(provider.ProviderID, provider.AssignedID, mustJSON(InferenceResponseEnd{
			Type:       "inference_response_end",
			RequestID:  probed.RequestID,
			Status:     "complete",
			ChunksSent: 1,
		}))
	}()

	candidateID := "byom_" + strings.Repeat("v", 52)
	payload := signedModelAdmissionProbeOffer(t, provider.ProviderID, candidateID, "ollama:qwen3-8b", priv, nil)
	status, body := postModelAdmissionProbeOfferWithContext(t, ctx, server, bearer, payload)
	if status != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", status, body)
	}
	<-probeDone
	response := decodeModelAdmissionProbeMap(t, body)
	if response["admission_state"] != "network_admitted_unsettled" {
		t.Fatalf("request cancellation prevented probe result response: %#v", response)
	}
	latest, found, err := sqliteAdmissions.LatestModelAdmissionStatus(context.Background(), provider.ProviderID, candidateID)
	if err != nil || !found {
		t.Fatalf("latest status found=%v err=%v", found, err)
	}
	if latest.State != "network_admitted_unsettled" {
		t.Fatalf("request cancellation stranded admission state: %+v", latest)
	}
}

func TestModelAdmissionOfferHandlerDoesNotDereferenceProviderEndpointWithoutWSSession(t *testing.T) {
	endpointHits := make(chan struct{}, 1)
	endpoint := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		endpointHits <- struct{}{}
		http.Error(w, "must not be called", http.StatusTeapot)
	}))
	defer endpoint.Close()

	registry := pool.NewRegistry(nil)
	registry.Register(&pool.Provider{
		ProviderID:      "provider-byom-http",
		AssignedID:      "session-http",
		ModelID:         "catalog-default",
		EndpointURL:     endpoint.URL,
		Tier:            pool.TierProvisional,
		InferencePath:   pool.InferencePathHTTPForwarding,
		State:           pool.StateReady,
		SlotsFree:       1,
		SlotsTotal:      1,
		MaxConcurrency:  1,
		LastActivityAt:  time.Now().UTC(),
		LastHeartbeatAt: time.Now().UTC(),
	}, nil)
	admissions := NewMemoryModelAdmissionStore()
	tokens, bearer, priv := bindModelAdmissionProbeIdentity(t, "provider-byom-http")
	server := NewServer(modelAdmissionProbeAuthConfig(), registry, zerolog.Nop(),
		WithTokenValidator(tokens),
		WithTokenIssuer(tokens),
		WithBootstrapTokenStore(tokens),
		WithModelAdmissionStore(admissions),
	)

	candidateID := "byom_" + strings.Repeat("u", 52)
	payload := signedModelAdmissionProbeOffer(t, "provider-byom-http", candidateID, "ollama:qwen3-8b", priv, nil)
	status, body := postModelAdmissionProbeOffer(t, server, bearer, payload)
	if status != http.StatusOK {
		t.Fatalf("offer status=%d body=%s", status, body)
	}
	response := decodeModelAdmissionProbeMap(t, body)
	if response["admission_state"] != modelAdmissionOfferSubmitted {
		t.Fatalf("unexpected offer response without WS session: %#v", response)
	}
	select {
	case <-endpointHits:
		t.Fatal("model admission trigger dereferenced provider EndpointURL")
	case <-time.After(100 * time.Millisecond):
	}
}

func modelAdmissionProbeOffer(tag, candidateRune string) ModelAdmissionEvent {
	return ModelAdmissionEvent{
		ProviderID:               "provider-byom-a",
		CandidateID:              "byom_" + strings.Repeat(candidateRune, 52),
		ServedModelRef:           "ollama:qwen3-8b",
		DiscoveryDigestSHA256:    modelAdmissionProbeStringsOf("a", 64),
		EvaluationDigestSHA256:   modelAdmissionProbeStringsOf("b", 64),
		RequestedDisclosureClass: "non_earning_provider_asserted",
		ReasonCode:               "provider_offer_submitted",
		RequestID:                "request_offer_probe_" + tag,
		Nonce:                    "nonce_offer_probe_" + tag,
		PayloadDigestSHA256:      modelAdmissionProbeStringsOf("c", 64),
		SignatureDigestSHA256:    modelAdmissionProbeStringsOf("d", 64),
		CreatedAt:                time.Unix(1800000200, 0).UTC(),
	}
}

func readModelAdmissionProbeRequestFrame(t *testing.T, conn net.Conn) InferenceRequest {
	t.Helper()
	if err := conn.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
		t.Fatalf("set read deadline: %v", err)
	}
	defer conn.SetReadDeadline(time.Time{})
	payload, op, err := wsutil.ReadServerData(conn)
	if err != nil {
		t.Fatalf("read synthetic probe inference request: %v", err)
	}
	if op != gobwas.OpText {
		t.Fatalf("op = %v, want text", op)
	}
	var req InferenceRequest
	if err := json.Unmarshal(payload, &req); err != nil {
		t.Fatalf("inference request json: %v", err)
	}
	if req.Type != "inference_request" {
		t.Fatalf("request type = %q, want inference_request", req.Type)
	}
	return req
}

func openProbeAdmissionStore(t *testing.T) *auth.Store {
	t.Helper()
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })
	return store
}

func modelAdmissionProbeStringsOf(value string, count int) string {
	return strings.Repeat(value, count)
}

func modelAdmissionProbeAuthConfig() config.Config {
	cfg := config.Default()
	cfg.Auth.RequireProviderTokens = true
	return cfg
}

func bindModelAdmissionProbeIdentity(t *testing.T, providerID string) (*auth.Store, string, ed25519.PrivateKey) {
	t.Helper()
	store := openProbeAdmissionStore(t)
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	_, bearer, err := store.IssueToken(context.Background(), providerID, providerID)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.BindAdmissionIdentity(context.Background(), providerID, bearer, pub, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	return store, bearer, priv
}

func signedModelAdmissionProbeOffer(t *testing.T, providerID, candidateID, servedModelRef string, priv ed25519.PrivateKey, overrides map[string]any) map[string]any {
	t.Helper()
	pubkey := priv.Public().(ed25519.PublicKey)
	pubkeyDigest := sha256.Sum256(pubkey)
	signedFields := map[string]any{
		"signature_domain":         "macprovider.model_admission.offer.v1",
		"provider_id":              providerID,
		"candidate_id":             candidateID,
		"runtime_source":           "ollama_loopback",
		"served_model_ref":         servedModelRef,
		"catalog_model_key":        "",
		"discovery_digest_sha256":  modelAdmissionProbeStringsOf("a", 64),
		"evaluation_digest_sha256": modelAdmissionProbeStringsOf("b", 64),
		"artifact_hashes":          map[string]any{},
		"advisory_capabilities": map[string]any{
			"chat_completions":              true,
			"streaming":                     nil,
			"tool_call_passthrough":         nil,
			"structured_output_passthrough": nil,
			"json_mode":                     nil,
			"usage_reporting":               nil,
			"max_context_tokens":            2048,
			"quantization":                  nil,
			"family":                        nil,
			"runtime_version":               nil,
		},
		"fit_evidence_source":        "local_discovery",
		"local_readiness":            "ready",
		"requested_disclosure_class": "non_earning_provider_asserted",
		"timestamp":                  time.Now().UTC().Format(time.RFC3339Nano),
		"nonce":                      "nonce_" + candidateID,
		"idempotency_key":            "request_" + candidateID,
		"signing_key_digest":         hex.EncodeToString(pubkeyDigest[:]),
		"cli_version":                "1.8.111",
	}
	for key, value := range overrides {
		signedFields[key] = value
	}
	canonical, err := billing.CanonicalJSON(signedFields)
	if err != nil {
		t.Fatal(err)
	}
	signature := ed25519.Sign(priv, canonical)
	request := map[string]any{"schema": "model_admission_offer_submit.v1"}
	for key, value := range signedFields {
		request[key] = value
	}
	request["signature_algorithm"] = "ed25519"
	request["provider_signature"] = base64.StdEncoding.EncodeToString(signature)
	return request
}

func postModelAdmissionProbeOffer(t *testing.T, server *Server, bearer string, payload map[string]any) (int, string) {
	t.Helper()
	return postModelAdmissionProbeOfferWithContext(t, context.Background(), server, bearer, payload)
}

func postModelAdmissionProbeOfferWithContext(t *testing.T, ctx context.Context, server *Server, bearer string, payload map[string]any) (int, string) {
	t.Helper()
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequestWithContext(ctx, http.MethodPost, "/v1/provider/model-admission/offers", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+bearer)
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()
	server.handleProviderModelAdmissionOffer(rr, req)
	resp := rr.Result()
	defer resp.Body.Close()
	out, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(out)
}

type cancelAfterModelAdmissionOfferStore struct {
	ModelAdmissionStore
	cancel context.CancelFunc
}

func (s cancelAfterModelAdmissionOfferStore) AppendModelAdmissionOffer(ctx context.Context, event ModelAdmissionEvent) (ModelAdmissionEvent, bool, error) {
	stored, replay, err := s.ModelAdmissionStore.AppendModelAdmissionOffer(ctx, event)
	if err == nil {
		s.cancel()
	}
	return stored, replay, err
}

func decodeModelAdmissionProbeMap(t *testing.T, body string) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode json: %v body=%s", err, body)
	}
	return out
}
