package onboarding

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
	_ "modernc.org/sqlite"
)

// TestProviderTrustActivePredicateEvictsRevokedOrExpiredRoot exercises the
// SHARED provider-wide active-trust predicate (providerTrustActivePredicate) that
// backs the admission gate's live-trust re-check (LatestVerified, issue #582). It
// builds on trustRootActiveExists, the same active-trust-row fragment the
// tuple-aware revalidation sweep reuses (FIX B). The batched sweep query is
// Postgres-only (unnest/pq.Array), so the predicate is validated here on the
// SQLite harness via the SELECT EXISTS(...) form directly: a verified provider
// whose backing hardware_verification_trust root is revoked (expires_at set into
// the past) or has lapsed past a finite expiry reads as NOT active (would be
// evicted), while an unexpired root reads active.
func TestProviderTrustActivePredicateEvictsRevokedOrExpiredRoot(t *testing.T) {
	jobHash := strings.Repeat("c", 64)
	tests := []struct {
		name            string
		profileChip     string
		profileMemory   int
		profileVerified bool
		haveTrustRoot   bool
		trustExpiry     time.Duration // relative to now; 0 with haveTrustRoot => NULL (active)
		wantActive      bool
	}{
		{
			name:            "active unexpired root keeps session",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: true,
			haveTrustRoot:   true,
			wantActive:      true,
		},
		{
			name:            "future expiry keeps session",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: true,
			haveTrustRoot:   true,
			trustExpiry:     time.Hour,
			wantActive:      true,
		},
		{
			name:            "expired root evicts session",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: true,
			haveTrustRoot:   true,
			trustExpiry:     -time.Hour,
			wantActive:      false,
		},
		{
			name:            "revoked (no trust root) evicts session",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: true,
			haveTrustRoot:   false,
			wantActive:      false,
		},
		{
			name:            "demoted profile evicts session",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: false,
			haveTrustRoot:   true,
			wantActive:      false,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			db := openTrustRevalidationTestDB(t)
			generatedAt := time.Now().UTC().Add(-time.Minute)
			if _, err := db.Exec(`
INSERT INTO provider_hardware_profiles (
    provider_id, chip_normalized, unified_memory_gb, verified
) VALUES (?, ?, ?, ?)`, "mp-provider", tc.profileChip, tc.profileMemory, tc.profileVerified); err != nil {
				t.Fatalf("insert provider profile: %v", err)
			}
			evidence := fmt.Sprintf(`{"hardware":{"hardware_identity_hash":%q}}`, jobHash)
			if _, err := db.Exec(`
INSERT INTO hardware_verification_jobs (
    provider_id, status, chip_normalized, unified_memory_gb,
    generated_at, decision_reason, evidence
) VALUES (?, 'verified', ?, ?, ?, ?, ?)`,
				"mp-provider", "apple m4 max", 64, generatedAt,
				hardwareverify.VerifiedDecisionReason, evidence); err != nil {
				t.Fatalf("insert verified job: %v", err)
			}
			if tc.haveTrustRoot {
				var expiresAt any
				if tc.trustExpiry != 0 {
					expiresAt = time.Now().UTC().Add(tc.trustExpiry)
				}
				if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at
) VALUES (?, ?, ?, ?, ?)`,
					"mp-provider", jobHash, "apple m4 max", 64, expiresAt); err != nil {
					t.Fatalf("insert trust root: %v", err)
				}
			}

			var active bool
			if err := db.QueryRowContext(context.Background(), providerTrustActiveQuery("$3"),
				"mp-provider", hardwareverify.VerifiedDecisionReason, time.Now().UTC()).Scan(&active); err != nil {
				t.Fatalf("active-trust predicate query: %v", err)
			}
			if active != tc.wantActive {
				t.Fatalf("active-trust predicate = %v, want %v", active, tc.wantActive)
			}
		})
	}
}

// TestProviderTrustActivePredicatePerSourceRowsCoexist proves the terminal
// structural fix (issue #582): with the trust table keyed by (provider_id,
// hardware_identity_hash, source), an operator_api row and an inventory row for
// the SAME tuple coexist as two independent rows, and the source-agnostic
// active-trust predicate stays TRUE while EITHER is active. Expiring the
// operator_api row (an operator revoke) leaves the provider trusted via the
// still-active inventory root; only when BOTH are inactive does admission drop.
func TestProviderTrustActivePredicatePerSourceRowsCoexist(t *testing.T) {
	jobHash := strings.Repeat("d", 64)
	db := openTrustRevalidationTestDB(t)
	generatedAt := time.Now().UTC().Add(-time.Minute)
	if _, err := db.Exec(`
INSERT INTO provider_hardware_profiles (
    provider_id, chip_normalized, unified_memory_gb, verified
) VALUES (?, ?, ?, ?)`, "mp-provider", "apple m4 max", 64, true); err != nil {
		t.Fatalf("insert provider profile: %v", err)
	}
	evidence := fmt.Sprintf(`{"hardware":{"hardware_identity_hash":%q}}`, jobHash)
	if _, err := db.Exec(`
INSERT INTO hardware_verification_jobs (
    provider_id, status, chip_normalized, unified_memory_gb,
    generated_at, decision_reason, evidence
) VALUES (?, 'verified', ?, ?, ?, ?, ?)`,
		"mp-provider", "apple m4 max", 64, generatedAt,
		hardwareverify.VerifiedDecisionReason, evidence); err != nil {
		t.Fatalf("insert verified job: %v", err)
	}

	insertTrust := func(source string, expiresAt any) {
		t.Helper()
		if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at, source
) VALUES (?, ?, ?, ?, ?, ?)`,
			"mp-provider", jobHash, "apple m4 max", 64, expiresAt, source); err != nil {
			t.Fatalf("insert %s trust root: %v", source, err)
		}
	}
	// An inventory root and an operator_api root for the SAME tuple coexist as two
	// independent rows under the 3-column primary key.
	insertTrust("inventory", nil)
	insertTrust("operator_api", nil)
	var rowCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM hardware_verification_trust WHERE provider_id = ? AND hardware_identity_hash = ?`,
		"mp-provider", jobHash).Scan(&rowCount); err != nil {
		t.Fatalf("count trust rows: %v", err)
	}
	if rowCount != 2 {
		t.Fatalf("trust rows = %d, want 2 (inventory + operator_api coexist)", rowCount)
	}

	active := func() bool {
		t.Helper()
		var a bool
		if err := db.QueryRowContext(context.Background(), providerTrustActiveQuery("$3"),
			"mp-provider", hardwareverify.VerifiedDecisionReason, time.Now().UTC()).Scan(&a); err != nil {
			t.Fatalf("active-trust predicate query: %v", err)
		}
		return a
	}
	if !active() {
		t.Fatal("predicate = inactive with both roots active, want active")
	}
	// Operator revoke: expire ONLY the operator_api row. The independent inventory
	// root still backs the tuple, so the provider stays trusted.
	if _, err := db.Exec(`
UPDATE hardware_verification_trust SET expires_at = ?
 WHERE provider_id = ? AND hardware_identity_hash = ? AND source = 'operator_api'`,
		time.Now().UTC().Add(-time.Hour), "mp-provider", jobHash); err != nil {
		t.Fatalf("expire operator_api root: %v", err)
	}
	if !active() {
		t.Fatal("predicate = inactive after operator revoke, want active via inventory root")
	}
	// Now expire the inventory root too: no active row of any source remains, so the
	// provider is finally untrusted.
	if _, err := db.Exec(`
UPDATE hardware_verification_trust SET expires_at = ?
 WHERE provider_id = ? AND hardware_identity_hash = ? AND source = 'inventory'`,
		time.Now().UTC().Add(-time.Hour), "mp-provider", jobHash); err != nil {
		t.Fatalf("expire inventory root: %v", err)
	}
	if active() {
		t.Fatal("predicate = active with all roots expired, want inactive")
	}
}

// TestSessionsWithoutActiveTrustGuards covers the input guards that short-circuit
// before any DB round-trip: a nil store errors, and an empty admitted-tuple list
// returns no untrusted sessions without querying.
func TestSessionsWithoutActiveTrustGuards(t *testing.T) {
	var nilStore *PGStore
	if _, err := nilStore.SessionsWithoutActiveTrust(context.Background(), []AdmittedTuple{{ProviderID: "mp-provider"}}); err == nil {
		t.Fatal("nil store accepted, want error")
	}
	store := &PGStore{db: openTrustRevalidationTestDB(t)}
	out, err := store.SessionsWithoutActiveTrust(context.Background(), nil)
	if err != nil {
		t.Fatalf("empty tuple list: %v", err)
	}
	if len(out) != 0 {
		t.Fatalf("empty tuple list returned %v, want none", out)
	}
}

// TestTupleAwareTrustBindsToAdmittedRootNotProviderWide is the FIX B (issue #582)
// regression: a provider admitted via root A must be evicted once root A expires
// EVEN IF a second root B (different hardware_identity_hash, same provider_id)
// stays active — proving the revalidation is bound to the admitted hardware tuple,
// not to the provider_id. The batched unnest read is Postgres-only, so the
// tuple-matching predicate (trustRootActiveExists) is exercised directly on the
// SQLite harness: a session's admitted tuple reads active iff an active trust row
// matches that EXACT tuple.
func TestTupleAwareTrustBindsToAdmittedRootNotProviderWide(t *testing.T) {
	const chip = "apple m4 max"
	const mem = 64
	hashA := strings.Repeat("a", 64)
	hashB := strings.Repeat("b", 64)
	db := openTrustRevalidationTestDB(t)

	insertTrust := func(hash string, expiresAt any) {
		t.Helper()
		if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at, source
) VALUES (?, ?, ?, ?, ?, 'inventory')`,
			"mp-provider", hash, chip, mem, expiresAt); err != nil {
			t.Fatalf("insert trust root %s: %v", hash, err)
		}
	}
	// Two independent Macs behind one provider_id: root A (admitted this session)
	// and root B (a different Mac). Both active.
	insertTrust(hashA, nil)
	insertTrust(hashB, nil)

	// tupleActive mirrors what SessionsWithoutActiveTrust asks per admitted tuple:
	// does an active trust row match this EXACT tuple?
	query := "SELECT " + trustRootActiveExists("$1", "$2", "$3", "$4", "$5")
	tupleActive := func(hash string) bool {
		t.Helper()
		var active bool
		if err := db.QueryRowContext(context.Background(), query,
			"mp-provider", hash, chip, mem, time.Now().UTC()).Scan(&active); err != nil {
			t.Fatalf("tuple predicate query: %v", err)
		}
		return active
	}

	if !tupleActive(hashA) || !tupleActive(hashB) {
		t.Fatal("both admitted tuples should read active while both roots are active")
	}

	// Root A expires (the Mac that admitted this session is revoked/lapses) while
	// root B stays active. The provider_id still has an active trust root (B), but
	// the ADMITTED tuple (A) has lost trust → the session bound to A must evict.
	if _, err := db.Exec(`
UPDATE hardware_verification_trust SET expires_at = ?
 WHERE provider_id = ? AND hardware_identity_hash = ?`,
		time.Now().UTC().Add(-time.Hour), "mp-provider", hashA); err != nil {
		t.Fatalf("expire root A: %v", err)
	}
	if tupleActive(hashA) {
		t.Fatal("admitted tuple A still active after root A expired; a provider-wide check would wrongly keep the session (FIX B regression)")
	}
	if !tupleActive(hashB) {
		t.Fatal("tuple B should remain active; only root A expired")
	}
}

func openTrustRevalidationTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", fmt.Sprintf("file:trust-reval-%s?mode=memory&cache=shared", strings.ReplaceAll(t.Name(), "/", "-")))
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	for _, statement := range []string{
		`CREATE TABLE provider_hardware_profiles (
            provider_id TEXT PRIMARY KEY,
            chip_normalized TEXT NOT NULL,
            unified_memory_gb INTEGER NOT NULL,
            verified BOOLEAN NOT NULL
        )`,
		`CREATE TABLE hardware_verification_jobs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            provider_id TEXT NOT NULL,
            status TEXT NOT NULL,
            chip_normalized TEXT NOT NULL,
            unified_memory_gb INTEGER NOT NULL,
            generated_at TIMESTAMP NOT NULL,
            decision_reason TEXT NOT NULL,
            evidence BLOB NOT NULL
        )`,
		`CREATE TABLE hardware_verification_trust (
            provider_id TEXT NOT NULL,
            hardware_identity_hash TEXT NOT NULL,
            chip_normalized TEXT NOT NULL,
            unified_memory_gb INTEGER NOT NULL,
            expires_at TIMESTAMP NULL,
            source TEXT NOT NULL DEFAULT 'inventory',
            PRIMARY KEY (provider_id, hardware_identity_hash, source)
        )`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("create trust revalidation test schema: %v", err)
		}
	}
	return db
}
