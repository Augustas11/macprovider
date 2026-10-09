package config

import (
	"strings"
	"testing"
)

const (
	compatibilitySetTarget    = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	compatibilitySetRollback  = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	compatibilitySetFuture    = "Augustas11/macprovider:v1.8.99@cccccccccccccccccccccccccccccccccccccccc"
	compatibilitySetBelow     = "Augustas11/macprovider:v1.8.2@dddddddddddddddddddddddddddddddddddddddd"
	compatibilitySetOtherRepo = "Augustas11/other:v1.8.99@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
)

func TestCompatibilitySetPolicyRequiresTargetAndRollbackSet(t *testing.T) {
	cfg := validTestConfig()
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
	cfg := validTestConfig()
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

func TestCompatibilitySetMinimumVersionAcceptsFutureSameRepoWithoutAllowlist(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:       compatibilitySetTarget,
		MinimumVersion: "1.8.4",
	}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	policy := cfg.Coordinator.CompatibilitySet
	if !policy.Accepts(compatibilitySetTarget) {
		t.Fatal("target compatibility set was not accepted")
	}
	if !policy.Accepts(compatibilitySetFuture) {
		t.Fatal("future same-repo compatibility set was not accepted")
	}
	if code := policy.RejectionCode(compatibilitySetFuture); code != "" {
		t.Fatalf("RejectionCode(future) = %q, want accepted", code)
	}
	if !policy.AllowsSession(compatibilitySetFuture) {
		t.Fatal("future same-repo compatibility set must allow a session")
	}
}

func TestCompatibilitySetMinimumVersionRejectsBelowFloorRevokedAndOtherRepo(t *testing.T) {
	revoked := "Augustas11/macprovider:v1.8.8@ffffffffffffffffffffffffffffffffffffffff"
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:       compatibilitySetTarget,
		MinimumVersion: "1.8.4",
		RevokedIDs:     []string{revoked},
	}

	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	policy := cfg.Coordinator.CompatibilitySet
	for _, test := range []struct {
		name string
		id   string
		want string
	}{
		{name: "below floor", id: compatibilitySetBelow, want: "provider_version_below_minimum"},
		{name: "revoked", id: revoked, want: "provider_release_revoked"},
		{name: "other repo", id: compatibilitySetOtherRepo, want: "compatibility_set_repository_mismatch"},
		{name: "malformed", id: "not-a-signed-release-set", want: "compatibility_set_invalid"},
		{name: "missing", id: "", want: "compatibility_set_required"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if policy.Accepts(test.id) {
				t.Fatalf("Accepts(%q) = true, want false", test.id)
			}
			if got := policy.RejectionCode(test.id); got != test.want {
				t.Fatalf("RejectionCode(%q) = %q, want %q", test.id, got, test.want)
			}
		})
	}
}

