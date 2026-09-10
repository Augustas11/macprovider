package sqlite

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/augstar/macprovider-gateway/internal/auth"
	"github.com/augstar/macprovider-gateway/internal/storage"
)

func oauthHandoffTestKey(id string) storage.APIKey {
	hash := keyHash(id)
	return storage.APIKey{KeyID: "key_" + id, KeyHash: hash[:], KeyHashPrefix: "mp_test", Status: "active"}
}

func storeHandoffIntent(t *testing.T, store *Store, token string) []byte {
	t.Helper()
	hash := auth.StateHash(token)
	if err := store.StoreOAuthHandoff(context.Background(), storage.OAuthHandoff{
		TokenHash: hash, AccountID: "acct_handoff", Action: "mint",
		CreatedAt: fixedTime(), ExpiresAt: fixedTime().Add(5 * time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	return hash
}

func assertHandoffKeyCount(t *testing.T, store *Store, want int) {
	t.Helper()
	var count int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM api_keys`).Scan(&count); err != nil || count != want {
		t.Fatalf("key count=%d want=%d err=%v", count, want, err)
	}
}

func TestOAuthHandoffConcurrentExchangeIssuesExactlyOneKey(t *testing.T) {
	store := newTestStore(t)
	createAccount(t, store, "acct_handoff")
	tokenHash := storeHandoffIntent(t, store, "concurrent-handoff")
	const attempts = 16
	start := make(chan struct{})
	var succeeded atomic.Int32
	var rejected atomic.Int32
	var wg sync.WaitGroup
	for i := 0; i < attempts; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			<-start
			_, err := store.ConsumeOAuthHandoff(context.Background(), tokenHash, oauthHandoffTestKey(fmt.Sprint(i)), fixedTime())
			switch {
			case err == nil:
				succeeded.Add(1)
			case errors.Is(err, storage.ErrNotFound):
				rejected.Add(1)
			default:
				t.Errorf("exchange: %v", err)
			}
		}(i)
	}
	close(start)
	wg.Wait()
	if succeeded.Load() != 1 || rejected.Load() != attempts-1 {
		t.Fatalf("succeeded=%d rejected=%d", succeeded.Load(), rejected.Load())
	}
	assertHandoffKeyCount(t, store, 1)
}

func TestOAuthHandoffExchangeRollback(t *testing.T) {
	for _, phase := range []string{"key_insert", "intent_consume"} {
		t.Run(phase, func(t *testing.T) {
			ctx := context.Background()
			store := newTestStore(t)
			createAccount(t, store, "acct_handoff")
			tokenHash := storeHandoffIntent(t, store, "rollback-handoff")
			trigger := `CREATE TRIGGER fail_exchange BEFORE INSERT ON api_keys BEGIN SELECT RAISE(ABORT, 'test failure'); END`
			if phase == "intent_consume" {
				trigger = `CREATE TRIGGER fail_exchange BEFORE UPDATE ON oauth_handoffs BEGIN SELECT RAISE(ABORT, 'test failure'); END`
			}
			if _, err := store.db.Exec(trigger); err != nil {
				t.Fatal(err)
			}
			key := oauthHandoffTestKey(phase)
			if _, err := store.ConsumeOAuthHandoff(ctx, tokenHash, key, fixedTime()); err == nil {
				t.Fatal("induced failure unexpectedly succeeded")
			}
			assertHandoffKeyCount(t, store, 0)
			var consumed string
			if err := store.db.QueryRow(`SELECT consumed_at FROM oauth_handoffs WHERE token_hash = ?`, tokenHash).Scan(&consumed); err != nil || consumed != "" {
				t.Fatalf("consumed=%q err=%v", consumed, err)
			}
			if _, err := store.db.Exec(`DROP TRIGGER fail_exchange`); err != nil {
				t.Fatal(err)
			}
			if _, err := store.ConsumeOAuthHandoff(ctx, tokenHash, key, fixedTime()); err != nil {
				t.Fatalf("retry: %v", err)
			}
			assertHandoffKeyCount(t, store, 1)
		})
	}
}

func TestOAuthHandoffExchangeUsesActiveIntentAccount(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_handoff")
	createAccount(t, store, "acct_other")
	tokenHash := storeHandoffIntent(t, store, "account-handoff")
	key := oauthHandoffTestKey("account")
	key.AccountID = "acct_other"
	if _, err := store.db.Exec(`UPDATE accounts SET status = 'blocked' WHERE account_id = 'acct_handoff'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsumeOAuthHandoff(ctx, tokenHash, key, fixedTime()); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("blocked account err=%v", err)
	}
	assertHandoffKeyCount(t, store, 0)
	if _, err := store.db.Exec(`UPDATE accounts SET status = 'active' WHERE account_id = 'acct_handoff'`); err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsumeOAuthHandoff(ctx, tokenHash, key, fixedTime()); err != nil {
		t.Fatal(err)
	}
	validation, err := store.ValidateAPIKeyHash(ctx, key.KeyHash)
	if err != nil || validation.AccountID != "acct_handoff" {
		t.Fatalf("account=%q err=%v", validation.AccountID, err)
	}
}

func TestOAuthHandoffDatabaseContainsNoReusableSecret(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "gateway.db")
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()
	createAccount(t, store, "acct_handoff")
	token, err := auth.StateToken()
	if err != nil {
		t.Fatal(err)
	}
	tokenHash := storeHandoffIntent(t, store, token)
	assertHandoffKeyCount(t, store, 0)
	manager := auth.NewKeyManager("mp_", "hmac_sha256", "test-only-key-hash-secret")
	secret, key, err := manager.Generate("")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.ConsumeOAuthHandoff(ctx, tokenHash, key, fixedTime()); err != nil {
		t.Fatal(err)
	}
	if _, err := manager.Validate(ctx, store, secret); err != nil {
		t.Fatalf("issued key invalid: %v", err)
	}
	var rawColumns int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('oauth_handoffs') WHERE name = 'api_key'`).Scan(&rawColumns); err != nil || rawColumns != 0 {
		t.Fatalf("raw key columns=%d err=%v", rawColumns, err)
	}
	// Inspect active WAL and checkpointed database bytes, not only live rows.
	assertNoSecret := func() {
		t.Helper()
		for _, name := range []string{path, path + "-wal"} {
			data, err := os.ReadFile(name)
			if os.IsNotExist(err) {
				continue
			}
			if err != nil {
				t.Fatal(err)
			}
			if bytes.Contains(data, []byte(secret)) || bytes.Contains(data, []byte(token)) {
				t.Fatal("database contains reusable credential or raw handoff token")
			}
		}
	}
	assertNoSecret()
	if _, err := store.db.Exec(`PRAGMA wal_checkpoint(TRUNCATE)`); err != nil {
		t.Fatal(err)
	}
	assertNoSecret()
}

func TestOAuthHandoffMigrationInvalidatesLegacyRows(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	createAccount(t, store, "acct_handoff")
	legacyKey := oauthHandoffTestKey("legacy")
	legacyKey.AccountID = "acct_handoff"
	if err := store.CreateAPIKey(ctx, legacyKey); err != nil {
		t.Fatal(err)
	}
	if _, err := store.db.Exec(`
		DROP TABLE oauth_handoffs;
		DELETE FROM schema_migrations WHERE version = 12;
		CREATE TABLE oauth_handoffs (
			token_hash BLOB PRIMARY KEY, api_key TEXT NOT NULL, created_at TEXT NOT NULL,
			expires_at TEXT NOT NULL, consumed_at TEXT NOT NULL DEFAULT ''
		);
		CREATE INDEX idx_oauth_handoffs_expires ON oauth_handoffs(expires_at)`); err != nil {
		t.Fatal(err)
	}
	for _, consumed := range []string{"", encodeTime(fixedTime())} {
		if _, err := store.db.Exec(`INSERT INTO oauth_handoffs VALUES(?, ?, ?, ?, ?)`,
			auth.StateHash("legacy"+consumed), "mp_legacy-test-only-secret", encodeTime(fixedTime()), encodeTime(fixedTime().Add(time.Hour)), consumed); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 2; i++ {
		if err := store.Migrate(ctx); err != nil {
			t.Fatalf("migration %d: %v", i, err)
		}
	}
	var columns, rows, version int
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM pragma_table_info('oauth_handoffs') WHERE name = 'api_key'`).Scan(&columns); err != nil || columns != 0 {
		t.Fatalf("plaintext columns=%d err=%v", columns, err)
	}
	if err := store.db.QueryRow(`SELECT COUNT(*) FROM oauth_handoffs`).Scan(&rows); err != nil || rows != 0 {
		t.Fatalf("legacy rows=%d err=%v", rows, err)
	}
	if err := store.db.QueryRow(`SELECT MAX(version) FROM schema_migrations`).Scan(&version); err != nil || version != maxKnownSchemaVersion {
		t.Fatalf("schema version=%d err=%v", version, err)
	}
	if _, err := store.ConsumeOAuthHandoff(ctx, auth.StateHash("legacy"), oauthHandoffTestKey("rejected"), fixedTime()); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("legacy handoff err=%v", err)
	}
	// Migration invalidates handoffs, not unrelated or previously issued keys.
	validation, err := store.ValidateAPIKeyHash(ctx, legacyKey.KeyHash)
	if err != nil || validation.KeyStatus != "active" {
		t.Fatalf("legacy key status=%q err=%v", validation.KeyStatus, err)
	}
	tokenHash := storeHandoffIntent(t, store, "after-upgrade")
	if _, err := store.ConsumeOAuthHandoff(ctx, tokenHash, oauthHandoffTestKey("new"), fixedTime()); err != nil {
		t.Fatalf("post-upgrade exchange: %v", err)
	}
}
