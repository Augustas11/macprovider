// Regression coverage for issue #196 — usage_events PRIMARY KEY is
// (account_id, request_id). Pre-issue-#196 the PK was just
// (request_id), which let two accounts collide on the same buyer-
// supplied X-Request-ID, escaping settlement after the streaming
// response had already flushed bytes to the buyer.
//
// Three checks here:
//
//  1. Cross-account collision now SUCCEEDS — both accounts get their
//     own row. This is the core acceptance criterion for #196.
//  2. Same-account collision still no-ops via INSERT OR IGNORE and
//     the EnsureUsageEvent payload verify still returns
//     ErrUsageEventConflict on a payload mismatch. Confirms the
//     composite PK didn't accidentally re-open the same-account
//     double-bill window.
//  3. A pre-existing gateway.db with the legacy single-column PK
//     survives Migrate(), gets rebuilt into the composite shape,
//     preserves all rows, AND the append-only triggers + indexes
//     are recreated.
package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/augstar/macprovider-gateway/internal/storage"
)

func TestUsageEventsCrossAccountCollisionInsertsBothRows(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	const sharedRequestID = "shared-uuid-1234"
	eventA := storage.UsageEvent{
		RequestID: sharedRequestID, AccountID: "acct_A",
		WindowDate: "2026-06-28", PromptTokens: 10, CompletionTokens: 5, TotalTokens: 15,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}
	eventB := storage.UsageEvent{
		RequestID: sharedRequestID, AccountID: "acct_B",
		WindowDate: "2026-06-28", PromptTokens: 20, CompletionTokens: 7, TotalTokens: 27,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}
	if err := store.EnsureUsageEvent(ctx, eventA); err != nil {
		t.Fatalf("EnsureUsageEvent(A): %v", err)
	}
	if err := store.EnsureUsageEvent(ctx, eventB); err != nil {
		t.Fatalf("EnsureUsageEvent(B) — composite PK should allow cross-account collision, got: %v", err)
	}

	rows, err := store.db.QueryContext(ctx, `
		SELECT account_id, total_tokens FROM usage_events WHERE request_id = ? ORDER BY account_id`,
		sharedRequestID)
	if err != nil {
		t.Fatalf("query: %v", err)
	}
	defer rows.Close()
	var got []struct {
		acct   string
		tokens int64
	}
	for rows.Next() {
		var s struct {
			acct   string
			tokens int64
		}
		if err := rows.Scan(&s.acct, &s.tokens); err != nil {
			t.Fatalf("scan: %v", err)
		}
		got = append(got, s)
	}
	if len(got) != 2 {
		t.Fatalf("want 2 rows after cross-account collision, got %d: %+v", len(got), got)
	}
	if got[0].acct != "acct_A" || got[0].tokens != 15 {
		t.Errorf("row 0 = %+v, want {acct_A, 15}", got[0])
	}
	if got[1].acct != "acct_B" || got[1].tokens != 27 {
		t.Errorf("row 1 = %+v, want {acct_B, 27}", got[1])
	}
}

func TestUsageEventsSameAccountCollisionStillVerifies(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)

	base := storage.UsageEvent{
		RequestID: "req-same-1", AccountID: "acct_A",
		WindowDate: "2026-06-28", PromptTokens: 10, CompletionTokens: 5, TotalTokens: 15,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}
	if err := store.EnsureUsageEvent(ctx, base); err != nil {
		t.Fatalf("first EnsureUsageEvent: %v", err)
	}

	// Same (account, request) with identical payload — must no-op cleanly.
	if err := store.EnsureUsageEvent(ctx, base); err != nil {
		t.Fatalf("idempotent retry must succeed: %v", err)
	}

	// Same (account, request) but the caller is trying to bill MORE
	// tokens. Must surface ErrUsageEventConflict — same-account
	// payload-drift attack would otherwise be silenced.
	drifted := base
	drifted.CompletionTokens = 500
	drifted.TotalTokens = 510
	if err := store.EnsureUsageEvent(ctx, drifted); !errors.Is(err, storage.ErrUsageEventConflict) {
		t.Fatalf("payload-drift retry: err = %v, want ErrUsageEventConflict", err)
	}
}

