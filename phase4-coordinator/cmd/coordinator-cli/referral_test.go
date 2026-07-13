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

func TestCreateSeedReferralIsInsertOnly(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	secret := strings.Repeat("s", 32)
	args := []string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch", "--max-uses", "3",
	}
	if err := createSeedReferral(args, func(string) string { return secret }, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	err := createSeedReferral(args, func(string) string { return secret }, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "already exists") || !strings.Contains(err.Error(), "adjust-seed-referral") {
		t.Fatalf("expected insert-only conflict, got %v", err)
	}
}

func TestAdjustSeedReferralDryRunDoesNotMutateAndApplyRefusesBelowUsed(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	secret := strings.Repeat("s", 32)
	getenv := func(string) string { return secret }
	var created bytes.Buffer
	if err := createSeedReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch", "--max-uses", "3",
	}, getenv, &created); err != nil {
		t.Fatal(err)
	}
	seedCode := strings.TrimPrefix(strings.Split(created.String(), "\n")[0], "referral_code=")
	policy := auth.ReferralPolicy{
		RequireForRegistration: true, PolicyVersion: "v1", Campaign: "prebeta_2026", CurrentKeyID: "k1",
		HMACKeys: map[string]string{"k1": secret}, ProviderBaseUses: 1, SocialBonusUses: 1, ChallengeTTL: time.Minute,
	}

	// Redeem two of the three seed uses so the floor is 2.
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	for _, pid := range []string{"prov-1", "prov-2"} {
		if _, _, err := store.IssueTokenWithReferral(context.Background(), pid, pid, seedCode, policy); err != nil {
			t.Fatalf("redeem %s err=%v", pid, err)
		}
	}
	store.Close()

	// Dry-run to 1 (below the redeemed floor) must not mutate and must preview.
	var dry bytes.Buffer
	if err := adjustSeedReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch", "--max-uses", "1",
	}, getenv, &dry); err != nil {
		t.Fatalf("dry-run err=%v", err)
	}
	if !strings.Contains(dry.String(), "mode=dry-run") || !strings.Contains(dry.String(), "current_capacity=3") || !strings.Contains(dry.String(), "redeemed=2") {
		t.Fatalf("unexpected dry-run output: %s", dry.String())
	}

	// Confirm no mutation happened during dry-run.
	store, err = auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	var cap int
	if err := store.DB().QueryRowContext(context.Background(), `SELECT base_capacity FROM referral_issuers WHERE issuer_id = 'launch'`).Scan(&cap); err != nil {
		t.Fatal(err)
	}
	store.Close()
	if cap != 3 {
		t.Fatalf("dry-run mutated capacity to %d", cap)
	}

	// Apply below the redeemed floor is refused.
	if err := adjustSeedReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch", "--max-uses", "1",
		"--apply", "--actor", "ops@malibu", "--reason", "shrink",
	}, getenv, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "redeemed") {
		t.Fatalf("expected refusal below redeemed+reserved, got %v", err)
	}

	// Apply raising capacity to 5 with actor+reason succeeds and mutates.
	var applied bytes.Buffer
	if err := adjustSeedReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch", "--max-uses", "5",
		"--apply", "--actor", "ops@malibu", "--reason", "beta expansion",
	}, getenv, &applied); err != nil {
		t.Fatalf("apply err=%v", err)
	}
	if !strings.Contains(applied.String(), "mode=applied") || !strings.Contains(applied.String(), "new_capacity=5") {
		t.Fatalf("unexpected apply output: %s", applied.String())
	}

	// Apply without actor/reason is refused.
	if err := adjustSeedReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--seed-id", "launch", "--max-uses", "5", "--apply",
	}, getenv, &bytes.Buffer{}); err == nil {
		t.Fatal("expected apply without actor/reason to be refused")
	}
}

func TestReplaceReferralIssuerMintsFreshUsableIssuer(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	secret := strings.Repeat("s", 32)
	getenv := func(string) string { return secret }
	policy := auth.ReferralPolicy{
		RequireForRegistration: true, PolicyVersion: "v1", Campaign: "prebeta_2026", CurrentKeyID: "k1",
		HMACKeys: map[string]string{"k1": secret}, ProviderBaseUses: 3, SocialBonusUses: 1, ChallengeTTL: time.Minute,
	}
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 12, 10, 0, 0, 0, time.UTC)
	prov, err := store.EnsureProviderReferral(context.Background(), policy, "prov-x", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.RevokeReferralIssuer(context.Background(), policy.Campaign, prov.IssuerID, now); err != nil {
		t.Fatal(err)
	}
	store.Close()

	var out bytes.Buffer
	if err := replaceReferralIssuer([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--key-id", "k1",
		"--secret-env", "REF_SECRET", "--issuer-id", prov.IssuerID,
		"--base-uses", "3",
		"--actor", "ops@malibu", "--reason", "reissue after compromise",
	}, getenv, &out); err != nil {
		t.Fatalf("replace err=%v", err)
	}
	// FIX-570 M4: the successor inherits the campaign's base capacity (3), not a
	// hardcoded 1.
	if !strings.Contains(out.String(), "base_capacity=3") {
		t.Fatalf("successor should keep base_capacity=3, got: %s", out.String())
	}
	newCode := ""
	for _, field := range strings.Fields(out.String()) {
		if strings.HasPrefix(field, "new_referral_code=") {
			newCode = strings.TrimPrefix(field, "new_referral_code=")
		}
	}
	if newCode == "" {
		t.Fatalf("no new code in output: %s", out.String())
	}
	store, err = auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	// New issuer validates.
	if _, err := store.ValidateReferral(context.Background(), policy, newCode, now); err != nil {
		t.Fatalf("new code should validate, err=%v", err)
	}
	// Old issuer stays revoked.
	oldCode, err := auth.EncodeReferralCode(policy, auth.ReferralTypeProvider, "k1", prov.IssuerID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ValidateReferral(context.Background(), policy, oldCode, now); !errors.Is(err, auth.ErrReferralRevoked) {
		t.Fatalf("old code should stay revoked, err=%v", err)
	}
	// Audit row written.
	var audits int
	if err := store.DB().QueryRowContext(context.Background(), `SELECT COUNT(1) FROM referral_admin_audit WHERE action = 'replace_issuer'`).Scan(&audits); err != nil {
		t.Fatal(err)
	}
	if audits != 1 {
		t.Fatalf("expected 1 replace audit row, got %d", audits)
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
	// FIX-570 M6: revoke without --apply is a dry-run preview that must NOT mutate.
	var preview bytes.Buffer
	if err := revokeReferral([]string{"--db", dbPath, "--campaign", "prebeta_2026", "--issuer-id", "launch"}, &preview); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(preview.String(), "mode=dry-run") || !strings.Contains(preview.String(), "issuer_id=launch") {
		t.Fatalf("unexpected preview output: %s", preview.String())
	}
	// Applying requires actor + reason and writes an audit row.
	var revoked bytes.Buffer
	if err := revokeReferral([]string{
		"--db", dbPath, "--campaign", "prebeta_2026", "--issuer-id", "launch",
		"--apply", "--actor", "ops@malibu", "--reason", "abuse report",
	}, &revoked); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(revoked.String(), "mode=applied") || !strings.Contains(revoked.String(), "issuer_id=launch") {
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
