package ws

import (
	"encoding/json"
	"net"
	"os"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/config"
	"github.com/augstar/macprovider-coordinator/internal/pool"
	"github.com/gobwas/ws/wsutil"
	"github.com/rs/zerolog"
)

// warmModelsContractFixture is the heartbeat the provider renders while two
// warm members are busy (phase3-binary CoordinatorClientTests
// testContendedHeartbeatPrimaryEntryMatchesTopLevelContract writes and
// checks it), with the supported_models its session declared.
const warmModelsContractFixture = "../../../test/fixtures/warm-models/contended-heartbeat-v1.json"

type warmModelsContract struct {
	SupportedModels []string                   `json:"supported_models"`
	Heartbeat       map[string]json.RawMessage `json:"heartbeat"`
}

func loadWarmModelsContract(t *testing.T) warmModelsContract {
	t.Helper()
	raw, err := os.ReadFile(warmModelsContractFixture)
	if err != nil {
		t.Fatalf("read warm_models contract fixture: %v", err)
	}
	var contract warmModelsContract
	if err := json.Unmarshal(raw, &contract); err != nil {
		t.Fatalf("decode warm_models contract fixture: %v", err)
	}
	return contract
}

// SPEC-001-R016/R018 and SPEC-002-R011: the provider's contended heartbeat
// passes the strict warm_models decoder and the supported_models check, and
// its primary carries the contended estimate at the top level too.
func TestWarmModelsContractFixtureIsAccepted(t *testing.T) {
	contract := loadWarmModelsContract(t)
	payload, err := json.Marshal(contract.Heartbeat)
	if err != nil {
		t.Fatal(err)
	}
	hb, _, field, err := ParseHeartbeat(payload)
	if err != nil {
		t.Fatalf("coordinator rejected the provider's contended heartbeat (field=%q): %v", field, err)
	}
	if err := validateWarmModelsSupported(hb.WarmModels, contract.SupportedModels, hb.ModelID); err != nil {
		t.Fatalf("warm_models outside the declared supported_models: %v", err)
	}
	if len(hb.WarmModels) != 2 || !hb.WarmModels[0].Primary || hb.WarmModels[1].Primary {
		t.Fatalf("warm_models = %+v, want the primary then one further member", hb.WarmModels)
	}
	primary, member := hb.WarmModels[0], hb.WarmModels[1]
	if hb.ThroughputTPSEstimate != primary.ThroughputTPSEstimate || primary.ThroughputTPSEstimate != 20 || member.ThroughputTPSEstimate != 25.7 {
		t.Fatalf("throughput top=%v primary=%v member=%v, want the contended 20 on both and 25.7", hb.ThroughputTPSEstimate, primary.ThroughputTPSEstimate, member.ThroughputTPSEstimate)
	}
	if primary.SlotsTotal != hb.SlotsTotal || primary.SlotsFree != hb.SlotsFree || member.ModelHash == "" {
		t.Fatalf("primary slots %d/%d vs top %d/%d, member hash %q", primary.SlotsFree, primary.SlotsTotal, hb.SlotsFree, hb.SlotsTotal, member.ModelHash)
	}
	// SPEC-001-R019: the member declares its own tool selection modes.
	if len(member.ToolSelectionCapabilities) != 1 || member.ToolSelectionCapabilities[0].ModelID != member.ModelID ||
		member.ToolSelectionCapabilities[0].Validation != "schema-holdback-v1" || primary.ToolSelectionCapabilities != nil {
		t.Fatalf("tool declarations primary=%+v member=%+v", primary.ToolSelectionCapabilities, member.ToolSelectionCapabilities)
	}
}

// The fixture still exercises the check it exists for: the solo estimate at
// the top level beside the contended primary entry drops the heartbeat.
func TestWarmModelsContractFixtureSoloTopLevelIsRejected(t *testing.T) {
	contract := loadWarmModelsContract(t)
	contract.Heartbeat["throughput_tps_estimate"] = json.RawMessage("40")
	payload, err := json.Marshal(contract.Heartbeat)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, field, err := ParseHeartbeat(payload); err == nil || field != warmModelsField {
		t.Fatalf("a solo top-level estimate beside a contended primary entry was accepted (field=%q err=%v)", field, err)
	}
}

// warmModelsFixture is a file in test/fixtures/warm-models/.
func warmModelsFixture(name string) string {
	return "../../../test/fixtures/warm-models/" + name
}

