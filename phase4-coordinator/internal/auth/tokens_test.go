package auth_test

import (
	"context"
	"database/sql"
	"net/http"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

func TestBearerTokenMatchesHeader(t *testing.T) {
	headers := http.Header{}
	headers.Set("Authorization", "Bearer operator-secret")
	if !auth.BearerTokenMatchesHeader(headers, "operator-secret") {
		t.Fatal("valid bearer token rejected")
	}
	headers.Set("Authorization", "Bearer wrong-secret")
	if auth.BearerTokenMatchesHeader(headers, "operator-secret") {
		t.Fatal("invalid bearer token accepted")
	}
	headers.Set("Authorization", "Basic operator-secret")
	if auth.BearerTokenMatchesHeader(headers, "operator-secret") {
		t.Fatal("non-bearer authorization accepted")
	}
	if auth.BearerTokenMatchesHeader(headers, "") {
		t.Fatal("empty expected token accepted")
	}
}

func TestTokenIssueValidateRevokeAndList(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	record, token, err := store.IssueToken(ctx, "m4-anon", "M4 Provider")
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	if len(token) != 64 {
		t.Fatalf("token len = %d, want 64", len(token))
	}
	if record.TokenPrefix != token[:12] {
		t.Fatalf("prefix = %q, want %q", record.TokenPrefix, token[:12])
	}
	if record.ProviderID != "m4-anon" {
		t.Fatalf("provider_id = %q, want m4-anon", record.ProviderID)
	}

	providerID, ok, err := store.ValidateToken(ctx, token)
	if err != nil || !ok || providerID != "m4-anon" {
		t.Fatalf("validate issued token provider_id=%q ok=%v err=%v", providerID, ok, err)
	}
	records, err := store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens before use: %v", err)
	}
	if len(records) != 1 || records[0].LastUsedAt.Valid {
		t.Fatalf("records before mark used = %#v", records)
	}
	if err := store.MarkTokenUsed(ctx, token); err != nil {
		t.Fatalf("mark token used: %v", err)
	}
	providerID, ok, err = store.ValidateToken(ctx, "bad-token")
	if err != nil || ok {
		t.Fatalf("validate bad token provider_id=%q ok=%v err=%v", providerID, ok, err)
	}

	revoked, err := store.RevokeToken(ctx, record.TokenPrefix)
	if err != nil {
		t.Fatalf("revoke token: %v", err)
	}
	if !revoked.RevokedAt.Valid {
		t.Fatal("revoked_at not set")
	}
	providerID, ok, err = store.ValidateToken(ctx, token)
	if err != nil || ok {
		t.Fatalf("validate revoked token provider_id=%q ok=%v err=%v", providerID, ok, err)
	}

	records, err = store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	if len(records) != 1 || records[0].TokenPrefix != record.TokenPrefix || records[0].ProviderID != "m4-anon" || !records[0].LastUsedAt.Valid {
		t.Fatalf("records = %#v", records)
	}
}

func TestRevokeTokenRejectsAmbiguousPrefix(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open sqlite fixture handle: %v", err)
	}
	defer db.Close()
	for _, row := range []struct {
		hash       string
		providerID string
		name       string
	}{
		{hash: "hash-a", providerID: "m4-a", name: "M4 A"},
		{hash: "hash-b", providerID: "m4-b", name: "M4 B"},
	} {
		if _, err := db.ExecContext(ctx, `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, row.hash, "abcdef123456", row.providerID, row.name, "2026-06-07T00:00:00Z"); err != nil {
			t.Fatalf("insert fixture token %s: %v", row.providerID, err)
		}
	}

	_, err = store.RevokeToken(ctx, "abcdef")
	if err == nil {
		t.Fatal("ambiguous prefix unexpectedly revoked token")
	}
	records, err := store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	for _, record := range records {
		if record.RevokedAt.Valid {
			t.Fatalf("record %d revoked despite ambiguous prefix: %#v", record.ID, record)
		}
	}
}
