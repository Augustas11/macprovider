package fleetcache

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

func openTestStore(t *testing.T) (*Store, *sql.DB, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "coordinator.db")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	db.SetMaxOpenConns(1)
	t.Cleanup(func() { _ = db.Close() })
	store, err := NewStore(db)
	if err != nil {
		t.Fatal(err)
	}
	return store, db, path
}

func TestGrantPurgeAckGenerationSurvivesRestart(t *testing.T) {
	store, db, path := openTestStore(t)
	ctx := context.Background()
	grant, err := store.Grant(ctx, "acct-a", "conv:opaque", "provider-a")
	if err != nil || grant.Generation != 1 {
		t.Fatalf("initial grant = %+v, %v", grant, err)
	}
	otherAccount, err := store.Grant(ctx, "acct-b", "conv:opaque", "provider-a")
	if err != nil {
		t.Fatal(err)
	}
	if otherAccount.ConversationKey == grant.ConversationKey {
		t.Fatal("identical supplied key shared a provider-facing cache scope across accounts")
	}
	otherProvider, err := store.Grant(ctx, "acct-a", "conv:opaque", "provider-b")
	if err != nil {
		t.Fatal(err)
	}
	if otherProvider.ConversationKey == grant.ConversationKey {
		t.Fatal("identical account/key shared a provider-facing cache scope across providers")
	}
	result, err := store.PurgeAccount(ctx, "acct-a")
	if err != nil || len(result.Pending) != 2 || result.Pending[0].Generation != 1 || result.Pending[1].Generation != 1 {
		t.Fatalf("purge = %+v, %v", result, err)
	}
	if _, err := store.Grant(ctx, "acct-a", "conv:other", "provider-a"); !errors.Is(err, ErrPending) {
		t.Fatalf("grant during provider/account purge = %v, want ErrPending", err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	reopened, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	reopened.SetMaxOpenConns(1)
	defer reopened.Close()
	restarted, err := NewStore(reopened)
	if err != nil {
		t.Fatal(err)
	}
	pending, err := restarted.PendingForProvider(ctx, "provider-a")
	if err != nil || len(pending) != 1 {
		t.Fatalf("restarted pending = %+v, %v", pending, err)
	}
	providerBPending, err := restarted.PendingForProvider(ctx, "provider-b")
	if err != nil || len(providerBPending) != 1 || providerBPending[0].ConversationKey != otherProvider.ConversationKey {
		t.Fatalf("provider-b pending = %+v, %v", providerBPending, err)
	}
	matched, err := restarted.Ack(ctx, "provider-b", pending[0], true)
	if err != nil || matched {
		t.Fatalf("wrong-provider ack matched=%v err=%v", matched, err)
	}
	matched, err = restarted.Ack(ctx, "provider-a", pending[0], true)
	if err != nil || !matched {
		t.Fatalf("matching ack matched=%v err=%v", matched, err)
	}
	grant, err = restarted.Grant(ctx, "acct-a", "conv:opaque", "provider-a")
	if err != nil || grant.Generation != 2 {
		t.Fatalf("post-purge grant = %+v, %v", grant, err)
	}
	if _, err := restarted.Grant(ctx, "acct-a", "conv:opaque", "provider-b"); !errors.Is(err, ErrPending) {
		t.Fatalf("provider-b grant crossed provider-a ACK fence: %v", err)
	}
}

func TestPurgeAccountIsScopedAndIdempotentWhilePending(t *testing.T) {
	store, _, _ := openTestStore(t)
	ctx := context.Background()
	for _, tc := range []struct{ account, key, provider string }{
		{"acct-a", "conv:a1", "provider-a"},
		{"acct-a", "conv:a2", "provider-b"},
		{"acct-b", "conv:b1", "provider-a"},
	} {
		if _, err := store.Grant(ctx, tc.account, tc.key, tc.provider); err != nil {
			t.Fatal(err)
		}
	}
	first, err := store.PurgeAccount(ctx, "acct-a")
	if err != nil || len(first.Pending) != 2 {
		t.Fatalf("first purge = %+v, %v", first, err)
	}
	second, err := store.PurgeAccount(ctx, "acct-a")
	if err != nil || len(second.Pending) != 2 || second.Pending[0] != first.Pending[0] || second.Pending[1] != first.Pending[1] {
		t.Fatalf("idempotent purge = %+v, %v; first %+v", second, err, first)
	}
	if grant, err := store.Grant(ctx, "acct-b", "conv:b1", "provider-a"); err != nil || grant.Generation != 1 {
		t.Fatalf("other account grant = %+v, %v", grant, err)
	}
}