func TestUsageEventsCompositePKUpgradeFromLegacyPK(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "legacy-gateway.db")

	// Stand up the LEGACY schema directly via raw sql.DB, then close.
	// This simulates a gateway.db file written by any pre-issue-#196
	// build. The schema below is the on-disk state from
	// migrate.go on origin/main prior to this commit.
	rawDB, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	legacyDDL := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`CREATE TABLE accounts (account_id TEXT PRIMARY KEY, status TEXT NOT NULL, quota_class TEXT NOT NULL, concurrency_class TEXT NOT NULL, created_at TEXT NOT NULL)`,
		`CREATE TABLE usage_events (
			request_id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			demo_identity TEXT NOT NULL DEFAULT '',
			window_date TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
			completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture')),
			outcome TEXT NOT NULL,
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX idx_usage_account_date ON usage_events(account_id, window_date)`,
		`CREATE INDEX idx_usage_created_at ON usage_events(created_at)`,
		`CREATE TRIGGER usage_events_no_update BEFORE UPDATE ON usage_events
			BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END`,
		`CREATE TRIGGER usage_events_no_delete BEFORE DELETE ON usage_events
			BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END`,
	}
	for _, d := range legacyDDL {
		if _, err := rawDB.ExecContext(ctx, d); err != nil {
			t.Fatalf("legacy DDL %q: %v", strings.SplitN(d, "(", 2)[0], err)
		}
	}
	// Seed two pre-existing rows. The legacy PK forbids two accounts
	// sharing a request_id, so we use distinct request_ids here.
	for _, seed := range []struct {
		req, acct string
		tokens    int64
	}{
		{"legacy-req-1", "acct_X", 100},
		{"legacy-req-2", "acct_Y", 200},
	} {
		if _, err := rawDB.ExecContext(ctx, `
			INSERT INTO usage_events(request_id, account_id, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
			VALUES(?, ?, '2026-06-27', 0, ?, ?, 'provider_reported', 'ok', '2026-06-27T00:00:00Z')`,
			seed.req, seed.acct, seed.tokens, seed.tokens); err != nil {
			t.Fatalf("seed %s: %v", seed.req, err)
		}
	}
	if err := rawDB.Close(); err != nil {
		t.Fatalf("close legacy db: %v", err)
	}

	// Open the file via the real Store. Migrate() must detect the
	// legacy PK shape and rebuild atomically.
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open (triggers migration): %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	// Composite PK now in place.
	pkCols := readPKColumns(t, store, "usage_events")
	if len(pkCols) != 2 || pkCols[0] != "account_id" || pkCols[1] != "request_id" {
		t.Fatalf("post-migration PK cols = %v, want [account_id request_id]", pkCols)
	}

	// Both seeded rows preserved.
	for _, want := range []struct {
		req, acct string
		tokens    int64
	}{
		{"legacy-req-1", "acct_X", 100},
		{"legacy-req-2", "acct_Y", 200},
	} {
		var gotAcct string
		var gotTotal int64
		if err := store.db.QueryRowContext(ctx, `
			SELECT account_id, total_tokens FROM usage_events WHERE request_id = ?`,
			want.req).Scan(&gotAcct, &gotTotal); err != nil {
			t.Fatalf("lookup %s: %v", want.req, err)
		}
		if gotAcct != want.acct || gotTotal != want.tokens {
			t.Errorf("%s: got (%s, %d), want (%s, %d)", want.req, gotAcct, gotTotal, want.acct, want.tokens)
		}
	}

	// Append-only DELETE trigger still fires.
	if _, err := store.db.ExecContext(ctx, `DELETE FROM usage_events WHERE request_id = 'legacy-req-1'`); err == nil {
		t.Fatal("DELETE on usage_events after migration unexpectedly succeeded; append-only trigger lost")
	}

	// Cross-account collision now works.
	createAccount(t, store, "acct_A")
	createAccount(t, store, "acct_B")
	if err := store.EnsureUsageEvent(ctx, storage.UsageEvent{
		RequestID: "shared-after-migration", AccountID: "acct_A",
		WindowDate: "2026-06-28", PromptTokens: 1, CompletionTokens: 1, TotalTokens: 2,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("post-migration insert A: %v", err)
	}
	if err := store.EnsureUsageEvent(ctx, storage.UsageEvent{
		RequestID: "shared-after-migration", AccountID: "acct_B",
		WindowDate: "2026-06-28", PromptTokens: 1, CompletionTokens: 1, TotalTokens: 2,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("post-migration cross-account insert B (composite PK was supposed to allow this): %v", err)
	}

	// Secondary indexes recreated — query the index list and confirm
	// both are present on the renamed table.
	var idxNames []string
	rows, err := store.db.QueryContext(ctx, `SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'usage_events' ORDER BY name`)
	if err != nil {
		t.Fatalf("query indexes: %v", err)
	}
	for rows.Next() {
		var n string
		if err := rows.Scan(&n); err != nil {
			rows.Close()
			t.Fatalf("scan index name: %v", err)
		}
		idxNames = append(idxNames, n)
	}
	rows.Close()
	wantIdx := map[string]bool{"idx_usage_account_date": true, "idx_usage_created_at": true}
	for _, n := range idxNames {
		delete(wantIdx, n)
	}
	if len(wantIdx) > 0 {
		t.Errorf("missing indexes after migration: %v (got: %v)", wantIdx, idxNames)
	}
}

// TestExplorerSessionDetailAmbiguityWhenAccountIDOmitted pins the
// ISS-196 R1 architect + security HIGH finding: with composite PK,
// a request_id can resolve to multiple accounts. ExplorerSessionDetail
// MUST detect the unscoped-lookup ambiguity and surface
// ErrExplorerAmbiguousRequestID with the matching account list,
// rather than silently returning one arbitrary row.
func TestExplorerSessionDetailAmbiguityWhenAccountIDOmitted(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	const sharedRequestID = "amb-uuid-0001"
	createAccount(t, store, "acct_A")
	createAccount(t, store, "acct_B")
	for _, acct := range []string{"acct_A", "acct_B"} {
		if err := store.EnsureUsageEvent(ctx, storage.UsageEvent{
			RequestID: sharedRequestID, AccountID: acct,
			WindowDate: "2026-06-28", PromptTokens: 1, CompletionTokens: 1, TotalTokens: 2,
			TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
		}); err != nil {
			t.Fatalf("EnsureUsageEvent(%s): %v", acct, err)
		}
	}
	// Unscoped lookup — must surface ambiguity, not a silent winner.
	got, err := store.ExplorerSessionDetail(ctx, "", sharedRequestID)
	if !errors.Is(err, storage.ErrExplorerAmbiguousRequestID) {
		t.Fatalf("unscoped lookup: err=%v, want ErrExplorerAmbiguousRequestID", err)
	}
	if len(got.MatchedAccountIDs) != 2 {
		t.Fatalf("MatchedAccountIDs=%v, want both accounts", got.MatchedAccountIDs)
	}
	if got.MatchedAccountIDs[0] != "acct_A" || got.MatchedAccountIDs[1] != "acct_B" {
		t.Errorf("MatchedAccountIDs=%v, want [acct_A acct_B] (sorted)", got.MatchedAccountIDs)
	}
	// Scoped lookup — must return the right account's row.
	scopedA, err := store.ExplorerSessionDetail(ctx, "acct_A", sharedRequestID)
	if err != nil {
		t.Fatalf("scoped(acct_A) lookup: %v", err)
	}
	if scopedA.UsageEvent == nil || scopedA.UsageEvent.AccountID != "acct_A" {
		t.Errorf("scoped(acct_A).UsageEvent=%+v, want acct_A row", scopedA.UsageEvent)
	}
	// Wrong-account scoped lookup → ErrNotFound, NOT cross-account leak.
	if _, err := store.ExplorerSessionDetail(ctx, "acct_NONE", sharedRequestID); !errors.Is(err, storage.ErrNotFound) {
		t.Fatalf("scoped(acct_NONE) lookup: err=%v, want ErrNotFound", err)
	}
}

// TestExplorerSessionDetailAmbiguityExtendedToFeedbackAndAudit pins the
// ISS-212 R2 security MEDIUM finding: a buyer-attachable feedback row
// (request_id is caller-supplied) from one account would otherwise
// cross-pollinate another account's 200 response on the unscoped path
// without triggering 409. The ambiguity union MUST include
// feedback_events and audit_events alongside usage_events,
// quota_reservations, and concurrency_reservations.
func TestExplorerSessionDetailAmbiguityExtendedToFeedbackAndAudit(t *testing.T) {
	ctx := context.Background()
	store := newTestStore(t)
	const sharedRequestID = "amb-feedback-uuid-0001"
	createAccount(t, store, "acct_A")
	createAccount(t, store, "acct_B")
	// acct_A has a usage_events row; acct_B has only a feedback_events
	// row (the buyer-attachable cross-account contamination shape).
	if err := store.EnsureUsageEvent(ctx, storage.UsageEvent{
		RequestID: sharedRequestID, AccountID: "acct_A",
		WindowDate: "2026-06-28", PromptTokens: 1, CompletionTokens: 1, TotalTokens: 2,
		TokenSource: "provider_reported", Outcome: "ok", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("EnsureUsageEvent(acct_A): %v", err)
	}
	if err := store.InsertFeedbackEvent(ctx, storage.FeedbackEvent{
		EventID: "evt_b_feedback", RequestID: sharedRequestID, AccountID: "acct_B",
		Scope: "request", Rating: 4, Comment: "hijack attempt", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertFeedbackEvent(acct_B): %v", err)
	}
	got, err := store.ExplorerSessionDetail(ctx, "", sharedRequestID)
	if !errors.Is(err, storage.ErrExplorerAmbiguousRequestID) {
		t.Fatalf("unscoped lookup with feedback-only second account: err=%v, want ErrExplorerAmbiguousRequestID", err)
	}
	if len(got.MatchedAccountIDs) != 2 {
		t.Fatalf("MatchedAccountIDs=%v, want both accounts", got.MatchedAccountIDs)
	}
	if got.MatchedAccountIDs[0] != "acct_A" || got.MatchedAccountIDs[1] != "acct_B" {
		t.Errorf("MatchedAccountIDs=%v, want [acct_A acct_B] (sorted)", got.MatchedAccountIDs)
	}
}

// TestSchemaVersionGateRejectsNewerDB pins the ISS-196 R1 architect
// HIGH "rollback" finding: an older binary opening a DB whose
// schema_migrations.version exceeds the binary's max-known version
// MUST refuse to open, preventing the legacy `WHERE request_id = ?`
// path from returning wrong-account rows on a downgrade.
func TestSchemaVersionGateRejectsNewerDB(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "future-gateway.db")
	// Open + Migrate normally, then bump the version past
	// maxKnownSchemaVersion to simulate a future-binary DB.
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	if _, err := store.db.ExecContext(ctx,
		`INSERT OR IGNORE INTO schema_migrations(version, applied_at) VALUES(?, ?)`,
		maxKnownSchemaVersion+1, encodeTime(fixedTime())); err != nil {
		t.Fatalf("stamp future version: %v", err)
	}
	_ = store.Close()
	// Re-open: must fail closed.
	store2, err := Open(ctx, path)
	if err == nil {
		_ = store2.Close()
		t.Fatal("Open on future-version DB unexpectedly succeeded; rollback safety regressed")
	}
	if !strings.Contains(err.Error(), "exceeds this binary's max-known version") {
		t.Errorf("error = %q, want 'exceeds this binary's max-known version'", err.Error())
	}
}

// TestUsageEventsCompositePKAndSchemaV2CommitAtomically pins ISS-196
// R4 architect HIGH: the table rebuild and the
// schema_migrations.version=2 stamp MUST commit in the SAME
// transaction. Otherwise a rebuild that committed but a stamp that
// failed in a prior run could leave a composite-PK DB with version=1,
// which an old binary would mishandle. We verify atomicity by
// inspecting the migrated DB: composite shape AND v2 marker must
// both be present whenever the rebuild path runs.
func TestUsageEventsCompositePKAndSchemaV2CommitAtomically(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "atomic-gateway.db")
	rawDB, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	for _, d := range []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`CREATE TABLE accounts (account_id TEXT PRIMARY KEY, status TEXT NOT NULL, quota_class TEXT NOT NULL, concurrency_class TEXT NOT NULL, created_at TEXT NOT NULL)`,
		`CREATE TABLE usage_events (
			request_id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			demo_identity TEXT NOT NULL DEFAULT '',
			window_date TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
			completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture')),
			outcome TEXT NOT NULL,
			created_at TEXT NOT NULL
		)`,
		`INSERT INTO schema_migrations VALUES (1, '2026-06-01T00:00:00Z')`,
	} {
		if _, err := rawDB.ExecContext(ctx, d); err != nil {
			t.Fatalf("legacy DDL: %v", err)
		}
	}
	if err := rawDB.Close(); err != nil {
		t.Fatalf("close legacy db: %v", err)
	}
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open (triggers migration): %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	// Composite PK installed.
	pkCols := readPKColumns(t, store, "usage_events")
	if !(len(pkCols) == 2 && pkCols[0] == "account_id" && pkCols[1] == "request_id") {
		t.Fatalf("post-migration PK = %v, want composite [account_id request_id]", pkCols)
	}
	// And v2 stamp present.
	var maxVer sql.NullInt64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&maxVer); err != nil {
		t.Fatalf("read schema_migrations: %v", err)
	}
	if !maxVer.Valid || maxVer.Int64 < 2 {
		t.Errorf("schema_migrations max version = %v, want >= 2 (must be stamped atomically with rebuild)", maxVer)
	}
}

