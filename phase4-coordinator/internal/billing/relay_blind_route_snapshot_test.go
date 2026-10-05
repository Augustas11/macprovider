package billing

import (
	"strings"
	"testing"
)

// SPEC-022 R-3.1 (v0.3.0): the relay-blind basis and entrypoint travel
// together, and the basis label is a digested member.
func TestRouteSnapshotRelayBlindBasisBindsToEntrypoint(t *testing.T) {
	plaintext := testRouteSnapshot()
	relayBlind := testRouteSnapshot()
	relayBlind.PaidEntrypoint = PaidEntrypointRelayBlindChat
	relayBlind.PromptHashBasis = PromptHashBasisRelayBlindEnvelopeV1
	if err := plaintext.Validate(); err != nil {
		t.Fatalf("plaintext: %v", err)
	}
	if err := relayBlind.Validate(); err != nil {
		t.Fatalf("relay-blind: %v", err)
	}
	mixed := plaintext
	mixed.PromptHashBasis = PromptHashBasisRelayBlindEnvelopeV1
	if err := mixed.Validate(); err == nil || !strings.Contains(err.Error(), "prompt_hash_basis") {
		t.Fatalf("plaintext entrypoint with relay-blind basis: %v", err)
	}
	mixed = relayBlind
	mixed.PromptHashBasis = PromptHashBasisCoordinatorV1
	if err := mixed.Validate(); err == nil || !strings.Contains(err.Error(), "prompt_hash_basis") {
		t.Fatalf("relay-blind entrypoint with plaintext basis: %v", err)
	}
	basisOnly := relayBlind
	basisOnly.PaidEntrypoint = PaidEntrypointCoordinatorBuyerChat
	basisOnly.PromptHashBasis = PromptHashBasisCoordinatorV1
	a, _, errA := relayBlind.Digest()
	b, _, errB := basisOnly.Digest()
	if errA != nil || errB != nil || a == b {
		t.Fatalf("basis/entrypoint must change the digest: %s %s %v %v", a, b, errA, errB)
	}
}
