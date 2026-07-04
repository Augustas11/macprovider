package scenario

import (
	"strings"
	"testing"
	"time"
)

func TestValidateChargedDeliveredToleranceBounds(t *testing.T) {
	sc := validTestScenario()
	sc.ChargedDeliveredToleranceTokens = maxChargedDeliveredToleranceTokens
	if err := sc.Validate(); err != nil {
		t.Fatalf("max tolerance should validate: %v", err)
	}

	sc.ChargedDeliveredToleranceTokens = -1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must be >= 0") {
		t.Fatalf("negative tolerance err=%v, want >= 0 validation", err)
	}

	sc.ChargedDeliveredToleranceTokens = maxChargedDeliveredToleranceTokens + 1
	if err := sc.Validate(); err == nil || !strings.Contains(err.Error(), "must be <=") {
		t.Fatalf("oversized tolerance err=%v, want max validation", err)
	}
}

func validTestScenario() Scenario {
	return Scenario{
		Name:     "test",
		Duration: time.Second,
		Target: Target{
			GatewayURL:     "http://gateway.test",
			BuyerToken:     "token",
			CoordinatorURL: "http://coordinator.test",
		},
		Buyers: Buyers{
			Count:            1,
			RequestsPerBuyer: 1,
			Pattern:          "constant",
		},
		Prompts: []Prompt{{Model: "model-a", User: "hello"}},
	}
}
