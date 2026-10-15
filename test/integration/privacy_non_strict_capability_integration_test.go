package integration

import (
	"fmt"
	"strings"
	"testing"
)

// SPEC-041 v0.6.0 R003/R004 with SPEC-049: a privacy-class request whose
// encrypted body needs SPEC-019 §1a non-strict json_schema mode declares it
// in the authenticated envelope, and the coordinator binds it only to a
// provider CLI that supports it. With only an older CLI enrolled the buyer
// gets the plaintext path's 400 and nothing is dispatched; with a capable
// CLI the real Swift provider decrypts, checks the declaration and serves it.
func TestPrivacyClassNonStrictJSONSchemaRoutesOnlyToCapableCLI(t *testing.T) {
	input := fmt.Sprintf(`{"model":%q,"messages":[{"role":"user","content":"structured canary"}],"stream":false,"max_tokens":32,"response_format":{"type":"json_schema","json_schema":{"name":"person","strict":false,"schema":{"type":"object","properties":{"name":{"type":"string"}}}}}}`, defaultFakeModelID)
	for _, tc := range []struct {
		binary  string
		capable bool
	}{
		{"1.8.240", false},
		{"1.8.242", true},
	} {
		t.Run(tc.binary, func(t *testing.T) {
			stack := newPrivacyStack(t, privacyStackOpts{completion: privacyCanaryCompletion, waitPosture: true, autoEnroll: true, binaryVersion: tc.binary})
			waitPrivacyStatus(t, stack, func(status string) bool {
				return privacyStatusValue(status, "enrollment_count") == "1"
			})
			stdout, stderr, err := runPrivacyClientInput(t, stack.s.apiKey, stack.s.gatewayBaseURL, "", stack.s.privacyDirectoryPublicKey, input, false, true)
			if !tc.capable {
				if err == nil || !strings.Contains(stderr, "json_schema_non_strict_unsupported") {
					t.Fatalf("old CLI run err=%v stderr=%s, want json_schema_non_strict_unsupported", err, privacyClientDetail(stderr))
				}
				assertDispatches(t, stack.fixture, 0)
				return
			}
			if err != nil {
				t.Fatalf("capable CLI run: %v (%s)", err, privacyClientDetail(stderr))
			}
			if !privacyPlaintextHas(stdout, privacyCanaryCompletion) {
				t.Fatal("decrypted plaintext missing completion")
			}
			assertDispatches(t, stack.fixture, 1)
		})
	}
}
