//go:build integration

package onboarding

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"database/sql"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
	tc "github.com/testcontainers/testcontainers-go"
	tcpg "github.com/testcontainers/testcontainers-go/modules/postgres"
	"github.com/testcontainers/testcontainers-go/wait"

	statsmigrations "github.com/augstar/macprovider-coordinator/internal/stats/migrations"
)

const (
	referralAttemptPGImage = "postgres:16.4-alpine3.20@sha256:5660c2cbfea50c7a9127d17dc4e48543eedd3d7a41a595a2dfa572471e37e64c"
	referralAttemptPGPass  = "referral-attempt-test-password"
)

func skipOnMissingDocker(t *testing.T, err error) {
	t.Helper()
	msg := err.Error()
	if strings.Contains(msg, "Docker not found") ||
		strings.Contains(msg, "rootless Docker not found") ||
		strings.Contains(msg, "Cannot connect to the Docker daemon") {
		if os.Getenv("CI") == "true" || os.Getenv("GITHUB_ACTIONS") == "true" {
			return
		}
		t.Skipf("skip local Postgres integration without Docker: %v", err)
	}
}

func TestProviderRegistrationPreparedSurvivesNoncePrune(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	container, err := tcpg.Run(ctx, referralAttemptPGImage,
		tcpg.WithDatabase("referral_attempt"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(referralAttemptPGPass),
		tc.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	if err != nil {
		skipOnMissingDocker(t, err)
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_ = container.Terminate(cleanup)
	})
	dsn, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = db.Close() })
	if err := statsmigrations.Apply(ctx, db); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}

	store := &PGStore{db: db}
	publicKey, _, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	observedAt := time.Now().UTC().Truncate(time.Second)
	attemptTS := observedAt.Add(-30 * time.Second)
	if err := store.PrepareProviderRegistration(
		ctx, "provider-a", "203.0.113.7", "nonce-a", observedAt, attemptTS,
		publicKey, false, nil,
	); err != nil {
		t.Fatalf("prepare: %v", err)
	}
	if _, err := db.ExecContext(ctx, `DELETE FROM provider_register_nonces`); err != nil {
		t.Fatalf("prune nonces: %v", err)
	}
	prepared, err := store.ProviderRegistrationPrepared(ctx, "provider-a", "nonce-a", attemptTS)
	if err != nil || !prepared {
		t.Fatalf("prepared=%v err=%v after nonce prune", prepared, err)
	}
	if wrong, err := store.ProviderRegistrationPrepared(ctx, "provider-a", "nonce-a", observedAt); err != nil || wrong {
		t.Fatalf("server observed timestamp matched signed marker: prepared=%v err=%v", wrong, err)
	}
	if missing, err := store.ProviderRegistrationPrepared(ctx, "provider-missing", "nonce-z", attemptTS); err != nil || missing {
		t.Fatalf("missing attempt prepared=%v err=%v", missing, err)
	}
}

