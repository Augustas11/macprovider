package sourceevidence

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestProducerSignsSortedCoordinatorProjection(t *testing.T) {
	ctx := context.Background()
	store, _ := newTestStore(t)
	first := testNoDispatchRow("acct-a", "external-a", "33333333-3333-4333-8333-333333333333", 404, "")
	second := testNoDispatchRow("acct-b", "external-b", "44444444-4444-4444-8444-444444444444", 503, "Pool unavailable")
	if err := store.RecordNoDispatch(ctx, ClosureInput{TerminalKind: TerminalModelNotFound, Row: first}); err != nil {
		t.Fatalf("first closure: %v", err)
	}
	if err := store.RecordNoDispatch(ctx, ClosureInput{TerminalKind: TerminalPoolUnavailable, Row: second}); err != nil {
		t.Fatalf("second closure: %v", err)
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("GenerateKey: %v", err)
	}
	dir := t.TempDir()
	keyPath := filepath.Join(dir, "signing.key")
	if err := os.WriteFile(keyPath, []byte(base64.RawURLEncoding.EncodeToString(priv)), 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}
	registry := map[string]any{
		"schema_version": "macprovider.source-evidence-key-registry.v1",
		"keys": []any{map[string]any{
			"key_id":            "coordinator-key-1",
			"algorithm":         "ed25519",
			"public_key":        base64.RawURLEncoding.EncodeToString(pub),
			"producer":          ProducerName,
			"instance_id":       "coordinator-prod-a",
			"permitted_roles":   []any{ProducerRole},
			"permitted_domains": []any{SignDomain},
			"not_before":        "2026-10-07T00:00:00.000Z",
			"not_after":         "2026-10-08T00:00:00.000Z",
			"revoked_at":        nil,
			"reviewed_source_constraints": map[string]any{
				"source_sha_allowlist": []any{"0123456789abcdef0123456789abcdef01234567"},
				"notes":                "test key",
			},
		}},
	}
	registryBytes, err := canonicalBytes(registry)
	if err != nil {
		t.Fatalf("registry canonical: %v", err)
	}
	registryPath := filepath.Join(dir, "registry.json")
	if err := os.WriteFile(registryPath, registryBytes, 0o600); err != nil {
		t.Fatalf("write registry: %v", err)
	}
	producer, err := NewProducer(store, Config{Enabled: true, SigningPrivateKeyPath: keyPath, MaxScopes: 10}, FixedProvenance{
		InstanceID:           "coordinator-prod-a",
		SourceSHA:            "0123456789abcdef0123456789abcdef01234567",
		KeyID:                "coordinator-key-1",
		ReviewedRegistryPath: registryPath,
		RegistryDigest:       "sha256:" + sha256Hex(registryBytes),
		Now:                  func() time.Time { return time.Date(2026, 10, 7, 12, 0, 1, 0, time.UTC) },
	})
	if err != nil {
		t.Fatalf("NewProducer: %v", err)
	}
	envelope, err := producer.Export(ctx, ExportRequest{SchemaVersion: RequestSchema, RunID: "run-1880", ChallengeNonce: base64.RawURLEncoding.EncodeToString(make([]byte, 32)), Scopes: []Scope{
		{AccountID: second.AccountID, ExternalRequestID: second.ExternalRequestID, RequiredInternalRequestID: second.RequestID, NotBeforeUnixMS: 1},
		{AccountID: first.AccountID, ExternalRequestID: first.ExternalRequestID, RequiredInternalRequestID: first.RequestID, NotBeforeUnixMS: 1},
	}})
	if err != nil {
		t.Fatalf("Export: %v", err)
	}
	if envelope.SchemaVersion != EnvelopeSchema || envelope.Signed["producer"] != ProducerName || envelope.Signed["role"] != ProducerRole {
		t.Fatalf("unexpected envelope: %+v", envelope)
	}
	scopes := envelope.Signed["request_scopes"].([]string)
	if len(scopes) != 2 || scopes[0] > scopes[1] {
		t.Fatalf("request scopes not sorted: %#v", scopes)
	}
	records := envelope.Signed["records"].([]map[string]any)
	if records[0]["request_scope_commitment"] != scopes[0] || records[1]["request_scope_commitment"] != scopes[1] {
		t.Fatalf("records do not match sorted request scopes")
	}
	signedBytes, err := canonicalBytes(envelope.Signed)
	if err != nil {
		t.Fatalf("signed canonical: %v", err)
	}
	sig := envelope.Signatures[0]
	rawSig, err := base64.RawURLEncoding.DecodeString(sig["signature"].(string))
	if err != nil {
		t.Fatalf("signature decode: %v", err)
	}
	if !ed25519.Verify(pub, append([]byte(SignDomain+"\n"), signedBytes...), rawSig) {
		t.Fatalf("signature did not verify")
	}

	// Validate the actual Go-produced bytes with the protected Python consumer,
	// so independently valid signatures cannot conceal a projection mismatch.
	envelopeBytes, err := json.Marshal(envelope)
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	envelopePath := filepath.Join(dir, "export.json")
	if err := os.WriteFile(envelopePath, envelopeBytes, 0o600); err != nil {
		t.Fatalf("write envelope: %v", err)
	}
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("repository path: %v", err)
	}
	const consumer = `import sys, pathlib
sys.path.insert(0, sys.argv[3] + "/scripts")
from source_authenticated_evidence import ExpectedExport, load_json_file, parse_timestamp_ms, validate_envelope
expected = ExpectedExport(producer="coordinator", role="no_dispatch_refusal", instance_id="coordinator-prod-a", source_sha="0123456789abcdef0123456789abcdef01234567", run_id="run-1880", challenge_nonce="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", domain="macprovider.source-authenticated-export.v1", now=parse_timestamp_ms("2026-10-07T12:00:01.000Z"))
validate_envelope(load_json_file(pathlib.Path(sys.argv[1])), load_json_file(pathlib.Path(sys.argv[2])), expected)
`
	cmd := exec.Command("python3", "-c", consumer, envelopePath, registryPath, repoRoot)
	cmd.Env = append(os.Environ(), "PYTHONDONTWRITEBYTECODE=1")
	if output, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("Python rejected Go-produced envelope: %v\n%s", err, output)
	}
}
