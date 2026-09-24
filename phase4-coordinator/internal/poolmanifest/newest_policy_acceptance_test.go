package poolmanifest

import (
	"errors"
	"testing"
)

// A NEW acceptance uses the online gate: a policy signed by a revoked signer set
// is rejected even though ReconstructPool would grandfather a recorded one.
func TestVerifyNewestPolicyAcceptanceUsesOnlineGate(t *testing.T) {
	root, entries, _ := revokedV1AuthLog(t)
	pol := policyCore(t, 1, GenesisPrevHash(), 1000, 2000) // SignerSetVersion 1, revoked
	snap := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: root, AuthorityLog: entries,
		Policies: []AcceptedPolicyRecord{{SignedCore: signPolicy2of3(t, pol), AcceptedAtUnix: 1500}},
	}
	if _, err := ReconstructPool(snap); err != nil {
		t.Fatalf("replay should still grandfather the recorded verdict: %v", err)
	}
	if err := VerifyNewestPolicyAcceptance(snap); !errors.Is(err, errSignerSetRevoked) {
		t.Fatalf("new acceptance under a revoked signer set: err=%v, want errSignerSetRevoked", err)
	}

	gRoot, gEntries, _ := genesisAuthLog(t)
	ok := ManifestSnapshot{
		IdentityCore: sampleIdentity(), RootIssuerKey: gRoot, AuthorityLog: gEntries,
		Policies: []AcceptedPolicyRecord{{SignedCore: signPolicy2of3(t, pol), AcceptedAtUnix: 1500}},
	}
	if err := VerifyNewestPolicyAcceptance(ok); err != nil {
		t.Fatalf("new acceptance under an active signer set: %v", err)
	}
	if err := VerifyNewestPolicyAcceptance(ManifestSnapshot{IdentityCore: sampleIdentity(), RootIssuerKey: gRoot, AuthorityLog: gEntries}); err == nil {
		t.Fatal("snapshot with no policy must not be acceptable")
	}
}
