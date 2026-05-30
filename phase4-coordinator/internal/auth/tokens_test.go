package auth_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

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
	if record.TokenPrefix != token[:6] {
		t.Fatalf("prefix = %q, want %q", record.TokenPrefix, token[:6])
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
