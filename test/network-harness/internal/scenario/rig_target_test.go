package scenario

import (
	"strings"
	"testing"
	"time"
)

// rigScenario returns a scenario with target.rig=local and a minimal
// valid providers list. Callers mutate the return before running
// Validate() so each test isolates one field.
func rigScenario() Scenario {
	return Scenario{
		Name:     "rig-test",
		Duration: time.Second,
		Target: Target{
			Rig: "local",
			Providers: []RigProvider{
				{ID: "prov-a", Model: "test-model", TTFTMs: 0, TokensPerSec: 20, CapacitySlots: 4},
			},
		},
		Buyers: Buyers{
			Count:            2,
			RequestsPerBuyer: 1,
			Pattern:          "constant",
		},
		Prompts: []Prompt{{Model: "test-model", User: "hi"}},
	}
}

func TestValidateRig_HappyPath(t *testing.T) {
	sc := rigScenario()
	if err := sc.Validate(); err != nil {
		t.Fatalf("rig scenario should validate: %v", err)
	}
}

func TestValidateRig_UnknownValueRejected(t *testing.T) {
	sc := rigScenario()
	sc.Target.Rig = "bogus"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "target.rig must be") {
		t.Fatalf("unknown rig value err=%v", err)
	}
}

func TestValidateRig_MutuallyExclusiveWithGatewayURL(t *testing.T) {
	sc := rigScenario()
	sc.Target.GatewayURL = "https://api.streamvc.live"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "gateway_url must not be set") {
		t.Fatalf("rig+gateway_url err=%v", err)
	}
}

func TestValidateRig_MutuallyExclusiveWithCoordinatorURL(t *testing.T) {
	sc := rigScenario()
	sc.Target.CoordinatorURL = "https://coordinator.streamvc.live"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "coordinator_url must not be set") {
		t.Fatalf("rig+coordinator_url err=%v", err)
	}
}

func TestValidateRig_MutuallyExclusiveWithBuyerToken(t *testing.T) {
	sc := rigScenario()
	sc.Target.BuyerToken = "mp_seeded"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "buyer_token must not be set") {
		t.Fatalf("rig+buyer_token err=%v", err)
	}
}

func TestValidateRig_MutuallyExclusiveWithDBPath(t *testing.T) {
	sc := rigScenario()
	sc.Target.CoordinatorDBPath = "/tmp/coord.db"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "db_path") {
		t.Fatalf("rig+db_path err=%v", err)
	}
}

func TestValidateRig_MutuallyExclusiveWithDBSSH(t *testing.T) {
	sc := rigScenario()
	sc.Target.CoordinatorDBSSH = "pearl:/tmp/coord.db"
	sc.Target.GatewayDBSSH = "pearl:/tmp/gw.db"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "db_ssh") {
		t.Fatalf("rig+db_ssh err=%v", err)
	}
}

func TestValidateRig_EmptyProvidersRejected(t *testing.T) {
	sc := rigScenario()
	sc.Target.Providers = nil
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must list at least one") {
		t.Fatalf("empty providers err=%v", err)
	}
}

func TestValidateRig_DuplicateProviderID(t *testing.T) {
	sc := rigScenario()
	sc.Target.Providers = append(sc.Target.Providers, RigProvider{
		ID: "prov-a", Model: "test-model", CapacitySlots: 4,
	})
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "duplicates") {
		t.Fatalf("duplicate provider id err=%v", err)
	}
}

func TestValidateRig_ProviderMissingModel(t *testing.T) {
	sc := rigScenario()
	sc.Target.Providers[0].Model = ""
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "model is required") {
		t.Fatalf("missing model err=%v", err)
	}
}

func TestValidateRig_NegativeTTFT(t *testing.T) {
	sc := rigScenario()
	sc.Target.Providers[0].TTFTMs = -1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "ttft_ms") {
		t.Fatalf("negative ttft err=%v", err)
	}
}

func TestValidateRig_NegativeTokensPerSec(t *testing.T) {
	sc := rigScenario()
	sc.Target.Providers[0].TokensPerSec = -0.5
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "tokens_per_sec") {
		t.Fatalf("negative tps err=%v", err)
	}
}

func TestValidateRig_CapacitySlotsZero(t *testing.T) {
	sc := rigScenario()
	sc.Target.Providers[0].CapacitySlots = 0
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "capacity_slots") {
		t.Fatalf("zero capacity err=%v", err)
	}
}

func TestValidateRig_PromptModelNotAdvertised(t *testing.T) {
	sc := rigScenario()
	sc.Prompts[0].Model = "different-model"
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "not advertised") {
		t.Fatalf("unadvertised model err=%v", err)
	}
}

