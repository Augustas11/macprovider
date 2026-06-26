package main

import (
	"bytes"
	"context"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/auth"
	_ "modernc.org/sqlite"
)

// osStat is a thin wrapper so the missing-DB test can detect side-effect
// creation without importing os in the test body (keeps the path check
// readable).
func osStat(path string) (os.FileInfo, error) { return os.Stat(path) }

// writeRawLastUsed UPDATEs last_used_at to a literal string, bypassing any
// format constraint — used to exercise non-canonical-format detection.
func writeRawLastUsed(t *testing.T, dbPath, tokenPrefix, raw string) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql.Open raw write: %v", err)
	}
	defer db.Close()
	res, err := db.ExecContext(context.Background(),
		`UPDATE provider_tokens SET last_used_at = ? WHERE token_prefix = ?`,
		raw, tokenPrefix)
	if err != nil {
		t.Fatalf("raw write UPDATE: %v", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		t.Fatalf("raw write matched 0 rows for token_prefix=%s", tokenPrefix)
	}
}

// preFlipAudit core scenarios.
func TestPreFlipAudit_NoTokens_Safe(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	closeFreshDB(t, dbPath)

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath})
	if stale {
		t.Fatalf("expected stale=false on empty DB, got true; output:\n%s", out)
	}
	if !strings.Contains(out, "safe_to_flip=true") {
		t.Fatalf("missing safe_to_flip=true in output:\n%s", out)
	}
	if !strings.Contains(out, "active_tokens=0") {
		t.Fatalf("missing active_tokens=0 in output:\n%s", out)
	}
}

func TestPreFlipAudit_AllFresh_Safe(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, prefix := issuePreFlipTestToken(t, dbPath, "fresh-provider")
	// Stamp last_used_at to now (well within 24h cutoff).
	backdateLastUsed(t, dbPath, prefix, time.Now().UTC())

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h"})
	if stale {
		t.Fatalf("expected stale=false for fresh row, got true; output:\n%s", out)
	}
	if !strings.Contains(out, "safe_to_flip=true") {
		t.Fatalf("missing safe_to_flip=true in output:\n%s", out)
	}
	if !strings.Contains(out, "active_tokens=1") {
		t.Fatalf("expected active_tokens=1; output:\n%s", out)
	}
}

func TestPreFlipAudit_NullLastUsed_Stale(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, prefix := issuePreFlipTestToken(t, dbPath, "unused-provider")
	// Leave last_used_at NULL (default after IssueToken).

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h"})
	if !stale {
		t.Fatalf("expected stale=true for NULL last_used_at, got false; output:\n%s", out)
	}
	if !strings.Contains(out, "safe_to_flip=false") {
		t.Fatalf("missing safe_to_flip=false in output:\n%s", out)
	}
	if !strings.Contains(out, "last_used_at=NULL") {
		t.Fatalf("expected last_used_at=NULL line; output:\n%s", out)
	}
	if !strings.Contains(out, prefix) {
		t.Fatalf("expected token prefix %s in offender list; output:\n%s", prefix, out)
	}
}

func TestPreFlipAudit_OldLastUsed_Stale(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, prefix := issuePreFlipTestToken(t, dbPath, "old-provider")
	// Backdate last_used_at to 48h ago (older than 24h cutoff).
	backdateLastUsed(t, dbPath, prefix, time.Now().UTC().Add(-48*time.Hour))

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h"})
	if !stale {
		t.Fatalf("expected stale=true for 48h-old last_used_at, got false; output:\n%s", out)
	}
	if !strings.Contains(out, "older than cutoff") {
		t.Fatalf("expected reason 'older than cutoff'; output:\n%s", out)
	}
	if !strings.Contains(out, prefix) {
		t.Fatalf("expected token prefix %s in offender list; output:\n%s", prefix, out)
	}
}

// Revoked tokens with NULL last_used_at must NOT be flagged as stale —
// they're no longer active and operators can't be expected to reactivate them.
func TestPreFlipAudit_RevokedRow_Ignored(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, revokedPrefix := issuePreFlipTestToken(t, dbPath, "revoked-provider")
	revokeTestToken(t, dbPath, revokedPrefix)
	_, freshPrefix := issuePreFlipTestToken(t, dbPath, "fresh-provider")
	backdateLastUsed(t, dbPath, freshPrefix, time.Now().UTC())

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h"})
	if stale {
		t.Fatalf("expected stale=false (only active row is fresh), got true; output:\n%s", out)
	}
	if !strings.Contains(out, "active_tokens=1") {
		t.Fatalf("expected active_tokens=1 (revoked row excluded); output:\n%s", out)
	}
}

