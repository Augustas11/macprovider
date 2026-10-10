package integration

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// SPEC-049-R029: with two enrolled privacy providers for one model, private
// requests through the real gateway and coordinator are served by both,
// not pinned to whichever session connected first.
func TestPrivacyClassSpreadsAcrossEnrolledProviders(t *testing.T) {
	stack := newPrivacyStack(t, privacyStackOpts{completion: privacyCanaryCompletion, waitPosture: true, autoEnroll: true})
	waitPrivacyStatus(t, stack, func(status string) bool {
		return privacyStatusValue(status, "enrollment_count") == "1"
	})

	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	secondID := "prov-swift-privacy-" + randHex(t, 4)
	second := startSwiftPrivacyFixture(t, resolved, defaultFakeModelID, swiftPrivacyFixtureOpts{
		ProviderID: secondID,
		Completion: privacyCanaryCompletion,
	})
	second.wsProviderID, second.wsProviderToken = secondID, stack.s.issueProviderToken(secondID, "swift-privacy-second")
	connectSwiftRelayProvider(t, stack.s.rootCtx, stack.s, second)
	second.waitPosture(25 * time.Second)
	waitPrivacyStatus(t, stack, func(status string) bool {
		return privacyStatusValue(status, "enrollment_count") == "2"
	})

	// Each tier starts at a random provider, so 16 sequential requests all
	// landing on one of two free providers has probability 2^-15.
	const runs = 16
	for i := range runs {
		stdout, stderr, err := runPrivacyClientWithDirectory(t, stack.s.apiKey, stack.s.gatewayBaseURL, "", stack.s.privacyDirectoryPublicKey, "spread across providers", false, true)
		if err != nil {
			t.Fatalf("privacy run %d: %v (%s)", i, err, privacyClientDetail(stderr))
		}
		if !privacyPlaintextHas(stdout, privacyCanaryCompletion) {
			t.Fatalf("privacy run %d: decrypted plaintext missing completion", i)
		}
	}
	first, other := stack.fixture.dispatches.Load(), second.dispatches.Load()
	if first+other != runs || first == 0 || other == 0 {
		t.Fatalf("dispatches first=%d second=%d, want %d spread across both enrolled providers", first, other, runs)
	}
}
