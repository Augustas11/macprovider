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

func TestPrivacyClassCLI(t *testing.T) {
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "relay-blind.sqlite")
	cfgPath := filepath.Join(dir, "coordinator.yaml")
	yaml := "auth:\n  operator_key: 0123456789abcdefABCDEFghijklmnop\n  gateway_service_token: fedcba9876543210PONMLKJIHGFEDCBA\nrelay_blind:\n  sqlite_path: " + quoteYAML(dbPath) + "\n"
	if err := os.WriteFile(cfgPath, []byte(yaml), 0o600); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := privacyClassCommand([]string{"status", "-config", cfgPath}, &out); err != nil {
		t.Fatalf("status: %v", err)
	}
	if !strings.Contains(out.String(), "disabled=0\n") || !strings.Contains(out.String(), "quarantine_count=0\n") {
		t.Fatalf("fresh status: %s", out.String())
	}
	store, err := relayblind.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC()
	ctx := context.Background()
	privacy, err := store.CreateReservation(ctx, privacyCLIReservation("kid-privacy", "digest-privacy", true, now), now)
	if err != nil {
		t.Fatal(err)
	}
	relay, err := store.CreateReservation(ctx, privacyCLIReservation("kid-relay", "digest-relay", false, now), now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	out.Reset()
	if err := privacyClassCommand([]string{"disable", "-config", cfgPath}, &out); err == nil {
		t.Fatal("disable without reason succeeded")
	}
	out.Reset()
	if err := privacyClassCommand([]string{"disable", "-config", cfgPath, "--reason", "maintenance"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "disabled=1\n") || !strings.Contains(out.String(), "reason=maintenance\n") || strings.Contains(out.String(), "digest-privacy") {
		t.Fatalf("disable status: %s", out.String())
	}
	store, err = relayblind.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	privacyRow, err := store.LookupReservation(ctx, privacy.ProviderBinding)
	if err != nil || privacyRow.State != relayblind.ReservationStateRejected {
		t.Fatalf("privacy row = %#v err=%v", privacyRow, err)
	}
	relayRow, err := store.LookupReservation(ctx, relay.ProviderBinding)
	if err != nil || relayRow.State != relayblind.ReservationStateReserved {
		t.Fatalf("relay row = %#v err=%v", relayRow, err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	out.Reset()
	if err := privacyClassCommand([]string{"enable", "-config", cfgPath}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "disabled=0\n") || !strings.Contains(out.String(), "reason=enabled\n") {
		t.Fatalf("enable status: %s", out.String())
	}
	if err := privacyClassCommand([]string{"quarantine", "-config", cfgPath, "--provider", "provider-a"}, &out); err == nil {
		t.Fatal("quarantine without reason succeeded")
	}
	if err := privacyClassCommand([]string{"quarantine", "-config", cfgPath, "--reason", "review", "--seconds", "60"}, &out); err == nil {
		t.Fatal("quarantine without provider succeeded")
	}
	if err := privacyClassCommand([]string{"quarantine", "-config", cfgPath, "--provider", "provider-a", "--reason", "review", "--seconds", "0"}, &out); err == nil {
		t.Fatal("zero quarantine seconds succeeded")
	}
	out.Reset()
	if err := privacyClassCommand([]string{"quarantine", "-config", cfgPath, "--provider", "provider-a", "--reason", "review", "--seconds", "60"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "quarantine.provider_id=provider-a\n") || !strings.Contains(out.String(), "quarantine.reason=review\n") || !strings.Contains(out.String(), "quarantine_count=1\n") {
		t.Fatalf("quarantine status: %s", out.String())
	}
	out.Reset()
	if err := privacyClassCommand([]string{"unquarantine", "-config", cfgPath, "--provider", "provider-a"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "quarantine_count=0\n") || strings.Contains(out.String(), "provider-a") {
		t.Fatalf("unquarantine status: %s", out.String())
	}
}

func privacyCLIReservation(kid, digest string, privacy bool, now time.Time) relayblind.ReservationCreate {
	return relayblind.ReservationCreate{
		AccountID: "account-a", WalletSession: "wallet-a", ProviderID: "provider-a", AssignedSession: "session-a",
		KeyRecord: relayblind.KeyRecord{KID: kid, KeyRecordDigest: digest}, Model: "model-a", ProviderModel: "model-a",
		MaxEncryptedRequestBytes: 32, MaxOutputTokens: 32, InputTokenUpperBound: 32,
		ExpiresAtUnix: now.Add(time.Hour).Unix(), PrivacyClass: privacy,
	}
}

func quoteYAML(value string) string {
	return `"` + value + `"`
}

func TestPrivacyClassCLIRevokeAppAttestKey(t *testing.T) {
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
	keyID := bytes.Repeat([]byte{7}, 32)
	if err := store.EnrollAppAttestKey(context.Background(), relayblind.AppAttestKey{
		KeyID: keyID, ProviderID: "provider-a", PublicKey: append([]byte{4}, bytes.Repeat([]byte{1}, 64)...), TeamID: "AB12CD34EF",
		SEPublicKeySHA256: bytes.Repeat([]byte{2}, 32), IdentityPublicKeySHA256: bytes.Repeat([]byte{3}, 32),
	}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := store.AdvanceAppAttestCounter(context.Background(), "provider-a", keyID, 4); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := privacyClassCommand([]string{"status", "-config", cfgPath}, &out); err != nil {
		t.Fatal(err)
	}
	want := "app_attest_key_count=1\napp_attest_key.provider_id=provider-a\napp_attest_key.key_id=BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc\napp_attest_key.state=active\napp_attest_key.last_counter=4\napp_attest_key.revoked_reason=\n"
	if !strings.Contains(out.String(), want) || strings.Contains(out.String(), "public_key") {
		t.Fatalf("status: %s", out.String())
	}
	if err := privacyClassCommand([]string{"revoke-app-attest-key", "-config", cfgPath, "--provider", "provider-a"}, &out); err == nil {
		t.Fatal("revoke without reason succeeded")
	}
	out.Reset()
	if err := privacyClassCommand([]string{"revoke-app-attest-key", "-config", cfgPath, "--provider", "provider-a", "--reason", "device lost"}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "app_attest_key.state=revoked\n") || !strings.Contains(out.String(), "app_attest_key.revoked_reason=operator_revoked\n") {
		t.Fatalf("revoke status: %s", out.String())
	}
	if err := privacyClassCommand([]string{"revoke-app-attest-key", "-config", cfgPath, "--provider", "provider-a", "--reason", "again"}, &out); err == nil {
		t.Fatal("second revoke succeeded")
	}
}