func TestCompatibilitySetMinimumVersionRejectsUnsafeConfig(t *testing.T) {
	overflowID := "Augustas11/macprovider:v999999999999999999999.0.0@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	tests := []struct {
		name   string
		policy CompatibilitySetConfig
		want   string
	}{
		{
			name: "accepted ids mixed with floor",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "1.8.4",
				AcceptedIDs:    []string{compatibilitySetTarget, compatibilitySetRollback},
			},
			want: "must not be combined with accepted_ids",
		},
		{
			name: "revoked ids without floor",
			policy: CompatibilitySetConfig{
				TargetID:    compatibilitySetTarget,
				AcceptedIDs: []string{compatibilitySetTarget, compatibilitySetRollback},
				RevokedIDs:  []string{compatibilitySetFuture},
			},
			want: "revoked_ids require minimum_version",
		},
		{
			name: "partial floor",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "1.8",
			},
			want: "strict three-component numeric version",
		},
		{
			name: "whitespace floor",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: " 1.8.4 ",
			},
			want: "strict three-component numeric version",
		},
		{
			name: "overflow floor",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "999999999999999999999.0.0",
			},
			want: "strict three-component numeric version",
		},
		{
			name: "target below floor",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "1.8.5",
			},
			want: "provider_version_below_minimum",
		},
		{
			name: "revoked other repo",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "1.8.4",
				RevokedIDs:     []string{compatibilitySetOtherRepo},
			},
			want: "repository must match target_id",
		},
		{
			name: "revoked overflow version",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "1.8.4",
				RevokedIDs:     []string{overflowID},
			},
			want: "invalid numeric version",
		},
		{
			name: "duplicate revoked",
			policy: CompatibilitySetConfig{
				TargetID:       compatibilitySetTarget,
				MinimumVersion: "1.8.4",
				RevokedIDs:     []string{compatibilitySetFuture, compatibilitySetFuture},
			},
			want: "duplicate",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.Coordinator.CompatibilitySet = test.policy
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want substring %q", err, test.want)
			}
		})
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
			cfg := validTestConfig()
			cfg.Coordinator.CompatibilitySet = test.policy
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestUnconfiguredCompatibilitySetPolicyRetainsLegacyValidation(t *testing.T) {
	cfg := validTestConfig()
	if cfg.Coordinator.CompatibilitySet.Configured() {
		t.Fatal("default compatibility-set policy must be unconfigured")
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
}

func TestCompatibilitySetConfiguredIncludesVersionPolicyFields(t *testing.T) {
	for _, policy := range []CompatibilitySetConfig{
		{MinimumVersion: "1.8.4"},
		{RevokedIDs: []string{compatibilitySetFuture}},
	} {
		if !policy.Configured() {
			t.Fatalf("Configured() = false for %+v", policy)
		}
	}
}

const compatibilitySetFirstHop = "Augustas11/macprovider:v1.8.48@b84b430aad74574e8a37bc052fe4f9863d0c0ce8"

func TestCompatibilitySetFirstHopBridgeAllowsSessionWithoutBuyerAcceptance(t *testing.T) {
	cfg := validTestConfig()
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

func TestCompatibilitySetMinimumVersionBridgeRemainsUpdateOnly(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:          compatibilitySetTarget,
		MinimumVersion:    "1.8.4",
		FirstHopBridgeIDs: []string{compatibilitySetBelow},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	policy := cfg.Coordinator.CompatibilitySet
	if policy.Accepts(compatibilitySetBelow) {
		t.Fatal("below-floor bridge must not satisfy buyer-serving admission")
	}
	if !policy.IsFirstHopBridgeOnly(compatibilitySetBelow) {
		t.Fatal("below-floor bridge must remain bridge-only")
	}
	if !policy.AllowsSession(compatibilitySetBelow) {
		t.Fatal("below-floor bridge must allow update session")
	}
}

func TestCompatibilitySetFirstHopBridgeRejectsOverlapAndTarget(t *testing.T) {
	overflowBridge := "Augustas11/macprovider:v999999999999999999999.0.0@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
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
		{
			name: "overlap revoked",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				MinimumVersion:    "1.8.4",
				RevokedIDs:        []string{compatibilitySetBelow},
				FirstHopBridgeIDs: []string{compatibilitySetBelow},
			},
			want: "must not overlap revoked_ids",
		},
		{
			name: "bridge satisfies floor",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				MinimumVersion:    "1.8.4",
				FirstHopBridgeIDs: []string{compatibilitySetFuture},
			},
			want: "must remain update-only",
		},
		{
			name: "bridge other repo",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				MinimumVersion:    "1.8.4",
				FirstHopBridgeIDs: []string{compatibilitySetOtherRepo},
			},
			want: "repository must match target_id",
		},
		{
			name: "bridge overflow version",
			policy: CompatibilitySetConfig{
				TargetID:          compatibilitySetTarget,
				MinimumVersion:    "1.8.4",
				FirstHopBridgeIDs: []string{overflowBridge},
			},
			want: "invalid numeric version",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := validTestConfig()
			cfg.Coordinator.CompatibilitySet = test.policy
			err := cfg.Validate()
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("Validate() error = %v, want substring %q", err, test.want)
			}
		})
	}
}

func TestCompatibilitySetRevocationPreservesOtherCommitAtSameVersion(t *testing.T) {
	revoked := "Augustas11/macprovider:v1.8.8@ffffffffffffffffffffffffffffffffffffffff"
	alternate := "Augustas11/macprovider:v1.8.8@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{TargetID: compatibilitySetTarget, MinimumVersion: "1.8.4", RevokedIDs: []string{revoked}}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	if cfg.Coordinator.CompatibilitySet.Accepts(revoked) || !cfg.Coordinator.CompatibilitySet.Accepts(alternate) {
		t.Fatal("revocation must deny only the exact release identity, preserving other commits at the same version")
	}
}