func readWarmModelsFixture(t *testing.T, name string) map[string]json.RawMessage {
	t.Helper()
	raw, err := os.ReadFile(warmModelsFixture(name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	var fixture map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("decode %s: %v", name, err)
	}
	return fixture
}

// overlayProviderFrame lays the provider-rendered fields over a valid base
// frame. The base's own primary fields go first, so the provider's frame
// alone decides what its primary entry is checked against.
func overlayProviderFrame(t *testing.T, base map[string]any, rendered json.RawMessage) []byte {
	t.Helper()
	for _, key := range warmModelsPrimaryFieldKeys {
		delete(base, key)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(rendered, &fields); err != nil {
		t.Fatal(err)
	}
	for key, value := range fields {
		base[key] = value
	}
	payload, err := json.Marshal(base)
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func warmModelIDs(models []pool.WarmModel) []string {
	out := make([]string, 0, len(models))
	for _, m := range models {
		out = append(out, m.ModelID+":"+string(m.State))
	}
	return out
}

// SPEC-001-R016 and SPEC-002-R011: the provider's auth_request initial stage
// and legacy hello (CoordinatorClientTests
// testHandshakeWarmModelsMatchTheContractFixture) pass the real handshake
// parsers with their warm_models.
func TestWarmModelsContractHandshakesAreAccepted(t *testing.T) {
	fixture := readWarmModelsFixture(t, "provider-handshakes-v1.json")

	auth, _, field, err := ParseAuthRequest(overlayProviderFrame(t, validAuthRequestInitial(), fixture["auth_request"]))
	if err != nil {
		t.Fatalf("coordinator rejected the provider's auth_request (field=%q): %v", field, err)
	}
	if got := warmModelIDs(auth.WarmModels); !reflect.DeepEqual(got, []string{"model-a:warm", "model-b:warm", "model-c:loading"}) {
		t.Fatalf("auth_request warm_models = %v", got)
	}
	if !auth.WarmModels[0].Primary || auth.WarmModels[0].ModelID != auth.ModelID || len(auth.SupportedModels) != 3 {
		t.Fatalf("auth_request primary %+v top %q supported %v", auth.WarmModels[0], auth.ModelID, auth.SupportedModels)
	}

	helloBase := map[string]any{
		"type": "hello", "version": 1, "tier": 1, "provider_id": "provider-a", "hostname": "provider.local",
		"ram_gb": 16, "max_concurrency": 1, "binary_version": "0.1.0", "attestation": nil,
	}
	hello, field, err := ParseHello(overlayProviderFrame(t, helloBase, fixture["hello"]))
	if err != nil {
		t.Fatalf("coordinator rejected the provider's hello (field=%q): %v", field, err)
	}
	if got := warmModelIDs(hello.WarmModels); !reflect.DeepEqual(got, []string{"model-a:warm"}) || !hello.WarmModels[0].Primary {
		t.Fatalf("hello warm_models = %v, want its top-level model alone", got)
	}
}

// SPEC-001-R016: heartbeats rendered while a further member loads, while one
// evicts, and at the promotion instant (CoordinatorClientTests
// testHeartbeatsAtMemberTransitionsMatchTheContractFixture) each pass the
// heartbeat parser and the supported_models check, with every member listed
// once and the top-level model as the one primary.
func TestWarmModelsContractHeartbeatTransitionsAreAccepted(t *testing.T) {
	fixture := readWarmModelsFixture(t, "heartbeat-transitions-v1.json")
	var supported []string
	if err := json.Unmarshal(fixture["supported_models"], &supported); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name   string
		top    string
		states []string
	}{
		{"mid_load", "model-a", []string{"model-a:warm", "model-b:warm", "model-c:loading"}},
		{"mid_eviction", "model-a", []string{"model-a:warm", "model-b:evicting", "model-c:loading"}},
		{"promotion_instant", "model-b", []string{"model-b:warm", "model-a:warm", "model-c:loading"}},
	} {
		hb, _, field, err := ParseHeartbeat(fixture[tc.name])
		if err != nil {
			t.Fatalf("%s: coordinator rejected the provider's heartbeat (field=%q): %v", tc.name, field, err)
		}
		if err := validateWarmModelsSupported(hb.WarmModels, supported, hb.ModelID); err != nil {
			t.Fatalf("%s: %v", tc.name, err)
		}
		if got := warmModelIDs(hb.WarmModels); hb.ModelID != tc.top || !reflect.DeepEqual(got, tc.states) || !hb.WarmModels[0].Primary {
			t.Fatalf("%s: top %q warm_models %v, want %q %v", tc.name, hb.ModelID, got, tc.top, tc.states)
		}
		for _, m := range hb.WarmModels[1:] {
			if m.Primary {
				t.Fatalf("%s: a second primary %+v", tc.name, m)
			}
		}
	}
}

// SPEC-001-R016: the provider's refusal of a served_model_id that names no
// warm member (CoordinatorClientTests
// testModelNotLoadedRefusalsMatchTheContractFixture) reads as
// model_not_loaded on each path: the preflight ack's typed rejection, the
// end frame's status and the HTTP body's error code.
func TestWarmModelsContractModelNotLoadedIsClassified(t *testing.T) {
	fixture := readWarmModelsFixture(t, "model-not-loaded-v1.json")
	ack, field, err := ParsePreflightAck(fixture["preflight_ack"])
	if err != nil {
		t.Fatalf("preflight_ack rejected (field=%q): %v", field, err)
	}
	if ack.Rejection() != PreflightRejectionModelNotLoaded {
		t.Fatalf("preflight rejection = %q", ack.Rejection())
	}
	var end InferenceResponseEnd
	if err := json.Unmarshal(fixture["inference_response_end"], &end); err != nil {
		t.Fatal(err)
	}
	if end.Type != "inference_response_end" || end.Status != "error_model_not_loaded" || end.ChunksSent != 0 {
		t.Fatalf("end frame = %+v", end)
	}
	var httpRefusal struct {
		Status int `json:"status"`
		Body   struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		} `json:"body"`
	}
	if err := json.Unmarshal(fixture["http"], &httpRefusal); err != nil {
		t.Fatal(err)
	}
	if httpRefusal.Status != 503 || httpRefusal.Body.Error.Code != "model_not_loaded" {
		t.Fatalf("http refusal = %+v", httpRefusal)
	}
}

const (
	warmModelsDispatchFixture = "coordinator-dispatch-v1.json"
	// warmModelsServedModelHeader is the gateway-forwarded served_model_id
	// header (internal/buyer servedModelHeader).
	warmModelsServedModelHeader = "X-MacProvider-Served-Model"
)

// renderWarmModelsDispatch renders what the coordinator sends a warm-set
// entry: the preflight from Server.Preflight, and the plain, relay-blind and
// encrypted inference_request frames from the dispatch sealers.
func renderWarmModelsDispatch(t *testing.T) map[string]any {
	t.Helper()
	serverConn, providerConn := net.Pipe()
	defer providerConn.Close()
	defer serverConn.Close()
	entry := pool.Provider{
		ProviderID: "provider-a", AssignedID: "session-a", ModelID: "model-a", ServedModelID: "model-b",
		Tier: pool.TierProvisional, InferencePath: pool.InferencePathWSTunneled,
	}
	registry := pool.NewRegistry(nil)
	registry.Register(&entry, serverConn)
	s := NewServer(config.Default(), registry, zerolog.Nop())
	session := newProviderSession(entry.ProviderID, entry.AssignedID, serverConn, 4)
	s.sessions.Store(sessionKey(entry.ProviderID, entry.AssignedID), session)
	go session.runWriter()
	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _, _ = s.Preflight(entry, "req-dispatch", 64, 50*time.Millisecond)
	}()
	preflight, _, err := wsutil.ReadServerData(providerConn)
	if err != nil {
		t.Fatalf("read preflight: %v", err)
	}
	<-done

	body := []byte(`{"model":"model-b","messages":[{"role":"user","content":"hi"}]}`)
	plain, err := (&providerSession{}).sealInferenceRequest(entry, "req-dispatch", body, false, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	relayBlind, err := (&providerSession{}).sealInferenceRequestWithRelayBlind(entry, "req-dispatch", body, false, nil, "", nil,
		&RelayBlindDispatchContext{RequestID: "req-dispatch", AssignedSession: entry.AssignedID, KID: "kid-1"})
	if err != nil {
		t.Fatal(err)
	}
	sealer, _, _ := sealedSizeTestSession()
	encrypted, err := sealer.sealInferenceRequest(entry, "req-dispatch", body, false, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{
		"served_model_id":               entry.ServedModelID,
		"preflight":                     json.RawMessage(preflight),
		"inference_request":             json.RawMessage(plain),
		"inference_request_relay_blind": json.RawMessage(relayBlind),
		"inference_request_encrypted":   json.RawMessage(encrypted),
		"served_model_header":           map[string]string{"name": warmModelsServedModelHeader, "value": entry.ServedModelID},
	}
}

// SPEC-001-R016: the coordinator's dispatch frames for a warm-set entry,
// checked into test/fixtures/warm-models/ for the provider's readers
// (CoordinatorClientTests testCoordinatorDispatchFixtureLeasesTheNamedMember).
// WARM_MODELS_CONTRACT_WRITE=1 rewrites the fixture first.
func TestWarmModelsContractCoordinatorDispatch(t *testing.T) {
	rendered, err := json.MarshalIndent(renderWarmModelsDispatch(t), "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	rendered = append(rendered, '\n')
	path := warmModelsFixture(warmModelsDispatchFixture)
	if os.Getenv("WARM_MODELS_CONTRACT_WRITE") == "1" {
		if err := os.WriteFile(path, rendered, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	golden, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var want, got any
	if err := json.Unmarshal(golden, &want); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(rendered, &got); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(want, got) {
		t.Fatalf("the coordinator's dispatch frames drifted from %s:\n%s", path, rendered)
	}
	frames := readWarmModelsFixture(t, warmModelsDispatchFixture)
	for _, kind := range []string{"preflight", "inference_request", "inference_request_relay_blind", "inference_request_encrypted"} {
		var frame struct {
			ServedModelID string          `json:"served_model_id"`
			Enc           json.RawMessage `json:"enc"`
		}
		if err := json.Unmarshal(frames[kind], &frame); err != nil || frame.ServedModelID != "model-b" {
			t.Fatalf("%s served_model_id = %q (%v)", kind, frame.ServedModelID, err)
		}
		if (kind == "inference_request_encrypted") != (len(frame.Enc) > 0) {
			t.Fatalf("%s enc present = %v", kind, len(frame.Enc) > 0)
		}
	}
}
