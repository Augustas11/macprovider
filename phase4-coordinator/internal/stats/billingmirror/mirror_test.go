package billingmirror

import (
	"bytes"
	"context"
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"

	_ "modernc.org/sqlite"
)

func TestRunDryRunReadsSQLiteWithoutPostgresDSN(t *testing.T) {
	dbPath := seedSQLite(t)
	var out bytes.Buffer
	res, err := Run(context.Background(), Options{
		SQLitePath:  dbPath,
		DryRun:      true,
		BatchSize:   10,
		OverlapRows: 1,
		SweepRows:   1,
		Stdout:      &out,
	})
	if err != nil {
		t.Fatalf("Run(dry-run) error = %v", err)
	}
	if res.RequestRowsRead != 2 {
		t.Fatalf("RequestRowsRead = %d, want 2", res.RequestRowsRead)
	}
	if res.ProviderRowsRead != 1 {
		t.Fatalf("ProviderRowsRead = %d, want 1", res.ProviderRowsRead)
	}
	if res.LastRequestID != 2 {
		t.Fatalf("LastRequestID = %d, want 2", res.LastRequestID)
	}
	if got := out.String(); !strings.Contains(got, "would upsert 2 request credit rows and ensure 1 provider identities") {
		t.Fatalf("dry-run output = %q", got)
	}
}

