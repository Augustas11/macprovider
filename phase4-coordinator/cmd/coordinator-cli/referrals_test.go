package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func TestReferralCommandsCreateAdjustAndRevoke(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	getenv := func(key string) string {
		if key == "REFERRAL_SECRET" {
			return strings.Repeat("s", 32)
		}
		return ""
	}
	base := []string{"--db", dbPath, "--campaign", "prebeta_test", "--key-id", "k1", "--secret-env", "REFERRAL_SECRET", "--seed-id", "launch"}
	var created bytes.Buffer
	if err := createSeedReferral(append(append([]string{}, base...), "--max-uses", "2"), getenv, &created); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(created.String(), "referral_code=MAL1-S-k1-launch-") {
		t.Fatalf("create output=%s", created.String())
	}
	if err := createSeedReferral(base, getenv, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "adjust-seed-referral") {
		t.Fatalf("duplicate create error=%v", err)
	}

	var adjusted bytes.Buffer
	adjustArgs := append(append([]string{}, base...), "--max-uses", "4", "--apply", "--actor", "ops", "--reason", "expand")
	if err := adjustSeedReferral(adjustArgs, getenv, &adjusted); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(adjusted.String(), "mode=applied") || strings.Contains(adjusted.String(), "reserved=") {
		t.Fatalf("adjust output=%s", adjusted.String())
	}

	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	var auditRows int
	if err := store.DB().QueryRowContext(context.Background(), `SELECT COUNT(1) FROM referral_admin_audit WHERE actor = 'ops'`).Scan(&auditRows); err != nil {
		t.Fatal(err)
	}
	store.Close()
	if auditRows != 1 {
		t.Fatalf("audit rows=%d", auditRows)
	}

	var preview bytes.Buffer
	if err := revokeReferral([]string{"--db", dbPath, "--campaign", "prebeta_test", "--issuer-id", "launch"}, &preview); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(preview.String(), "redeemed=0") || strings.Contains(preview.String(), "reservation") {
		t.Fatalf("revoke preview=%s", preview.String())
	}
	if err := revokeReferral([]string{"--db", dbPath, "--campaign", "prebeta_test", "--issuer-id", "launch", "--apply", "--actor", "ops", "--reason", "retire", "--expect-redeemed", "0"}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
}

func TestReferralCommandsNeverAcceptSecretOnArgv(t *testing.T) {
	err := createSeedReferral([]string{"--campaign", "prebeta_test", "--key-id", "k1", "--seed-id", "launch"}, func(string) string { return "" }, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "--secret-env is required") {
		t.Fatalf("error=%v", err)
	}
}

func TestReplaceReferralIssuerRequiresDryRunAndUsesConfigSecret(t *testing.T) {
	t.Setenv("REFERRAL_REPLACE_SECRET", strings.Repeat("r", 32))
	dir := t.TempDir()
	dbPath := filepath.Join(dir, "coordinator.db")
	configPath := filepath.Join(dir, "coordinator.yaml")
	configBody := `auth:
  operator_key: test-only-operator-key-1234567890
referrals:
  require_for_registration: true
  enable_social_invite_bonus: false
  campaign: prebeta_test
  policy_version: v1
  current_key_id: k1
  hmac_keys:
    k1: env:REFERRAL_REPLACE_SECRET
  provider_base_uses: 3
  social_bonus_uses: 2
  challenge_ttl_s: 900
  join_base_url: https://malibu.tech/j
`
	if err := os.WriteFile(configPath, []byte(configBody), 0o600); err != nil {
		t.Fatal(err)
	}
	policy := auth.ReferralPolicy{
		RequireForRegistration: true,
		Campaign:               "prebeta_test",
		PolicyVersion:          "v1",
		CurrentKeyID:           "k1",
		HMACKeys:               map[string]string{"k1": strings.Repeat("r", 32)},
		ProviderBaseUses:       3,
	}
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	issued, err := store.EnsureProviderReferral(context.Background(), policy, "provider-replace", time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.RevokeReferralIssuerAudited(context.Background(), policy.Campaign, issued.IssuerID, true, "ops", "compromised", &auth.ReferralRevokeExpectation{Redeemed: 0}, time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	store.Close()

	base := []string{
		"--db", dbPath, "--config", configPath, "--campaign", policy.Campaign,
		"--key-id", policy.CurrentKeyID, "--issuer-id", issued.IssuerID, "--base-uses", "3",
	}
	var preview bytes.Buffer
	if err := replaceReferralIssuer(base, &preview); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(preview.String(), "mode=dry-run") || strings.Contains(preview.String(), "new_referral_code") || strings.Contains(preview.String(), strings.Repeat("r", 32)) {
		t.Fatalf("preview=%s", preview.String())
	}
	var applied bytes.Buffer
	apply := append(append([]string{}, base...), "--apply", "--actor", "ops", "--reason", "rotate compromised link")
	if err := replaceReferralIssuer(apply, &applied); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(applied.String(), "mode=applied") || !strings.Contains(applied.String(), "verified=true") ||
		!strings.Contains(applied.String(), "new_referral_code=MAL1-P-") || strings.Contains(applied.String(), strings.Repeat("r", 32)) {
		t.Fatalf("applied=%s", applied.String())
	}
	if err := replaceReferralIssuer(append(append([]string{}, base...), "--secret", strings.Repeat("x", 32)), &bytes.Buffer{}); err == nil {
		t.Fatal("replacement accepted a secret flag on argv")
	}
}
