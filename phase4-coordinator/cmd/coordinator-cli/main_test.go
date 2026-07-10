package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func TestRevokeAndKickUsesTokenProviderID(t *testing.T) {
	dbPath, prefix := issueCLITestToken(t, "p1")
	var kickedProviderID string
	admin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/admin/blacklist" {
			t.Fatalf("path = %q", r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer operator" {
			t.Fatalf("authorization = %q", got)
		}
		var body struct {
			ProviderID string `json:"provider_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatalf("decode blacklist body: %v", err)
		}
		kickedProviderID = body.ProviderID
		w.WriteHeader(http.StatusOK)
	}))
	defer admin.Close()

	err := revokeAndKick([]string{
		"--db", dbPath,
		"--token-prefix", prefix,
		"--admin-url", admin.URL,
		"--operator-key", "operator",
	})
	if err != nil {
		t.Fatalf("revoke-and-kick: %v", err)
	}
	if kickedProviderID != "p1" {
		t.Fatalf("kicked provider_id = %q, want p1", kickedProviderID)
	}
}

func TestRevokeAndKickRejectsMismatchedProviderOverride(t *testing.T) {
	dbPath, prefix := issueCLITestToken(t, "p1")
	err := revokeAndKick([]string{
		"--db", dbPath,
		"--token-prefix", prefix,
		"--admin-url", "http://127.0.0.1:1",
		"--operator-key", "operator",
		"--provider-id", "p2",
	})
	if err == nil || !strings.Contains(err.Error(), "token belongs to provider_id p1") {
		t.Fatalf("err = %v, want provider mismatch", err)
	}
}

func TestBootstrapIdentityOperatorCommandsCoverExpiredCustody(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	providerID := "mp-00000000000000000000000000000071"
	now := time.Now().UTC().Add(-2 * time.Minute)
	mint, err := store.MintBootstrapToken(context.Background(), auth.BootstrapMintRequest{
		ProviderID: providerID, ProviderName: "expired operator custody", SourceIP: "192.0.2.71",
		ReceiptPubkey: bytes.Repeat([]byte{0x71}, 32), Now: now, TTL: time.Minute,
		PerIPLimitPerHour: 8, PerProviderPerHour: 3, GlobalLimitPerHour: 128,
		UnconfirmedIDMax: 64, OutstandingTokenMax: 64, IdentityRetention: 7 * 24 * time.Hour,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.PruneUnusedTokens(context.Background(), time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if err := store.Close(); err != nil {
		t.Fatal(err)
	}

	listed := captureStdout(t, func() {
		if err := listBootstrapIdentities([]string{"--db", dbPath, "--state", "unconfirmed-expired"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(listed, "provider_id="+providerID+" state=unconfirmed-expired") ||
		!strings.Contains(listed, " age_s=") || !strings.Contains(listed, " collect_in_s=") ||
		!strings.Contains(listed, "count=1") {
		t.Fatalf("expired identity list output=%q", listed)
	}
	for attempt := 0; attempt < 2; attempt++ {
		captureStdout(t, func() {
			if err := revokeBootstrapIdentity([]string{"--db", dbPath, "--provider-id", providerID}); err != nil {
				t.Fatalf("revoke attempt %d: %v", attempt, err)
			}
		})
	}
	listed = captureStdout(t, func() {
		if err := listBootstrapIdentities([]string{"--db", dbPath, "--state", "operator-revoked"}); err != nil {
			t.Fatal(err)
		}
	})
	if !strings.Contains(listed, "provider_id="+providerID+" state=operator-revoked") {
		t.Fatalf("revoked identity list output=%q", listed)
	}
	store, err = auth.OpenStore(dbPath)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	if _, valid, err := store.ValidateToken(context.Background(), mint.ProviderToken); err != nil || valid {
		t.Fatalf("retired bootstrap bearer valid=%v err=%v", valid, err)
	}
	missingID := "mp-00000000000000000000000000000072"
	if err := store.RevokeBootstrapIdentity(context.Background(), missingID); err == nil {
		t.Fatal("missing bootstrap identity revocation unexpectedly succeeded")
	}
}

func TestListPairOTMints_Exits0_OnPopulatedLog(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if err := store.LogPairOTMint(context.Background(), "provider-a", "127.0.0.1", "test-agent", http.StatusOK, time.Date(2026, 6, 21, 12, 0, 0, 0, time.UTC)); err != nil {
		t.Fatalf("log mint: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close store: %v", err)
	}
	output := captureStdout(t, func() {
		if err := listPairOTMints([]string{"--db", dbPath, "--provider-id", "provider-a"}); err != nil {
			t.Fatalf("listPairOTMints: %v", err)
		}
	})
	if !strings.Contains(output, "provider-a") || !strings.Contains(output, "200") {
		t.Fatalf("output = %q, want provider-a and 200", output)
	}
}

func issueCLITestToken(t *testing.T, providerID string) (string, string) {
	t.Helper()
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	record, _, err := store.IssueToken(context.Background(), providerID, providerID+" provider")
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	return dbPath, record.TokenPrefix
}

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	os.Stdout = w
	fn()
	if err := w.Close(); err != nil {
		t.Fatalf("close writer: %v", err)
	}
	os.Stdout = orig
	out, err := io.ReadAll(r)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	return string(out)
}
