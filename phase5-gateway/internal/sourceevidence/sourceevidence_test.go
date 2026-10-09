package sourceevidence

import (
	"strings"
	"testing"
)

// The intent binding is recomputed by scripts/source_authenticated_evidence.py
// (gateway_intent_binding); this vector pins both implementations.
func TestIntentBindingCrossLanguageVector(t *testing.T) {
	in := Intent{AccountID: "acct", ExternalRequestID: "00000000-0000-4000-8000-000000000001",
		Model: "pool/abcdefghijklmnopqrstuv/m", PoolSelect: "abcdefghijklmnopqrstuv", EngineSelect: "llamacpp"}
	const want = "98196f215d5ab8903a20ede754d0540c60bf41fadce12d38eb3d69f68845e6b8"
	if got := IntentBinding("run-1", strings.Repeat("N", 43), in); got != want {
		t.Fatalf("IntentBinding=%s want %s", got, want)
	}
}

// Length prefixes keep field boundaries: moving a byte between fields must
// change both the commitment and the binding.
func TestIntentCommitmentSeparatesFields(t *testing.T) {
	key := []byte(strings.Repeat("k", 32))
	a := Intent{AccountID: "acct", ExternalRequestID: "r", Model: "pool/x/ab", PoolSelect: "c"}
	b := Intent{AccountID: "acct", ExternalRequestID: "r", Model: "pool/x/a", PoolSelect: "bc"}
	if IntentCommitment(key, a) == IntentCommitment(key, b) || IntentBinding("r", "n", a) == IntentBinding("r", "n", b) {
		t.Fatal("field boundary collision")
	}
	if IntentCommitment(key, a) == IntentCommitment([]byte(strings.Repeat("j", 32)), a) {
		t.Fatal("commitment does not depend on the private key")
	}
}

func TestCanonicalBytesSortsAndRejectsNonASCII(t *testing.T) {
	got, err := CanonicalBytes(map[string]any{"b": 1, "a": []string{"<x>"}, "c": map[string]any{"z": false, "y": nil}})
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != `{"a":["<x>"],"b":1,"c":{"y":null,"z":false}}` {
		t.Fatalf("canonical=%s", got)
	}
	if _, err := CanonicalBytes(map[string]any{"a": "é"}); err == nil {
		t.Fatal("non-ASCII accepted")
	}
	if _, err := CanonicalBytes(map[string]any{"a": -1}); err == nil {
		t.Fatal("negative integer accepted")
	}
}

func TestNewSignerFailsClosedWithoutProvenance(t *testing.T) {
	if _, err := NewSigner("unused", DefaultFixedProvenance()); err == nil {
		t.Fatal("default provenance must fail closed")
	}
}
