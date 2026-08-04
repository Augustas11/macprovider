package autotune

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/augstar/macprovider-coordinator/internal/stats/hardwareverify"
	_ "modernc.org/sqlite"
)

func TestLatestVerifiedRequiresCurrentVerifiedHardwareTuple(t *testing.T) {
	generatedAt := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	// The verified job's evidence carries hardware_identity_hash = c*64 (see
	// mustVerifiedEvidenceJSON). An ACTIVE trust root for the job tuple (apple m4
	// max / 64 / that hash) backs the admittable cases; trustExpired parks an
	// already-expired root so FIX 4's live-trust re-check must reject even a
	// verified profile.
	jobHash := strings.Repeat("c", 64)
	tests := []struct {
		name            string
		profileChip     string
		profileMemory   int
		profileVerified bool
		trustExpired    bool
		wantOK          bool
	}{
		{
			name:            "current verified exact tuple admits",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: true,
			wantOK:          true,
		},
		{
			name:            "changed chip rejects old verified job",
			profileChip:     "apple m3 max",
			profileMemory:   64,
			profileVerified: true,
		},
		{
			name:            "changed memory rejects old verified job",
			profileChip:     "apple m4 max",
			profileMemory:   32,
			profileVerified: true,
		},
		{
			name:            "unverified current tuple rejects old verified job",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: false,
		},
		{
			// FIX 4 (round-6): verified bit is TRUE and the profile tuple matches,
			// but the backing trust root is expired — admission must reject.
			name:            "expired trust root rejects verified profile",
			profileChip:     "apple m4 max",
			profileMemory:   64,
			profileVerified: true,
			trustExpired:    true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			db := openAutotuneEvidenceTestDB(t)
			if _, err := db.Exec(`
INSERT INTO provider_hardware_profiles (
    provider_id, chip_normalized, unified_memory_gb, verified
) VALUES (?, ?, ?, ?)`, "mp-provider", tc.profileChip, tc.profileMemory, tc.profileVerified); err != nil {
				t.Fatalf("insert provider profile: %v", err)
			}
			if _, err := db.Exec(`
INSERT INTO hardware_verification_jobs (
    provider_id, status, chip_normalized, unified_memory_gb,
    generated_at, decision_reason, evidence
) VALUES (?, 'verified', ?, ?, ?, ?, ?)`,
				"mp-provider", "apple m4 max", 64, generatedAt,
				hardwareverify.VerifiedDecisionReason, mustVerifiedEvidenceJSON(t, generatedAt)); err != nil {
				t.Fatalf("insert verified job: %v", err)
			}
			// Back the job tuple with a trust root: NULL expiry = active, or an
			// already-past expiry for the expired-root case.
			var expiresAt any
			if tc.trustExpired {
				expiresAt = generatedAt.Add(-time.Hour)
			}
			if _, err := db.Exec(`
INSERT INTO hardware_verification_trust (
    provider_id, hardware_identity_hash, chip_normalized, unified_memory_gb, expires_at
) VALUES (?, ?, ?, ?, ?)`,
				"mp-provider", jobHash, "apple m4 max", 64, expiresAt); err != nil {
				t.Fatalf("insert trust root: %v", err)
			}

			store := NewPGEvidenceStore(db)
			store.now = func() time.Time { return generatedAt.Add(time.Hour) }
			evidence, ok, err := store.LatestVerified(context.Background(), "mp-provider", 24*time.Hour)
			if err != nil {
				t.Fatalf("LatestVerified: %v", err)
			}
			if ok != tc.wantOK {
				t.Fatalf("LatestVerified ok = %v, want %v (evidence=%+v)", ok, tc.wantOK, evidence)
			}
			if tc.wantOK && (len(evidence.Benchmarks) != 1 || evidence.Benchmarks[0].ModelKey != "model") {
				t.Fatalf("unexpected verified evidence: %+v", evidence)
			}
		})
	}
}