func TestFetchRequestCreditsParsesEffectiveStatsColumns(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	rows, err := FetchRequestCredits(context.Background(), db, 0, 10)
	if err != nil {
		t.Fatalf("FetchRequestCredits() error = %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("len(rows) = %d, want 2", len(rows))
	}
	first := rows[0]
	if first.RequestID != "req-1" || first.AttemptN != 0 || first.ProviderID != "provider-a" {
		t.Fatalf("first identity = %#v", first)
	}
	if !first.PromptTokens.Valid || first.PromptTokens.Int64 != 100 {
		t.Fatalf("prompt tokens = %#v, want 100", first.PromptTokens)
	}
	if !first.CompletionTokens.Valid || first.CompletionTokens.Int64 != 200 {
		t.Fatalf("completion tokens = %#v, want 200", first.CompletionTokens)
	}
	if first.Quarantined {
		t.Fatal("first.Quarantined = true, want false")
	}
	if first.SettlementPolicyMode != "enforce" {
		t.Fatalf("first settlement policy = %q, want enforce", first.SettlementPolicyMode)
	}
	if !first.Spec022Verified {
		t.Fatal("first.Spec022Verified = false, want true")
	}
	second := rows[1]
	if second.UsageSource != "byte_estimated" {
		t.Fatalf("second usage source = %q, want byte_estimated", second.UsageSource)
	}
	if second.CompletionTokens.Valid {
		t.Fatalf("second completion tokens = %#v, want NULL", second.CompletionTokens)
	}
	if !second.EstimatedCompletionTokens.Valid || second.EstimatedCompletionTokens.Int64 != 44 {
		t.Fatalf("second estimated completion = %#v, want 44", second.EstimatedCompletionTokens)
	}
	if !second.Quarantined {
		t.Fatal("second.Quarantined = false, want true")
	}
	if second.Spec022Verified {
		t.Fatal("second.Spec022Verified = true, want false")
	}
}

func TestFetchRequestCreditsSupportsLegacySourceSchema(t *testing.T) {
	dbPath := seedLegacySQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	rows, err := FetchRequestCredits(context.Background(), db, 0, 10)
	if err != nil {
		t.Fatalf("FetchRequestCredits() error = %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	if got := rows[0].SettlementPolicyMode; got != "legacy" {
		t.Fatalf("SettlementPolicyMode = %q, want legacy", got)
	}
	if rows[0].Spec022Verified {
		t.Fatal("Spec022Verified = true, want false for legacy source schema")
	}
}

func TestFetchMaxRequestCreditID(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	maxID, err := FetchMaxRequestCreditID(context.Background(), db)
	if err != nil {
		t.Fatalf("FetchMaxRequestCreditID() error = %v", err)
	}
	if maxID != 2 {
		t.Fatalf("maxID = %d, want 2", maxID)
	}
}

func TestFetchRequestCreditsThroughReplaysOnlyBoundedOverlap(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	rows, err := FetchRequestCreditsThrough(context.Background(), db, 0, 1, 10)
	if err != nil {
		t.Fatalf("FetchRequestCreditsThrough() error = %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	if rows[0].SQLiteID != 1 {
		t.Fatalf("SQLiteID = %d, want 1", rows[0].SQLiteID)
	}
}

func TestMaxSQLiteIDOnlyUsesSequentialNewRows(t *testing.T) {
	newRows := []RequestCredit{{SQLiteID: 11}, {SQLiteID: 12}}
	recentReplay := []RequestCredit{{SQLiteID: 99}}
	next := maxSQLiteID(newRows, 10)
	if next != 12 {
		t.Fatalf("next = %d, want 12", next)
	}
	if got := maxSQLiteID(recentReplay, next); got != 99 {
		t.Fatalf("sanity max = %d, want 99", got)
	}
	// Run intentionally calls maxSQLiteID before merging recentReplay so a
	// recently updated high-ID row cannot skip unfetched IDs 13..98.
}

func TestFetchProviderIdentitiesDoesNotRequireTokenHashes(t *testing.T) {
	dbPath := seedSQLite(t)
	db, err := OpenSQLite(dbPath)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer db.Close()

	providers, err := FetchProviderIdentities(context.Background(), db)
	if err != nil {
		t.Fatalf("FetchProviderIdentities() error = %v", err)
	}
	if len(providers) != 1 {
		t.Fatalf("len(providers) = %d, want 1", len(providers))
	}
	if providers[0].ProviderID != "provider-a" {
		t.Fatalf("provider id = %q, want provider-a", providers[0].ProviderID)
	}
	if providers[0].ProviderName != "Provider A" {
		t.Fatalf("provider name = %q, want Provider A", providers[0].ProviderName)
	}
	if !providers[0].LastUsedAt.Valid {
		t.Fatal("LastUsedAt.Valid = false, want true")
	}
}

func TestFetchProviderIdentitiesFailsWhenTrustSourceMissing(t *testing.T) {
	path := filepath.Join(t.TempDir(), "request-log.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	if _, err := db.Exec(`CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY)`); err != nil {
		t.Fatalf("seed sqlite: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close sqlite: %v", err)
	}
	source, err := OpenSQLite(path)
	if err != nil {
		t.Fatalf("OpenSQLite() error = %v", err)
	}
	defer source.Close()
	_, err = FetchProviderIdentities(context.Background(), source)
	if err == nil || !strings.Contains(err.Error(), "provider_tokens") {
		t.Fatalf("FetchProviderIdentities() error = %v, want provider_tokens failure", err)
	}
}

func TestMergeRequestCreditsDeduplicatesNaturalKey(t *testing.T) {
	old := RequestCredit{SQLiteID: 10, RequestID: "req", AttemptN: 0, ProviderID: "p", ProviderCredits: 1}
	updated := old
	updated.ProviderCredits = 2
	rows := mergeRequestCredits([]RequestCredit{old}, []RequestCredit{updated})
	if len(rows) != 1 {
		t.Fatalf("len(rows) = %d, want 1", len(rows))
	}
	if rows[0].ProviderCredits != 2 {
		t.Fatalf("ProviderCredits = %d, want updated value 2", rows[0].ProviderCredits)
	}
}

func TestSyntheticTokenHashDoesNotExposeProviderID(t *testing.T) {
	got := syntheticTokenHash("provider-secret")
	if !strings.HasPrefix(got, "stats-mirror-sha256:") {
		t.Fatalf("hash = %q, want stats mirror prefix", got)
	}
	if strings.Contains(got, "provider-secret") {
		t.Fatalf("hash exposes provider id: %q", got)
	}
	if got != syntheticTokenHash("provider-secret") {
		t.Fatal("syntheticTokenHash is not deterministic")
	}
}

func seedSQLite(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "request-log.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open sqlite seed db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`
CREATE TABLE ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    ts_utc TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    prompt_tokens INTEGER NULL,
    completion_tokens INTEGER NULL,
    estimated_completion_tokens INTEGER NULL,
    usage_source TEXT NOT NULL,
    provider_credits INTEGER NOT NULL,
    fault_flag TEXT NOT NULL,
    quarantined INTEGER NOT NULL,
    settlement_policy_mode TEXT NOT NULL DEFAULT 'legacy'
);
CREATE VIEW spec022_payable_request_credits AS
SELECT *
  FROM ledger_request_credits
 WHERE quarantined = 0
   AND settlement_policy_mode = 'enforce';
CREATE TABLE provider_tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash TEXT NOT NULL UNIQUE,
    token_prefix TEXT NOT NULL,
    provider_id TEXT NOT NULL DEFAULT '',
    provider_name TEXT NOT NULL,
    created_at TEXT NOT NULL,
    revoked_at TEXT DEFAULT NULL,
    last_used_at TEXT DEFAULT NULL
);
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
    prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
    provider_credits, fault_flag, quarantined, settlement_policy_mode
) VALUES
    ('req-1', 0, 'provider-a', '2026-07-05T08:59:00Z', '2026-07-05T08:59:01Z', NULL,
     100, 200, NULL, 'provider_reported', 300, 'none', 0, 'enforce'),
    ('req-2', 0, 'provider-a', '2026-07-05T09:01:00Z', '2026-07-05T09:01:01Z', '2026-07-05T09:02:00Z',
     33, NULL, 44, 'byte_estimated', 0, 'none', 1, 'enforce');
INSERT INTO provider_tokens (token_hash, token_prefix, provider_id, provider_name, created_at, last_used_at)
VALUES ('hash-a', 'hash-a', 'provider-a', 'Provider A', '2026-07-05T08:00:00Z', '2026-07-05T09:00:00Z');
`); err != nil {
		t.Fatalf("seed sqlite: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close sqlite seed db: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stat seed sqlite: %v", err)
	}
	return path
}

func seedLegacySQLite(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "legacy-request-log.sqlite")
	db, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("open legacy sqlite seed db: %v", err)
	}
	defer db.Close()
	if _, err := db.Exec(`
CREATE TABLE ledger_request_credits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    request_id TEXT NOT NULL,
    attempt_n INTEGER NOT NULL,
    provider_id TEXT NOT NULL,
    ts_utc TEXT NOT NULL,
    created_at_utc TEXT NOT NULL,
    updated_at_utc TEXT NULL,
    prompt_tokens INTEGER NULL,
    completion_tokens INTEGER NULL,
    estimated_completion_tokens INTEGER NULL,
    usage_source TEXT NOT NULL,
    provider_credits INTEGER NOT NULL,
    fault_flag TEXT NOT NULL,
    quarantined INTEGER NOT NULL
);
INSERT INTO ledger_request_credits (
    request_id, attempt_n, provider_id, ts_utc, created_at_utc, updated_at_utc,
    prompt_tokens, completion_tokens, estimated_completion_tokens, usage_source,
    provider_credits, fault_flag, quarantined
) VALUES (
    'legacy-req', 0, 'provider-legacy', '2026-07-05T08:59:00Z', '2026-07-05T08:59:01Z', NULL,
    10, 20, NULL, 'provider_reported', 30, 'none', 0
);
`); err != nil {
		t.Fatalf("seed legacy sqlite: %v", err)
	}
	if err := db.Close(); err != nil {
		t.Fatalf("close legacy sqlite seed db: %v", err)
	}
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("stat legacy seed sqlite: %v", err)
	}
	return path
}
