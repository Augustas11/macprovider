package ws

import (
	"encoding/json"
	"os"
	"testing"
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