func openAutotuneEvidenceTestDB(t *testing.T) *sql.DB {
	t.Helper()
	db, err := sql.Open("sqlite", fmt.Sprintf("file:autotune-evidence-%s?mode=memory&cache=shared", strings.ReplaceAll(t.Name(), "/", "-")))
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
            PRIMARY KEY (provider_id, hardware_identity_hash)
        )`,
	} {
		if _, err := db.Exec(statement); err != nil {
			t.Fatalf("create evidence test schema: %v", err)
		}
	}
	return db
}

func TestDecodeVerifiedEvidenceRequiresImmutableBindings(t *testing.T) {
	generatedAt := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	raw := mustVerifiedEvidenceJSON(t, generatedAt)
	evidence, err := decodeVerifiedEvidence(raw, generatedAt, generatedAt.Add(-time.Hour))
	if err != nil {
		t.Fatalf("decodeVerifiedEvidence: %v", err)
	}
	if len(evidence.Benchmarks) != 1 || evidence.Benchmarks[0].ModelKey != "model" {
		t.Fatalf("unexpected evidence: %+v", evidence)
	}
}

func TestDecodeVerifiedEvidenceRejectsReboundOrStaleRows(t *testing.T) {
	generatedAt := time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)
	tests := []struct {
		name   string
		mutate func(map[string]any)
	}{
		{
			name: "top timestamp rebound",
			mutate: func(payload map[string]any) {
				payload["generated_at"] = generatedAt.Add(time.Minute).Format(time.RFC3339)
			},
		},
		{
			name: "catalog rebound",
			mutate: func(payload map[string]any) {
				payload["benchmarks"].([]map[string]any)[0]["candidate_catalog_sha256"] = strings.Repeat("a", 64)
			},
		},
		{
			name:   "binary rebound",
			mutate: func(payload map[string]any) { payload["benchmarks"].([]map[string]any)[0]["binary_version"] = "1.8.0" },
		},
		{
			name: "hardware rebound",
			mutate: func(payload map[string]any) {
				payload["benchmarks"].([]map[string]any)[0]["hardware_identity_hash"] = strings.Repeat("a", 64)
			},
		},
		{
			name: "benchmark older than admission ttl",
			mutate: func(payload map[string]any) {
				payload["benchmarks"].([]map[string]any)[0]["generated_at"] = generatedAt.Add(-2 * time.Hour).Format(time.RFC3339)
			},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var payload map[string]any
			if err := json.Unmarshal(mustVerifiedEvidenceJSON(t, generatedAt), &payload); err != nil {
				t.Fatal(err)
			}
			benchmarks := payload["benchmarks"].([]any)
			payload["benchmarks"] = []map[string]any{benchmarks[0].(map[string]any)}
			tc.mutate(payload)
			raw, err := json.Marshal(payload)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := decodeVerifiedEvidence(raw, generatedAt, generatedAt.Add(-time.Hour)); err == nil {
				t.Fatal("decodeVerifiedEvidence succeeded, want binding rejection")
			}
		})
	}
}

func mustVerifiedEvidenceJSON(t *testing.T, generatedAt time.Time) []byte {
	t.Helper()
	payload := map[string]any{
		"generated_at":             generatedAt.Format(time.RFC3339),
		"candidate_catalog_sha256": strings.Repeat("b", 64),
		"probe_protocol":           "spec-023-harmony-stream.v2",
		"hardware": map[string]any{
			"binary_version":         "1.7.9",
			"hardware_identity_hash": strings.Repeat("c", 64),
			"executable_sha256":      strings.Repeat("e", 64),
		},
		"benchmarks": []map[string]any{{
			"model_key":                "model",
			"model_id":                 "mlx-community/model",
			"sustained_tps":            42.5,
			"ttft_ms":                  1200,
			"artifact_sha256":          strings.Repeat("d", 64),
			"candidate_catalog_sha256": strings.Repeat("b", 64),
			"generated_at":             generatedAt.Format(time.RFC3339),
			"binary_version":           "1.7.9",
			"hardware_identity_hash":   strings.Repeat("c", 64),
			"candidate_row_identity":   strings.Repeat("f", 64),
		}},
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}
