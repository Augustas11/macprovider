package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

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