func TestValidateRig_ProvidersRequiresRig(t *testing.T) {
	sc := validTestScenario()
	sc.Target.Providers = []RigProvider{{ID: "x", Model: "m", CapacitySlots: 1}}
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "target.providers must not be set unless") {
		t.Fatalf("providers without rig err=%v", err)
	}
}

func TestProdLoadGuard_LowConcurrencyAllowed(t *testing.T) {
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://api.streamvc.live"
	sc.Buyers.Count = ProdLoadGuardBuyerLimit
	if err := sc.Validate(); err != nil {
		t.Fatalf("count=%d against prod must be allowed: %v", sc.Buyers.Count, err)
	}
}

func TestProdLoadGuard_HighConcurrencyRejected(t *testing.T) {
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://api.streamvc.live"
	sc.Buyers.Count = ProdLoadGuardBuyerLimit + 1
	// Ensure ALLOW_PROD_LOAD is not set in the test env — the harness
	// process shouldn't have it, but be explicit.
	t.Setenv(ProdLoadGuardEnv, "")
	err := sc.Validate()
	if err == nil || !strings.Contains(err.Error(), "requires ALLOW_PROD_LOAD=1") {
		t.Fatalf("count=%d against prod must be rejected without override: %v", sc.Buyers.Count, err)
	}
}

func TestProdLoadGuard_OverrideAccepted(t *testing.T) {
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://api.streamvc.live"
	sc.Buyers.Count = 50
	t.Setenv(ProdLoadGuardEnv, "1")
	if err := sc.Validate(); err != nil {
		t.Fatalf("override should permit count=50 against prod: %v", err)
	}
}

func TestProdLoadGuard_NonProdHostSkipsGuard(t *testing.T) {
	sc := validTestScenario()
	sc.Target.GatewayURL = "http://127.0.0.1:8080"
	sc.Buyers.Count = 50
	if err := sc.Validate(); err != nil {
		t.Fatalf("local host with count=50 must be allowed: %v", err)
	}
}

func TestProdLoadGuard_TrailingDotHost(t *testing.T) {
	// SEC-r1: `api.streamvc.live.` (DNS root form) must trip the guard
	// exactly like `api.streamvc.live`.
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://api.streamvc.live."
	sc.Buyers.Count = ProdLoadGuardBuyerLimit + 1
	t.Setenv(ProdLoadGuardEnv, "")
	err := sc.Validate()
	if err == nil || !strings.Contains(err.Error(), "requires ALLOW_PROD_LOAD=1") {
		t.Fatalf("trailing-dot host must trip guard: %v", err)
	}
}

func TestProdLoadGuard_UpperCaseHost(t *testing.T) {
	sc := validTestScenario()
	sc.Target.GatewayURL = "HTTPS://API.STREAMVC.LIVE"
	sc.Buyers.Count = ProdLoadGuardBuyerLimit + 1
	t.Setenv(ProdLoadGuardEnv, "")
	err := sc.Validate()
	if err == nil || !strings.Contains(err.Error(), "requires ALLOW_PROD_LOAD=1") {
		t.Fatalf("uppercase host must trip guard: %v", err)
	}
}

func TestProdLoadGuard_ApexHostTrips(t *testing.T) {
	// Apex `streamvc.live` (no subdomain) — the check must cover it too,
	// not just entries that end with `.streamvc.live`.
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://streamvc.live"
	sc.Buyers.Count = ProdLoadGuardBuyerLimit + 1
	t.Setenv(ProdLoadGuardEnv, "")
	err := sc.Validate()
	if err == nil || !strings.Contains(err.Error(), "requires ALLOW_PROD_LOAD=1") {
		t.Fatalf("apex host must trip guard: %v", err)
	}
}

func TestProdLoadGuard_OnlyLiteralOneBypasses(t *testing.T) {
	// The bypass must be strict — `true`, `yes`, and any other truthy
	// value must NOT be accepted.
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://api.streamvc.live"
	sc.Buyers.Count = ProdLoadGuardBuyerLimit + 1
	for _, v := range []string{"true", "yes", "TRUE", "on", "2", ""} {
		t.Setenv(ProdLoadGuardEnv, v)
		err := sc.Validate()
		if err == nil {
			t.Fatalf("ALLOW_PROD_LOAD=%q must not bypass guard", v)
		}
	}
}

func TestProdLoadGuard_CoordinatorHostAlsoTrips(t *testing.T) {
	sc := validTestScenario()
	sc.Target.GatewayURL = "https://coordinator.streamvc.live"
	sc.Buyers.Count = 11
	t.Setenv(ProdLoadGuardEnv, "")
	err := sc.Validate()
	if err == nil || !strings.Contains(err.Error(), "requires ALLOW_PROD_LOAD=1") {
		t.Fatalf("*.streamvc.live suffix should trip guard: %v", err)
	}
}