// Near-boundary: a row stamped 1s ago must be considered fresh under a
// generous 30s cutoff regardless of CI scheduling jitter. (An earlier
// version used a 1s cutoff with 500ms backdate; the cushion was too
// small for slow CI runners.)
func TestPreFlipAudit_NearBoundary_Fresh(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, prefix := issuePreFlipTestToken(t, dbPath, "boundary-provider")
	backdateLastUsed(t, dbPath, prefix, time.Now().UTC().Add(-1*time.Second))

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "30s"})
	if stale {
		t.Fatalf("expected stale=false within 30s cutoff; output:\n%s", out)
	}
}

func TestPreFlipAudit_JSONMode(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, prefix := issuePreFlipTestToken(t, dbPath, "json-provider")
	backdateLastUsed(t, dbPath, prefix, time.Now().UTC().Add(-72*time.Hour))

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h", "--json"})
	if !stale {
		t.Fatalf("expected stale=true; output:\n%s", out)
	}
	var parsed struct {
		Cutoff       string `json:"cutoff"`
		MaxAge       string `json:"max_last_used_age"`
		ActiveTokens int    `json:"active_tokens"`
		StaleCount   int    `json:"stale_count"`
		Offenders    []struct {
			TokenPrefix string  `json:"token_prefix"`
			LastUsedAt  *string `json:"last_used_at"`
			Reason      string  `json:"reason"`
		} `json:"offenders"`
		SafeToFlip bool `json:"safe_to_flip"`
	}
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		t.Fatalf("json unmarshal: %v; output:\n%s", err, out)
	}
	if parsed.SafeToFlip {
		t.Fatalf("expected safe_to_flip=false, got true")
	}
	if parsed.ActiveTokens != 1 || parsed.StaleCount != 1 {
		t.Fatalf("counts wrong: active=%d stale=%d, want 1/1", parsed.ActiveTokens, parsed.StaleCount)
	}
	if len(parsed.Offenders) != 1 || parsed.Offenders[0].TokenPrefix != prefix {
		t.Fatalf("offender list mismatch: %+v want prefix=%s", parsed.Offenders, prefix)
	}
	if parsed.Offenders[0].LastUsedAt == nil {
		t.Fatalf("expected non-nil last_used_at for backdated row")
	}
}

// r2 H1: a typo'd --db path must fail closed, not create an empty SQLite file
// and silently return safe_to_flip=true.
func TestPreFlipAudit_MissingDBPath_FailsClosed(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "does-not-exist.db")
	var buf bytes.Buffer
	stale, err := preFlipAuditRun([]string{"--db", missing}, &buf)
	if err == nil {
		t.Fatalf("expected error for missing DB path, got nil; stale=%v output=%q", stale, buf.String())
	}
	if !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("expected 'does not exist' in error, got %v", err)
	}
	// Crucially: the missing path MUST NOT have been created.
	if _, statErr := osStat(missing); statErr == nil {
		t.Fatalf("missing DB path %q was created — fail-closed violated", missing)
	}
}

// r2 M1: a row with a non-canonical last_used_at must be flagged as stale,
// not pass via lex compare. Defense-in-depth against corruption / out-of-
// band writes. Covers BOTH:
//
//  1. time.Parse failure (offset format, garbage)
//  2. time.Parse success but non-canonical (fractional seconds — caught by
//     the round-trip check in r2.1, NOT by Go's layout match alone)
func TestPreFlipAudit_NonCanonicalTimestamp_FlagsAsStale(t *testing.T) {
	cases := []struct {
		name string
		raw  string
	}{
		{"offset_instead_of_Z", "2099-01-01T00:00:00+00:00"},
		{"fractional_seconds_Z", "2099-01-01T00:00:00.123Z"}, // r2.1 — Go's time.Parse permits this
		{"space_instead_of_T", "2099-01-01 00:00:00Z"},
		{"totally_garbage", "not-a-timestamp"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			dbPath := filepath.Join(t.TempDir(), "coordinator.db")
			_, prefix := issuePreFlipTestToken(t, dbPath, "corrupt-"+tc.name)
			writeRawLastUsed(t, dbPath, prefix, tc.raw)

			stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h"})
			if !stale {
				t.Fatalf("expected stale=true for non-canonical %q, got false; output:\n%s", tc.raw, out)
			}
			if !strings.Contains(out, "not canonical RFC3339Z") {
				t.Fatalf("expected canonical-format reason in offender list; output:\n%s", out)
			}
		})
	}
}

