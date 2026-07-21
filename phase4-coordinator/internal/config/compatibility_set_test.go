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

const compatibilitySetFirstHop = "Augustas11/macprovider:v1.8.48@b84b430aad74574e8a37bc052fe4f9863d0c0ce8"

func TestCompatibilitySetFirstHopBridgeAllowsSessionWithoutBuyerAcceptance(t *testing.T) {
	cfg := Default()
	cfg.Auth.OperatorKey = "test-operator-key"
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:          compatibilitySetTarget,
		AcceptedIDs:       []string{compatibilitySetTarget, compatibilitySetRollback},
		FirstHopBridgeIDs: []string{compatibilitySetFirstHop},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	policy := cfg.Coordinator.CompatibilitySet
	if policy.Accepts(compatibilitySetFirstHop) {
		t.Fatal("first-hop bridge must not imply buyer-serving Accepts")
	}
	if !policy.IsFirstHopBridge(compatibilitySetFirstHop) {
		t.Fatal("first-hop bridge id was not recognized")
	}
	if !policy.IsFirstHopBridgeOnly(compatibilitySetFirstHop) {
		t.Fatal("first-hop bridge-only predicate failed")
	}
	if !policy.AllowsSession(compatibilitySetFirstHop) {
		t.Fatal("first-hop bridge must allow an update session")
	}
	if !policy.AllowsSession(compatibilitySetRollback) {
		t.Fatal("accepted rollback set must still allow a session")
	}
	if policy.AllowsSession(strings.ToUpper(compatibilitySetFirstHop)) {
		t.Fatal("first-hop bridge admission must be exact and case-sensitive")
	}
}

func TestCompatibilitySetFirstHopBridgeRejectsOverlapAndTarget(t *testing.T) {
	tests := []struct {
		name   string
		policy CompatibilitySetConfig
		want   string
	}{
		{
			name: "overlap accepted",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				AcceptedIDs:       []string{compatibilitySetTarget, compatibilitySetRollback},
				FirstHopBridgeIDs: []string{compatibilitySetRollback},
			},
			want: "must not overlap accepted_ids",
		},
		{
			name: "contains target",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				AcceptedIDs:       []string{compatibilitySetTarget, compatibilitySetRollback},
				FirstHopBridgeIDs: []string{compatibilitySetTarget},
			},
			want: "must not contain target_id",
		},
		{
			name: "duplicate bridge",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				AcceptedIDs:       []string{compatibilitySetTarget, compatibilitySetRollback},
				FirstHopBridgeIDs: []string{compatibilitySetFirstHop, compatibilitySetFirstHop},
			},
			want: "duplicate",
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