func TestProviderHardwareUpsertsRespectColumnLimitedGrants(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	container, err := tcpg.Run(ctx, referralAttemptPGImage,
		tcpg.WithDatabase("hardware_upsert"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(referralAttemptPGPass),
		tc.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	if err != nil {
		skipOnMissingDocker(t, err)
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_ = container.Terminate(cleanup)
	})
	adminDSN, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	adminDB, err := sql.Open("postgres", adminDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}

	const onboardingPassword = "hardware-upsert-test-password"
	if _, err := adminDB.ExecContext(ctx, `ALTER ROLE provider_onboarding PASSWORD '`+onboardingPassword+`'`); err != nil {
		t.Fatalf("set provider_onboarding password: %v", err)
	}
	onboardingURL, err := url.Parse(adminDSN)
	if err != nil {
		t.Fatalf("parse admin DSN: %v", err)
	}
	onboardingURL.User = url.UserPassword("provider_onboarding", onboardingPassword)
	onboardingDB, err := sql.Open("postgres", onboardingURL.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = onboardingDB.Close() })
	if err := onboardingDB.PingContext(ctx); err != nil {
		t.Fatalf("connect as provider_onboarding: %v", err)
	}
	store := &PGStore{db: onboardingDB}

	observedAt := time.Now().UTC().Truncate(time.Second)
	if err := store.UpsertProviderHardwareProfile(ctx, "provider-app", HardwareSummary{
		Chip:            "Apple M5",
		UnifiedMemoryGB: 32,
		MacOSVersion:    "26.5",
		AppVersion:      "1.8.42",
	}, observedAt); err != nil {
		t.Fatalf("initial app-track hardware upsert: %v", err)
	}
	if err := store.UpsertProviderHardwareProfile(ctx, "provider-app", HardwareSummary{
		Chip:            "Apple M5",
		UnifiedMemoryGB: 32,
		MacOSVersion:    "26.5.1",
		AppVersion:      "1.8.43",
	}, observedAt.Add(time.Second)); err != nil {
		t.Fatalf("conflicting app-track hardware upsert: %v", err)
	}

	if err := store.UpsertProviderHardwareProfile(ctx, "provider-cli", HardwareSummary{
		Chip:            "Apple M5",
		UnifiedMemoryGB: 32,
		MacOSVersion:    "26.5",
		AppVersion:      "1.8.42",
	}, observedAt.Add(-time.Second)); err != nil {
		t.Fatalf("seed CLI hardware profile: %v", err)
	}
	evidence := HardwareEvidenceRequest{
		SchemaVersion:          hardwareEvidenceSchemaVersion,
		ProviderID:             "provider-cli",
		GeneratedAt:            observedAt.Format(time.RFC3339),
		CandidateCatalogSHA256: "catalog-sha",
		RecommendedModel:       "model-a",
		ProbeProtocol:          hardwareEvidenceProbeProtocol,
		Hardware: HardwareEvidenceHardware{
			Chip:                 "Apple M5",
			MemoryGB:             32,
			BandwidthTier:        "C",
			Detected:             true,
			OSVersion:            "26.5",
			BinaryVersion:        "1.8.42",
			HardwareIdentityHash: "hardware-hash",
			ExecutableSHA256:     strings.Repeat("d", 64),
		},
		Benchmarks: []HardwareEvidenceBenchmark{{
			ModelKey:               "model-a",
			ModelID:                "mlx-community/model-a",
			SustainedTPS:           12.5,
			ArtifactSHA256:         "artifact-sha",
			CandidateCatalogSHA256: "catalog-sha",
			GeneratedAt:            observedAt.Format(time.RFC3339),
			BinaryVersion:          "1.8.42",
			HardwareIdentityHash:   "hardware-hash",
			CandidateRowIdentity:   strings.Repeat("e", 64),
		}},
	}
	record, err := store.InsertHardwareVerificationJob(ctx, "provider-cli", evidence, observedAt)
	if err != nil {
		t.Fatalf("conflicting CLI hardware upsert: %v", err)
	}
	if record.JobID == 0 || record.Status != hardwareEvidenceJobPending {
		t.Fatalf("hardware evidence record = %+v, want queued pending job", record)
	}

	if _, err := onboardingDB.QueryContext(ctx, `SELECT source FROM provider_hardware_profiles LIMIT 1`); err == nil {
		t.Fatal("provider_onboarding unexpectedly gained direct source read")
	} else if !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("provider_onboarding source read error = %q, want permission denied", err)
	}
}