// r2 L1: JSON-mode coverage for a NULL last_used_at — confirms the offender
// field unmarshals to nil.
func TestPreFlipAudit_JSONMode_NullLastUsed(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	_, prefix := issuePreFlipTestToken(t, dbPath, "json-null-provider")

	stale, out := runPreFlipAudit(t, []string{"--db", dbPath, "--max-last-used-age", "24h", "--json"})
	if !stale {
		t.Fatalf("expected stale=true; output:\n%s", out)
	}
	var parsed struct {
		Offenders []struct {
			TokenPrefix string  `json:"token_prefix"`
			LastUsedAt  *string `json:"last_used_at"`
			Reason      string  `json:"reason"`
		} `json:"offenders"`
		SafeToFlip bool `json:"safe_to_flip"`
	}
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		t.Fatalf("json unmarshal: %v; output:\n%s", err, out)
	}
	if parsed.SafeToFlip {
		t.Fatalf("expected safe_to_flip=false; got true")
	}
	if len(parsed.Offenders) != 1 || parsed.Offenders[0].TokenPrefix != prefix {
		t.Fatalf("offender list mismatch: %+v want prefix=%s", parsed.Offenders, prefix)
	}
	if parsed.Offenders[0].LastUsedAt != nil {
		t.Fatalf("expected nil last_used_at for NULL row, got %v", *parsed.Offenders[0].LastUsedAt)
	}
}

func TestPreFlipAudit_RejectsZeroDuration(t *testing.T) {
	dbPath := filepath.Join(t.TempDir(), "coordinator.db")
	closeFreshDB(t, dbPath)
	var buf bytes.Buffer
	_, err := preFlipAuditRun([]string{"--db", dbPath, "--max-last-used-age", "0s"}, &buf)
	if err == nil || !strings.Contains(err.Error(), "must be positive") {
		t.Fatalf("expected positive-duration error, got %v", err)
	}
}

func runPreFlipAudit(t *testing.T, args []string) (stale bool, output string) {
	t.Helper()
	var buf bytes.Buffer
	stale, err := preFlipAuditRun(args, &buf)
	if err != nil {
		t.Fatalf("preFlipAuditRun: %v", err)
	}
	return stale, buf.String()
}

func issuePreFlipTestToken(t *testing.T, dbPath, providerID string) (id int64, tokenPrefix string) {
	t.Helper()
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	record, _, err := store.IssueToken(context.Background(), providerID, providerID+" provider")
	if err != nil {
		t.Fatalf("issue token: %v", err)
	}
	return record.ID, record.TokenPrefix
}

func revokeTestToken(t *testing.T, dbPath, tokenPrefix string) {
	t.Helper()
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	defer store.Close()
	if _, err := store.RevokeToken(context.Background(), tokenPrefix); err != nil {
		t.Fatalf("revoke token: %v", err)
	}
}

func closeFreshDB(t *testing.T, dbPath string) {
	t.Helper()
	store, err := auth.OpenStore(dbPath)
	if err != nil {
		t.Fatalf("open store: %v", err)
	}
	if err := store.Close(); err != nil {
		t.Fatalf("close store: %v", err)
	}
}

// backdateLastUsed UPDATEs the row's last_used_at to a specific past timestamp,
// bypassing the runtime stamping that always uses nowString(). Used to exercise
// the "stale by age" branch deterministically.
func backdateLastUsed(t *testing.T, dbPath, tokenPrefix string, when time.Time) {
	t.Helper()
	db, err := sql.Open("sqlite", dbPath)
	if err != nil {
		t.Fatalf("sql.Open backdate: %v", err)
	}
	defer db.Close()
	stamp := when.UTC().Format("2006-01-02T15:04:05Z")
	res, err := db.ExecContext(context.Background(),
		`UPDATE provider_tokens SET last_used_at = ? WHERE token_prefix = ?`,
		stamp, tokenPrefix)
	if err != nil {
		t.Fatalf("backdate UPDATE: %v", err)
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		t.Fatalf("backdate UPDATE matched 0 rows for token_prefix=%s", tokenPrefix)
	}
}
