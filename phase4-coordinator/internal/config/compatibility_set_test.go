package config

import (
	"strings"
	"testing"
)

const (
	compatibilitySetTarget   = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	compatibilitySetRollback = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
)

func TestCompatibilitySetPolicyRequiresTargetAndRollbackSet(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:    compatibilitySetTarget,
		AcceptedIDs: []string{compatibilitySetTarget},
	}

	err := cfg.Validate()
	if err == nil || !strings.Contains(err.Error(), "at least one rollback set") {
		t.Fatalf("Validate() error = %v, want rollback-set requirement", err)
	}
}

func TestCompatibilitySetPolicyAcceptsExactTargetAndRollbackSet(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:    compatibilitySetTarget,
		AcceptedIDs: []string{compatibilitySetTarget, compatibilitySetRollback},
	}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	if !cfg.Coordinator.CompatibilitySet.Accepts(compatibilitySetRollback) {
		t.Fatal("rollback compatibility set was not accepted")
	}
	if cfg.Coordinator.CompatibilitySet.Accepts(strings.ToUpper(compatibilitySetRollback)) {
		t.Fatal("compatibility-set admission must be exact and case-sensitive")
	}
}

func TestCompatibilitySetPolicyRejectsMalformedAndPartialConfiguration(t *testing.T) {
	tests := []struct {
		name   string
		policy CompatibilitySetConfig
		want   string
	}{
		{
			name:   "accepted IDs without target",
			policy: CompatibilitySetConfig{AcceptedIDs: []string{compatibilitySetTarget, compatibilitySetRollback}},
			want:   "target_id",
		},
		{
			name: "target omitted from accepted IDs",
			policy: CompatibilitySetConfig{
				TargetID: compatibilitySetTarget,
				AcceptedIDs: []string{
					compatibilitySetRollback,
					"Augustas11/macprovider:v1.8.2@cccccccccccccccccccccccccccccccccccccccc",
				},
			},
			want: "must contain target_id",
		},
		{
			name: "malformed accepted ID",
			policy: CompatibilitySetConfig{
				TargetID:    compatibilitySetTarget,
				AcceptedIDs: []string{compatibilitySetTarget, "not-a-signed-release-set"},
			},
			want: "invalid compatibility_set_id",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := Default()
			cfg.Auth.OperatorKey = "test-operator-key"
			cfg.Coordinator.CompatibilitySet = test.policy
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestUnconfiguredCompatibilitySetPolicyRetainsLegacyValidation(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	if cfg.Coordinator.CompatibilitySet.Configured() {
		t.Fatal("default compatibility-set policy must be unconfigured")
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
}