func TestUsageEventsCoordinatorObservedSourceMigration(t *testing.T) {
	ctx := context.Background()
	path := filepath.Join(t.TempDir(), "v4-gateway.db")
	rawDB, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	for _, d := range []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`INSERT INTO schema_migrations VALUES (1, '2026-06-01T00:00:00Z')`,
		`INSERT INTO schema_migrations VALUES (2, '2026-06-02T00:00:00Z')`,
		`INSERT INTO schema_migrations VALUES (3, '2026-06-03T00:00:00Z')`,
		`INSERT INTO schema_migrations VALUES (4, '2026-06-04T00:00:00Z')`,
		`CREATE TABLE accounts (account_id TEXT PRIMARY KEY, status TEXT NOT NULL, quota_class TEXT NOT NULL, concurrency_class TEXT NOT NULL, created_at TEXT NOT NULL)`,
		`CREATE TABLE usage_events (
			request_id TEXT NOT NULL,
			account_id TEXT NOT NULL,
			demo_identity TEXT NOT NULL DEFAULT '',
			window_date TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
			completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture')),
			outcome TEXT NOT NULL,
			created_at TEXT NOT NULL,
			PRIMARY KEY (account_id, request_id)
		)`,
		`CREATE INDEX idx_usage_account_date ON usage_events(account_id, window_date)`,
		`CREATE INDEX idx_usage_created_at ON usage_events(created_at)`,
		`CREATE TRIGGER usage_events_no_update BEFORE UPDATE ON usage_events
			BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END`,
		`CREATE TRIGGER usage_events_no_delete BEFORE DELETE ON usage_events
			BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END`,
		`INSERT INTO usage_events(request_id, account_id, window_date, prompt_tokens, completion_tokens, total_tokens, token_source, outcome, created_at)
			VALUES('req_existing', 'acct_v4', '2026-06-27', 1, 2, 3, 'provider_reported', 'ok', '2026-06-27T00:00:00Z')`,
	} {
		if _, err := rawDB.ExecContext(ctx, d); err != nil {
			t.Fatalf("v4 DDL: %v", err)
		}
	}
	if err := rawDB.Close(); err != nil {
		t.Fatalf("close v4 db: %v", err)
	}
	store, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open (triggers migration): %v", err)
	}
	t.Cleanup(func() { _ = store.Close() })

	sqlText := readUsageEventsMaster(t, store)["usage_events"]
	if !strings.Contains(sqlText, "coordinator_observed") {
		t.Fatalf("usage_events DDL missing coordinator_observed after migration: %s", sqlText)
	}
	var maxVer int64
	if err := store.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_migrations`).Scan(&maxVer); err != nil {
		t.Fatalf("read schema_migrations: %v", err)
	}
	if maxVer < 5 {
		t.Fatalf("schema_migrations max version=%d want >=5", maxVer)
	}
	if err := store.InsertUsageEvent(ctx, storage.UsageEvent{
		RequestID: "req_coord", AccountID: "acct_v4", WindowDate: "2026-06-27",
		PromptTokens: 4, CompletionTokens: 5, TotalTokens: 9,
		TokenSource: "coordinator_observed", Outcome: "spec022_verified", CreatedAt: fixedTime(),
	}); err != nil {
		t.Fatalf("InsertUsageEvent coordinator_observed: %v", err)
	}
	var n int
	if err := store.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM usage_events WHERE account_id = 'acct_v4'`).Scan(&n); err != nil {
		t.Fatalf("count usage_events: %v", err)
	}
	if n != 2 {
		t.Fatalf("usage_events count=%d want existing row plus coordinator_observed row", n)
	}
	assertSQLFails(t, store, `UPDATE usage_events SET total_tokens = 99 WHERE request_id = 'req_coord'`)
}

