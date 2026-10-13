package auth_test

import (
	"context"
	"path/filepath"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
)

// SPEC-036 FR-19: a claimed provider's operator is its GitHub identity; an
// unclaimed provider is its own operator.
func TestProviderOperatorKey(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	ctx := context.Background()
	if err := store.UpsertGitHubIdentity(ctx, 42, "octo", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().ExecContext(ctx, `INSERT INTO provider_ownership (provider_id, github_user_id) VALUES ('claimed-mac', 42)`); err != nil {
		t.Fatal(err)
	}
	if got, err := store.ProviderOperatorKey(ctx, "claimed-mac"); err != nil || got != "github:42" {
		t.Fatalf("claimed: got %q, %v", got, err)
	}
	if got, err := store.ProviderOperatorKey(ctx, "loose-mac"); err != nil || got != "provider:loose-mac" {
		t.Fatalf("unclaimed: got %q, %v", got, err)
	}
}
