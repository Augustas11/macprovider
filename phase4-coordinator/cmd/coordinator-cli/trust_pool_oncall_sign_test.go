package main

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/trustpool"
)

func writeEd25519PKCS8PEM(t *testing.T, dir string) (string, ed25519.PrivateKey) {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(priv)
	if err != nil {
		t.Fatalf("MarshalPKCS8PrivateKey: %v", err)
	}
	path := filepath.Join(dir, "priv.pem")
	if err := os.WriteFile(path, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	return path, priv
}

const unsignedOnCallJSON = `{
  "operation_id": "op-oncall-sign-1",
  "launch_environment_id": "production",
  "record_version": "oncall-v1",
  "primary_operator_contact": "ops-primary@example.test",
  "secondary_operator_contact": "ops-secondary@example.test",
  "break_glass_escalation_path": "page break-glass on-call",
  "compromise_notification_channel": "security-alerts@example.test",
  "creator_agreement_notification_commitment_ack": "creator-agreement-notify-ack-v1",
  "creator_emergency_notification_mechanism": "creator-emergency-webhook",
  "last_confirmed_at_utc": "2026-09-05T00:00:00Z",
  "confirmation_ttl_seconds": 7776000
}`

func TestTrustPoolOnCallSign_MatchesLibraryAndVerifies(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	keyPath, priv := writeEd25519PKCS8PEM(t, dir)
	inPath := filepath.Join(dir, "unsigned.json")
	if err := os.WriteFile(inPath, []byte(unsignedOnCallJSON), 0o600); err != nil {
		t.Fatalf("write unsigned: %v", err)
	}

	var out bytes.Buffer
	if err := trustPoolOnCallSign(
		[]string{"--in", inPath, "--key-file", keyPath},
		func(string) string { return "" },
		nil,
		&out,
	); err != nil {
		t.Fatalf("trustPoolOnCallSign: %v", err)
	}

	var signed trustpool.OnCallReadiness
	if err := json.Unmarshal(out.Bytes(), &signed); err != nil {
		t.Fatalf("decode signed output: %v", err)
	}
	if signed.OperationsAuthorityPublicKey == "" || signed.OperationsAuthoritySignature == "" {
		t.Fatalf("signed output missing authority fields: %+v", signed)
	}

	// The CLI output must be byte-identical to the library the coordinator
	// verifies with: same deterministic Ed25519 signature over the same
	// preimage. Re-sign the same input via the library and compare.
	var input trustpool.OnCallReadiness
	if err := json.Unmarshal([]byte(unsignedOnCallJSON), &input); err != nil {
		t.Fatalf("decode input: %v", err)
	}
	lib, err := trustpool.SignOnCallReadiness(priv, input)
	if err != nil {
		t.Fatalf("SignOnCallReadiness: %v", err)
	}
	if signed.OperationsAuthoritySignature != lib.OperationsAuthoritySignature {
		t.Fatalf("CLI signature %q != library signature %q", signed.OperationsAuthoritySignature, lib.OperationsAuthoritySignature)
	}
	if signed.OperationsAuthorityPublicKey != lib.OperationsAuthorityPublicKey {
		t.Fatalf("CLI pubkey %q != library pubkey %q", signed.OperationsAuthorityPublicKey, lib.OperationsAuthorityPublicKey)
	}
}

func TestTrustPoolOnCallSign_RequiresKey(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	inPath := filepath.Join(dir, "unsigned.json")
	if err := os.WriteFile(inPath, []byte(unsignedOnCallJSON), 0o600); err != nil {
		t.Fatalf("write unsigned: %v", err)
	}
	err := trustPoolOnCallSign([]string{"--in", inPath}, func(string) string { return "" }, nil, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), oncallSigningKeyEnv) {
		t.Fatalf("missing key err=%v, want mention of %s", err, oncallSigningKeyEnv)
	}
}

func TestTrustPoolOnCallSign_RejectsTrailingJSON(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	keyPath, _ := writeEd25519PKCS8PEM(t, dir)
	inPath := filepath.Join(dir, "unsigned.json")
	if err := os.WriteFile(inPath, []byte(unsignedOnCallJSON+"\n{\"operation_id\":\"ignored\"}"), 0o600); err != nil {
		t.Fatalf("write unsigned: %v", err)
	}
	if err := trustPoolOnCallSign([]string{"--in", inPath, "--key-file", keyPath}, func(string) string { return "" }, nil, &bytes.Buffer{}); err == nil {
		t.Fatalf("expected error for trailing JSON")
	}
}

func TestTrustPoolOnCallSign_RejectsNonEd25519Key(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	inPath := filepath.Join(dir, "unsigned.json")
	if err := os.WriteFile(inPath, []byte(unsignedOnCallJSON), 0o600); err != nil {
		t.Fatalf("write unsigned: %v", err)
	}
	// A non-PEM key file must fail closed.
	keyPath := filepath.Join(dir, "bad.pem")
	if err := os.WriteFile(keyPath, []byte("not a pem"), 0o600); err != nil {
		t.Fatalf("write bad key: %v", err)
	}
	if err := trustPoolOnCallSign([]string{"--in", inPath, "--key-file", keyPath}, func(string) string { return "" }, nil, &bytes.Buffer{}); err == nil {
		t.Fatalf("expected error for non-PEM key")
	}
}