// TestUsageEventsSqliteMasterByteIdenticalAcrossPaths pins ISS-196
// R2 architect MEDIUM: schema-comparison tools (sqldiff, dbschema)
// expect the post-migration sqlite_master.sql entries for
// usage_events + indexes + triggers to be byte-for-byte identical
// to a fresh install. The rebuild-and-rename pattern in
// ensureUsageEventsCompositePK uses the shared usageEventsTableDDL
// / usageEventsAuxiliaryDDL constants for exactly this reason.
func TestUsageEventsSqliteMasterByteIdenticalAcrossPaths(t *testing.T) {
	ctx := context.Background()
	freshStore := newTestStore(t)
	freshMaster := readUsageEventsMaster(t, freshStore)

	// Migrated store: build from legacy schema, then Open via the
	// real Store which runs ensureUsageEventsCompositePK.
	path := filepath.Join(t.TempDir(), "migrated-gateway.db")
	rawDB, err := sql.Open("sqlite", sqliteDSN(path))
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	legacyDDL := []string{
		`CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, applied_at TEXT NOT NULL)`,
		`CREATE TABLE accounts (account_id TEXT PRIMARY KEY, status TEXT NOT NULL, quota_class TEXT NOT NULL, concurrency_class TEXT NOT NULL, created_at TEXT NOT NULL)`,
		`CREATE TABLE usage_events (
			request_id TEXT PRIMARY KEY,
			account_id TEXT NOT NULL,
			demo_identity TEXT NOT NULL DEFAULT '',
			window_date TEXT NOT NULL,
			prompt_tokens INTEGER NOT NULL CHECK (prompt_tokens >= 0),
			completion_tokens INTEGER NOT NULL CHECK (completion_tokens >= 0),
			total_tokens INTEGER NOT NULL CHECK (total_tokens >= 0),
			token_source TEXT NOT NULL CHECK (token_source IN ('provider_reported', 'gateway_estimated', 'manual_fixture')),
			outcome TEXT NOT NULL,
			created_at TEXT NOT NULL
		)`,
		`CREATE INDEX idx_usage_account_date ON usage_events(account_id, window_date)`,
		`CREATE INDEX idx_usage_created_at ON usage_events(created_at)`,
		`CREATE TRIGGER usage_events_no_update BEFORE UPDATE ON usage_events
			BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END`,
		`CREATE TRIGGER usage_events_no_delete BEFORE DELETE ON usage_events
			BEGIN SELECT RAISE(ABORT, 'usage_events are append-only'); END`,
	}
	for _, d := range legacyDDL {
		if _, err := rawDB.ExecContext(ctx, d); err != nil {
			t.Fatalf("legacy DDL: %v", err)
		}
	}
	if err := rawDB.Close(); err != nil {
		t.Fatalf("close legacy db: %v", err)
	}
	migrated, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("Open (triggers migration): %v", err)
	}
	t.Cleanup(func() { _ = migrated.Close() })
	migratedMaster := readUsageEventsMaster(t, migrated)

	if len(freshMaster) != len(migratedMaster) {
		t.Fatalf("master row counts differ: fresh=%d migrated=%d", len(freshMaster), len(migratedMaster))
	}
	for name, freshSQL := range freshMaster {
		migSQL, ok := migratedMaster[name]
		if !ok {
			t.Errorf("migrated master missing %q", name)
			continue
		}
		if freshSQL != migSQL {
			t.Errorf("sqlite_master.sql diverges for %q\n  fresh:    %q\n  migrated: %q", name, freshSQL, migSQL)
		}
	}
}

