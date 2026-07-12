package main

import (
	"bytes"
	"context"
	"errors"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func TestCreateSeedReferralReadsSecretOnlyFromEnvironment(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	var out bytes.Buffer
	err := createSeedReferral([]string{
		"--db", dbPath,
		"--campaign", "prebeta_2026",
		"--key-id", "k1",
		"--secret-env", "TEST_REFERRAL_HMAC",
		"--seed-id", "launch",
		"--max-uses", "3",
	}, func(key string) string {
		if key == "TEST_REFERRAL_HMAC" {
			return strings.Repeat("s", 32)
		}
		return ""
	}, &out)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "referral_code=MAL1-S-k1-launch-") || !strings.Contains(out.String(), "max_uses=3") {
		t.Fatalf("unexpected output: %s", out.String())
	}
}

func TestCreateSeedReferralRejectsMissingSecretEnvironment(t *testing.T) {
	err := createSeedReferral([]string{
		"--db", filepath.Join(t.TempDir(), "coordinator.db"),
		"--campaign", "prebeta_2026",
		"--key-id", "k1",
		"--secret-env", "MISSING",
		"--seed-id", "launch",
	}, func(string) string { return "" }, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "at least 32 bytes") {
		t.Fatalf("expected missing secret rejection, got %v", err)
	}
}

func TestRevokeReferralInvalidatesSeedCode(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	var created bytes.Buffer
	secret := strings.Repeat("s", 32)
	if err := createSeedReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch",
	}, func(string) string { return secret }, &created); err != nil {
		t.Fatal(err)
	}
	var revoked bytes.Buffer
	if err := revokeReferral([]string{"--db", dbPath, "--campaign", "prebeta_2026", "--issuer-id", "launch"}, &revoked); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(revoked.String(), "issuer_id=launch") {
		t.Fatalf("unexpected output: %s", revoked.String())
	}
	code := strings.TrimPrefix(strings.Split(created.String(), "\n")[0], "referral_code=")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	policy := auth.ReferralPolicy{
		PolicyVersion: "v1",
		Campaign:      "prebeta_2026", CurrentKeyID: "k1", HMACKeys: map[string]string{"k1": secret},
		ProviderBaseUses: 1, SocialBonusUses: 1, ChallengeTTL: time.Minute,
	}
	if _, err := store.ValidateReferral(context.Background(), policy, code, time.Now().UTC()); !errors.Is(err, auth.ErrReferralRevoked) {
		t.Fatalf("validation err=%v", err)
	}
}
