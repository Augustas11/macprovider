package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

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
