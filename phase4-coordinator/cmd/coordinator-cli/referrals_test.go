package main

import (
	"bytes"
	"context"
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
	createArgs := append(append([]string{}, base...), "--max-uses", "2", "--apply", "--actor", "release", "--reason", "open cohort")
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
