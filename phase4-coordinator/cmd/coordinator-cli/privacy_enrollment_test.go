package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/relayblind"
)

func TestPrivacyClassCLIReenrollAndDirectoryKeygen(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "relay-blind.sqlite")
	cfgPath := filepath.Join(dir, "coordinator.yaml")
	yaml := "auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nrelay_blind:\n  sqlite_path: " + quoteYAML(dbPath) + "\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	store, err := relayblind.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	ctx := context.Background()
	enrollment := relayblind.PrivacyEnrollment{
		ProviderID: "provider-a", IdentityPublicKey: "identity-key", IdentityFingerprint: "identity-fp",
		SEPublicKey: "se-key", SEFingerprint: "se-fp", TeamID: "AB12CD34EF", SigningIdentifier: "live.malibu.provider.cli",
		CodeCDHash: strings.Repeat("a", 40), BinaryVersion: "1.8.230", EnrolledAtUnix: now.Unix(),
	}
	if err := store.EnrollPrivacyIdentity(ctx, enrollment); err != nil {
		t.Fatal(err)
	}
	if err := store.Quarantine(ctx, "provider-a", "privacy_enrollment_key_changed", now, time.Hour); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	if err := privacyClassCommand([]string{"status", "-config", cfgPath}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "enrollment_count=1\n") || !strings.Contains(out.String(), "enrollment.identity_fingerprint=identity-fp\n") ||
		strings.Contains(out.String(), "identity-key") || strings.Contains(out.String(), "se-key") {
		t.Fatalf("status enrollment listing: %s", out.String())
	}
	if err := privacyClassCommand([]string{"reenroll", "-config", cfgPath, "--provider", "provider-a"}, &out); err == nil {
		t.Fatal("reenroll without a reason accepted")
	}
	out.Reset()
	if err := privacyClassCommand([]string{"reenroll", "-config", cfgPath, "--provider", "provider-a", "--reason", "device replaced"}, &out); err != nil {
		t.Fatalf("reenroll: %v", err)
	}
	if !strings.Contains(out.String(), "reenroll.revoked_active_enrollment=true\n") || !strings.Contains(out.String(), "quarantine_count=0\n") ||
		strings.Contains(out.String(), "enrollment.revoked_at_unix=0\n") {
		t.Fatalf("reenroll status: %s", out.String())
	}

	keyPath := filepath.Join(dir, "directory.key")
	out.Reset()
	if err := privacyClassCommand([]string{"directory-keygen", "--out", keyPath}, &out); err != nil {
		t.Fatalf("directory-keygen: %v", err)
	}
	seed, err := os.ReadFile(keyPath)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out.String(), strings.TrimSpace(string(seed))) || !strings.Contains(out.String(), "directory_public_key=") || !strings.Contains(out.String(), "directory_key_id=") {
		t.Fatalf("keygen output: %s", out.String())
	}
	if err := privacyClassCommand([]string{"directory-keygen", "--out", keyPath}, &out); err == nil {
		t.Fatal("directory-keygen overwrote an existing key")
	}
	if err := privacyClassCommand([]string{"directory-keygen"}, &out); err == nil {
		t.Fatal("directory-keygen without --out accepted")
	}
}
