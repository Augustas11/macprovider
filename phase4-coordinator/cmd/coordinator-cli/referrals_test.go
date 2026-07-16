package main

import (
	"bytes"
	"context"
	"database/sql"
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
	createArgs := append(append([]string{}, base...), "--max-uses", "2", "--apply", "--operation-id", "11111111-1111-4111-8111-111111111111", "--actor", "release", "--reason", "open cohort")
	if err := createSeedReferral(createArgs, getenv, &created); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(created.String(), "referral_code=MAL1-S-k1-launch-") {
		t.Fatalf("create output=%s", created.String())
	}
	var recovered bytes.Buffer
	if err := createSeedReferral(createArgs, getenv, &recovered); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(recovered.String(), "mode=recovered") || !strings.Contains(recovered.String(), "referral_code=MAL1-S-k1-launch-") {
		t.Fatalf("response-loss recovery output=%s", recovered.String())
	}
	if err := createSeedReferral(base, getenv, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "adjust-seed-referral") {
		t.Fatalf("duplicate create error=%v", err)
	}

	var adjustPreview bytes.Buffer
	adjustPreviewArgs := append(append([]string{}, base...), "--max-uses", "4")
	if err := adjustSeedReferral(adjustPreviewArgs, getenv, &adjustPreview); err != nil {
		t.Fatal(err)
	}
	adjustExpected := referralOutputValue(t, adjustPreview.String(), "expected_state")
	var adjusted bytes.Buffer
	adjustArgs := append(append([]string{}, adjustPreviewArgs...), "--apply", "--operation-id", "22222222-2222-4222-8222-222222222222", "--expect-state", adjustExpected, "--actor", "ops", "--reason", "expand")
	if err := adjustSeedReferral(adjustArgs, getenv, &adjusted); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(adjusted.String(), "mode=applied") || strings.Contains(adjusted.String(), "reserved=") {
		t.Fatalf("adjust output=%s", adjusted.String())
	}
	var adjustRecovered bytes.Buffer
	if err := adjustSeedReferral(adjustArgs, getenv, &adjustRecovered); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(adjustRecovered.String(), "mode=recovered") {
		t.Fatalf("adjust recovery output=%s", adjustRecovered.String())
	}

	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	var auditRows int
	if err := store.DB().QueryRowContext(context.Background(), `SELECT COUNT(1) FROM referral_admin_audit WHERE actor = 'ops' AND unix_uid = ?`, os.Geteuid()).Scan(&auditRows); err != nil {
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
	revokeExpected := referralOutputValue(t, preview.String(), "expected_state")
	revokeArgs := []string{"--db", dbPath, "--campaign", "prebeta_test", "--issuer-id", "launch", "--apply", "--operation-id", "33333333-3333-4333-8333-333333333333", "--expect-state", revokeExpected, "--actor", "ops", "--reason", "retire"}
	if err := revokeReferral(revokeArgs, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	var revokeRecovered bytes.Buffer
	if err := revokeReferral(revokeArgs, &revokeRecovered); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(revokeRecovered.String(), "mode=recovered") {
		t.Fatalf("revoke recovery output=%s", revokeRecovered.String())
	}
}

func TestReferralCommandReplacesSeedAtomicallyAndRecovers(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	getenv := func(string) string { return strings.Repeat("s", 32) }
	policyArgs := []string{"--db", dbPath, "--campaign", "prebeta_test", "--key-id", "k1", "--secret-env", "REFERRAL_SECRET"}
	if err := createSeedReferral(append(append([]string{}, policyArgs...), "--seed-id", "launch", "--max-uses", "2", "--apply", "--operation-id", "44444444-4444-4444-8444-444444444444", "--actor", "release", "--reason", "open"), getenv, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	replaceBase := append(append([]string{}, policyArgs...), "--old-seed-id", "launch", "--new-seed-id", "launch2", "--max-uses", "3")
	var preview bytes.Buffer
	if err := replaceSeedReferral(replaceBase, getenv, &preview); err != nil {
		t.Fatal(err)
	}
	expected := referralOutputValue(t, preview.String(), "expected_state")
	applyArgs := append(append([]string{}, replaceBase...), "--apply", "--operation-id", "55555555-5555-4555-8555-555555555555", "--expect-state", expected, "--actor", "ops", "--reason", "rotate")
	var applied bytes.Buffer
	if err := replaceSeedReferral(applyArgs, getenv, &applied); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(applied.String(), "mode=applied") || !strings.Contains(applied.String(), "referral_code=MAL1-S-k1-launch2-") {
		t.Fatalf("replace output=%s", applied.String())
	}
	var recovered bytes.Buffer
	if err := replaceSeedReferral(applyArgs, getenv, &recovered); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(recovered.String(), "mode=recovered") || !strings.Contains(recovered.String(), "referral_code=MAL1-S-k1-launch2-") {
		t.Fatalf("replace recovery output=%s", recovered.String())
	}
}

func TestReferralCommandsNeverAcceptSecretOnArgv(t *testing.T) {
	err := createSeedReferral([]string{"--campaign", "prebeta_test", "--key-id", "k1", "--seed-id", "launch"}, func(string) string { return "" }, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "--secret-env is required") {
		t.Fatalf("error=%v", err)
	}
}

func referralOutputValue(t *testing.T, output, key string) string {
	t.Helper()
	prefix := key + "="
	for _, line := range strings.Split(output, "\n") {
		if strings.HasPrefix(line, prefix) {
			value := strings.TrimPrefix(line, prefix)
			if value == "" {
				t.Fatalf("%s is empty in output %q", key, output)
			}
			return value
		}
	}
	t.Fatalf("%s missing from output %q", key, output)
	return ""
}

func TestReplaceProviderReferralDryRun(t *testing.T) {
	dbPath, policy, issuerID, providerID, getenv := setupReplaceProviderReferral(t)
	var stdout bytes.Buffer
	if err := replaceProviderReferral(replaceProviderBaseArgs(dbPath, issuerID), getenv, &stdout); err != nil {
		t.Fatal(err)
	}
	output := stdout.String()
	for _, want := range []string{
		"mode=dry-run",
		"provider_id=" + providerID,
		"old_issuer_id=" + issuerID,
		"current_base_capacity=1",
		"current_bonus_capacity=0",
		"redeemed=0",
		"remaining=1",
		"pending_social_review=false",
	} {
		if !strings.Contains(output, want) {
			t.Fatalf("dry-run output %q missing %q", output, want)
		}
	}
	if strings.Contains(output, "new_referral_code=") || strings.Contains(output, "new_issuer_id=") {
		t.Fatalf("dry-run disclosed apply-only output: %s", output)
	}
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	status, err := store.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || status.IssuerID != issuerID || !status.Revoked {
		t.Fatalf("status=%+v err=%v", status, err)
	}
}

func TestReplaceProviderReferralApplyRequiresAllExpectations(t *testing.T) {
	dbPath, _, issuerID, _, getenv := setupReplaceProviderReferral(t)
	args := append(replaceProviderBaseArgs(dbPath, issuerID), "--apply", "--actor", "ops", "--reason", "rotate")
	err := replaceProviderReferral(args, getenv, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "--expect-provider-id") {
		t.Fatalf("error=%v", err)
	}
}

func TestReplaceProviderReferralRejectsPreviewMismatch(t *testing.T) {
	dbPath, policy, issuerID, providerID, getenv := setupReplaceProviderReferral(t)
	args := replaceProviderApplyArgs(dbPath, issuerID, "different-provider")
	err := replaceProviderReferral(args, getenv, &bytes.Buffer{})
	if err == nil || !strings.Contains(err.Error(), "replacement snapshot drift") {
		t.Fatalf("error=%v", err)
	}
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	status, err := store.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || status.IssuerID != issuerID || !status.Revoked {
		t.Fatalf("status=%+v err=%v", status, err)
	}
}

func TestReplaceProviderReferralApplied(t *testing.T) {
	dbPath, policy, issuerID, providerID, getenv := setupReplaceProviderReferral(t)
	var stdout bytes.Buffer
	if err := replaceProviderReferral(replaceProviderApplyArgs(dbPath, issuerID, providerID), getenv, &stdout); err != nil {
		t.Fatal(err)
	}
	output := stdout.String()
	for _, want := range []string{"mode=applied", "provider_id=" + providerID, "old_issuer_id=" + issuerID, "new_issuer_id=", "new_referral_code=MAL1-P-k1-"} {
		if !strings.Contains(output, want) {
			t.Fatalf("apply output %q missing %q", output, want)
		}
	}
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	status, err := store.ProviderReferralStatus(context.Background(), policy, providerID)
	if err != nil || status.IssuerID == issuerID || status.Revoked {
		t.Fatalf("status=%+v err=%v", status, err)
	}
	var oldProvider sql.NullString
	var replacedBy sql.NullString
	if err := store.DB().QueryRow(`SELECT provider_id, replaced_by FROM referral_issuers WHERE issuer_id = ?`, issuerID).Scan(&oldProvider, &replacedBy); err != nil {
		t.Fatal(err)
	}
	if oldProvider.Valid || !replacedBy.Valid || replacedBy.String != status.IssuerID {
		t.Fatalf("old provider=%+v replaced_by=%+v new issuer=%q", oldProvider, replacedBy, status.IssuerID)
	}
}

func TestReplaceProviderReferralRequiresServingQualification(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Date(2026, 7, 16, 9, 0, 0, 0, time.UTC).Format(time.RFC3339)
	if _, err := store.DB().Exec(`
INSERT INTO referral_issuers (
    issuer_id, code_type, key_id, campaign, provider_id,
    base_capacity, bonus_capacity, created_at, first_serving_at, revoked_at
) VALUES ('unqualified', 'P', 'k1', 'prebeta_test', 'provider-unqualified', 1, 0, ?, ?, ?)`, now, now, now); err != nil {
		store.Close()
		t.Fatal(err)
	}
	store.Close()
	getenv := func(key string) string {
		if key == "REFERRAL_SECRET" {
			return strings.Repeat("s", 32)
		}
		return ""
	}
	err = replaceProviderReferral(replaceProviderBaseArgs(dbPath, "unqualified"), getenv, &bytes.Buffer{})
	if err == nil {
		t.Fatal("replacement succeeded without serving qualification")
	}
	store, err = auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	var issuerRows int
	if err := store.DB().QueryRow(`SELECT COUNT(1) FROM referral_issuers`).Scan(&issuerRows); err != nil {
		t.Fatal(err)
	}
	if issuerRows != 1 {
		t.Fatalf("issuer rows=%d", issuerRows)
	}
}

func setupReplaceProviderReferral(t *testing.T) (string, auth.ReferralPolicy, string, string, func(string) string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	getenv := func(key string) string {
		if key == "REFERRAL_SECRET" {
			return strings.Repeat("s", 32)
		}
		return ""
	}
	policy, err := referralCLIPolicy("prebeta_test", "k1", "REFERRAL_SECRET", getenv)
	if err != nil {
		t.Fatal(err)
	}
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	now := time.Date(2026, 7, 16, 9, 0, 0, 0, time.UTC)
	providerID := "provider-replace"
	status, created, err := store.QualifyProviderReferral(context.Background(), policy, providerID, "receipt-replace", now.Add(-time.Minute), now)
	if err != nil || !created {
		t.Fatalf("qualify status=%+v created=%t err=%v", status, created, err)
	}
	if _, err := store.RevokeReferralIssuerAudited(context.Background(), policy.Campaign, status.IssuerID, true, "ops", "rotate", &auth.ReferralRevokeExpectation{Redeemed: 0}, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	return dbPath, policy, status.IssuerID, providerID, getenv
}

func replaceProviderBaseArgs(dbPath, issuerID string) []string {
	return []string{"--db", dbPath, "--campaign", "prebeta_test", "--key-id", "k1", "--secret-env", "REFERRAL_SECRET", "--issuer-id", issuerID}
}

func replaceProviderApplyArgs(dbPath, issuerID, providerID string) []string {
	return append(replaceProviderBaseArgs(dbPath, issuerID),
		"--apply",
		"--actor", "ops",
		"--reason", "rotate compromised link",
		"--expect-provider-id", providerID,
		"--expect-base-capacity", "1",
		"--expect-bonus-capacity", "0",
		"--expect-redeemed", "0",
		"--expect-pending-social-review=false",
	)
}
