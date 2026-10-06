package integration

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// waitPrivacyStatus polls coordinator-cli privacy-class status until want
// holds, so assertions do not race the coordinator's durable writes.
func waitPrivacyStatus(t *testing.T, stack *privacyStack, want func(status string) bool) string {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	status := ""
	for time.Now().Before(deadline) {
		status = runPrivacyCLI(t, "privacy-class", "status", "--config", stack.s.coordYAML)
		if want(status) {
			return status
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatalf("privacy status did not converge: enrollment_count=%s quarantine_count=%s", privacyStatusValue(status, "enrollment_count"), privacyStatusValue(status, "quarantine_count"))
	return status
}

// SPEC-049-R021/R025/R028: a Swift provider with no operator pins is
// enrolled from its first verified posture, and the buyer client completes
// stream and non-stream privacy-class requests with its pin taken from the
// signed identity directory, with no pin file.
func TestPrivacyClassAutoEnrolledSwiftProviderEndToEnd(t *testing.T) {
	stack := newPrivacyStack(t, privacyStackOpts{
		completion:  privacyCanaryCompletion,
		waitPosture: true,
		autoEnroll:  true,
	})
	status := waitPrivacyStatus(t, stack, func(status string) bool {
		return privacyStatusValue(status, "enrollment_count") == "1"
	})
	if privacyStatusValue(status, "enrollment.provider_id") != stack.providerID || privacyStatusValue(status, "enrollment.revoked_at_unix") != "0" {
		t.Fatalf("enrollment provider=%s revoked_at=%s", privacyStatusValue(status, "enrollment.provider_id"), privacyStatusValue(status, "enrollment.revoked_at_unix"))
	}
	for _, stream := range []bool{true, false} {
		stdout, stderr, err := runPrivacyClientWithDirectory(t, stack.s.apiKey, stack.s.gatewayBaseURL, "", stack.s.privacyDirectoryPublicKey, "auto-enrolled privacy class", stream, true)
		if err != nil {
			t.Fatalf("auto-pinned privacy client stream=%t: %v (%s)", stream, err, privacyClientDetail(stderr))
		}
		if !privacyPlaintextHas(stdout, privacyCanaryCompletion) {
			t.Fatalf("decrypted plaintext missing completion, stream=%t stdout_len=%d", stream, len(stdout))
		}
		if !strings.Contains(stderr, "privacy class satisfied") || !strings.Contains(stderr, "identity_pin_source: signed_directory") {
			t.Fatalf("client did not report a directory-pinned satisfied run (%s)", privacyClientDetail(stderr))
		}
	}
	assertDispatches(t, stack.fixture, 2)
	assertUsageTokens(t, stack.s)
}

// SPEC-049-R028: a directory signed by a key other than the buyer's pinned
// key is rejected before any reservation or envelope.
func TestPrivacyClassDirectorySignedByAnotherKeyRejected(t *testing.T) {
	stack := newPrivacyStack(t, privacyStackOpts{waitPosture: true, autoEnroll: true})
	waitPrivacyStatus(t, stack, func(status string) bool {
		return privacyStatusValue(status, "enrollment_count") == "1"
	})
	other, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	base, capture := startPrivacyProxy(t, stack.s.gatewayBaseURL, privacyProxyObserve)
	_, stderr, err := runPrivacyClientWithDirectory(t, stack.s.apiKey, base, "", base64.RawURLEncoding.EncodeToString(other), "wrong directory key", false, true)
	if err == nil || !strings.Contains(stderr, "privacy identity directory rejected") {
		t.Fatalf("directory under another key accepted: err=%v (%s)", err, privacyClientDetail(stderr))
	}
	if capture.code("reservation") != "" {
		t.Fatal("client reserved after rejecting the directory")
	}
	assertDispatches(t, stack.fixture, 0)
}

// SPEC-049-R026: a different device presenting new keys under an enrolled
// provider ID is quarantined, the enrollment is not replaced, and only the
// operator reenroll path admits the new keys.
func TestPrivacyClassEnrollmentKeyChangeQuarantines(t *testing.T) {
	stack := newPrivacyStack(t, privacyStackOpts{waitPosture: true, autoEnroll: true})
	enrolled := waitPrivacyStatus(t, stack, func(status string) bool {
		return privacyStatusValue(status, "enrollment_count") == "1"
	})
	fingerprint := privacyStatusValue(enrolled, "enrollment.identity_fingerprint")
	if fingerprint == "" {
		t.Fatal("enrollment fingerprint missing")
	}

	stateDir := t.TempDir()
	if err := os.Chmod(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	resolved, err := filepath.EvalSymlinks(stateDir)
	if err != nil {
		t.Fatal(err)
	}
	swapped := startSwiftPrivacyFixture(t, resolved, defaultFakeModelID, swiftPrivacyFixtureOpts{ProviderID: stack.providerID})
	if swapped.descriptor.IdentityPublicKey == stack.fixture.descriptor.IdentityPublicKey {
		t.Fatal("swapped fixture reused the enrolled identity")
	}
	stack.fixture.stop()
	connectSwiftRelayProvider(t, stack.s.rootCtx, stack.s, swapped)
	status := waitPrivacyStatus(t, stack, func(status string) bool {
		return privacyStatusValue(status, "quarantine.reason") == "privacy_enrollment_key_changed"
	})
	if privacyStatusValue(status, "enrollment.identity_fingerprint") != fingerprint || privacyStatusValue(status, "enrollment_count") != "1" {
		t.Fatalf("key change replaced the enrollment: count=%s", privacyStatusValue(status, "enrollment_count"))
	}
	_, stderr, err := runPrivacyClientWithDirectory(t, stack.s.apiKey, stack.s.gatewayBaseURL, "", stack.s.privacyDirectoryPublicKey, "after key change", false, true)
	if err == nil {
		t.Fatalf("privacy run succeeded against a quarantined provider (%s)", privacyClientDetail(stderr))
	}
	assertDispatches(t, swapped, 0)

	reenrolled := runPrivacyCLI(t, "privacy-class", "reenroll",
		"--config", stack.s.coordYAML,
		"--provider", stack.providerID,
		"--reason", "integration device swap",
	)
	if privacyStatusValue(reenrolled, "reenroll.revoked_active_enrollment") != "true" || privacyStatusValue(reenrolled, "quarantine_count") != "0" {
		t.Fatalf("reenroll status revoked=%s quarantine_count=%s", privacyStatusValue(reenrolled, "reenroll.revoked_active_enrollment"), privacyStatusValue(reenrolled, "quarantine_count"))
	}
}
