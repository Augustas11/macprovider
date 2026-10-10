package config

import (
	"os"
	"strings"
	"testing"
)

const (
	compatibilitySetTarget   = "Augustas11/macprovider:v1.8.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	compatibilitySetRollback = "Augustas11/macprovider:v1.8.3@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	compatibilitySetOld      = "Augustas11/macprovider:v1.8.117@cccccccccccccccccccccccccccccccccccccccc"
	compatibilitySetFuture   = "Augustas11/macprovider:v1.9.0@dddddddddddddddddddddddddddddddddddddddd"
	compatibilitySetRevoked  = "Augustas11/macprovider:v1.8.2@eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
	compatibilitySetForeign  = "Augustas11/other:v1.8.4@ffffffffffffffffffffffffffffffffffffffff"
)

func repositoryPolicy() CompatibilitySetConfig {
	return CompatibilitySetConfig{TargetID: compatibilitySetTarget, RevokedIDs: []string{compatibilitySetRevoked}}
}

// SPEC-002-R004: any well-formed target-repository release serves buyers,
// older or newer than the target, without an allowlist or floor.
func TestCompatibilitySetAdmitsEveryWellFormedTargetRepositoryRelease(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = repositoryPolicy()
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	policy := cfg.Coordinator.CompatibilitySet
	for _, id := range []string{compatibilitySetTarget, compatibilitySetRollback, compatibilitySetOld, compatibilitySetFuture} {
		if !policy.Accepts(id) || !policy.AllowsSession(id) || policy.IsUpdateOnly(id) {
			t.Fatalf("%s: Accepts=%v AllowsSession=%v IsUpdateOnly=%v, want buyer-serving", id,
				policy.Accepts(id), policy.AllowsSession(id), policy.IsUpdateOnly(id))
		}
	}
}

func TestCompatibilitySetRevokedReleaseIsUpdateOnly(t *testing.T) {
	policy := repositoryPolicy()
	if policy.Accepts(compatibilitySetRevoked) {
		t.Fatal("revoked release must not serve buyers")
	}
	if !policy.AllowsSession(compatibilitySetRevoked) || !policy.IsUpdateOnly(compatibilitySetRevoked) {
		t.Fatal("revoked release must keep an update-only session")
	}
	if got := policy.RejectionCode(compatibilitySetRevoked); got != "provider_release_revoked" {
		t.Fatalf("RejectionCode = %q, want provider_release_revoked", got)
	}
	// Revocation is exact: another commit at the same version still serves.
	sameVersion := "Augustas11/macprovider:v1.8.2@1111111111111111111111111111111111111111"
	if !policy.Accepts(sameVersion) {
		t.Fatal("revocation must match the exact identity only")
	}
}

func TestCompatibilitySetRejectsForeignMalformedAndNoncanonicalIDs(t *testing.T) {
	policy := repositoryPolicy()
	for id, want := range map[string]string{
		"":                                      "compatibility_set_required",
		"not-a-signed-release":                  "compatibility_set_invalid",
		compatibilitySetForeign:                 "compatibility_set_repository_mismatch",
		strings.ToUpper(compatibilitySetTarget): "compatibility_set_invalid",
		"Augustas11/macprovider:v1.8.0224@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa":                "compatibility_set_invalid",
		"Augustas11/macprovider:v9223372036854775808.0.0@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa": "compatibility_set_invalid",
	} {
		if got := policy.RejectionCode(id); got != want {
			t.Errorf("RejectionCode(%q) = %q, want %q", id, got, want)
		}
		if policy.AllowsSession(id) {
			t.Errorf("AllowsSession(%q) = true, want rejected", id)
		}
	}
}

// Existing coordinator.yaml files with the former allowlist and #610 bridge
// list still load; those fields are reported as deprecated and ignored.
func TestCompatibilitySetDeprecatedFieldsStillLoadAndAreIgnored(t *testing.T) {
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:          compatibilitySetTarget,
		AcceptedIDs:       []string{compatibilitySetTarget, compatibilitySetRollback},
		FirstHopBridgeIDs: []string{"Augustas11/macprovider:v1.8.48@b84b430aad74574e8a37bc052fe4f9863d0c0ce8"},
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
	policy := cfg.Coordinator.CompatibilitySet
	if got := policy.DeprecatedFields(); len(got) != 2 || got[0] != "accepted_ids" || got[1] != "first_hop_bridge_ids" {
		t.Fatalf("DeprecatedFields() = %v", got)
	}
	if !policy.Accepts(compatibilitySetOld) {
		t.Fatal("accepted_ids must no longer restrict admission")
	}
}

func TestCompatibilitySetRejectsUnsafeConfiguration(t *testing.T) {
	tests := []struct {
		name   string
		policy CompatibilitySetConfig
		want   string
	}{
		{"accepted IDs without target", CompatibilitySetConfig{AcceptedIDs: []string{compatibilitySetTarget}}, "target_id"},
		{"revocations without target", CompatibilitySetConfig{RevokedIDs: []string{compatibilitySetRevoked}}, "target_id"},
		{"malformed revocation", CompatibilitySetConfig{TargetID: compatibilitySetTarget, RevokedIDs: []string{"bad"}}, "invalid compatibility_set_id"},
		{"duplicate revocation", CompatibilitySetConfig{TargetID: compatibilitySetTarget, RevokedIDs: []string{compatibilitySetRevoked, compatibilitySetRevoked}}, "duplicate"},
		{"foreign revocation", CompatibilitySetConfig{TargetID: compatibilitySetTarget, RevokedIDs: []string{compatibilitySetForeign}}, "repository must match"},
		{"revoked target", CompatibilitySetConfig{TargetID: compatibilitySetTarget, RevokedIDs: []string{compatibilitySetTarget}}, "must not contain target_id"},
		{"leading-zero target", CompatibilitySetConfig{TargetID: "Augustas11/macprovider:v1.08.4@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, "invalid compatibility_set_id"},
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
	if !cfg.Coordinator.CompatibilitySet.Accepts("") {
		t.Fatal("unconfigured policy keeps the legacy open hello")
	}
}

// The checked-in one-time revocation seed (scripts/legacy-compatibility-
// revocations.py) must validate as revoked_ids under the live target repository.
func TestCompatibilitySetCheckedInRevocationSeedValidates(t *testing.T) {
	raw, err := os.ReadFile("../../dist/compatibility-revoked-ids.txt")
	if err != nil {
		t.Fatalf("read seed: %v", err)
	}
	var ids []string
	for _, line := range strings.Split(string(raw), "\n") {
		if line = strings.TrimSpace(line); line != "" && !strings.HasPrefix(line, "#") {
			ids = append(ids, line)
		}
	}
	if len(ids) == 0 {
		t.Fatal("revocation seed is empty")
	}
	cfg := validTestConfig()
	cfg.Coordinator.CompatibilitySet = CompatibilitySetConfig{
		TargetID:   "Augustas11/macprovider:v1.8.232@aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		RevokedIDs: ids,
	}
	if err := cfg.Validate(); err != nil {
		t.Fatalf("seed does not validate: %v", err)
	}
	for _, id := range ids {
		if !cfg.Coordinator.CompatibilitySet.IsUpdateOnly(id) {
			t.Fatalf("%s must connect update-only", id)
		}
	}
}
