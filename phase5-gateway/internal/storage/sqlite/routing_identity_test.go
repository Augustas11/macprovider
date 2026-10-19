package sqlite

import (
	"context"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

// The routing identity lookup runs on every chat attempt; on the read-only
// handle it must answer with committed links while a settlement write holds
// the single primary connection.
func TestRoutingGitHubIdentitiesReadOnlyDuringHeldWriter(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	primary, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer primary.Close()
	createAccount(t, primary, "acct")
	if err := primary.AddAccountIdentity(ctx, storage.AccountIdentity{AccountID: "acct", Provider: "github", ProviderUserID: "7", CreatedAt: fixedTime()}); err != nil {
		t.Fatal(err)
	}
	reader, err := OpenReadOnly(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	conn, err := primary.db.Conn(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	defer conn.ExecContext(context.Background(), `ROLLBACK`)
	if _, err := conn.ExecContext(ctx, `BEGIN IMMEDIATE`); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.ExecContext(ctx, `INSERT INTO account_identities (account_id, provider, provider_user_id, created_at) VALUES ('acct', 'github', '8', '2026-05-29T00:00:00Z')`); err != nil {
		t.Fatal(err)
	}

	// The primary pool's only connection is held: a lookup on it stalls.
	stalled, cancel := context.WithTimeout(ctx, 100*time.Millisecond)
	defer cancel()
	if _, err := primary.RoutingGitHubIdentities(stalled, "acct"); err == nil {
		t.Fatal("primary lookup answered while its single connection was held")
	}

	prompt, cancelPrompt := context.WithTimeout(ctx, time.Second)
	defer cancelPrompt()
	start := time.Now()
	ids, err := reader.RoutingGitHubIdentities(prompt, "acct")
	if err != nil || !reflect.DeepEqual(ids, []int64{7}) {
		t.Fatalf("committed identity through reader while writer held: ids=%v err=%v", ids, err)
	}
	if elapsed := time.Since(start); elapsed > 500*time.Millisecond {
		t.Fatalf("reader lookup took %v while writer held", elapsed)
	}
	if _, err := conn.ExecContext(ctx, `COMMIT`); err != nil {
		t.Fatal(err)
	}
	ids, err = reader.RoutingGitHubIdentities(prompt, "acct")
	if err != nil || !reflect.DeepEqual(ids, []int64{7, 8}) {
		t.Fatalf("fresh identity after commit: ids=%v err=%v", ids, err)
	}
}
