package config

import (
	"strings"
	"testing"
)

// SPEC-022 R-1.3 / R-13.8: relay-blind under enforce is admitted only with
// the R-13 settlement profile; the guard is never lifted by exemption.
func TestRelayBlindEnforceRequiresSettlementProfile(t *testing.T) {
	if got := Default().RelayBlind.EnforceSettlementProfile; got != "" {
		t.Fatalf("default enforce_settlement_profile = %q, want empty", got)
	}
	cases := []struct {
		name    string
		mode    string
		profile string
		wantErr string
	}{
		{name: "observe without profile", mode: "observe"},
		{name: "observe with profile", mode: "observe", profile: RelayBlindSettlementProfileV1},
		{name: "enforce without profile", mode: "enforce", wantErr: "relay_blind.enforce_settlement_profile=relay-blind-settlement-v1"},
		{name: "enforce with profile", mode: "enforce", profile: RelayBlindSettlementProfileV1},
		{name: "enforce with v0.4 profile", mode: "enforce", profile: "spec015-v0.4", wantErr: "relay_blind.enforce_settlement_profile"},
		{name: "observe with unknown profile", mode: "observe", profile: "relay-blind-settlement-v2", wantErr: "relay_blind.enforce_settlement_profile must be empty"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			cfg := privacyReadyConfig(t)
			cfg.PrivacyClass.Enabled = false
			cfg.Settlement.VerifiedModelSettlementMode = tc.mode
			cfg.RelayBlind.EnforceSettlementProfile = tc.profile
			err := cfg.Validate()
			if tc.wantErr == "" {
				if err != nil {
					t.Fatalf("Validate = %v", err)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("Validate = %v, want %q", err, tc.wantErr)
			}
		})
	}
}

// A profile value is validated even while relay-blind is disabled, so a typo
// cannot sit dormant until the pilot is switched on.
func TestRelayBlindSettlementProfileValidatedWhenDisabled(t *testing.T) {
	cfg := validTestConfig()
	cfg.RelayBlind.Enabled = false
	cfg.RelayBlind.EnforceSettlementProfile = "verified"
	if err := cfg.Validate(); err == nil || !strings.Contains(err.Error(), "enforce_settlement_profile") {
		t.Fatalf("Validate = %v", err)
	}
}