// readUsageEventsMaster returns name → sql for every sqlite_master
// row attached to the usage_events table (table itself + indexes +
// triggers), skipping auto-generated entries.
func readUsageEventsMaster(t *testing.T, store *Store) map[string]string {
	t.Helper()
	rows, err := store.db.QueryContext(context.Background(), `
		SELECT name, COALESCE(sql, '') FROM sqlite_master
		WHERE tbl_name = 'usage_events' AND name NOT LIKE 'sqlite_autoindex_%'
		ORDER BY name`)
	if err != nil {
		t.Fatalf("query sqlite_master: %v", err)
	}
	defer rows.Close()
	out := map[string]string{}
	for rows.Next() {
		var name, sqlText string
		if err := rows.Scan(&name, &sqlText); err != nil {
			t.Fatalf("scan: %v", err)
		}
		out[name] = sqlText
	}
	return out
}

func readPKColumns(t *testing.T, store *Store, table string) []string {
	t.Helper()
	rows, err := store.db.QueryContext(context.Background(), `PRAGMA table_info(`+table+`)`)
	if err != nil {
		t.Fatalf("PRAGMA table_info: %v", err)
	}
	defer rows.Close()
	type colInfo struct {
		name string
		pk   int
	}
	var pkCols []colInfo
	for rows.Next() {
		var cid int
		var name, typ string
		var notNull int
		var defaultValue sql.NullString
		var pk int
		if err := rows.Scan(&cid, &name, &typ, &notNull, &defaultValue, &pk); err != nil {
			t.Fatalf("scan: %v", err)
		}
		if pk > 0 {
			pkCols = append(pkCols, colInfo{name: name, pk: pk})
		}
	}
	// Sort by pk column index (1, 2, ...).
	for i := 0; i < len(pkCols); i++ {
		for j := i + 1; j < len(pkCols); j++ {
			if pkCols[j].pk < pkCols[i].pk {
				pkCols[i], pkCols[j] = pkCols[j], pkCols[i]
			}
		}
	}
	out := make([]string, len(pkCols))
	for i, c := range pkCols {
		out[i] = c.name
	}
	return out
}
