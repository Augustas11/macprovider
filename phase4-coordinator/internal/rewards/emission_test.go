package rewards_test

import (
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/rewards"
)

func TestConfigDefaultsAndValidate(t *testing.T) {
	cfg := rewards.Config{Enabled: true, WriterDSN: "postgres://x", SQLitePayoutDBPath: "/tmp/x.db"}
	applied := cfg.DefaultsApplied()
	if applied.TickInterval != 15*time.Minute {
		t.Fatalf("tick interval = %v", applied.TickInterval)
	}
	if applied.ProviderDailyCapMALIBU != 25 {
		t.Fatalf("provider cap = %v", applied.ProviderDailyCapMALIBU)
	}
	if applied.WalletDailyCapMALIBU != 100 {
		t.Fatalf("wallet cap = %v", applied.WalletDailyCapMALIBU)
	}
	if err := applied.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}

	disabled := rewards.Config{Enabled: false}
	if err := disabled.Validate(); err != nil {
		t.Fatalf("disabled validate: %v", err)
	}

	missing := rewards.Config{Enabled: true}
	if err := missing.Validate(); err == nil {
		t.Fatal("expected error for missing writer dsn")
	}
}

func TestHoldReasonConstants(t *testing.T) {
	if rewards.HoldTrustTierProvisional == "" {
		t.Fatal("hold constant must be set")
	}
}