func TestListWaitingTrustJobsReportsChipProfilePresenceWithRuntimeRole(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	container, err := tcpg.Run(ctx, referralAttemptPGImage,
		tcpg.WithDatabase("waiting_trust"),
		tcpg.WithUsername("postgres"),
		tcpg.WithPassword(referralAttemptPGPass),
		tc.WithWaitStrategy(wait.ForLog("database system is ready to accept connections").WithOccurrence(2).WithStartupTimeout(60*time.Second)),
	)
	if err != nil {
		skipOnMissingDocker(t, err)
		t.Fatalf("start postgres: %v", err)
	}
	t.Cleanup(func() {
		cleanup, cleanupCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cleanupCancel()
		_ = container.Terminate(cleanup)
	})
	adminDSN, err := container.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		t.Fatal(err)
	}
	adminDB, err := sql.Open("postgres", adminDSN)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = adminDB.Close() })
	if err := statsmigrations.Apply(ctx, adminDB); err != nil {
		t.Fatalf("apply migrations: %v", err)
	}

	const onboardingPassword = "waiting-trust-test-password"
	if _, err := adminDB.ExecContext(ctx, `ALTER ROLE provider_onboarding PASSWORD '`+onboardingPassword+`'`); err != nil {
		t.Fatalf("set provider_onboarding password: %v", err)
	}
	onboardingURL, err := url.Parse(adminDSN)
	if err != nil {
		t.Fatalf("parse admin DSN: %v", err)
	}
	onboardingURL.User = url.UserPassword("provider_onboarding", onboardingPassword)
	onboardingDB, err := sql.Open("postgres", onboardingURL.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = onboardingDB.Close() })
	if err := onboardingDB.PingContext(ctx); err != nil {
		t.Fatalf("connect as provider_onboarding: %v", err)
	}

	submitted := time.Now().UTC().Truncate(time.Second)
	if _, err := adminDB.ExecContext(ctx, `
INSERT INTO chip_hardware_profiles
    (chip_normalized, display_chip, memory_bandwidth_gb_per_s, network_power_kw, gpu_cores, cpu_cores)
VALUES
    ('apple m4 pro', 'Apple M4 Pro', 273, 0.065, 20, 14)
ON CONFLICT (chip_normalized) DO NOTHING`); err != nil {
		t.Fatalf("seed chip profile: %v", err)
	}
	for _, job := range []struct {
		providerID     string
		chip           string
		chipNormalized string
		memoryGB       int
		hash           string
		evidenceSHA    string
	}{
		{"provider-present", "Apple M4 Pro", "apple m4 pro", 24, "hash-present", "sha-present"},
		{"provider-missing", "Apple M6", "apple m6", 32, "hash-missing", "sha-missing"},
	} {
		if _, err := adminDB.ExecContext(ctx, `
INSERT INTO hardware_verification_jobs (
    provider_id,
    source,
    status,
    chip,
    chip_normalized,
    unified_memory_gb,
    generated_at,
    submitted_at,
    decision_reason,
    evidence,
    evidence_sha256
) VALUES (
    $1,
    'autotune',
    'waiting_trust',
    $2,
    $3,
    $4,
    $5,
    $5,
    'hardware-verifier.v2:missing_trusted_hardware_identity',
    jsonb_build_object('hardware', jsonb_build_object('hardware_identity_hash', $6::text)),
    $7
)`, job.providerID, job.chip, job.chipNormalized, job.memoryGB, submitted, job.hash, job.evidenceSHA); err != nil {
			t.Fatalf("seed waiting trust job %s: %v", job.providerID, err)
		}
	}

	store := &PGStore{db: onboardingDB}
	if err := store.Smoke(ctx); err != nil {
		t.Fatalf("provider_onboarding smoke: %v", err)
	}
	jobs, err := store.ListWaitingTrustJobs(ctx, 0, WaitingTrustJobsPageCap)
	if err != nil {
		t.Fatalf("list waiting trust jobs: %v", err)
	}
	if len(jobs) != 2 {
		t.Fatalf("waiting trust jobs length = %d, want 2: %+v", len(jobs), jobs)
	}
	got := map[string]bool{}
	for _, job := range jobs {
		got[job.ProviderID] = job.ChipProfilePresent
	}
	if got["provider-present"] != true {
		t.Fatalf("provider-present ChipProfilePresent = %t, want true", got["provider-present"])
	}
	if got["provider-missing"] != false {
		t.Fatalf("provider-missing ChipProfilePresent = %t, want false", got["provider-missing"])
	}
	if _, err := onboardingDB.QueryContext(ctx, `SELECT display_chip FROM chip_hardware_profiles LIMIT 1`); err == nil {
		t.Fatal("provider_onboarding unexpectedly gained direct display_chip read")
	} else if !strings.Contains(err.Error(), "permission denied") {
		t.Fatalf("provider_onboarding display_chip read error = %q, want permission denied", err)
	}
}
