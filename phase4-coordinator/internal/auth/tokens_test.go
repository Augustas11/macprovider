package auth_test

import (
	"context"
	"database/sql"
	"errors"
	"net/http"
	"path/filepath"
	"sync"
	"sync/atomic"
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

// SPEC-003 v0.8.2 FR-C9.4 — the partial unique index installed by
// ensureActiveProviderIDUniqueness MUST prevent two unrevoked tokens
// from existing simultaneously for the same provider_id. The codex
// security re-audit MAJOR-1 finding on PR #44 showed that the prior
// `SELECT COUNT` + later `INSERT` sequence had a TOCTOU window: two
// concurrent tokenless connects could both pass the gate before either
// committed. This test races N concurrent IssueToken calls for the same
// provider_id and asserts that EXACTLY ONE succeeds; the rest must
// receive ErrActiveTokenAlreadyExists (mapped to TOFU close on the wire
// by ws/server.go resolveProvisionalToken).
func TestIssueTokenRefusesConcurrentDuplicateForSameProviderID(t *testing.T) {
	store, err := auth.OpenStore(filepath.Join(t.TempDir(), "coordinator.db"))
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	const racers = 16
	var (
		wg              sync.WaitGroup
		startGate       = make(chan struct{})
		successes       int32
		dupRejections   int32
		otherErrors     atomic.Value
	)
	for i := 0; i < racers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-startGate
			_, _, err := store.IssueToken(ctx, "race-target", "racer hostname")
			switch {
			case err == nil:
				atomic.AddInt32(&successes, 1)
			case errors.Is(err, auth.ErrActiveTokenAlreadyExists):
				atomic.AddInt32(&dupRejections, 1)
			default:
				otherErrors.Store(err)
			}
		}()
	}
	close(startGate)
	wg.Wait()

	if other := otherErrors.Load(); other != nil {
		t.Fatalf("unexpected non-TOFU error during concurrent IssueToken: %v", other)
	}
	if successes != 1 {
		t.Fatalf("got %d successes, want exactly 1 (the TOCTOU gate must elect a single winner)", successes)
	}
	if dupRejections != racers-1 {
		t.Fatalf("got %d ErrActiveTokenAlreadyExists rejections, want %d (one per loser)", dupRejections, racers-1)
	}

	// And the DB must reflect exactly one unrevoked row for race-target.
	records, err := store.ListTokens(ctx)
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	active := 0
	for _, r := range records {
		if r.ProviderID == "race-target" && !r.RevokedAt.Valid {
			active++
		}
	}
	if active != 1 {
		t.Fatalf("active rows for race-target = %d, want 1: %#v", active, records)
	}
}

// SPEC-003 v0.8.2 FR-C9.4 — the partial unique index migration step
// MUST collapse pre-existing duplicate active rows down to one (keeping
// the most recently created) so that the unique index can be created
// without aborting on legacy data from the v0.8 pre-TOFU era. This test
// seeds two unrevoked rows for the same provider_id BEFORE the unique
// index exists, then opens a fresh Store on the same DB and verifies
// the migration revoked the older duplicate.
func TestIssueTokenMigrationRevokesPreexistingDuplicates(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	// Phase 1: open store, but bypass the unique constraint by writing
	// two raw rows BEFORE we let the migration install the index.
	rawDB, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("open raw db: %v", err)
	}
	if _, err := rawDB.ExecContext(context.Background(), `
CREATE TABLE provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
`); err != nil {
		t.Fatalf("seed schema: %v", err)
	}
	for _, h := range []string{"legacy-hash-1", "legacy-hash-2"} {
		if _, err := rawDB.ExecContext(context.Background(), `INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at) VALUES (?, ?, ?, ?, ?)`, h, h[:12], "legacy-dup", "legacy provider", "2026-06-01T00:00:00Z"); err != nil {
			t.Fatalf("seed dup row %s: %v", h, err)
		}
	}
	_ = rawDB.Close()

	// Phase 2: open through auth.OpenStore. Its migrate() must collapse
	// the duplicates and install the index without erroring out.
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store post-seed: %v", err)
	}
	defer store.Close()

	records, err := store.ListTokens(context.Background())
	if err != nil {
		t.Fatalf("list tokens: %v", err)
	}
	active := 0
	revoked := 0
	for _, r := range records {
		if r.ProviderID != "legacy-dup" {
			continue
		}
		if r.RevokedAt.Valid {
			revoked++
		} else {
			active++
		}
	}
	if active != 1 || revoked != 1 {
		t.Fatalf("after migration: legacy-dup active=%d revoked=%d, want 1/1: %#v", active, revoked, records)
	}
}
